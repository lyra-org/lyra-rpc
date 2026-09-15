// This Source Code Form is subject to the terms of the Lyra Public License,
// v1.0. If a copy of the Lyra Public License was not distributed with this
// file, You can obtain one here:
// www.meshiplaw.com/lyra.

const Config = @This();

const std = @import("std");
const presencepkg = @import("presence.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const max_config_bytes = 1024 * 1024;

/// A trailing slash is tolerated.
base_url: []const u8 = "http://localhost:4746",

/// Empty disables the Authorization header.
auth_token: []const u8 = "",

poll_interval_sec: u32 = 5,

images: Images = .{},

presence: Presence = .{},

pub const Uploader = enum {
    none,
    litterbox,
    imgur,
};

pub const Images = struct {
    uploader: Uploader = .none,

    /// Required when `uploader` is `.imgur`.
    imgur_client_id: []const u8 = "",
};

pub const Presence = struct {
    title: []const u8 = "{track.title}",

    subtitle: []const u8 = "{release.title} ({release.year})",

    /// Third line and large image hover text.
    image_text: []const u8 = "{artists}",

    list_separator: []const u8 = ", ",
};

pub const ValidateError = error{MissingImgurClientId} || presencepkg.TemplateError;

pub const LoadError = Io.Dir.ReadFileAllocError ||
    std.json.ParseError(std.json.Scanner) ||
    ValidateError;

/// Defaults apply when `path` is absent.
/// `arena_alloc` must be an arena: input and parsed allocations are retained
/// on success and failure. It must outlive the config and Apps borrowing it.
pub fn load(arena_alloc: Allocator, io: Io, path: []const u8) LoadError!Config {
    const data = Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena_alloc,
        .limited(max_config_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };

    var config = try std.json.parseFromSliceLeaky(Config, arena_alloc, data, .{
        .ignore_unknown_fields = true,
    });

    const defaults: Config = .{};
    if (config.base_url.len == 0) config.base_url = defaults.base_url;
    if (config.poll_interval_sec == 0) config.poll_interval_sec = defaults.poll_interval_sec;

    try config.validate();
    return config;
}

pub fn validate(self: Config) ValidateError!void {
    if (self.images.uploader == .imgur and self.images.imgur_client_id.len == 0) {
        return error.MissingImgurClientId;
    }
    try presencepkg.validate(self.presence);
}

test "partial presence config keeps the other defaults" {
    var parsed = try std.json.parseFromSlice(Config, std.testing.allocator,
        \\{"presence":{"image_text":"Lyra"}}
    , .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("{track.title}", parsed.value.presence.title);
    try std.testing.expectEqualStrings("{release.title} ({release.year})", parsed.value.presence.subtitle);
    try std.testing.expectEqualStrings("Lyra", parsed.value.presence.image_text);
    try std.testing.expectEqualStrings(", ", parsed.value.presence.list_separator);
}

test "validate requires an imgur client id" {
    const config: Config = .{ .images = .{ .uploader = .imgur } };
    try std.testing.expectError(error.MissingImgurClientId, config.validate());

    const ok: Config = .{ .images = .{ .uploader = .imgur, .imgur_client_id = "id" } };
    try ok.validate();
}

test "validate rejects unknown placeholders" {
    const config: Config = .{ .presence = .{ .title = "{bad.placeholder}" } };
    try std.testing.expectError(error.InvalidPresenceTemplate, config.validate());
}
