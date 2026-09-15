// This Source Code Form is subject to the terms of the Lyra Public License,
// v1.0. If a copy of the Lyra Public License was not distributed with this
// file, You can obtain one here:
// www.meshiplaw.com/lyra.

const std = @import("std");
const Config = @import("Config.zig");
const lyra = @import("lyra.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const TemplateError = error{InvalidPresenceTemplate};

pub const RenderError = TemplateError || Allocator.Error || Io.Writer.Error;

/// Caller joins lists with the configured separator.
pub const Context = struct {
    track: lyra.Track,
    release: ?lyra.Release = null,
    artists: []const u8 = "",
    release_artists: []const u8 = "",
    release_genres: []const u8 = "",
};

/// Caller owns the strings.
pub const Text = struct {
    title: []u8,
    subtitle: []u8,
    image_text: []u8,

    pub fn deinit(self: *Text, alloc: Allocator) void {
        alloc.free(self.title);
        alloc.free(self.subtitle);
        alloc.free(self.image_text);
        self.* = undefined;
    }
};

pub const Inputs = struct {
    track_artists: bool = false,
    release: bool = false,
    release_artists: bool = false,
    release_genres: bool = false,

    pub fn releaseLookupIncludes(self: Inputs) lyra.ReleaseLookupIncludes {
        return .{
            .artists = self.release_artists,
            .genres = self.release_genres,
        };
    }
};

const Placeholder = enum {
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

const placeholders = std.StaticStringMap(Placeholder).initComptime(.{
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

/// Expands `{placeholder}` markers, e.g. `{release.title} ({release.year})`.
/// Removes empty parenthesized groups and trims surrounding whitespace.
pub fn render(
    alloc: Allocator,
    config: Config.Presence,
    context: Context,
) RenderError!Text {
    const title = try renderTemplate(alloc, config.title, context);
    errdefer alloc.free(title);

    const subtitle = try renderTemplate(alloc, config.subtitle, context);
    errdefer alloc.free(subtitle);

    const image_text = try renderTemplate(alloc, config.image_text, context);
    errdefer alloc.free(image_text);

    return .{
        .title = title,
        .subtitle = subtitle,
        .image_text = image_text,
    };
}

pub fn inputs(config: Config.Presence) Inputs {
    const release_artists = usesPlaceholder(config, .release_artists);
    const release_genres = usesPlaceholder(config, .release_genres);

    return .{
        .track_artists = usesPlaceholder(config, .artists),
        .release = release_artists or
            release_genres or
            usesPlaceholder(config, .release_title) or
            usesPlaceholder(config, .release_date) or
            usesPlaceholder(config, .release_year),
        .release_artists = release_artists,
        .release_genres = release_genres,
    };
}

pub fn validate(config: Config.Presence) TemplateError!void {
    try validateTemplate(config.title);
    try validateTemplate(config.subtitle);
    try validateTemplate(config.image_text);
}

fn usesPlaceholder(config: Config.Presence, expected: Placeholder) bool {
    return templateUsesPlaceholder(config.title, expected) or
        templateUsesPlaceholder(config.subtitle, expected) or
        templateUsesPlaceholder(config.image_text, expected);
}

fn renderTemplate(
    alloc: Allocator,
    template: []const u8,
    context: Context,
) RenderError![]u8 {
    var out: Io.Writer.Allocating = .init(alloc);
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
        const placeholder = try parsePlaceholder(template[index + 1 .. end]);
        try writePlaceholder(&out.writer, context, placeholder);
        index = end + 1;
    }

    const new_len = compactEmptyParenthesizedGroups(out.written());
    out.shrinkRetainingCapacity(new_len);
    return out.toOwnedSlice();
}

fn validateTemplate(template: []const u8) TemplateError!void {
    var index: usize = 0;
    while (index < template.len) {
        const start = std.mem.findScalarPos(u8, template, index, '{') orelse return;
        const end = std.mem.findScalarPos(u8, template, start + 1, '}') orelse {
            return error.InvalidPresenceTemplate;
        };
        _ = try parsePlaceholder(template[start + 1 .. end]);
        index = end + 1;
    }
}

fn templateUsesPlaceholder(template: []const u8, expected: Placeholder) bool {
    var index: usize = 0;
    while (index < template.len) {
        const start = std.mem.findScalarPos(u8, template, index, '{') orelse return false;
        const end = std.mem.findScalarPos(u8, template, start + 1, '}') orelse return false;
        index = end + 1;
        const placeholder = parsePlaceholder(template[start + 1 .. end]) catch continue;
        if (placeholder == expected) return true;
    }
    return false;
}

fn parsePlaceholder(name: []const u8) TemplateError!Placeholder {
    return placeholders.get(name) orelse error.InvalidPresenceTemplate;
}

fn writePlaceholder(
    writer: *Io.Writer,
    context: Context,
    placeholder: Placeholder,
) Io.Writer.Error!void {
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
        .release_year => if (context.release) |release| try writer.writeAll(lyra.releaseYear(release)),
        .release_artists => try writer.writeAll(context.release_artists),
        .release_genres => try writer.writeAll(context.release_genres),
    }
}

fn writeDuration(writer: *Io.Writer, duration_ms: u64) Io.Writer.Error!void {
    const total_seconds = duration_ms / std.time.ms_per_s;
    const seconds = total_seconds % 60;
    const total_minutes = total_seconds / 60;
    const minutes = total_minutes % 60;
    const hours = total_minutes / 60;
    if (hours > 0) {
        try writer.print("{}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds });
        return;
    }
    try writer.print("{}:{d:0>2}", .{ total_minutes, seconds });
}

/// Compacts and trims in place; returns the new length.
fn compactEmptyParenthesizedGroups(input: []u8) usize {
    var index: usize = 0;
    var write_index: usize = 0;
    while (index < input.len) {
        if (input[index] == '(') {
            if (std.mem.findScalarPos(u8, input, index + 1, ')')) |end| {
                if (lyra.trimSpace(input[index + 1 .. end]).len == 0) {
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

test "render: default templates" {
    const release: lyra.Release = .{
        .title = "Album",
        .release_date = "2024-05-01",
    };
    var text = try render(std.testing.allocator, .{}, .{
        .track = .{ .id = "track", .title = "Song" },
        .release = release,
        .artists = "Artist One, Artist Two",
    });
    defer text.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Song", text.title);
    try std.testing.expectEqualStrings("Album (2024)", text.subtitle);
    try std.testing.expectEqualStrings("Artist One, Artist Two", text.image_text);
}

test "render: empty parenthesized groups are removed" {
    var text = try render(std.testing.allocator, .{}, .{
        .track = .{ .title = "Song" },
        .release = .{ .title = "Album" },
        .artists = "Artist",
    });
    defer text.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Album", text.subtitle);

    var cleaned = try std.testing.allocator.dupe(u8, "A () B");
    defer std.testing.allocator.free(cleaned);
    const cleaned_len = compactEmptyParenthesizedGroups(cleaned);
    try std.testing.expectEqualStrings("A B", cleaned[0..cleaned_len]);
}

test "render: hardcoded text and every placeholder" {
    const genres = [_][]const u8{ "Rock", "Pop" };
    var text = try render(std.testing.allocator, .{
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
    defer text.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Lyra", text.title);
    try std.testing.expectEqualStrings("2024-05-01 - Release Artist - Rock, Pop", text.subtitle);
    try std.testing.expectEqualStrings("track 2024 2.7 3:42", text.image_text);
}

test "render: duration with hours" {
    var text = try render(std.testing.allocator, .{
        .title = "{track.duration}",
    }, .{
        .track = .{ .duration_ms = 3_784_000 },
    });
    defer text.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("1:03:04", text.title);
}

test "validate: unknown placeholder and unclosed brace" {
    try std.testing.expectError(error.InvalidPresenceTemplate, validate(.{
        .title = "{bad.placeholder}",
    }));
    try std.testing.expectError(error.InvalidPresenceTemplate, validate(.{
        .subtitle = "{track.title",
    }));
    try validate(.{});
}

test "inputs: tracks the placeholders each template needs" {
    const defaults = inputs(.{});
    try std.testing.expect(defaults.track_artists);
    try std.testing.expect(defaults.release);
    try std.testing.expect(!defaults.release_artists);
    try std.testing.expect(!defaults.release_genres);

    const hardcoded = inputs(.{
        .title = "Lyra",
        .subtitle = "Playing",
        .image_text = "Music",
    });
    try std.testing.expect(!hardcoded.track_artists);
    try std.testing.expect(!hardcoded.release);

    const release_lists = inputs(.{
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
