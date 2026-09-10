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

pub const PresenceConfig = struct {
    title: []const u8 = "{track.title}",
    subtitle: []const u8 = "{release.title} ({release.year})",
    image_text: []const u8 = "{artists}",
    list_separator: []const u8 = ", ",
};

pub const Config = struct {
    base_url: []const u8 = "http://localhost:4746",
    auth_token: []const u8 = "",
    poll_interval_sec: u32 = 5,
    images: ImageConfig = .{},
    presence: PresenceConfig = .{},
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
    artists: ?[]Artist = null,
    genres: ?[]const []const u8 = null,
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
    disc: ?u32 = null,
    track: ?u32 = null,
    year: ?u32 = null,
    duration_ms: ?u64 = null,
    artists: ?[]Artist = null,
    releases: ?[]Release = null,
};

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

pub fn loadConfig(allocator: Allocator, io: Io, path: []const u8) !Config {
    const data = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const loaded = try std.json.parseFromSliceLeaky(Config, allocator, data, .{
        .ignore_unknown_fields = true,
    });

    var config: Config = .{};
    if (loaded.base_url.len != 0) config.base_url = loaded.base_url;
    config.auth_token = loaded.auth_token;
    if (loaded.poll_interval_sec > 0) config.poll_interval_sec = loaded.poll_interval_sec;
    config.images = loaded.images;
    config.presence = loaded.presence;
    try validatePresenceConfig(config.presence);
    return config;
}

pub const PresenceTemplateContext = struct {
    track: Track,
    release: ?Release = null,
    artists: []const u8 = "",
    release_artists: []const u8 = "",
    release_genres: []const u8 = "",
};

pub const PresenceText = struct {
    allocator: Allocator,
    title: []u8,
    subtitle: []u8,
    image_text: []u8,

    pub fn deinit(self: *PresenceText) void {
        self.allocator.free(self.title);
        self.allocator.free(self.subtitle);
        self.allocator.free(self.image_text);
        self.* = undefined;
    }
};

pub fn renderPresenceText(
    allocator: Allocator,
    config: PresenceConfig,
    context: PresenceTemplateContext,
) !PresenceText {
    const title = try renderPresenceTemplate(allocator, config.title, context);
    errdefer allocator.free(title);

    const subtitle = try renderPresenceTemplate(allocator, config.subtitle, context);
    errdefer allocator.free(subtitle);

    const image_text = try renderPresenceTemplate(allocator, config.image_text, context);
    errdefer allocator.free(image_text);

    return .{
        .allocator = allocator,
        .title = title,
        .subtitle = subtitle,
        .image_text = image_text,
    };
}

pub const PresenceTemplateInputs = struct {
    track_artists: bool = false,
    release: bool = false,
    release_artists: bool = false,
    release_genres: bool = false,

    pub fn releaseLookupIncludes(self: PresenceTemplateInputs) ReleaseLookupIncludes {
        return .{
            .artists = self.release_artists,
            .genres = self.release_genres,
        };
    }
};

const PresencePlaceholder = enum {
    artists,
    track_title,
    track_id,
    track_year,
    track_disc,
    track_number,
    track_duration,
    release_title,
    release_date,
    release_year,
    release_artists,
    release_genres,
};

const presence_placeholders = std.StaticStringMap(PresencePlaceholder).initComptime(.{
    .{ "artists", .artists },
    .{ "track.title", .track_title },
    .{ "track.id", .track_id },
    .{ "track.year", .track_year },
    .{ "track.disc", .track_disc },
    .{ "track.number", .track_number },
    .{ "track.duration", .track_duration },
    .{ "release.title", .release_title },
    .{ "release.date", .release_date },
    .{ "release.year", .release_year },
    .{ "release.artists", .release_artists },
    .{ "release.genres", .release_genres },
});

pub fn presenceConfigInputs(config: PresenceConfig) PresenceTemplateInputs {
    const release_artists = presenceConfigUsesPlaceholder(config, .release_artists);
    const release_genres = presenceConfigUsesPlaceholder(config, .release_genres);

    return .{
        .track_artists = presenceConfigUsesPlaceholder(config, .artists),
        .release = release_artists or
            release_genres or
            presenceConfigUsesPlaceholder(config, .release_title) or
            presenceConfigUsesPlaceholder(config, .release_date) or
            presenceConfigUsesPlaceholder(config, .release_year),
        .release_artists = release_artists,
        .release_genres = release_genres,
    };
}

fn presenceConfigUsesPlaceholder(config: PresenceConfig, expected: PresencePlaceholder) bool {
    return presenceTemplateUsesPlaceholder(config.title, expected) or
        presenceTemplateUsesPlaceholder(config.subtitle, expected) or
        presenceTemplateUsesPlaceholder(config.image_text, expected);
}

pub fn validatePresenceConfig(config: PresenceConfig) !void {
    try validatePresenceTemplate(config.title);
    try validatePresenceTemplate(config.subtitle);
    try validatePresenceTemplate(config.image_text);
}

fn renderPresenceTemplate(
    allocator: Allocator,
    template: []const u8,
    context: PresenceTemplateContext,
) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var index: usize = 0;
    while (index < template.len) {
        if (template[index] != '{') {
            const next = std.mem.findScalarPos(u8, template, index, '{') orelse template.len;
            try out.writer.writeAll(template[index..next]);
            index = next;
            continue;
        }

        const end = std.mem.findScalarPos(u8, template, index + 1, '}') orelse {
            return error.InvalidPresenceTemplate;
        };
        const placeholder = try presencePlaceholder(template[index + 1 .. end]);
        try writePresencePlaceholder(&out.writer, context, placeholder);
        index = end + 1;
    }

    removeEmptyParenthesizedGroups(&out);
    return out.toOwnedSlice();
}

fn validatePresenceTemplate(template: []const u8) !void {
    var index: usize = 0;
    while (index < template.len) {
        const start = std.mem.findScalarPos(u8, template, index, '{') orelse return;
        const end = std.mem.findScalarPos(u8, template, start + 1, '}') orelse {
            return error.InvalidPresenceTemplate;
        };
        _ = try presencePlaceholder(template[start + 1 .. end]);
        index = end + 1;
    }
}

fn presenceTemplateUsesPlaceholder(template: []const u8, expected: PresencePlaceholder) bool {
    var index: usize = 0;
    while (index < template.len) {
        const start = std.mem.findScalarPos(u8, template, index, '{') orelse return false;
        const end = std.mem.findScalarPos(u8, template, start + 1, '}') orelse return false;
        const placeholder = presencePlaceholder(template[start + 1 .. end]) catch {
            index = end + 1;
            continue;
        };
        if (placeholder == expected) return true;
        index = end + 1;
    }
    return false;
}

fn presencePlaceholder(name: []const u8) !PresencePlaceholder {
    return presence_placeholders.get(name) orelse error.InvalidPresenceTemplate;
}

fn writePresencePlaceholder(
    writer: *Io.Writer,
    context: PresenceTemplateContext,
    placeholder: PresencePlaceholder,
) !void {
    switch (placeholder) {
        .artists => try writer.writeAll(context.artists),
        .track_title => try writer.writeAll(context.track.title),
        .track_id => try writer.writeAll(context.track.id),
        .track_year => if (context.track.year) |value| try writer.print("{}", .{value}),
        .track_disc => if (context.track.disc) |value| try writer.print("{}", .{value}),
        .track_number => if (context.track.track) |value| try writer.print("{}", .{value}),
        .track_duration => if (context.track.duration_ms) |value| try writeDuration(writer, value),
        .release_title => if (context.release) |release| try writer.writeAll(release.title),
        .release_date => if (context.release) |release| try writer.writeAll(release.release_date orelse ""),
        .release_year => if (context.release) |release| try writer.writeAll(releaseYear(release)),
        .release_artists => try writer.writeAll(context.release_artists),
        .release_genres => try writer.writeAll(context.release_genres),
    }
}

fn removeEmptyParenthesizedGroups(out: *Io.Writer.Allocating) void {
    const new_len = compactEmptyParenthesizedGroups(out.written());
    out.shrinkRetainingCapacity(new_len);
}

fn compactEmptyParenthesizedGroups(input: []u8) usize {
    var index: usize = 0;
    var write_index: usize = 0;
    while (index < input.len) {
        if (input[index] == '(') {
            if (std.mem.findScalarPos(u8, input, index + 1, ')')) |end| {
                if (trimSpace(input[index + 1 .. end]).len == 0) {
                    while (write_index > 0 and isTemplateSpace(input[write_index - 1])) {
                        write_index -= 1;
                    }

                    index = end + 1;
                    while (index < input.len and isTemplateSpace(input[index])) {
                        index += 1;
                    }
                    if (index < input.len and write_index > 0) {
                        input[write_index] = ' ';
                        write_index += 1;
                    }
                    continue;
                }
            }
        }

        input[write_index] = input[index];
        write_index += 1;
        index += 1;
    }

    var start: usize = 0;
    while (start < write_index and isTemplateSpace(input[start])) {
        start += 1;
    }

    var end = write_index;
    while (end > start and isTemplateSpace(input[end - 1])) {
        end -= 1;
    }

    const new_len = end - start;
    if (start > 0 and new_len > 0) {
        @memmove(input[0..new_len], input[start..end]);
    }
    return new_len;
}

fn isTemplateSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
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

pub fn formatDuration(allocator: Allocator, duration_ms: u64) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeDuration(&out.writer, duration_ms);
    return out.toOwnedSlice();
}

fn writeDuration(writer: *Io.Writer, duration_ms: u64) !void {
    const total_seconds = duration_ms / 1000;
    const seconds = total_seconds % 60;
    const total_minutes = total_seconds / 60;
    const minutes = total_minutes % 60;
    const hours = total_minutes / 60;
    if (hours > 0) {
        try writer.print("{}:{d:0>2}:{d:0>2}", .{
            hours,
            minutes,
            seconds,
        });
        return;
    }
    try writer.print("{}:{d:0>2}", .{
        total_minutes,
        seconds,
    });
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

    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.print("{s}: {s}", .{ state_label, track.title });
    if (artist_names.len > 0) {
        try out.writer.writeAll(" - ");
        try writeJoinedStrings(&out.writer, ", ", artist_names);
    }
    return out.toOwnedSlice();
}

fn writeJoinedStrings(
    writer: *Io.Writer,
    separator: []const u8,
    values: []const []const u8,
) !void {
    for (values, 0..) |value, index| {
        if (index > 0) try writer.writeAll(separator);
        try writer.writeAll(value);
    }
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

pub fn activePlaybackPath(allocator: Allocator, cursor: ?[]const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeAll("/api/playbacks?active=true");
    if (cursor) |value| {
        try out.writer.writeAll("&cursor=");
        try writePathEscaped(&out.writer, value);
    }
    return out.toOwnedSlice();
}

pub fn trackLookupPath(allocator: Allocator, track_id: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeAll("/api/tracks/");
    try writePathEscaped(&out.writer, track_id);
    try out.writer.writeAll("?inc=releases%2Cartists");
    return out.toOwnedSlice();
}

pub fn releaseCoverLookupPath(allocator: Allocator, release_id: []const u8) ![]u8 {
    return releaseLookupPath(allocator, release_id, .{ .covers = true });
}

pub fn releaseGenresLookupPath(allocator: Allocator, release_id: []const u8) ![]u8 {
    return releaseLookupPath(allocator, release_id, .{ .genres = true });
}

pub const ReleaseLookupIncludes = struct {
    artists: bool = false,
    covers: bool = false,
    genres: bool = false,

    pub fn any(self: ReleaseLookupIncludes) bool {
        return self.artists or self.covers or self.genres;
    }

    pub fn contains(self: ReleaseLookupIncludes, required: ReleaseLookupIncludes) bool {
        return (!required.artists or self.artists) and
            (!required.covers or self.covers) and
            (!required.genres or self.genres);
    }

    pub fn merge(self: ReleaseLookupIncludes, other: ReleaseLookupIncludes) ReleaseLookupIncludes {
        return .{
            .artists = self.artists or other.artists,
            .covers = self.covers or other.covers,
            .genres = self.genres or other.genres,
        };
    }
};

pub fn releaseLookupPath(
    allocator: Allocator,
    release_id: []const u8,
    includes: ReleaseLookupIncludes,
) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeAll("/api/releases/");
    try writePathEscaped(&out.writer, release_id);
    if (includes.artists or includes.covers or includes.genres) {
        try out.writer.writeAll("?inc=");
        var needs_separator = false;
        if (includes.artists) {
            try out.writer.writeAll("artists");
            needs_separator = true;
        }
        if (includes.covers) {
            if (needs_separator) try out.writer.writeAll("%2C");
            try out.writer.writeAll("covers");
            needs_separator = true;
        }
        if (includes.genres) {
            if (needs_separator) try out.writer.writeAll("%2C");
            try out.writer.writeAll("genres");
        }
    }
    return out.toOwnedSlice();
}

pub fn pathEscapeAlloc(allocator: Allocator, input: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writePathEscaped(&out.writer, input);
    return out.toOwnedSlice();
}

fn writePathEscaped(writer: *Io.Writer, input: []const u8) !void {
    try @as(std.Uri.Component, .{ .raw = input }).formatEscaped(writer);
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

test "format duration" {
    const short = try formatDuration(std.testing.allocator, 222_000);
    defer std.testing.allocator.free(short);
    try std.testing.expectEqualStrings("3:42", short);

    const long = try formatDuration(std.testing.allocator, 3_784_000);
    defer std.testing.allocator.free(long);
    try std.testing.expectEqualStrings("1:03:04", long);
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
    const track: Track = .{
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

test "presence templates render configured text" {
    const release: Release = .{
        .title = "Album",
        .release_date = "2024-05-01",
    };
    var text = try renderPresenceText(std.testing.allocator, .{}, .{
        .track = .{ .id = "track", .title = "Song" },
        .release = release,
        .artists = "Artist One, Artist Two",
    });
    defer text.deinit();

    try std.testing.expectEqualStrings("Song", text.title);
    try std.testing.expectEqualStrings("Album (2024)", text.subtitle);
    try std.testing.expectEqualStrings("Artist One, Artist Two", text.image_text);
}

test "presence templates remove empty parenthesized groups" {
    var text = try renderPresenceText(std.testing.allocator, .{}, .{
        .track = .{ .title = "Song" },
        .release = .{ .title = "Album" },
        .artists = "Artist",
    });
    defer text.deinit();

    try std.testing.expectEqualStrings("Album", text.subtitle);

    var cleaned = try std.testing.allocator.dupe(u8, "A () B");
    defer std.testing.allocator.free(cleaned);
    const cleaned_len = compactEmptyParenthesizedGroups(cleaned);
    try std.testing.expectEqualStrings("A B", cleaned[0..cleaned_len]);
}

test "presence templates render hardcoded strings and release genres" {
    const genres = [_][]const u8{ "Rock", "Pop" };
    var text = try renderPresenceText(std.testing.allocator, .{
        .title = "Lyra",
        .subtitle = "{release.date} - {release.artists} - {release.genres}",
        .image_text = "{track.id} {track.year} {track.disc}.{track.number} {track.duration}",
    }, .{
        .track = .{
            .id = "track",
            .title = "Song",
            .year = 2024,
            .disc = 2,
            .track = 7,
            .duration_ms = 222_000,
        },
        .release = .{ .title = "Album", .release_date = "2024-05-01", .genres = &genres },
        .release_artists = "Release Artist",
        .release_genres = "Rock, Pop",
    });
    defer text.deinit();

    try std.testing.expectEqualStrings("Lyra", text.title);
    try std.testing.expectEqualStrings("2024-05-01 - Release Artist - Rock, Pop", text.subtitle);
    try std.testing.expectEqualStrings("track 2024 2.7 3:42", text.image_text);
}

test "presence templates reject unknown placeholders" {
    try std.testing.expectError(error.InvalidPresenceTemplate, validatePresenceConfig(.{
        .title = "{bad.placeholder}",
    }));
}

test "config decodes partial presence defaults" {
    var parsed = try std.json.parseFromSlice(Config, std.testing.allocator,
        \\{"presence":{"image_text":"Lyra"}}
    , .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("{track.title}", parsed.value.presence.title);
    try std.testing.expectEqualStrings("{release.title} ({release.year})", parsed.value.presence.subtitle);
    try std.testing.expectEqualStrings("Lyra", parsed.value.presence.image_text);
    try std.testing.expectEqualStrings(", ", parsed.value.presence.list_separator);
}

test "presence config input analysis tracks required placeholders" {
    const defaults = presenceConfigInputs(.{});
    try std.testing.expect(defaults.track_artists);
    try std.testing.expect(defaults.release);
    try std.testing.expect(!defaults.release_artists);
    try std.testing.expect(!defaults.release_genres);

    const hardcoded = presenceConfigInputs(.{
        .title = "Lyra",
        .subtitle = "Playing",
        .image_text = "Music",
    });
    try std.testing.expect(!hardcoded.track_artists);
    try std.testing.expect(!hardcoded.release);

    const release_lists = presenceConfigInputs(.{
        .subtitle = "{release.artists} / {release.genres}",
    });
    try std.testing.expect(release_lists.release);
    try std.testing.expect(release_lists.release_artists);
    try std.testing.expect(release_lists.release_genres);
    try std.testing.expect(release_lists.releaseLookupIncludes().contains(.{
        .artists = true,
        .genres = true,
    }));
}

test "format Lyra request error for connection refused" {
    const raw_error = "dial_tcp failed for address localhost:4746\n" ++
        "tried addrs:\n" ++
        "\t[::1]:4746: net: socket error: 111; code: 111";
    const message = try formatLyraRequestError(
        std.testing.allocator,
        "http://localhost:4746/",
        "http://localhost:4746/api/playbacks?active=true",
        raw_error,
    );
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings(
        "could not connect to Lyra at http://localhost:4746 (connection refused). " ++
            "Start Lyra, or update base_url in config.json.",
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

    const release_genres_path = try releaseGenresLookupPath(std.testing.allocator, "release/id");
    defer std.testing.allocator.free(release_genres_path);
    try std.testing.expectEqualStrings("/api/releases/release%2Fid?inc=genres", release_genres_path);

    const release_artists_path = try releaseLookupPath(std.testing.allocator, "release/id", .{
        .artists = true,
    });
    defer std.testing.allocator.free(release_artists_path);
    try std.testing.expectEqualStrings("/api/releases/release%2Fid?inc=artists", release_artists_path);

    const release_full_path = try releaseLookupPath(std.testing.allocator, "release/id", .{
        .artists = true,
        .covers = true,
        .genres = true,
    });
    defer std.testing.allocator.free(release_full_path);
    try std.testing.expectEqualStrings("/api/releases/release%2Fid?inc=artists%2Ccovers%2Cgenres", release_full_path);
}

test "playback pages decode native and reported current playback" {
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
        const page = try std.json.parseFromSlice(PlaybackPage, std.testing.allocator, body, api_json_parse_options);
        defer page.deinit();

        const current = page.value.firstCurrent().?;
        try std.testing.expectEqualStrings("track", current.track_id);
        try std.testing.expectEqualStrings("playing", current.state);
        try std.testing.expectEqual(@as(u64, 1200), current.position_ms);
        try std.testing.expectEqual(@as(u64, 1500), current.effective_position_ms);
        try std.testing.expectEqual(@as(u64, 3000), current.duration_ms.?);
        try std.testing.expect(page.value.next_cursor == null);
    }
}

test "playback pages preserve order and skip null current playback" {
    const page = try std.json.parseFromSlice(PlaybackPage, std.testing.allocator,
        \\{"items":[{"current":null},
        \\{"current":{"track_id":"first","state":"paused","duration_ms":null}},
        \\{"current":{"track_id":"second","state":"playing"}}],"next_cursor":"next"}
    , api_json_parse_options);
    defer page.deinit();

    const current = page.value.firstCurrent().?;
    try std.testing.expectEqualStrings("first", current.track_id);
    try std.testing.expectEqualStrings("paused", current.state);
    try std.testing.expect(current.duration_ms == null);
    try std.testing.expectEqualStrings("next", page.value.next_cursor.?);
}

test "playback pages allow no current playback without hiding a cursor" {
    for ([_][]const u8{
        \\{"items":[],"next_cursor":null}
        ,
        \\{"items":[{"current":null}],"next_cursor":"next"}
        ,
    }) |body| {
        const page = try std.json.parseFromSlice(PlaybackPage, std.testing.allocator, body, api_json_parse_options);
        defer page.deinit();
        try std.testing.expect(page.value.firstCurrent() == null);
        if (page.value.items.len != 0) {
            try std.testing.expectEqualStrings("next", page.value.next_cursor.?);
        }
    }
}

test "active playback paths preserve the filter and escape cursors" {
    const first = try activePlaybackPath(std.testing.allocator, null);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("/api/playbacks?active=true", first);
    const next = try activePlaybackPath(std.testing.allocator, "a+/=&?");
    defer std.testing.allocator.free(next);
    try std.testing.expectEqualStrings("/api/playbacks?active=true&cursor=a%2B%2F%3D%26%3F", next);
}

test "track decodes nullable documented includes" {
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
    , api_json_parse_options);
    defer track.deinit();

    try std.testing.expectEqualStrings("Song", track.value.title);
    try std.testing.expectEqual(@as(u32, 2), track.value.disc.?);
    try std.testing.expectEqual(@as(u32, 7), track.value.track.?);
    try std.testing.expectEqual(@as(u32, 2024), track.value.year.?);
    try std.testing.expectEqual(@as(u64, 222000), track.value.duration_ms.?);
    try std.testing.expectEqual(@as(usize, 0), trackArtists(track.value).len);
    try std.testing.expectEqual(@as(usize, 0), trackReleases(track.value).len);
}

test "release decodes documented cover response" {
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
    , api_json_parse_options);
    defer release.deinit();
    const cover = release.value.cover orelse return error.TestExpectedCover;
    try std.testing.expectEqualStrings("cov", cover.id);
    try std.testing.expectEqualStrings("/api/covers/cov?v=hash", cover.url);
    try std.testing.expectEqualStrings("image/jpeg", cover.mime_type);
    try std.testing.expectEqualStrings("hash", cover.hash);
    const artists = releaseArtists(release.value);
    try std.testing.expectEqual(@as(usize, 1), artists.len);
    try std.testing.expectEqualStrings("Release Artist", artists[0].name);
    const genres = releaseGenres(release.value);
    try std.testing.expectEqual(@as(usize, 2), genres.len);
    try std.testing.expectEqualStrings("Rock", genres[0]);
    try std.testing.expectEqualStrings("Pop", genres[1]);
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
