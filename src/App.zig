// This Source Code Form is subject to the terms of the Lyra Public License,
// v1.0. If a copy of the Lyra Public License was not distributed with this
// file, You can obtain one here:
// www.meshiplaw.com/lyra.

const std = @import("std");
const discord_mod = @import("discord.zig");
const lyra = @import("lyra.zig");

const App = @This();
const Allocator = std.mem.Allocator;
const Io = std.Io;

const litterbox_api_url = "https://litterbox.catbox.moe/resources/internals/api.php";
const imgur_api_url = "https://api.imgur.com/3/image";
const seek_detection_threshold_ms = 2000;
const multipart_boundary = "----lyra-rpc-zig-boundary";
const multipart_content_type = "multipart/form-data; boundary=" ++ multipart_boundary;

const ImgurResponse = struct {
    data: ImgurData = .{},
};

const ImgurData = struct {
    link: []const u8 = "",
};

const HttpResponse = struct {
    allocator: Allocator,
    status: std.http.Status,
    body: []u8,

    fn deinit(self: *HttpResponse) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

const ActivePlayback = struct {
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

allocator: Allocator,
io: Io,
environ_map: *std.process.Environ.Map,
config: lyra.Config,
base_url: []const u8,
auth_header: []const u8 = "",
imgur_auth_header: []const u8 = "",
presence_inputs: lyra.PresenceTemplateInputs,
http_client: std.http.Client,
cover_cache: std.StringHashMap([]u8),
missing_cover_cache: std.StringHashMap(void),
last_track_id: []u8 = &.{},
last_state: []u8 = &.{},
last_duration_ms: ?u64 = null,
last_activity_start_ms: ?u64 = null,
cached_track: ?std.json.Parsed(lyra.Track) = null,
cached_release_details: ?std.json.Parsed(lyra.Release) = null,
cached_release_details_includes: lyra.ReleaseLookupIncludes = .{},
cached_release_details_failed: bool = false,
cached_image: []const u8 = "",
playback_fetch_failed: bool = false,
discord: discord_mod.Client,

pub fn init(
    allocator: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
    config: lyra.Config,
) !App {
    const auth_header = if (config.auth_token.len > 0)
        try std.fmt.allocPrint(allocator, "Bearer {s}", .{config.auth_token})
    else
        &.{};
    errdefer if (auth_header.len > 0) allocator.free(auth_header);

    const imgur_auth_header = if (config.images.uploader == .imgur and config.images.imgur_client_id.len > 0)
        try std.fmt.allocPrint(allocator, "Client-ID {s}", .{config.images.imgur_client_id})
    else
        &.{};
    errdefer if (imgur_auth_header.len > 0) allocator.free(imgur_auth_header);

    return .{
        .allocator = allocator,
        .io = io,
        .environ_map = environ_map,
        .config = config,
        .base_url = std.mem.trimEnd(u8, config.base_url, "/"),
        .auth_header = auth_header,
        .imgur_auth_header = imgur_auth_header,
        .presence_inputs = lyra.presenceConfigInputs(config.presence),
        .http_client = .{ .allocator = allocator, .io = io },
        .cover_cache = std.StringHashMap([]u8).init(allocator),
        .missing_cover_cache = std.StringHashMap(void).init(allocator),
        .discord = discord_mod.Client.init(allocator, io, environ_map),
    };
}

pub fn deinit(self: *App) void {
    self.discord.logout();
    self.clearCachedTrack();
    self.clearLastPlayback();

    var cover_it = self.cover_cache.iterator();
    while (cover_it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.cover_cache.deinit();

    var missing_it = self.missing_cover_cache.iterator();
    while (missing_it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
    }
    self.missing_cover_cache.deinit();

    self.http_client.deinit();
    if (self.auth_header.len > 0) self.allocator.free(self.auth_header);
    if (self.imgur_auth_header.len > 0) self.allocator.free(self.imgur_auth_header);
    self.* = undefined;
}

fn lyraGet(self: *App, path: []const u8) !HttpResponse {
    const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
    defer self.allocator.free(url);
    return self.httpGet(url, true);
}

fn lyraGetUrlOrPath(self: *App, url_or_path: []const u8) !HttpResponse {
    if (std.mem.startsWith(u8, url_or_path, "http://") or
        std.mem.startsWith(u8, url_or_path, "https://"))
    {
        return self.httpGet(url_or_path, false);
    }
    return self.lyraGet(url_or_path);
}

fn httpGet(self: *App, url: []const u8, include_auth: bool) !HttpResponse {
    var body_writer: Io.Writer.Allocating = .init(self.allocator);
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

    return .{
        .allocator = self.allocator,
        .status = result.status,
        .body = try body_writer.toOwnedSlice(),
    };
}

fn fetchActivePlayback(self: *App) !ActivePlayback {
    var path = try lyra.activePlaybackPath(self.allocator, null);
    defer self.allocator.free(path);

    while (true) {
        var resp = try self.lyraGet(path);
        defer resp.deinit();
        if (resp.status != .ok) return error.UnexpectedApiStatus;

        const parsed = try std.json.parseFromSlice(lyra.PlaybackPage, self.allocator, resp.body, lyra.api_json_parse_options);
        errdefer parsed.deinit();
        if (parsed.value.firstCurrent()) |playback| {
            return .{ .parsed = parsed, .playback = playback };
        }
        const next_path = if (parsed.value.next_cursor) |cursor|
            try lyra.activePlaybackPath(self.allocator, cursor)
        else {
            parsed.deinit();
            return .{};
        };
        parsed.deinit();
        self.allocator.free(path);
        path = next_path;
    }
}

fn fetchTrack(self: *App, id: []const u8) !std.json.Parsed(lyra.Track) {
    const path = try lyra.trackLookupPath(self.allocator, id);
    defer self.allocator.free(path);

    var resp = try self.lyraGet(path);
    defer resp.deinit();

    if (resp.status != .ok) return error.UnexpectedApiStatus;
    return std.json.parseFromSlice(lyra.Track, self.allocator, resp.body, lyra.api_json_parse_options);
}

fn fetchReleaseDetails(
    self: *App,
    id: []const u8,
    includes: lyra.ReleaseLookupIncludes,
) !std.json.Parsed(lyra.Release) {
    const path = try lyra.releaseLookupPath(self.allocator, id, includes);
    defer self.allocator.free(path);

    var resp = try self.lyraGet(path);
    defer resp.deinit();

    if (resp.status == .not_found) return error.ReleaseNotFound;
    if (resp.status != .ok) return error.UnexpectedApiStatus;
    return std.json.parseFromSlice(lyra.Release, self.allocator, resp.body, lyra.api_json_parse_options);
}

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
    defer resp.deinit();

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
    errdefer self.allocator.free(uploaded_url);

    const key = try self.allocator.dupe(u8, release_id);
    errdefer self.allocator.free(key);

    try self.cover_cache.put(key, uploaded_url);
    return uploaded_url;
}

fn rememberMissingCover(self: *App, release_id: []const u8) !void {
    const key = try self.allocator.dupe(u8, release_id);
    errdefer self.allocator.free(key);
    try self.missing_cover_cache.put(key, {});
}

fn uploadToLitterbox(self: *App, image: []const u8) ![]u8 {
    var resp = try self.postMultipart(litterbox_api_url, &.{
        .{ .name = "reqtype", .value = "fileupload" },
        .{ .name = "time", .value = "72h" },
    }, "fileToUpload", image, null);
    defer resp.deinit();

    if (resp.status != .ok) return error.UnexpectedApiStatus;
    return self.allocator.dupe(u8, lyra.trimSpace(resp.body));
}

fn uploadToImgur(self: *App, image: []const u8) ![]u8 {
    var resp = try self.postMultipart(imgur_api_url, &.{
        .{ .name = "type", .value = "file" },
    }, "image", image, self.imgur_auth_header);
    defer resp.deinit();

    if (resp.status != .ok) return error.UnexpectedApiStatus;

    var parsed = try std.json.parseFromSlice(ImgurResponse, self.allocator, resp.body, lyra.api_json_parse_options);
    defer parsed.deinit();

    return self.allocator.dupe(u8, parsed.value.data.link);
}

fn postMultipart(
    self: *App,
    url: []const u8,
    fields: []const MultipartField,
    file_field_name: []const u8,
    file_data: []const u8,
    authorization: ?[]const u8,
) !HttpResponse {
    var payload_writer: Io.Writer.Allocating = .init(self.allocator);
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

    const payload = try payload_writer.toOwnedSlice();
    defer self.allocator.free(payload);

    var request_headers: std.http.Client.Request.Headers = .{
        .content_type = .{ .override = multipart_content_type },
    };
    if (authorization) |value| request_headers.authorization = .{ .override = value };

    var response_writer: Io.Writer.Allocating = .init(self.allocator);
    defer response_writer.deinit();

    const result = try self.http_client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .response_writer = &response_writer.writer,
        .headers = request_headers,
    });

    return .{
        .allocator = self.allocator,
        .status = result.status,
        .body = try response_writer.toOwnedSlice(),
    };
}

pub fn poll(self: *App) void {
    var active_playback = self.fetchActivePlayback() catch |err| {
        if (!self.playback_fetch_failed) {
            logLyraRequestError("Error fetching playback", self.config, err);
            self.playback_fetch_failed = true;
        }
        return;
    };
    defer active_playback.deinit();

    self.playback_fetch_failed = false;
    const snapshot_now = Io.Timestamp.now(self.io, .real);

    const playback = active_playback.playback orelse {
        self.clearPresenceIfNeeded();
        return;
    };

    if (!std.mem.eql(u8, playback.state, "playing") and
        !std.mem.eql(u8, playback.state, "paused"))
    {
        self.clearPresenceIfNeeded();
        return;
    }

    self.updatePresence(playback, snapshot_now) catch |err| {
        logError("Error setting activity: {s}", .{@errorName(err)});
    };
}

fn clearPresenceIfNeeded(self: *App) void {
    if (self.last_state.len != 0) {
        self.discord.clearActivity() catch |err| {
            logError("Error clearing activity: {s}", .{@errorName(err)});
            return;
        };
        logInfo("No active playback, cleared presence.", .{});
    }
    self.clearLastPlayback();
    self.clearCachedTrack();
    self.cached_image = "";
}

fn updatePresence(self: *App, playback: lyra.CurrentPlayback, snapshot_now: Io.Timestamp) !void {
    const timestamps = playbackTimestamps(playback, snapshot_now);
    if (!self.shouldUpdatePresence(playback, timestamps)) return;

    if (!std.mem.eql(u8, playback.track_id, self.last_track_id)) {
        const track = self.fetchTrack(playback.track_id) catch |err| {
            logError("Error fetching track: {s}", .{@errorName(err)});
            return;
        };

        self.clearCachedTrack();
        self.cached_track = track;
        self.cached_image = "logo-dark";

        const releases = lyra.trackReleases(track.value);
        if (self.config.images.uploader != .none and releases.len > 0) {
            const url = self.uploadCover(
                releases[0].id,
                self.presence_inputs.releaseLookupIncludes(),
            ) catch |err| blk: {
                logError("Error uploading cover: {s}", .{@errorName(err)});
                break :blk "";
            };
            if (url.len != 0) self.cached_image = url;
        }

        const state_label = if (std.mem.eql(u8, playback.state, "paused")) "Paused" else "Playing";
        const line = try lyra.playbackLogLine(self.allocator, state_label, track.value);
        defer self.allocator.free(line);
        logInfo("{s}", .{line});
    } else if (!std.mem.eql(u8, playback.state, self.last_state)) {
        const track = self.cachedTrack() orelse return error.MissingCachedTrack;
        const state_label = if (std.mem.eql(u8, playback.state, "paused")) "Paused" else "Playing";
        const line = try lyra.playbackLogLine(self.allocator, state_label, track.*);
        defer self.allocator.free(line);
        logInfo("{s}", .{line});
    }

    const track = self.cachedTrack() orelse return error.MissingCachedTrack;
    const inputs = self.presence_inputs;

    var artists_text_alloc: ?[]u8 = null;
    defer if (artists_text_alloc) |value| self.allocator.free(value);
    var artists_text: []const u8 = "";
    if (inputs.track_artists) {
        const artist_names = try lyra.displayArtistNames(self.allocator, lyra.trackArtists(track.*));
        defer self.allocator.free(artist_names);
        artists_text_alloc = try std.mem.join(self.allocator, self.config.presence.list_separator, artist_names);
        artists_text = artists_text_alloc.?;
    }

    const release = try self.presenceRelease(track.*, inputs);

    var release_artists_alloc: ?[]u8 = null;
    defer if (release_artists_alloc) |value| self.allocator.free(value);
    var release_artists_text: []const u8 = "";
    if (inputs.release_artists) {
        if (release) |release_value| {
            const release_artist_names = try lyra.displayArtistNames(
                self.allocator,
                lyra.releaseArtists(release_value),
            );
            defer self.allocator.free(release_artist_names);
            release_artists_alloc = try std.mem.join(
                self.allocator,
                self.config.presence.list_separator,
                release_artist_names,
            );
            release_artists_text = release_artists_alloc.?;
        }
    }

    var genres_alloc: ?[]u8 = null;
    defer if (genres_alloc) |value| self.allocator.free(value);
    var release_genres_text: []const u8 = "";
    if (inputs.release_genres) {
        if (release) |release_value| {
            const genres = lyra.releaseGenres(release_value);
            if (genres.len != 0) {
                genres_alloc = try std.mem.join(self.allocator, self.config.presence.list_separator, genres);
                release_genres_text = genres_alloc.?;
            }
        }
    }

    var presence_text = try lyra.renderPresenceText(self.allocator, self.config.presence, .{
        .track = track.*,
        .release = release,
        .artists = artists_text,
        .release_artists = release_artists_text,
        .release_genres = release_genres_text,
    });
    defer presence_text.deinit();

    var activity: discord_mod.Activity = .{
        .details = presence_text.title,
        .state = presence_text.subtitle,
        .assets = .{
            .large_image = self.cached_image,
            .large_text = presence_text.image_text,
        },
    };

    if (timestamps) |value| {
        activity.timestamps = value;
        activity.assets.small_image = "playing";
        activity.assets.small_text = "Playing";
    } else {
        activity.assets.small_image = discord_mod.paused_image;
        activity.assets.small_text = "Paused";
    }

    try self.discord.setActivity(activity);
    try self.rememberPlayback(playback, timestamps);
}

fn shouldUpdatePresence(
    self: *App,
    playback: lyra.CurrentPlayback,
    timestamps: ?discord_mod.Timestamps,
) bool {
    if (!std.mem.eql(u8, playback.track_id, self.last_track_id)) return true;
    if (!std.mem.eql(u8, playback.state, self.last_state)) return true;
    if (playback.duration_ms != self.last_duration_ms) return true;

    if (timestamps) |value| {
        const last_start = self.last_activity_start_ms orelse return true;
        if (absDiff(value.start, last_start) > seek_detection_threshold_ms) return true;
    }

    return false;
}

fn cachedTrack(self: *App) ?*lyra.Track {
    if (self.cached_track) |*cached| return &cached.value;
    return null;
}

fn presenceRelease(
    self: *App,
    track: lyra.Track,
    inputs: lyra.PresenceTemplateInputs,
) !?lyra.Release {
    const releases = lyra.trackReleases(track);
    if (releases.len == 0) return null;
    if (!inputs.release) return null;

    const includes = inputs.releaseLookupIncludes();
    if (!includes.any()) return releases[0];
    if (self.cached_release_details_failed) return releases[0];

    return self.ensureReleaseDetails(releases[0].id, includes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            logError("Error fetching release details: {s}", .{@errorName(err)});
            self.cached_release_details_failed = true;
            return releases[0];
        },
    };
}

fn ensureReleaseDetails(
    self: *App,
    release_id: []const u8,
    includes: lyra.ReleaseLookupIncludes,
) !lyra.Release {
    if (self.cached_release_details) |*cached| {
        if (self.cached_release_details_includes.contains(includes)) return cached.value;
    }

    const fetch_includes = self.cached_release_details_includes.merge(includes);
    const parsed = try self.fetchReleaseDetails(release_id, fetch_includes);
    self.clearCachedReleaseDetails();
    self.cached_release_details = parsed;
    self.cached_release_details_includes = fetch_includes;
    return self.cached_release_details.?.value;
}

fn clearCachedTrack(self: *App) void {
    if (self.cached_track) |cached| cached.deinit();
    self.cached_track = null;
    self.clearCachedReleaseDetails();
}

fn clearCachedReleaseDetails(self: *App) void {
    if (self.cached_release_details) |cached| cached.deinit();
    self.cached_release_details = null;
    self.cached_release_details_includes = .{};
    self.cached_release_details_failed = false;
}

fn rememberPlayback(
    self: *App,
    playback: lyra.CurrentPlayback,
    timestamps: ?discord_mod.Timestamps,
) !void {
    const track_changed = !std.mem.eql(u8, playback.track_id, self.last_track_id);
    const state_changed = !std.mem.eql(u8, playback.state, self.last_state);

    const next_track_id = if (track_changed)
        try self.allocator.dupe(u8, playback.track_id)
    else
        null;
    errdefer if (next_track_id) |value| self.allocator.free(value);

    const next_state = if (state_changed)
        try self.allocator.dupe(u8, playback.state)
    else
        null;
    errdefer if (next_state) |value| self.allocator.free(value);

    if (next_track_id) |value| {
        self.allocator.free(self.last_track_id);
        self.last_track_id = value;
    }
    if (next_state) |value| {
        self.allocator.free(self.last_state);
        self.last_state = value;
    }
    self.last_duration_ms = playback.duration_ms;
    self.last_activity_start_ms = if (timestamps) |value| value.start else null;
}

fn clearLastPlayback(self: *App) void {
    self.allocator.free(self.last_track_id);
    self.allocator.free(self.last_state);
    self.last_track_id = &.{};
    self.last_state = &.{};
    self.last_duration_ms = null;
    self.last_activity_start_ms = null;
}

fn playbackTimestamps(
    playback: lyra.CurrentPlayback,
    snapshot_now: Io.Timestamp,
) ?discord_mod.Timestamps {
    if (!std.mem.eql(u8, playback.state, "playing")) return null;

    var effective_ms = playback.effective_position_ms;
    if (effective_ms == 0) effective_ms = playback.position_ms;
    if (playback.duration_ms) |duration_ms| {
        if (effective_ms > duration_ms) effective_ms = duration_ms;
    }

    const start_ms_i64 = snapshot_now.toMilliseconds() - millisToSigned(effective_ms);
    const start_ms: u64 = @intCast(@max(start_ms_i64, 0));
    const end_ms = if (playback.duration_ms) |duration_ms|
        @as(u64, @intCast(@max(addMillisClamped(start_ms_i64, duration_ms), 0)))
    else
        null;
    return .{
        .start = start_ms,
        .end = end_ms,
    };
}

fn absDiff(a: u64, b: u64) u64 {
    return if (a > b) a - b else b - a;
}

fn millisToSigned(ms: u64) i64 {
    return std.math.cast(i64, ms) orelse std.math.maxInt(i64);
}

fn addMillisClamped(base_ms: i64, offset_ms: u64) i64 {
    const offset = millisToSigned(offset_ms);
    if (base_ms > 0 and offset > std.math.maxInt(i64) - base_ms) {
        return std.math.maxInt(i64);
    }
    return base_ms + offset;
}

test "presence update detection skips normal playing progress" {
    var app: App = undefined;
    app.last_track_id = @constCast("track");
    app.last_state = @constCast("playing");
    app.last_duration_ms = 300_000;
    app.last_activity_start_ms = 10_000;

    try std.testing.expect(!app.shouldUpdatePresence(.{
        .track_id = "track",
        .state = "playing",
        .duration_ms = 300_000,
    }, .{ .start = 11_500 }));

    try std.testing.expect(app.shouldUpdatePresence(.{
        .track_id = "track",
        .state = "playing",
        .duration_ms = 300_000,
    }, .{ .start = 12_001 }));

    try std.testing.expect(app.shouldUpdatePresence(.{
        .track_id = "track",
        .state = "playing",
        .duration_ms = 301_000,
    }, .{ .start = 10_000 }));

    try std.testing.expect(app.shouldUpdatePresence(.{
        .track_id = "track",
        .state = "paused",
        .duration_ms = 300_000,
    }, null));
}

fn logInfo(comptime format: []const u8, args: anytype) void {
    std.debug.print(format ++ "\n", args);
}

fn logError(comptime format: []const u8, args: anytype) void {
    std.debug.print(format ++ "\n", args);
}

fn logLyraRequestError(comptime label: []const u8, config: lyra.Config, err: anyerror) void {
    if (err == error.ConnectionRefused) {
        logError(
            "{s}: could not connect to Lyra at {s} (connection refused). " ++
                "Start Lyra, or update base_url in config.json.",
            .{
                label,
                std.mem.trimEnd(u8, config.base_url, "/"),
            },
        );
        return;
    }
    logError("{s}: {s}", .{ label, @errorName(err) });
}
