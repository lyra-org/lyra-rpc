// This Source Code Form is subject to the terms of the Lyra Public License,
// v1.0. If a copy of the Lyra Public License was not distributed with this
// file, You can obtain one here:
// www.meshiplaw.com/lyra.

const std = @import("std");
const builtin = @import("builtin");

const App = @import("App.zig");
const Config = @import("Config.zig");
const discord = @import("discord.zig");

const Io = std.Io;

const log = std.log.scoped(.main);

pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
};

/// Set by the signal handler; the poll loop checks it between sleeps.
var shutdown_requested: std.atomic.Value(bool) = .init(false);

const shutdown_poll_interval: Io.Duration = .fromMilliseconds(100);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const config = Config.load(arena, init.io, "config.json") catch |err| {
        switch (err) {
            error.MissingImgurClientId => log.err(
                "images.imgur_client_id is required when images.uploader is \"imgur\"",
                .{},
            ),
            error.InvalidPresenceTemplate => log.err(
                "presence templates contain an unknown placeholder or an unclosed brace",
                .{},
            ),
            else => log.err("failed to load config.json err={}", .{err}),
        }
        return err;
    };

    var app = try App.init(init.gpa, init.io, init.environ_map, config);
    defer app.deinit();

    app.discord.login(discord.client_id) catch |err| {
        log.err("failed to connect to Discord err={}", .{err});
        return err;
    };

    installSignalHandlers();
    log.info("rich presence is running, press Ctrl+C to exit", .{});

    app.poll();
    while (!shutdown_requested.load(.seq_cst)) {
        sleepUntilNextPoll(init.io, config.poll_interval_sec);
        if (shutdown_requested.load(.seq_cst)) break;
        app.poll();
    }
    log.info("shutting down", .{});
}

/// Short sleeps keep shutdown responsive.
fn sleepUntilNextPoll(io: Io, seconds: u32) void {
    var remaining: Io.Duration = .fromSeconds(seconds);
    while (remaining.nanoseconds > 0 and !shutdown_requested.load(.seq_cst)) {
        const step: Io.Duration = .{ .nanoseconds = @min(remaining.nanoseconds, shutdown_poll_interval.nanoseconds) };
        Io.sleep(io, step, .awake) catch return;
        remaining.nanoseconds -= step.nanoseconds;
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

test {
    // Zig 0.16 reports any stderr output during tests as a failed command,
    // so keep log output down to errors while testing.
    std.testing.log_level = .err;
    _ = App;
    _ = Config;
    _ = discord;
    _ = @import("lyra.zig");
    _ = @import("presence.zig");
}
