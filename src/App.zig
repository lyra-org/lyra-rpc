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
    status: std.http.Status = .ok,
    parsed: ?std.json.Parsed([]lyra.Playback) = null,
    playback: ?lyra.Playback = null,

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
presence_release_includes: lyra.PresenceReleaseIncludes,
http_client: std.http.Client,
cover_cache: std.StringHashMap([]u8),
missing_cover_cache: std.StringHashMap(void),
last_track_id: []u8 = &.{},
last_state: []u8 = &.{},
last_position_ms: u64 = 0,
cached_track: ?std.json.Parsed(lyra.Track) = null,
cached_release_details: ?std.json.Parsed(lyra.Release) = null,
cached_release_details_failed: bool = false,
cached_image: []const u8 = "",
playback_fetch_failed: bool = false,
discord: discord_mod.Client,

pub fn init(
    allocator: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
    config: lyra.Config,
) App {
    return .{
        .allocator = allocator,
        .io = io,
        .environ_map = environ_map,
        .config = config,
        .presence_release_includes = lyra.presenceConfigReleaseIncludes(config.presence),
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
    self.* = undefined;
}

fn lyraGet(self: *App, path: []const u8) !HttpResponse {
    const base = std.mem.trimEnd(u8, self.config.base_url, "/");
    const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base, path });
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

    var auth_value: ?[]u8 = null;
    defer if (auth_value) |value| self.allocator.free(value);

    var request_headers: std.http.Client.Request.Headers = .{};
    if (include_auth and self.config.auth_token.len > 0) {
        auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.config.auth_token});
        request_headers.authorization = .{ .override = auth_value.? };
    }

    const result = try self.http_client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body_writer.writer,
        .headers = request_headers,
        .keep_alive = false,
    });

    return .{
        .allocator = self.allocator,
        .status = result.status,
        .body = try body_writer.toOwnedSlice(),
    };
}

fn fetchActivePlayback(self: *App) !ActivePlayback {
    const active = try self.fetchPlaybackSessions("/api/playback-sessions/active");
    if (active.status == .ok) return active;

    if (active.status != .not_found and active.status != .method_not_allowed) {
        return error.UnexpectedApiStatus;
    }

    const fallback = try self.fetchPlaybackSessions("/api/playback-sessions?active=true");
    if (fallback.status != .ok) return error.UnexpectedApiStatus;
    return fallback;
}

fn fetchPlaybackSessions(self: *App, path: []const u8) !ActivePlayback {
    var resp = try self.lyraGet(path);
    defer resp.deinit();

    if (resp.status != .ok) {
        return .{ .status = resp.status };
    }

    const parsed = try std.json.parseFromSlice([]lyra.Playback, self.allocator, resp.body, lyra.api_json_parse_options);
    const playback = if (parsed.value.len == 0) null else parsed.value[0];
    return .{ .parsed = parsed, .playback = playback };
}

fn fetchTrack(self: *App, id: []const u8) !std.json.Parsed(lyra.Track) {
    const path = try lyra.trackLookupPath(self.allocator, id);
    defer self.allocator.free(path);

    var resp = try self.lyraGet(path);
    defer resp.deinit();

    if (resp.status != .ok) return error.UnexpectedApiStatus;
    return std.json.parseFromSlice(lyra.Track, self.allocator, resp.body, lyra.api_json_parse_options);
}

fn fetchReleaseWithCover(self: *App, id: []const u8) !std.json.Parsed(lyra.Release) {
    const path = try lyra.releaseCoverLookupPath(self.allocator, id);
    defer self.allocator.free(path);

    var resp = try self.lyraGet(path);
    defer resp.deinit();

    if (resp.status == .not_found) return error.ReleaseNotFound;
    if (resp.status != .ok) return error.UnexpectedApiStatus;
    return std.json.parseFromSlice(lyra.Release, self.allocator, resp.body, lyra.api_json_parse_options);
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

fn uploadCover(self: *App, release_id: []const u8) ![]const u8 {
    if (self.config.images.uploader == .none) return error.ImageUploadsDisabled;
    if (self.cover_cache.get(release_id)) |url| return url;
    if (self.missing_cover_cache.contains(release_id)) return "";

    var release = try self.fetchReleaseWithCover(release_id);
    defer release.deinit();

    const cover = release.value.cover orelse {
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
    const auth = try std.fmt.allocPrint(self.allocator, "Client-ID {s}", .{
        self.config.images.imgur_client_id,
    });
    defer self.allocator.free(auth);

    var resp = try self.postMultipart(imgur_api_url, &.{
        .{ .name = "type", .value = "file" },
    }, "image", image, auth);
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
    const boundary = "----lyra-rpc-zig-boundary";
    var payload_writer: Io.Writer.Allocating = .init(self.allocator);
    defer payload_writer.deinit();

    for (fields) |field| {
        try payload_writer.writer.print(
            "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"\r\n\r\n{s}\r\n",
            .{ boundary, field.name, field.value },
        );
    }
    try payload_writer.writer.print(
        "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"cover.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n",
        .{ boundary, file_field_name },
    );
    try payload_writer.writer.writeAll(file_data);
    try payload_writer.writer.print("\r\n--{s}--\r\n", .{boundary});

    const payload = try payload_writer.toOwnedSlice();
    defer self.allocator.free(payload);

    const content_type = try std.fmt.allocPrint(
        self.allocator,
        "multipart/form-data; boundary={s}",
        .{boundary},
    );
    defer self.allocator.free(content_type);

    var request_headers: std.http.Client.Request.Headers = .{
        .content_type = .{ .override = content_type },
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
        .keep_alive = false,
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
            logLyraRequestError(self.config, "Error fetching playback", err);
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

fn updatePresence(self: *App, playback: lyra.Playback, snapshot_now: Io.Timestamp) !void {
    if (std.mem.eql(u8, playback.track_id, self.last_track_id) and
        std.mem.eql(u8, playback.state, self.last_state) and
        playback.position_ms == self.last_position_ms)
    {
        return;
    }

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
            const url = self.uploadCover(releases[0].id) catch |err| blk: {
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
    const artist_names = try lyra.displayArtistNames(self.allocator, lyra.trackArtists(track.*));
    defer self.allocator.free(artist_names);
    const artists_text = try std.mem.join(self.allocator, self.config.presence.list_separator, artist_names);
    defer self.allocator.free(artists_text);

    const release_includes = self.presence_release_includes;
    const release = try self.presenceRelease(track.*, release_includes);

    var release_artists_alloc: ?[]u8 = null;
    defer if (release_artists_alloc) |value| self.allocator.free(value);
    var release_artists_text: []const u8 = "";
    if (release_includes.artists) {
        if (release) |release_value| {
            const release_artist_names = try lyra.displayArtistNames(self.allocator, lyra.releaseArtists(release_value));
            defer self.allocator.free(release_artist_names);
            release_artists_alloc = try std.mem.join(self.allocator, self.config.presence.list_separator, release_artist_names);
            release_artists_text = release_artists_alloc.?;
        }
    }

    var genres_alloc: ?[]u8 = null;
    defer if (genres_alloc) |value| self.allocator.free(value);
    var release_genres_text: []const u8 = "";
    if (release_includes.genres) {
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

    var activity = discord_mod.Activity{
        .details = presence_text.title,
        .state = presence_text.subtitle,
        .assets = .{
            .large_image = self.cached_image,
            .large_text = presence_text.image_text,
        },
    };

    if (std.mem.eql(u8, playback.state, "playing")) {
        var effective_ms = playback.effective_position_ms;
        if (effective_ms == 0) effective_ms = playback.position_ms;
        if (playback.duration_ms) |duration_ms| {
            if (effective_ms > duration_ms) effective_ms = duration_ms;
        }

        const start_ms_i64 = snapshot_now.toMilliseconds() - millisToSigned(effective_ms);
        const start_ms: u64 = @intCast(@max(start_ms_i64, 0));
        activity.timestamps = .{
            .start = start_ms,
            .end = if (playback.duration_ms) |duration_ms| @as(u64, @intCast(@max(addMillisClamped(start_ms_i64, duration_ms), 0))) else null,
        };
        activity.assets.small_image = "playing";
        activity.assets.small_text = "Playing";
    } else {
        activity.assets.small_image = discord_mod.paused_image;
        activity.assets.small_text = "Paused";
    }

    try self.rememberPlayback(playback);
    try self.discord.setActivity(activity);
}

fn cachedTrack(self: *App) ?*lyra.Track {
    if (self.cached_track) |*cached| return &cached.value;
    return null;
}

fn presenceRelease(
    self: *App,
    track: lyra.Track,
    includes: lyra.PresenceReleaseIncludes,
) !?lyra.Release {
    const releases = lyra.trackReleases(track);
    if (releases.len == 0) return null;
    if (!includes.any()) return releases[0];
    if (self.cached_release_details) |*cached| return cached.value;
    if (self.cached_release_details_failed) return releases[0];

    const parsed = self.fetchReleaseDetails(releases[0].id, .{
        .artists = includes.artists,
        .genres = includes.genres,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            logError("Error fetching release details: {s}", .{@errorName(err)});
            self.cached_release_details_failed = true;
            return releases[0];
        },
    };

    self.cached_release_details = parsed;
    return self.cached_release_details.?.value;
}

fn clearCachedTrack(self: *App) void {
    if (self.cached_track) |cached| cached.deinit();
    self.cached_track = null;
    if (self.cached_release_details) |cached| cached.deinit();
    self.cached_release_details = null;
    self.cached_release_details_failed = false;
}

fn rememberPlayback(self: *App, playback: lyra.Playback) !void {
    const next_track_id = try self.allocator.dupe(u8, playback.track_id);
    errdefer self.allocator.free(next_track_id);
    const next_state = try self.allocator.dupe(u8, playback.state);
    errdefer self.allocator.free(next_state);

    self.clearLastPlayback();
    self.last_track_id = next_track_id;
    self.last_state = next_state;
    self.last_position_ms = playback.position_ms;
}

fn clearLastPlayback(self: *App) void {
    self.allocator.free(self.last_track_id);
    self.allocator.free(self.last_state);
    self.last_track_id = &.{};
    self.last_state = &.{};
    self.last_position_ms = 0;
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

fn logInfo(comptime format: []const u8, args: anytype) void {
    std.debug.print(format ++ "\n", args);
}

fn logError(comptime format: []const u8, args: anytype) void {
    std.debug.print(format ++ "\n", args);
}

fn logLyraRequestError(config: lyra.Config, comptime label: []const u8, err: anyerror) void {
    if (err == error.ConnectionRefused) {
        logError("{s}: could not connect to Lyra at {s} (connection refused). Start Lyra, or update base_url in config.json.", .{
            label,
            std.mem.trimEnd(u8, config.base_url, "/"),
        });
        return;
    }
    logError("{s}: {s}", .{ label, @errorName(err) });
}
