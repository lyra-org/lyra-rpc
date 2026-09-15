// This Source Code Form is subject to the terms of the Lyra Public License,
// v1.0. If a copy of the Lyra Public License was not distributed with this
// file, You can obtain one here:
// www.meshiplaw.com/lyra.

const App = @This();

const std = @import("std");
const Config = @import("Config.zig");
const discordpkg = @import("discord.zig");
const lyra = @import("lyra.zig");
const presence = @import("presence.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = std.log.scoped(.app);

const litterbox_api_url = "https://litterbox.catbox.moe/resources/internals/api.php";
const imgur_api_url = "https://api.imgur.com/3/image";

// Limits apply to decoded bodies, including chunked or compressed responses.
const api_response_limit = 1024 * 1024;
const cover_response_limit = 20 * 1024 * 1024;
const upload_response_limit = 64 * 1024;

const fallback_image = "logo-dark";

/// A change in the computed activity start larger than this is treated
/// as a seek and pushes a new presence; smaller drift is clock jitter.
const seek_detection_threshold_ms = 2000;

const multipart_boundary = "----lyra-rpc-zig-boundary";
const multipart_content_type = "multipart/form-data; boundary=" ++ multipart_boundary;

alloc: Allocator,
io: Io,
config: Config,

/// `config.base_url` without a trailing slash.
base_url: []const u8,

/// Precomputed `Authorization` header values. Empty means no header.
auth_header: []const u8 = "",
imgur_auth_header: []const u8 = "",

presence_inputs: presence.Inputs,

http_client: std.http.Client,

/// Owns release id keys and uploaded URL values.
cover_cache: std.StringHashMapUnmanaged([]u8) = .empty,

/// Owns release id keys.
missing_cover_cache: std.StringHashMapUnmanaged(void) = .empty,

last: LastPlayback = .{},

/// Requested id of the cached track, independent of the last successful
/// publication because fetching can succeed while publishing fails.
cached_track_id: []u8 = &.{},

/// Metadata for `cached_track_id`, retained across publication retries.
cached_track: ?std.json.Parsed(lyra.Track) = null,

release_details: ReleaseDetailsCache = .{},

/// Borrows an uploaded URL from `cover_cache` or uses `fallback_image`.
cached_image: []const u8 = fallback_image,

/// Suppresses repeated error logs.
playback_fetch_failed: bool = false,

discord: discordpkg.Client,

const LastPlayback = struct {
    /// Owned copy of the track id, empty when nothing is pushed.
    track_id: []u8 = &.{},

    /// Null when no presence is currently shown.
    state: ?lyra.PlaybackState = null,
    duration_ms: ?u64 = null,
    activity_start_ms: ?u64 = null,

    fn deinit(self: *LastPlayback, alloc: Allocator) void {
        alloc.free(self.track_id);
        self.* = undefined;
    }

    fn active(self: LastPlayback) bool {
        return self.state != null;
    }

    fn needsUpdate(
        self: LastPlayback,
        playback: lyra.CurrentPlayback,
        timestamps: ?discordpkg.Timestamps,
    ) bool {
        if (!std.mem.eql(u8, playback.track_id, self.track_id)) return true;
        if (playback.state != self.state) return true;
        if (playback.duration_ms != self.duration_ms) return true;

        if (timestamps) |value| {
            const last_start = self.activity_start_ms orelse return true;
            if (absDiff(value.start, last_start) > seek_detection_threshold_ms) return true;
        }

        return false;
    }

    fn set(
        self: *LastPlayback,
        alloc: Allocator,
        playback: lyra.CurrentPlayback,
        timestamps: ?discordpkg.Timestamps,
    ) Allocator.Error!void {
        if (!std.mem.eql(u8, playback.track_id, self.track_id)) {
            const track_id = try alloc.dupe(u8, playback.track_id);
            alloc.free(self.track_id);
            self.track_id = track_id;
        }
        self.state = playback.state;
        self.duration_ms = playback.duration_ms;
        self.activity_start_ms = if (timestamps) |value| value.start else null;
    }

    fn clear(self: *LastPlayback, alloc: Allocator) void {
        alloc.free(self.track_id);
        self.* = .{};
    }
};

/// Expands cached includes as needed; remembers failures for embedded-release fallback.
const ReleaseDetailsCache = struct {
    parsed: ?std.json.Parsed(lyra.Release) = null,
    includes: lyra.ReleaseLookupIncludes = .{},
    failed: bool = false,

    fn get(self: *ReleaseDetailsCache, includes: lyra.ReleaseLookupIncludes) ?lyra.Release {
        const parsed = self.parsed orelse return null;
        if (!self.includes.contains(includes)) return null;
        return parsed.value;
    }

    fn clear(self: *ReleaseDetailsCache) void {
        if (self.parsed) |parsed| parsed.deinit();
        self.* = .{};
    }
};

const HttpResponse = struct {
    status: std.http.Status,
    body: []u8,

    fn deinit(self: *HttpResponse, alloc: Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

/// Retains rejected responses so their bodies can be logged.
const PlaybackResult = union(enum) {
    active: ActivePlayback,
    rejected: HttpResponse,
};

const ActivePlayback = struct {
    /// Owns the strings in `playback`. Null when nothing is playing.
    parsed: ?std.json.Parsed(lyra.PlaybackPage) = null,
    playback: ?lyra.CurrentPlayback = null,

    fn deinit(self: *ActivePlayback) void {
        if (self.parsed) |parsed| parsed.deinit();
        self.* = undefined;
    }
};

const MultipartField = struct {
    name: []const u8,
    value: []const u8,
};

const ImgurResponse = struct {
    data: struct {
        link: []const u8 = "",
    } = .{},
};

pub const HttpError = std.http.Client.FetchError || Allocator.Error || error{ResponseTooLarge};

/// Checks each write before allowing the response buffer to grow.
const ResponseWriter = struct {
    writer: Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
    body: Io.Writer.Allocating,
    limit: usize,
    too_large: bool = false,

    fn drain(writer: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *ResponseWriter = @fieldParentPtr("writer", writer);
        var remaining = self.limit - self.body.written().len;
        for (data, 0..) |part, i| {
            const repetitions = if (i == data.len - 1) splat else 1;
            if (part.len != 0 and repetitions > remaining / part.len) {
                self.too_large = true;
                return error.WriteFailed;
            }
            remaining -= part.len * repetitions;
        }
        return self.body.writer.writeSplat(data, splat);
    }
};

pub const ApiError = HttpError ||
    std.json.ParseError(std.json.Scanner) ||
    error{ UnexpectedApiStatus, ReleaseNotFound };

pub fn init(
    alloc: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
    config: Config,
) Allocator.Error!App {
    const auth_header = if (config.auth_token.len > 0)
        try std.fmt.allocPrint(alloc, "Bearer {s}", .{config.auth_token})
    else
        &.{};
    errdefer alloc.free(auth_header);

    const imgur_auth_header = if (config.images.uploader == .imgur)
        try std.fmt.allocPrint(alloc, "Client-ID {s}", .{config.images.imgur_client_id})
    else
        &.{};
    errdefer alloc.free(imgur_auth_header);

    return .{
        .alloc = alloc,
        .io = io,
        .config = config,
        .base_url = std.mem.trimEnd(u8, config.base_url, "/"),
        .auth_header = auth_header,
        .imgur_auth_header = imgur_auth_header,
        .presence_inputs = presence.inputs(config.presence),
        .http_client = .{ .allocator = alloc, .io = io },
        .discord = discordpkg.Client.init(alloc, io, environ_map),
    };
}

pub fn deinit(self: *App) void {
    self.discord.logout();
    self.clearCachedTrack();
    self.last.deinit(self.alloc);

    var cover_it = self.cover_cache.iterator();
    while (cover_it.next()) |entry| {
        self.alloc.free(entry.key_ptr.*);
        self.alloc.free(entry.value_ptr.*);
    }
    self.cover_cache.deinit(self.alloc);

    var missing_it = self.missing_cover_cache.keyIterator();
    while (missing_it.next()) |key| self.alloc.free(key.*);
    self.missing_cover_cache.deinit(self.alloc);

    self.http_client.deinit();
    self.alloc.free(self.auth_header);
    self.alloc.free(self.imgur_auth_header);
    self.* = undefined;
}

/// Logs errors and leaves polling active.
pub fn poll(self: *App) void {
    var result = self.fetchActivePlayback() catch |err| {
        if (!self.playback_fetch_failed) {
            self.logRequestError("Error fetching playback", err);
            self.playback_fetch_failed = true;
        }
        return;
    };
    var active_playback = switch (result) {
        .active => |active| active,
        .rejected => |*resp| {
            defer resp.deinit(self.alloc);
            if (!self.playback_fetch_failed) {
                log.err("{f}", .{lyra.ApiStatusError{
                    .label = "Error fetching playback",
                    .status = resp.status,
                    .body = resp.body,
                }});
                self.playback_fetch_failed = true;
            }
            return;
        },
    };
    defer active_playback.deinit();

    self.playback_fetch_failed = false;
    const snapshot_now = Io.Timestamp.now(self.io, .real);

    const playback = active_playback.playback orelse {
        self.clearPresence();
        return;
    };

    switch (playback.state) {
        .playing, .paused => {},
        .unknown => {
            self.clearPresence();
            return;
        },
    }

    self.updatePresence(playback, snapshot_now) catch |err| {
        log.err("error setting activity err={}", .{err});
    };
}

fn lyraGet(self: *App, path: []const u8) HttpError!HttpResponse {
    const url = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ self.base_url, path });
    defer self.alloc.free(url);
    return self.httpGet(url, true, api_response_limit);
}

/// Credentials are only sent for paths, never to an arbitrary host.
fn lyraGetUrlOrPath(self: *App, url_or_path: []const u8) HttpError!HttpResponse {
    if (std.mem.startsWith(u8, url_or_path, "http://") or
        std.mem.startsWith(u8, url_or_path, "https://"))
    {
        return self.httpGet(url_or_path, false, cover_response_limit);
    }
    const url = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ self.base_url, url_or_path });
    defer self.alloc.free(url);
    return self.httpGet(url, true, cover_response_limit);
}

fn httpGet(self: *App, url: []const u8, include_auth: bool, limit: usize) HttpError!HttpResponse {
    var request_headers: std.http.Client.Request.Headers = .{};
    if (include_auth and self.auth_header.len > 0) {
        request_headers.authorization = .{ .override = self.auth_header };
    }

    return self.fetchBounded(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = request_headers,
    }, limit);
}

fn fetchBounded(self: *App, options: std.http.Client.FetchOptions, limit: usize) HttpError!HttpResponse {
    var response_writer: ResponseWriter = .{ .body = .init(self.alloc), .limit = limit };
    defer response_writer.body.deinit();
    var bounded_options = options;
    bounded_options.response_writer = &response_writer.writer;
    const result = self.http_client.fetch(bounded_options) catch |err| {
        if (response_writer.too_large) return error.ResponseTooLarge;
        return err;
    };
    return .{ .status = result.status, .body = try response_writer.body.toOwnedSlice() };
}

fn fetchActivePlayback(self: *App) ApiError!PlaybackResult {
    var path = try lyra.activePlaybackPath(self.alloc, null);
    defer self.alloc.free(path);

    while (true) {
        var resp = try self.lyraGet(path);
        if (resp.status != .ok) return .{ .rejected = resp };
        defer resp.deinit(self.alloc);

        const parsed = try std.json.parseFromSlice(
            lyra.PlaybackPage,
            self.alloc,
            resp.body,
            lyra.json_parse_options,
        );
        errdefer parsed.deinit();
        if (parsed.value.firstCurrent()) |playback| {
            return .{ .active = .{ .parsed = parsed, .playback = playback } };
        }
        const cursor = parsed.value.next_cursor orelse {
            parsed.deinit();
            return .{ .active = .{} };
        };
        const next_path = try lyra.activePlaybackPath(self.alloc, cursor);
        parsed.deinit();
        self.alloc.free(path);
        path = next_path;
    }
}

fn fetchTrack(self: *App, id: []const u8) ApiError!std.json.Parsed(lyra.Track) {
    const path = try lyra.trackLookupPath(self.alloc, id);
    defer self.alloc.free(path);

    var resp = try self.lyraGet(path);
    defer resp.deinit(self.alloc);

    if (resp.status != .ok) return error.UnexpectedApiStatus;
    return std.json.parseFromSlice(lyra.Track, self.alloc, resp.body, lyra.json_parse_options);
}

fn fetchReleaseDetails(
    self: *App,
    id: []const u8,
    includes: lyra.ReleaseLookupIncludes,
) ApiError!std.json.Parsed(lyra.Release) {
    const path = try lyra.releaseLookupPath(self.alloc, id, includes);
    defer self.alloc.free(path);

    var resp = try self.lyraGet(path);
    defer resp.deinit(self.alloc);

    if (resp.status == .not_found) return error.ReleaseNotFound;
    if (resp.status != .ok) return error.UnexpectedApiStatus;
    return std.json.parseFromSlice(lyra.Release, self.alloc, resp.body, lyra.json_parse_options);
}

/// Caches by release id; returns an empty URL when no cover exists.
fn uploadCover(
    self: *App,
    release_id: []const u8,
    includes: lyra.ReleaseLookupIncludes,
) ![]const u8 {
    if (self.config.images.uploader == .none) return error.ImageUploadsDisabled;
    if (self.cover_cache.get(release_id)) |url| return url;
    if (self.missing_cover_cache.contains(release_id)) return "";

    const release = try self.ensureReleaseDetails(release_id, includes.merge(.{ .covers = true }));

    const cover = release.cover orelse {
        try self.rememberMissingCover(release_id);
        return "";
    };

    var resp = try self.lyraGetUrlOrPath(cover.url);
    defer resp.deinit(self.alloc);

    if (resp.status == .not_found) {
        try self.rememberMissingCover(release_id);
        return "";
    }
    if (resp.status != .ok) return error.UnexpectedApiStatus;

    const uploaded_url = switch (self.config.images.uploader) {
        .imgur => try self.uploadToImgur(resp.body),
        .litterbox => try self.uploadToLitterbox(resp.body),
        .none => unreachable,
    };
    errdefer self.alloc.free(uploaded_url);

    const key = try self.alloc.dupe(u8, release_id);
    errdefer self.alloc.free(key);

    try self.cover_cache.put(self.alloc, key, uploaded_url);
    return uploaded_url;
}

fn rememberMissingCover(self: *App, release_id: []const u8) Allocator.Error!void {
    const key = try self.alloc.dupe(u8, release_id);
    errdefer self.alloc.free(key);
    try self.missing_cover_cache.put(self.alloc, key, {});
}

fn uploadToLitterbox(self: *App, image: []const u8) ![]u8 {
    var resp = try self.postMultipart(litterbox_api_url, &.{
        .{ .name = "reqtype", .value = "fileupload" },
        .{ .name = "time", .value = "72h" },
    }, "fileToUpload", image, null);
    defer resp.deinit(self.alloc);

    if (resp.status != .ok) return error.UnexpectedApiStatus;
    return self.alloc.dupe(u8, lyra.trimSpace(resp.body));
}

fn uploadToImgur(self: *App, image: []const u8) ![]u8 {
    var resp = try self.postMultipart(imgur_api_url, &.{
        .{ .name = "type", .value = "file" },
    }, "image", image, self.imgur_auth_header);
    defer resp.deinit(self.alloc);

    if (resp.status != .ok) return error.UnexpectedApiStatus;

    var parsed = try std.json.parseFromSlice(ImgurResponse, self.alloc, resp.body, lyra.json_parse_options);
    defer parsed.deinit();

    return self.alloc.dupe(u8, parsed.value.data.link);
}

fn postMultipart(
    self: *App,
    url: []const u8,
    fields: []const MultipartField,
    file_field_name: []const u8,
    file_data: []const u8,
    authorization: ?[]const u8,
) !HttpResponse {
    var payload_writer: Io.Writer.Allocating = .init(self.alloc);
    defer payload_writer.deinit();

    for (fields) |field| {
        try payload_writer.writer.print(
            "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"\r\n\r\n{s}\r\n",
            .{ multipart_boundary, field.name, field.value },
        );
    }
    try payload_writer.writer.print(
        "--{s}\r\n" ++
            "Content-Disposition: form-data; name=\"{s}\"; filename=\"cover.jpg\"\r\n" ++
            "Content-Type: image/jpeg\r\n\r\n",
        .{ multipart_boundary, file_field_name },
    );
    try payload_writer.writer.writeAll(file_data);
    try payload_writer.writer.print("\r\n--{s}--\r\n", .{multipart_boundary});

    var request_headers: std.http.Client.Request.Headers = .{
        .content_type = .{ .override = multipart_content_type },
    };
    if (authorization) |value| request_headers.authorization = .{ .override = value };

    return self.fetchBounded(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload_writer.written(),
        .headers = request_headers,
    }, upload_response_limit);
}

fn clearPresence(self: *App) void {
    if (self.last.active()) {
        self.discord.clearActivity() catch |err| {
            log.err("error clearing activity err={}", .{err});
            return;
        };
        log.info("no active playback, cleared presence", .{});
    }
    self.last.clear(self.alloc);
    self.clearCachedTrack();
}

fn updatePresence(self: *App, playback: lyra.CurrentPlayback, snapshot_now: Io.Timestamp) !void {
    const timestamps = playbackTimestamps(playback, snapshot_now);
    if (!self.last.needsUpdate(playback, timestamps)) return;

    const track_changed = !std.mem.eql(u8, playback.track_id, self.last.track_id);
    if (self.cachedTrack(playback.track_id) == null) try self.loadTrack(playback.track_id);

    const track = self.cachedTrack(playback.track_id) orelse return error.MissingCachedTrack;
    if (track_changed or playback.state != self.last.state) {
        const line = try lyra.playbackLogLine(self.alloc, playback.state, track.*);
        defer self.alloc.free(line);
        log.info("{s}", .{line});
    }

    const inputs = self.presence_inputs;
    const release = try self.presenceRelease(track.*, inputs);

    const artists_text = if (inputs.track_artists)
        try self.joinArtistNames(lyra.trackArtists(track.*))
    else
        "";
    defer self.alloc.free(artists_text);

    const release_artists_text = if (inputs.release_artists and release != null)
        try self.joinArtistNames(lyra.releaseArtists(release.?))
    else
        "";
    defer self.alloc.free(release_artists_text);

    const release_genres_text = if (inputs.release_genres and release != null)
        try std.mem.join(self.alloc, self.config.presence.list_separator, lyra.releaseGenres(release.?))
    else
        "";
    defer self.alloc.free(release_genres_text);

    var text = try presence.render(self.alloc, self.config.presence, .{
        .track = track.*,
        .release = release,
        .artists = artists_text,
        .release_artists = release_artists_text,
        .release_genres = release_genres_text,
    });
    defer text.deinit(self.alloc);

    var activity: discordpkg.Activity = .{
        .details = text.title,
        .state = text.subtitle,
        .assets = .{
            .large_image = self.cached_image,
            .large_text = text.image_text,
        },
    };

    if (timestamps) |value| {
        activity.timestamps = value;
        activity.assets.small_image = "playing";
        activity.assets.small_text = lyra.PlaybackState.playing.label();
    } else {
        activity.assets.small_image = discordpkg.paused_image;
        activity.assets.small_text = lyra.PlaybackState.paused.label();
    }

    // Prepare owned state before publishing so the commit cannot fail.
    var next: LastPlayback = .{};
    defer next.deinit(self.alloc);
    try next.set(self.alloc, playback, timestamps);
    try self.discord.setActivity(activity);
    std.mem.swap(LastPlayback, &self.last, &next);
}

/// A cover upload failure is logged and falls back to the default image.
fn loadTrack(self: *App, track_id: []const u8) ApiError!void {
    const owned_id = try self.alloc.dupe(u8, track_id);
    errdefer self.alloc.free(owned_id);
    const track = try self.fetchTrack(track_id);
    self.clearCachedTrack();
    self.cached_track_id = owned_id;
    self.cached_track = track;

    const releases = lyra.trackReleases(track.value);
    if (self.config.images.uploader == .none or releases.len == 0) return;

    const url = self.uploadCover(
        releases[0].id,
        self.presence_inputs.releaseLookupIncludes(),
    ) catch |err| {
        log.err("error uploading cover err={}", .{err});
        return;
    };
    if (url.len != 0) self.cached_image = url;
}

/// Caller owns the joined names.
fn joinArtistNames(self: *App, artists: []const lyra.Artist) Allocator.Error![]u8 {
    const names = try lyra.displayArtistNames(self.alloc, artists);
    defer self.alloc.free(names);
    return std.mem.join(self.alloc, self.config.presence.list_separator, names);
}

fn cachedTrack(self: *App, track_id: []const u8) ?*lyra.Track {
    if (!std.mem.eql(u8, track_id, self.cached_track_id)) return null;
    if (self.cached_track) |*cached| return &cached.value;
    return null;
}

/// Falls back to the embedded release if fetching details fails.
fn presenceRelease(
    self: *App,
    track: lyra.Track,
    inputs: presence.Inputs,
) Allocator.Error!?lyra.Release {
    const releases = lyra.trackReleases(track);
    if (releases.len == 0) return null;
    if (!inputs.release) return null;

    const includes = inputs.releaseLookupIncludes();
    if (!includes.any()) return releases[0];
    if (self.release_details.failed) return releases[0];

    return self.ensureReleaseDetails(releases[0].id, includes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.err("error fetching release details err={}", .{err});
            self.release_details.failed = true;
            return releases[0];
        },
    };
}

fn ensureReleaseDetails(
    self: *App,
    release_id: []const u8,
    includes: lyra.ReleaseLookupIncludes,
) ApiError!lyra.Release {
    if (self.release_details.get(includes)) |release| return release;

    const fetch_includes = self.release_details.includes.merge(includes);
    const parsed = try self.fetchReleaseDetails(release_id, fetch_includes);
    self.release_details.clear();
    self.release_details = .{ .parsed = parsed, .includes = fetch_includes };
    return parsed.value;
}

fn clearCachedTrack(self: *App) void {
    self.alloc.free(self.cached_track_id);
    self.cached_track_id = &.{};
    if (self.cached_track) |cached| cached.deinit();
    self.cached_track = null;
    self.cached_image = fallback_image;
    self.release_details.clear();
}

/// Backdates the start by playback position; null while paused.
fn playbackTimestamps(
    playback: lyra.CurrentPlayback,
    snapshot_now: Io.Timestamp,
) ?discordpkg.Timestamps {
    if (playback.state != .playing) return null;

    var effective_ms = playback.effective_position_ms;
    if (effective_ms == 0) effective_ms = playback.position_ms;
    if (playback.duration_ms) |duration_ms| {
        if (effective_ms > duration_ms) effective_ms = duration_ms;
    }

    const now_ms = snapshot_now.toMilliseconds();
    const start_ms = now_ms -| std.math.lossyCast(i64, effective_ms);
    const end_ms = if (playback.duration_ms) |duration_ms|
        start_ms +| std.math.lossyCast(i64, duration_ms)
    else
        null;
    return .{
        .start = @intCast(@max(start_ms, 0)),
        .end = if (end_ms) |value| @intCast(@max(value, 0)) else null,
    };
}

fn absDiff(a: u64, b: u64) u64 {
    return if (a > b) a - b else b - a;
}

fn logRequestError(self: *App, comptime label: []const u8, err: ApiError) void {
    switch (err) {
        error.ConnectionRefused => log.err(
            label ++ ": could not connect to Lyra at {s} (connection refused). " ++
                "Start Lyra, or update base_url in config.json.",
            .{self.base_url},
        ),
        else => log.err(label ++ " err={}", .{err}),
    }
}

test "LastPlayback.needsUpdate: skips normal playing progress" {
    const last: LastPlayback = .{
        .track_id = @constCast("track"),
        .state = .playing,
        .duration_ms = 300_000,
        .activity_start_ms = 10_000,
    };

    try std.testing.expect(!last.needsUpdate(.{
        .track_id = "track",
        .state = .playing,
        .duration_ms = 300_000,
    }, .{ .start = 11_500 }));

    try std.testing.expect(last.needsUpdate(.{
        .track_id = "track",
        .state = .playing,
        .duration_ms = 300_000,
    }, .{ .start = 12_001 }));

    try std.testing.expect(last.needsUpdate(.{
        .track_id = "track",
        .state = .playing,
        .duration_ms = 301_000,
    }, .{ .start = 10_000 }));

    try std.testing.expect(last.needsUpdate(.{
        .track_id = "track",
        .state = .paused,
        .duration_ms = 300_000,
    }, null));

    try std.testing.expect(last.needsUpdate(.{
        .track_id = "other",
        .state = .playing,
        .duration_ms = 300_000,
    }, .{ .start = 10_000 }));
}

test "LastPlayback.set: copies the track id and tracks activity" {
    var last: LastPlayback = .{};
    defer last.deinit(std.testing.allocator);
    try std.testing.expect(!last.active());

    try last.set(std.testing.allocator, .{
        .track_id = "track",
        .state = .playing,
        .duration_ms = 1000,
    }, .{ .start = 5 });
    try std.testing.expect(last.active());
    try std.testing.expectEqualStrings("track", last.track_id);
    try std.testing.expectEqual(5, last.activity_start_ms.?);

    last.clear(std.testing.allocator);
    try std.testing.expect(!last.active());
    try std.testing.expectEqual(0, last.track_id.len);
}

test "playbackTimestamps: playing derives start from position" {
    const now: Io.Timestamp = .{ .nanoseconds = 100_000 * std.time.ns_per_ms };
    const timestamps = playbackTimestamps(.{
        .state = .playing,
        .position_ms = 30_000,
        .duration_ms = 200_000,
    }, now).?;
    try std.testing.expectEqual(70_000, timestamps.start);
    try std.testing.expectEqual(270_000, timestamps.end.?);

    try std.testing.expect(playbackTimestamps(.{ .state = .paused }, now) == null);
}

test "ResponseWriter bounds chunked HTTP bodies across writes" {
    for ([_]usize{ 7, 8 }) |limit| {
        var input: Io.Reader = .fixed(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
                "4\r\nabcd\r\n4\r\nefgh\r\n0\r\n\r\n",
        );
        var http_reader: std.http.Reader = .{
            .in = &input,
            .interface = undefined,
            .state = .ready,
            .max_head_len = 1024,
        };
        _ = try http_reader.receiveHead();
        var transfer_buffer: [3]u8 = undefined;
        const body = http_reader.bodyReader(&transfer_buffer, .chunked, null);
        var output: ResponseWriter = .{ .body = .init(std.testing.allocator), .limit = limit };
        defer output.body.deinit();
        if (limit == 8) {
            try std.testing.expectEqual(8, try body.streamRemaining(&output.writer));
            try std.testing.expectEqualStrings("abcdefgh", output.body.written());
            try std.testing.expect(!output.too_large);
        } else {
            try std.testing.expectError(error.WriteFailed, body.streamRemaining(&output.writer));
            try std.testing.expect(output.too_large);
            try std.testing.expect(output.body.written().len <= limit);
        }
    }
}

test "ResponseWriter bounds repeated writes without allocating excess data" {
    var output: ResponseWriter = .{ .body = .init(std.testing.allocator), .limit = 8 };
    defer output.body.deinit();
    try output.writer.writeAll("abcd");
    try std.testing.expectError(error.WriteFailed, output.writer.splatByteAll('x', 5));
    try std.testing.expect(output.too_large);
    try std.testing.expectEqualStrings("abcd", output.body.written());
}

test "failed publication preserves last playback and keeps cache identity separate" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testFailedPublication, .{});
}

fn testFailedPublication(alloc: Allocator) !void {
    var environ = std.process.Environ.Map.init(alloc);
    defer environ.deinit();
    var app = try App.init(alloc, std.testing.io, &environ, .{});
    defer app.deinit();

    try app.last.set(alloc, .{ .track_id = "A", .state = .playing }, .{ .start = 1000 });
    app.cached_track = try std.json.parseFromSlice(lyra.Track, alloc,
        \\{"id":"B","title":"Track B"}
    , lyra.json_parse_options);
    app.cached_track_id = try alloc.dupe(u8, "B");

    // B was fetched, but Discord is disconnected. Reuse B without another
    // HTTP fetch and leave the successfully published A unchanged.
    const publication = app.updatePresence(
        .{ .track_id = "B", .state = .paused },
        .{ .nanoseconds = 0 },
    );
    if (publication) |_| {
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqualStrings("A", app.last.track_id);
        try std.testing.expectEqual(.playing, app.last.state.?);
        if (err == error.OutOfMemory or err == error.WriteFailed) return error.OutOfMemory;
        try std.testing.expectEqual(error.NotConnected, err);
    }
    try std.testing.expectEqualStrings("A", app.last.track_id);
    try std.testing.expectEqual(.playing, app.last.state.?);
    try std.testing.expectEqual(1000, app.last.activity_start_ms.?);
    try std.testing.expectEqualStrings("Track B", app.cachedTrack("B").?.title);

    // Returning to A and pausing must fetch A, never render B under A's id.
    try std.testing.expect(app.last.needsUpdate(.{ .track_id = "A", .state = .paused }, null));
    try std.testing.expect(app.cachedTrack("A") == null);
}
