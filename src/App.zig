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

/// Cached across play/pause changes to avoid refetching the track.
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

pub const HttpError = std.http.Client.FetchError || Allocator.Error;

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
    return self.httpGet(url, true);
}

/// Credentials are only sent for paths, never to an arbitrary host.
fn lyraGetUrlOrPath(self: *App, url_or_path: []const u8) HttpError!HttpResponse {
    if (std.mem.startsWith(u8, url_or_path, "http://") or
        std.mem.startsWith(u8, url_or_path, "https://"))
    {
        return self.httpGet(url_or_path, false);
    }
    return self.lyraGet(url_or_path);
}

fn httpGet(self: *App, url: []const u8, include_auth: bool) HttpError!HttpResponse {
    var body_writer: Io.Writer.Allocating = .init(self.alloc);
    defer body_writer.deinit();
    var request_headers: std.http.Client.Request.Headers = .{};
    if (include_auth and self.auth_header.len > 0) {
        request_headers.authorization = .{ .override = self.auth_header };
    }
    const result = try self.http_client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body_writer.writer,
        .headers = request_headers,
    });
    return .{ .status = result.status, .body = try body_writer.toOwnedSlice() };
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

    var response_writer: Io.Writer.Allocating = .init(self.alloc);
    defer response_writer.deinit();
    const result = try self.http_client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .response_writer = &response_writer.writer,
        .payload = payload_writer.written(),
        .headers = request_headers,
    });
    return .{ .status = result.status, .body = try response_writer.toOwnedSlice() };
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
    if (track_changed) try self.loadTrack(playback.track_id);

    const track = self.cachedTrack() orelse return error.MissingCachedTrack;
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

    try self.discord.setActivity(activity);
    try self.last.set(self.alloc, playback, timestamps);
}

/// A cover upload failure is logged and falls back to the default image.
fn loadTrack(self: *App, track_id: []const u8) ApiError!void {
    const track = try self.fetchTrack(track_id);
    self.clearCachedTrack();
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

fn cachedTrack(self: *App) ?*lyra.Track {
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
