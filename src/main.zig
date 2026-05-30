// This Source Code Form is subject to the terms of the Lyra Public License,
// v1.0. If a copy of the Lyra Public License was not distributed with this
// file, You can obtain one here:
// www.meshiplaw.com/lyra.

const std = @import("std");
const builtin = @import("builtin");

const App = @import("App.zig");
const discord = @import("discord.zig");
const lyra = @import("lyra.zig");

const Io = std.Io;

var shutdown_requested = std.atomic.Value(bool).init(false);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const config = lyra.loadConfig(arena, init.io, "config.json") catch |err| {
        std.debug.print("Error loading config: {s}\n", .{@errorName(err)});
        return err;
    };

    if (config.images.uploader == .imgur and config.images.imgur_client_id.len == 0) {
        std.debug.print("images.imgur_client_id is required when images.uploader is set to \"imgur\"\n", .{});
        return error.MissingImgurClientId;
    }

    var app = try App.init(init.gpa, init.io, init.environ_map, config);
    defer app.deinit();

    app.discord.login(discord.client_id) catch |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        return err;
    };

    installSignalHandlers();
    logInfo("Rich presence is running. Press Ctrl+C to exit.", .{});

    app.poll();
    while (!shutdown_requested.load(.seq_cst)) {
        sleepUntilNextPoll(init.io, config.poll_interval_sec);
        if (shutdown_requested.load(.seq_cst)) break;
        app.poll();
    }
    logInfo("Shutting down.", .{});
}

fn sleepUntilNextPoll(io: Io, seconds: u32) void {
    var remaining_ms: i64 = @as(i64, seconds) * std.time.ms_per_s;
    while (remaining_ms > 0 and !shutdown_requested.load(.seq_cst)) {
        const step_ms = @min(remaining_ms, 100);
        Io.sleep(io, .fromMilliseconds(step_ms), .awake) catch return;
        remaining_ms -= step_ms;
    }
}

fn installSignalHandlers() void {
    switch (builtin.os.tag) {
        .windows => return,
        else => {
            const act: std.posix.Sigaction = .{
                .handler = .{ .handler = shutdownSignalHandler },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            std.posix.sigaction(.INT, &act, null);
            std.posix.sigaction(.TERM, &act, null);
        },
    }
}

fn shutdownSignalHandler(_: std.posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
}

fn logInfo(comptime format: []const u8, args: anytype) void {
    std.debug.print(format ++ "\n", args);
}

test {
    _ = App;
    _ = discord;
    _ = lyra;
}
