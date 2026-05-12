// This Source Code Form is subject to the terms of the Lyra Public License,
// v1.0. If a copy of the Lyra Public License was not distributed with this
// file, You can obtain one here:
// www.meshiplaw.com/lyra.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const api_json_parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
};

pub const ImageUploader = enum {
    none,
    litterbox,
    imgur,
};

pub const ImageConfig = struct {
    uploader: ImageUploader = .none,
    imgur_client_id: []const u8 = "",
};

pub const Config = struct {
    base_url: []const u8 = "http://localhost:4746",
    auth_token: []const u8 = "",
    poll_interval_sec: u32 = 5,
    images: ImageConfig = .{},
};

pub const Playback = struct {
    playback_session_id: []const u8 = "",
    track_id: []const u8 = "",
    user_id: []const u8 = "",
    position_ms: u64 = 0,
    effective_position_ms: u64 = 0,
    state: []const u8 = "",
    activity_ms: u64 = 0,
    updated_at: []const u8 = "",
    duration_ms: ?u64 = null,
};

pub const Artist = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    credit: ?ArtistCredit = null,
};

pub const ArtistCredit = struct {
    type: []const u8 = "",
    detail: ?[]const u8 = null,
    source: []const u8 = "",
};

pub const Release = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    release_date: ?[]const u8 = null,
    cover: ?Cover = null,
};

pub const Cover = struct {
    id: []const u8 = "",
    url: []const u8 = "",
    mime_type: []const u8 = "",
    hash: []const u8 = "",
    blurhash: ?[]const u8 = null,
};

pub const Track = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    artists: ?[]Artist = null,
    releases: ?[]Release = null,
};

pub fn trackArtists(track: Track) []const Artist {
    return track.artists orelse &.{};
}

pub fn trackReleases(track: Track) []const Release {
    return track.releases orelse &.{};
}

pub fn loadConfig(allocator: Allocator, io: Io, path: []const u8) !Config {
    const data = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const loaded = try std.json.parseFromSliceLeaky(Config, allocator, data, .{
        .ignore_unknown_fields = true,
    });

    var config = Config{};
    if (loaded.base_url.len != 0) config.base_url = loaded.base_url;
    config.auth_token = loaded.auth_token;
    if (loaded.poll_interval_sec > 0) config.poll_interval_sec = loaded.poll_interval_sec;
    config.images = loaded.images;
    return config;
}

pub fn releaseYear(release: Release) []const u8 {
    const date = release.release_date orelse return "";
    if (date.len < 4) return "";
    const year = date[0..4];
    for (year) |ch| {
        if (ch < '0' or ch > '9') return "";
    }
    return year;
}

pub fn displayArtistNames(allocator: Allocator, artists: []const Artist) ![][]const u8 {
    const primary = try filteredArtistNames(allocator, artists, true);
    if (primary.len > 0) return primary;
    allocator.free(primary);
    return filteredArtistNames(allocator, artists, false);
}

fn filteredArtistNames(
    allocator: Allocator,
    artists: []const Artist,
    primary_only: bool,
) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);

    for (artists) |artist| {
        if (artist.name.len == 0) continue;
        if (primary_only) {
            const credit = artist.credit orelse continue;
            if (!std.mem.eql(u8, credit.type, "artist")) continue;
        }
        if (containsString(names.items, artist.name)) continue;
        try names.append(allocator, artist.name);
    }

    return names.toOwnedSlice(allocator);
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

pub fn playbackLogLine(allocator: Allocator, state_label: []const u8, track: Track) ![]u8 {
    const artist_names = try displayArtistNames(allocator, trackArtists(track));
    defer allocator.free(artist_names);

    if (artist_names.len == 0) {
        return std.fmt.allocPrint(allocator, "{s}: {s}", .{ state_label, track.title });
    }

    const artists = try std.mem.join(allocator, ", ", artist_names);
    defer allocator.free(artists);
    return std.fmt.allocPrint(allocator, "{s}: {s} - {s}", .{
        state_label,
        track.title,
        artists,
    });
}

pub fn formatLyraRequestError(
    allocator: Allocator,
    base_url: []const u8,
    url: []const u8,
    raw_error: []const u8,
) ![]u8 {
    const clean_base_url = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.indexOf(u8, raw_error, "dial_tcp failed") != null or
        std.mem.indexOf(u8, raw_error, "connection refused") != null or
        std.mem.indexOf(u8, raw_error, "socket error: 111") != null)
    {
        return std.fmt.allocPrint(
            allocator,
            "could not connect to Lyra at {s} (connection refused). Start Lyra, or update base_url in config.json.",
            .{clean_base_url},
        );
    }
    return std.fmt.allocPrint(allocator, "Lyra request failed for {s}: {s}", .{
        url,
        raw_error,
    });
}

pub fn formatApiStatusError(
    allocator: Allocator,
    label: []const u8,
    status_code: u16,
    body: []const u8,
) ![]u8 {
    const clean_body = trimSpace(body);
    if (clean_body.len == 0) {
        return std.fmt.allocPrint(allocator, "{s} returned status {}", .{ label, status_code });
    }
    return std.fmt.allocPrint(allocator, "{s} returned status {}: {s}", .{
        label,
        status_code,
        clean_body,
    });
}

pub fn trackLookupPath(allocator: Allocator, track_id: []const u8) ![]u8 {
    const escaped = try pathEscapeAlloc(allocator, track_id);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "/api/tracks/{s}?inc=releases%2Cartists", .{escaped});
}

pub fn releaseCoverLookupPath(allocator: Allocator, release_id: []const u8) ![]u8 {
    const escaped = try pathEscapeAlloc(allocator, release_id);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "/api/releases/{s}?inc=covers", .{escaped});
}

pub fn pathEscapeAlloc(allocator: Allocator, input: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try @as(std.Uri.Component, .{ .raw = input }).formatEscaped(&out.writer);
    return out.toOwnedSlice();
}

pub fn trimSpace(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n");
}

test "release year" {
    try std.testing.expectEqualStrings("2024", releaseYear(.{ .release_date = "2024-05-01" }));
    try std.testing.expectEqualStrings("", releaseYear(.{ .release_date = "abcd-05-01" }));
    try std.testing.expectEqualStrings("", releaseYear(.{ .release_date = "20" }));
    try std.testing.expectEqualStrings("", releaseYear(.{}));
}

test "display artist names prefers primary credits" {
    const artists = [_]Artist{
        .{ .name = "Primary One", .credit = .{ .type = "artist" } },
        .{ .name = "Featured", .credit = .{ .type = "guest" } },
        .{ .name = "Primary One", .credit = .{ .type = "artist" } },
    };
    const names = try displayArtistNames(std.testing.allocator, &artists);
    defer std.testing.allocator.free(names);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("Primary One", names[0]);
}

test "display artist names falls back to all names" {
    const artists = [_]Artist{
        .{ .name = "First" },
        .{ .name = "Second" },
        .{ .name = "First" },
    };
    const names = try displayArtistNames(std.testing.allocator, &artists);
    defer std.testing.allocator.free(names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("First", names[0]);
    try std.testing.expectEqualStrings("Second", names[1]);
}

test "playback log line includes artists" {
    const track = Track{
        .title = "Song",
        .artists = @constCast(&[_]Artist{
            .{ .name = "Artist One", .credit = .{ .type = "artist" } },
            .{ .name = "Artist Two", .credit = .{ .type = "artist" } },
        }),
    };
    const paused = try playbackLogLine(std.testing.allocator, "Paused", track);
    defer std.testing.allocator.free(paused);
    try std.testing.expectEqualStrings("Paused: Song - Artist One, Artist Two", paused);
}

test "playback log line omits empty artist suffix" {
    const line = try playbackLogLine(std.testing.allocator, "Playing", .{ .title = "Song" });
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("Playing: Song", line);
}

test "format Lyra request error for connection refused" {
    const raw_error = "dial_tcp failed for address localhost:4746\ntried addrs:\n\t[::1]:4746: net: socket error: 111; code: 111";
    const message = try formatLyraRequestError(
        std.testing.allocator,
        "http://localhost:4746/",
        "http://localhost:4746/api/playback-sessions/active",
        raw_error,
    );
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings(
        "could not connect to Lyra at http://localhost:4746 (connection refused). Start Lyra, or update base_url in config.json.",
        message,
    );
}

test "format Lyra request error keeps unexpected context" {
    const message = try formatLyraRequestError(
        std.testing.allocator,
        "http://localhost:4746",
        "http://localhost:4746/api/tracks/abc",
        "tls handshake failed",
    );
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings(
        "Lyra request failed for http://localhost:4746/api/tracks/abc: tls handshake failed",
        message,
    );
}

test "format API status error" {
    const with_body = try formatApiStatusError(
        std.testing.allocator,
        "tracks API",
        400,
        "Failed to deserialize query string: duplicate field `inc`\n",
    );
    defer std.testing.allocator.free(with_body);
    try std.testing.expectEqualStrings(
        "tracks API returned status 400: Failed to deserialize query string: duplicate field `inc`",
        with_body,
    );

    const without_body = try formatApiStatusError(std.testing.allocator, "tracks API", 500, "");
    defer std.testing.allocator.free(without_body);
    try std.testing.expectEqualStrings("tracks API returned status 500", without_body);
}

test "lookup paths use documented includes" {
    const track_path = try trackLookupPath(std.testing.allocator, "track/id");
    defer std.testing.allocator.free(track_path);
    try std.testing.expectEqualStrings("/api/tracks/track%2Fid?inc=releases%2Cartists", track_path);

    const release_path = try releaseCoverLookupPath(std.testing.allocator, "release/id");
    defer std.testing.allocator.free(release_path);
    try std.testing.expectEqualStrings("/api/releases/release%2Fid?inc=covers", release_path);
}

test "playback decodes documented active session response" {
    var playback = try std.json.parseFromSlice([]Playback, std.testing.allocator,
        \\[{"playback_session_id":"session","track_id":"track","user_id":"user","position_ms":1200,"state":"playing","activity_ms":3400,"updated_at":"2026-05-11T07:00:00Z","effective_position_ms":1500,"duration_ms":3000,"supported_commands":["pause"],"remote_control_degraded":false}]
    , api_json_parse_options);
    defer playback.deinit();

    try std.testing.expectEqual(@as(usize, 1), playback.value.len);
    try std.testing.expectEqualStrings("2026-05-11T07:00:00Z", playback.value[0].updated_at);
    try std.testing.expectEqual(@as(u64, 1500), playback.value[0].effective_position_ms);
    try std.testing.expectEqual(@as(u64, 3000), playback.value[0].duration_ms.?);
}

test "track decodes nullable documented includes" {
    var track = try std.json.parseFromSlice(Track, std.testing.allocator,
        \\{"id":"track","title":"Song","artists":null,"releases":null,"duration_ms":null}
    , api_json_parse_options);
    defer track.deinit();

    try std.testing.expectEqualStrings("Song", track.value.title);
    try std.testing.expectEqual(@as(usize, 0), trackArtists(track.value).len);
    try std.testing.expectEqual(@as(usize, 0), trackReleases(track.value).len);
}

test "release decodes documented cover response" {
    var release = try std.json.parseFromSlice(Release, std.testing.allocator,
        \\{"id":"rel","title":"Album","release_date":"2021-07-14","cover":{"id":"cov","url":"/api/covers/cov?v=hash","mime_type":"image/jpeg","hash":"hash","blurhash":null}}
    , api_json_parse_options);
    defer release.deinit();
    const cover = release.value.cover orelse return error.TestExpectedCover;
    try std.testing.expectEqualStrings("cov", cover.id);
    try std.testing.expectEqualStrings("/api/covers/cov?v=hash", cover.url);
    try std.testing.expectEqualStrings("image/jpeg", cover.mime_type);
    try std.testing.expectEqualStrings("hash", cover.hash);
}

test "API JSON strings do not borrow response body" {
    const body = try std.testing.allocator.dupe(u8,
        \\{"id":"track","title":"Song","artists":[{"name":"Artist","credit":{"type":"artist"}}],"releases":[]}
    );
    var parsed = try std.json.parseFromSlice(Track, std.testing.allocator, body, api_json_parse_options);
    std.testing.allocator.free(body);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Song", parsed.value.title);
    const artists = trackArtists(parsed.value);
    try std.testing.expectEqual(@as(usize, 1), artists.len);
    try std.testing.expectEqualStrings("Artist", artists[0].name);
}
