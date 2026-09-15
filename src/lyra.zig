// This Source Code Form is subject to the terms of the Lyra Public License,
// v1.0. If a copy of the Lyra Public License was not distributed with this
// file, You can obtain one here:
// www.meshiplaw.com/lyra.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Copies strings so parsed values never borrow the response body.
pub const json_parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
};

pub const PlaybackPage = struct {
    items: []Playback,
    next_cursor: ?[]const u8,

    pub fn firstCurrent(self: PlaybackPage) ?CurrentPlayback {
        for (self.items) |playback| {
            if (playback.current) |current| return current;
        }
        return null;
    }
};

pub const Playback = struct {
    current: ?CurrentPlayback,
};

pub const CurrentPlayback = struct {
    track_id: []const u8 = "",
    position_ms: u64 = 0,
    effective_position_ms: u64 = 0,
    state: PlaybackState = .unknown,
    duration_ms: ?u64 = null,
};

/// Unrecognized states decode as `.unknown`.
pub const PlaybackState = enum {
    playing,
    paused,
    unknown,

    pub fn jsonParse(
        alloc: Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !PlaybackState {
        return parseEnumOrUnknown(PlaybackState, alloc, source, options);
    }

    pub fn label(self: PlaybackState) []const u8 {
        return switch (self) {
            .playing => "Playing",
            .paused => "Paused",
            .unknown => "Unknown",
        };
    }
};

pub const Artist = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    credit: ?ArtistCredit = null,
};

pub const ArtistCredit = struct {
    type: CreditType = .unknown,
};

/// Only primary (`artist`) credits are distinguished; others decode as `.unknown`.
pub const CreditType = enum {
    artist,
    unknown,

    pub fn jsonParse(
        alloc: Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !CreditType {
        return parseEnumOrUnknown(CreditType, alloc, source, options);
    }
};

pub const Release = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    release_date: ?[]const u8 = null,
    cover: ?Cover = null,
    artists: ?[]Artist = null,
    genres: ?[]const []const u8 = null,
};

pub const Cover = struct {
    /// Absolute URL or a path relative to the Lyra base URL.
    url: []const u8 = "",
};

pub const Track = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    disc: ?u32 = null,
    track: ?u32 = null,
    year: ?u32 = null,
    duration_ms: ?u64 = null,
    artists: ?[]Artist = null,
    releases: ?[]Release = null,
};

fn parseEnumOrUnknown(
    comptime T: type,
    alloc: Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !T {
    const name = try std.json.innerParse([]const u8, alloc, source, options);
    return std.meta.stringToEnum(T, name) orelse .unknown;
}

pub fn trackArtists(track: Track) []const Artist {
    return track.artists orelse &.{};
}

pub fn trackReleases(track: Track) []const Release {
    return track.releases orelse &.{};
}

pub fn releaseGenres(release: Release) []const []const u8 {
    return release.genres orelse &.{};
}

pub fn releaseArtists(release: Release) []const Artist {
    return release.artists orelse &.{};
}

pub fn releaseYear(release: Release) []const u8 {
    const date = release.release_date orelse return "";
    if (date.len < 4) return "";
    const year = date[0..4];
    for (year) |ch| {
        if (!std.ascii.isDigit(ch)) return "";
    }
    return year;
}

/// Unique artist names to display, preferring primary credits and falling
/// back to every credited artist. The slice is owned by the caller; the
/// names borrow from `artists`.
pub fn displayArtistNames(alloc: Allocator, artists: []const Artist) Allocator.Error![][]const u8 {
    const primary = try filteredArtistNames(alloc, artists, true);
    if (primary.len > 0) return primary;
    alloc.free(primary);
    return filteredArtistNames(alloc, artists, false);
}

fn filteredArtistNames(
    alloc: Allocator,
    artists: []const Artist,
    primary_only: bool,
) Allocator.Error![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(alloc);

    for (artists) |artist| {
        if (artist.name.len == 0) continue;
        if (primary_only) {
            const credit = artist.credit orelse continue;
            if (credit.type != .artist) continue;
        }
        if (containsString(names.items, artist.name)) continue;
        try names.append(alloc, artist.name);
    }

    return names.toOwnedSlice(alloc);
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

pub fn playbackLogLine(alloc: Allocator, state: PlaybackState, track: Track) ![]u8 {
    const artist_names = try displayArtistNames(alloc, trackArtists(track));
    defer alloc.free(artist_names);

    var out: Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.print("{s}: {s}", .{ state.label(), track.title });
    for (artist_names, 0..) |name, index| {
        try out.writer.writeAll(if (index == 0) " - " else ", ");
        try out.writer.writeAll(name);
    }
    return out.toOwnedSlice();
}

pub const ApiStatusError = struct {
    label: []const u8,
    status: std.http.Status,
    body: []const u8,

    pub fn format(self: ApiStatusError, writer: *Io.Writer) Io.Writer.Error!void {
        var clean_body = trimSpace(self.body);
        if (std.mem.cutPrefix(u8, clean_body, "Error:")) |rest| clean_body = trimSpace(rest);
        const hint: []const u8 = switch (self.status.class()) {
            .server_error => "\nCheck the Lyra server logs for details.",
            else => switch (self.status) {
                .unauthorized => "\nSet auth_token in config.json to a valid Lyra bearer token, then restart lyra-rpc.",
                else => "",
            },
        };
        try writer.print("{s}: HTTP {}{s}{s}{s}", .{
            self.label,
            @intFromEnum(self.status),
            if (clean_body.len == 0) "" else ": ",
            clean_body,
            hint,
        });
    }
};

pub fn activePlaybackPath(alloc: Allocator, cursor: ?[]const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("/api/playbacks?active=true");
    if (cursor) |value| {
        try out.writer.writeAll("&cursor=");
        try writePathEscaped(&out.writer, value);
    }
    return out.toOwnedSlice();
}

pub fn trackLookupPath(alloc: Allocator, track_id: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("/api/tracks/");
    try writePathEscaped(&out.writer, track_id);
    try out.writer.writeAll("?inc=releases%2Cartists");
    return out.toOwnedSlice();
}

pub const ReleaseLookupIncludes = packed struct(u3) {
    artists: bool = false,
    covers: bool = false,
    genres: bool = false,

    pub fn any(self: ReleaseLookupIncludes) bool {
        return @as(u3, @bitCast(self)) != 0;
    }

    pub fn contains(self: ReleaseLookupIncludes, required: ReleaseLookupIncludes) bool {
        const self_bits: u3 = @bitCast(self);
        const required_bits: u3 = @bitCast(required);
        return self_bits & required_bits == required_bits;
    }

    pub fn merge(self: ReleaseLookupIncludes, other: ReleaseLookupIncludes) ReleaseLookupIncludes {
        return @bitCast(@as(u3, @bitCast(self)) | @as(u3, @bitCast(other)));
    }
};

pub fn releaseLookupPath(
    alloc: Allocator,
    release_id: []const u8,
    includes: ReleaseLookupIncludes,
) ![]u8 {
    var out: Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("/api/releases/");
    try writePathEscaped(&out.writer, release_id);
    if (includes.any()) {
        try out.writer.writeAll("?inc=");
        var needs_separator = false;
        inline for (std.meta.fields(ReleaseLookupIncludes)) |field| {
            if (@field(includes, field.name)) {
                if (needs_separator) try out.writer.writeAll("%2C");
                try out.writer.writeAll(field.name);
                needs_separator = true;
            }
        }
    }
    return out.toOwnedSlice();
}

fn writePathEscaped(writer: *Io.Writer, input: []const u8) Io.Writer.Error!void {
    try @as(std.Uri.Component, .{ .raw = input }).formatEscaped(writer);
}

pub fn trimSpace(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n");
}

test "releaseYear" {
    try std.testing.expectEqualStrings("2024", releaseYear(.{ .release_date = "2024-05-01" }));
    try std.testing.expectEqualStrings("", releaseYear(.{ .release_date = "abcd-05-01" }));
    try std.testing.expectEqualStrings("", releaseYear(.{ .release_date = "20" }));
    try std.testing.expectEqualStrings("", releaseYear(.{}));
}

test "displayArtistNames: prefers primary credits" {
    const artists = [_]Artist{
        .{ .name = "Primary One", .credit = .{ .type = .artist } },
        .{ .name = "Featured", .credit = .{ .type = .unknown } },
        .{ .name = "Primary One", .credit = .{ .type = .artist } },
    };
    const names = try displayArtistNames(std.testing.allocator, &artists);
    defer std.testing.allocator.free(names);
    try std.testing.expectEqual(1, names.len);
    try std.testing.expectEqualStrings("Primary One", names[0]);
}

test "displayArtistNames: falls back to all names" {
    const artists = [_]Artist{
        .{ .name = "First" },
        .{ .name = "Second" },
        .{ .name = "First" },
    };
    const names = try displayArtistNames(std.testing.allocator, &artists);
    defer std.testing.allocator.free(names);
    try std.testing.expectEqual(2, names.len);
    try std.testing.expectEqualStrings("First", names[0]);
    try std.testing.expectEqualStrings("Second", names[1]);
}

test "playbackLogLine: includes artists" {
    const track: Track = .{
        .title = "Song",
        .artists = @constCast(&[_]Artist{
            .{ .name = "Artist One", .credit = .{ .type = .artist } },
            .{ .name = "Artist Two", .credit = .{ .type = .artist } },
        }),
    };
    const paused = try playbackLogLine(std.testing.allocator, .paused, track);
    defer std.testing.allocator.free(paused);
    try std.testing.expectEqualStrings("Paused: Song - Artist One, Artist Two", paused);
}

test "playbackLogLine: omits empty artist suffix" {
    const line = try playbackLogLine(std.testing.allocator, .playing, .{ .title = "Song" });
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("Playing: Song", line);
}

test "ApiStatusError: format" {
    try std.testing.expectFmt(
        "tracks API: HTTP 400: Failed to deserialize query string: duplicate field `inc`",
        "{f}",
        .{ApiStatusError{
            .label = "tracks API",
            .status = .bad_request,
            .body = "Failed to deserialize query string: duplicate field `inc`\n",
        }},
    );
    try std.testing.expectFmt(
        "tracks API: HTTP 500\nCheck the Lyra server logs for details.",
        "{f}",
        .{ApiStatusError{ .label = "tracks API", .status = .internal_server_error, .body = "" }},
    );
    try std.testing.expectFmt(
        "Error fetching playback: HTTP 500: internal server error\nCheck the Lyra server logs for details.",
        "{f}",
        .{ApiStatusError{
            .label = "Error fetching playback",
            .status = .internal_server_error,
            .body = "Error: internal server error\n",
        }},
    );
    try std.testing.expectFmt(
        "Error fetching playback: HTTP 401: missing bearer credential\nSet auth_token in config.json to a valid Lyra bearer token, then restart lyra-rpc.",
        "{f}",
        .{ApiStatusError{
            .label = "Error fetching playback",
            .status = .unauthorized,
            .body = "Error: missing bearer credential",
        }},
    );
}

test "lookup paths: escape ids and list includes" {
    const track_path = try trackLookupPath(std.testing.allocator, "track/id");
    defer std.testing.allocator.free(track_path);
    try std.testing.expectEqualStrings("/api/tracks/track%2Fid?inc=releases%2Cartists", track_path);

    const cover_path = try releaseLookupPath(std.testing.allocator, "release/id", .{ .covers = true });
    defer std.testing.allocator.free(cover_path);
    try std.testing.expectEqualStrings("/api/releases/release%2Fid?inc=covers", cover_path);

    const artists_path = try releaseLookupPath(std.testing.allocator, "release/id", .{ .artists = true });
    defer std.testing.allocator.free(artists_path);
    try std.testing.expectEqualStrings("/api/releases/release%2Fid?inc=artists", artists_path);

    const full_path = try releaseLookupPath(std.testing.allocator, "release/id", .{
        .artists = true,
        .covers = true,
        .genres = true,
    });
    defer std.testing.allocator.free(full_path);
    try std.testing.expectEqualStrings("/api/releases/release%2Fid?inc=artists%2Ccovers%2Cgenres", full_path);
}

test "ReleaseLookupIncludes: set operations" {
    const covers: ReleaseLookupIncludes = .{ .covers = true };
    try std.testing.expect(!ReleaseLookupIncludes.any(.{}));
    try std.testing.expect(covers.any());
    try std.testing.expect(covers.contains(.{}));
    try std.testing.expect(covers.contains(.{ .covers = true }));
    try std.testing.expect(!covers.contains(.{ .genres = true }));
    const merged = covers.merge(.{ .genres = true });
    try std.testing.expect(merged.covers and merged.genres and !merged.artists);
}

test "PlaybackPage: decodes native and reported current playback" {
    for ([_][]const u8{ "1", "null" }) |revision| {
        const body = try std.fmt.allocPrint(std.testing.allocator,
            \\{{"items":[{{"id":"context","user_id":"user","queue_revision":{s},
            \\"updated_at":"2026-09-10T07:00:00Z","current":{{
            \\"track_id":"track","position_ms":1200,"effective_position_ms":1500,
            \\"duration_ms":3000,"state":"playing","activity_ms":3400,
            \\"updated_at":"2026-09-10T07:00:00Z","client_name":"Player"
            \\}}}}],"next_cursor":null}}
        , .{revision});
        defer std.testing.allocator.free(body);
        const page = try std.json.parseFromSlice(PlaybackPage, std.testing.allocator, body, json_parse_options);
        defer page.deinit();

        const current = page.value.firstCurrent().?;
        try std.testing.expectEqualStrings("track", current.track_id);
        try std.testing.expectEqual(.playing, current.state);
        try std.testing.expectEqual(1200, current.position_ms);
        try std.testing.expectEqual(1500, current.effective_position_ms);
        try std.testing.expectEqual(3000, current.duration_ms.?);
        try std.testing.expect(page.value.next_cursor == null);
    }
}

test "PlaybackPage: preserves order and skips null current playback" {
    const page = try std.json.parseFromSlice(PlaybackPage, std.testing.allocator,
        \\{"items":[{"current":null},
        \\{"current":{"track_id":"first","state":"paused","duration_ms":null}},
        \\{"current":{"track_id":"second","state":"playing"}}],"next_cursor":"next"}
    , json_parse_options);
    defer page.deinit();

    const current = page.value.firstCurrent().?;
    try std.testing.expectEqualStrings("first", current.track_id);
    try std.testing.expectEqual(.paused, current.state);
    try std.testing.expect(current.duration_ms == null);
    try std.testing.expectEqualStrings("next", page.value.next_cursor.?);
}

test "PlaybackPage: no current playback keeps the cursor" {
    for ([_][]const u8{
        \\{"items":[],"next_cursor":null}
        ,
        \\{"items":[{"current":null}],"next_cursor":"next"}
        ,
    }) |body| {
        const page = try std.json.parseFromSlice(PlaybackPage, std.testing.allocator, body, json_parse_options);
        defer page.deinit();
        try std.testing.expect(page.value.firstCurrent() == null);
        if (page.value.items.len != 0) {
            try std.testing.expectEqualStrings("next", page.value.next_cursor.?);
        }
    }
}

test "PlaybackState: unknown states decode instead of failing" {
    const page = try std.json.parseFromSlice(PlaybackPage, std.testing.allocator,
        \\{"items":[{"current":{"track_id":"t","state":"buffering"}}],"next_cursor":null}
    , json_parse_options);
    defer page.deinit();
    try std.testing.expectEqual(.unknown, page.value.firstCurrent().?.state);
}

test "activePlaybackPath: preserves the filter and escapes cursors" {
    const first = try activePlaybackPath(std.testing.allocator, null);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("/api/playbacks?active=true", first);
    const next = try activePlaybackPath(std.testing.allocator, "a+/=&?");
    defer std.testing.allocator.free(next);
    try std.testing.expectEqualStrings("/api/playbacks?active=true&cursor=a%2B%2F%3D%26%3F", next);
}

test "Track: decodes nullable includes" {
    var track = try std.json.parseFromSlice(Track, std.testing.allocator,
        \\{
        \\  "id": "track",
        \\  "title": "Song",
        \\  "disc": 2,
        \\  "track": 7,
        \\  "year": 2024,
        \\  "artists": null,
        \\  "releases": null,
        \\  "duration_ms": 222000
        \\}
    , json_parse_options);
    defer track.deinit();

    try std.testing.expectEqualStrings("Song", track.value.title);
    try std.testing.expectEqual(2, track.value.disc.?);
    try std.testing.expectEqual(7, track.value.track.?);
    try std.testing.expectEqual(2024, track.value.year.?);
    try std.testing.expectEqual(222000, track.value.duration_ms.?);
    try std.testing.expectEqual(0, trackArtists(track.value).len);
    try std.testing.expectEqual(0, trackReleases(track.value).len);
}

test "Release: decodes the documented cover response" {
    var release = try std.json.parseFromSlice(Release, std.testing.allocator,
        \\{
        \\  "id": "rel",
        \\  "title": "Album",
        \\  "release_date": "2021-07-14",
        \\  "cover": {
        \\    "id": "cov",
        \\    "url": "/api/covers/cov?v=hash",
        \\    "mime_type": "image/jpeg",
        \\    "hash": "hash",
        \\    "blurhash": null
        \\  },
        \\  "artists": [
        \\    {
        \\      "name": "Release Artist",
        \\      "credit": {
        \\        "type": "artist"
        \\      }
        \\    }
        \\  ],
        \\  "genres": ["Rock", "Pop"]
        \\}
    , json_parse_options);
    defer release.deinit();
    const cover = release.value.cover orelse return error.TestExpectedCover;
    try std.testing.expectEqualStrings("/api/covers/cov?v=hash", cover.url);
    const artists = releaseArtists(release.value);
    try std.testing.expectEqual(1, artists.len);
    try std.testing.expectEqualStrings("Release Artist", artists[0].name);
    try std.testing.expectEqual(.artist, artists[0].credit.?.type);
    const genres = releaseGenres(release.value);
    try std.testing.expectEqual(2, genres.len);
    try std.testing.expectEqualStrings("Rock", genres[0]);
    try std.testing.expectEqualStrings("Pop", genres[1]);
}

test "json strings do not borrow the response body" {
    const body = try std.testing.allocator.dupe(u8,
        \\{"id":"track","title":"Song","artists":[{"name":"Artist","credit":{"type":"artist"}}],"releases":[]}
    );
    var parsed = try std.json.parseFromSlice(Track, std.testing.allocator, body, json_parse_options);
    std.testing.allocator.free(body);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Song", parsed.value.title);
    const artists = trackArtists(parsed.value);
    try std.testing.expectEqual(1, artists.len);
    try std.testing.expectEqualStrings("Artist", artists[0].name);
}
