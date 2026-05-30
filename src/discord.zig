// This Source Code Form is subject to the terms of the Lyra Public License,
// v1.0. If a copy of the Lyra Public License was not distributed with this
// file, You can obtain one here:
// www.meshiplaw.com/lyra.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const client_id = "1474543583473176846";
pub const activity_listening = 2;
pub const paused_image = "https://files.catbox.moe/ibpq2d.png";

pub const Assets = struct {
    large_image: []const u8 = "",
    large_text: []const u8 = "",
    small_image: []const u8 = "",
    small_text: []const u8 = "",
};

pub const Timestamps = struct {
    start: u64,
    end: ?u64 = null,
};

pub const Activity = struct {
    type: u8 = activity_listening,
    details: []const u8 = "",
    state: []const u8 = "",
    assets: Assets = .{},
    timestamps: ?Timestamps = null,
};

pub const Client = struct {
    allocator: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
    conn: ?IpcConn = null,
    logged: bool = false,

    pub fn init(allocator: Allocator, io: Io, environ_map: *std.process.Environ.Map) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .environ_map = environ_map,
        };
    }

    pub fn login(self: *Client, app_client_id: []const u8) !void {
        if (self.logged) return;
        self.conn = try IpcConn.connect(self.allocator, self.io, self.environ_map);
        errdefer {
            if (self.conn) |*conn| conn.close(self.io);
            self.conn = null;
        }

        const payload = try handshakeJson(self.allocator, app_client_id);
        defer self.allocator.free(payload);
        const response = try self.send(0, payload);
        self.allocator.free(response);
        self.logged = true;
    }

    pub fn logout(self: *Client) void {
        self.logged = false;
        if (self.conn) |*conn| conn.close(self.io);
        self.conn = null;
    }

    pub fn setActivity(self: *Client, activity: Activity) !void {
        if (!self.logged) return;
        const nonce = newNonce(self.io);
        const payload = try activityFrameJsonWithNonce(self.allocator, activity, &nonce);
        defer self.allocator.free(payload);
        const response = try self.send(1, payload);
        defer self.allocator.free(response);
        if (response.len == 0) return error.EmptyDiscordResponse;
    }

    pub fn clearActivity(self: *Client) !void {
        if (!self.logged) return;
        const nonce = newNonce(self.io);
        const payload = try clearActivityFrameJsonWithNonce(self.allocator, &nonce);
        defer self.allocator.free(payload);
        const response = try self.send(1, payload);
        defer self.allocator.free(response);
        if (response.len == 0) return error.EmptyDiscordResponse;
    }

    fn send(self: *Client, opcode: u32, payload: []const u8) ![]const u8 {
        const conn = if (self.conn) |*conn| conn else return error.DiscordIpcNotConnected;
        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], opcode, .little);
        std.mem.writeInt(u32, header[4..8], @intCast(payload.len), .little);

        try conn.writeFrame(self.io, &header, payload);
        return conn.readFrame(self.allocator, self.io);
    }
};

const IpcConn = union(enum) {
    stream: Io.net.Stream,
    file: Io.File,

    fn connect(
        allocator: Allocator,
        io: Io,
        environ_map: *std.process.Environ.Map,
    ) !IpcConn {
        switch (builtin.os.tag) {
            .windows => return connectWindowsIpc(allocator, io),
            else => {
                const socket_path = try ipcSocketPath(allocator, io, environ_map);
                defer allocator.free(socket_path);
                const address = try Io.net.UnixAddress.init(socket_path);
                const stream = address.connect(io) catch return error.DiscordIpcConnectFailed;
                return .{ .stream = stream };
            },
        }
    }

    fn close(self: *IpcConn, io: Io) void {
        switch (self.*) {
            .stream => |*stream| stream.close(io),
            .file => |file| file.close(io),
        }
    }

    fn writeFrame(
        self: *IpcConn,
        io: Io,
        header: []const u8,
        payload: []const u8,
    ) !void {
        var buffer: [1024]u8 = undefined;
        switch (self.*) {
            .stream => |stream| {
                var writer = stream.writer(io, &buffer);
                try writeFrameWithWriter(&writer, header, payload);
            },
            .file => |file| {
                var writer = file.writerStreaming(io, &buffer);
                try writeFrameWithWriter(&writer, header, payload);
            },
        }
    }

    fn readFrame(self: *IpcConn, allocator: Allocator, io: Io) ![]const u8 {
        var buffer: [1024]u8 = undefined;
        switch (self.*) {
            .stream => |stream| {
                var reader = stream.reader(io, &buffer);
                return readFrameWithReader(allocator, &reader);
            },
            .file => |file| {
                var reader = file.readerStreaming(io, &buffer);
                return readFrameWithReader(allocator, &reader);
            },
        }
    }
};

fn writeFrameWithWriter(writer: anytype, header: []const u8, payload: []const u8) !void {
    writer.interface.writeAll(header) catch |err| {
        if (err == error.WriteFailed) return writer.err orelse err;
        return err;
    };
    writer.interface.writeAll(payload) catch |err| {
        if (err == error.WriteFailed) return writer.err orelse err;
        return err;
    };
    writer.interface.flush() catch |err| {
        if (err == error.WriteFailed) return writer.err orelse err;
        return err;
    };
}

fn readFrameWithReader(allocator: Allocator, reader: anytype) ![]const u8 {
    var header: [8]u8 = undefined;
    try readExact(reader, &header);

    const length = std.mem.readInt(u32, header[4..8], .little);
    if (length == 0) return "";

    const payload = try allocator.alloc(u8, length);
    errdefer allocator.free(payload);
    try readExact(reader, payload);
    return payload;
}

fn connectWindowsIpc(allocator: Allocator, io: Io) !IpcConn {
    for (0..10) |index| {
        const pipe_name = try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\discord-ipc-{}", .{index});
        defer allocator.free(pipe_name);
        const file = Io.Dir.openFileAbsolute(io, pipe_name, .{
            .mode = .read_write,
            .allow_directory = false,
        }) catch continue;
        return .{ .file = file };
    }
    return error.DiscordIpcConnectFailed;
}

fn readExact(reader: anytype, out: []u8) !void {
    reader.interface.readSliceAll(out) catch |err| switch (err) {
        error.ReadFailed => return reader.err orelse err,
        else => return err,
    };
}

fn ipcSocketPath(
    allocator: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
) ![]u8 {
    if (environ_map.get("XDG_RUNTIME_DIR")) |base| {
        if (try ipcPathInBase(allocator, io, base)) |path| return path;
        const snap_base = try std.fs.path.join(allocator, &.{ base, "snap.discord" });
        defer allocator.free(snap_base);
        if (try ipcPathInBase(allocator, io, snap_base)) |path| return path;
        const flatpak_base = try std.fs.path.join(allocator, &.{ base, ".flatpak/com.discordapp.Discord/xdg-run" });
        defer allocator.free(flatpak_base);
        if (try ipcPathInBase(allocator, io, flatpak_base)) |path| return path;
    }

    inline for (.{ "TMPDIR", "TMP", "TEMP" }) |env_name| {
        if (environ_map.get(env_name)) |base| {
            if (try ipcPathInBase(allocator, io, base)) |path| return path;
        }
    }

    if (try ipcPathInBase(allocator, io, "/tmp")) |path| return path;
    return error.DiscordIpcSocketNotFound;
}

fn ipcPathInBase(allocator: Allocator, io: Io, base: []const u8) !?[]u8 {
    if (base.len == 0) return null;
    const path = try std.fs.path.join(allocator, &.{ base, "discord-ipc-0" });
    errdefer allocator.free(path);
    Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return path;
}

fn handshakeJson(allocator: Allocator, app_client_id: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("v");
    try json.write("1");
    try json.objectField("client_id");
    try json.write(app_client_id);
    try json.endObject();
    return out.toOwnedSlice();
}

fn clearActivityFrameJson(allocator: Allocator) ![]u8 {
    return clearActivityFrameJsonWithNonce(allocator, "nonce");
}

fn clearActivityFrameJsonWithNonce(allocator: Allocator, nonce: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try writeFrameStart(&json);
    try json.write(@as(?u8, null));
    try writeFrameEnd(&json, nonce);
    return out.toOwnedSlice();
}

fn activityFrameJson(allocator: Allocator, activity: Activity) ![]u8 {
    return activityFrameJsonWithNonce(allocator, activity, "nonce");
}

fn activityFrameJsonWithNonce(
    allocator: Allocator,
    activity: Activity,
    nonce: []const u8,
) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try writeFrameStart(&json);
    try writeActivity(&json, activity);
    try writeFrameEnd(&json, nonce);
    return out.toOwnedSlice();
}

fn writeFrameStart(json: *std.json.Stringify) !void {
    try json.beginObject();
    try json.objectField("cmd");
    try json.write("SET_ACTIVITY");
    try json.objectField("args");
    try json.beginObject();
    try json.objectField("pid");
    try json.write(processId());
    try json.objectField("activity");
}

fn writeFrameEnd(json: *std.json.Stringify, nonce: []const u8) !void {
    try json.endObject();
    try json.objectField("nonce");
    try json.write(nonce);
    try json.endObject();
}

fn writeActivity(json: *std.json.Stringify, activity: Activity) !void {
    try json.beginObject();
    try json.objectField("type");
    try json.write(activity.type);
    if (activity.details.len != 0) {
        try json.objectField("details");
        try json.write(activity.details);
    }
    if (activity.state.len != 0) {
        try json.objectField("state");
        try json.write(activity.state);
    }
    try json.objectField("assets");
    try writeAssets(json, activity.assets);
    if (activity.timestamps) |timestamps| {
        try json.objectField("timestamps");
        try writeTimestamps(json, timestamps);
    }
    try json.endObject();
}

fn writeAssets(json: *std.json.Stringify, assets: Assets) !void {
    try json.beginObject();
    if (assets.large_image.len != 0) {
        try json.objectField("large_image");
        try json.write(assets.large_image);
    }
    if (assets.large_text.len != 0) {
        try json.objectField("large_text");
        try json.write(assets.large_text);
    }
    if (assets.small_image.len != 0) {
        try json.objectField("small_image");
        try json.write(assets.small_image);
    }
    if (assets.small_text.len != 0) {
        try json.objectField("small_text");
        try json.write(assets.small_text);
    }
    try json.endObject();
}

fn writeTimestamps(json: *std.json.Stringify, timestamps: Timestamps) !void {
    try json.beginObject();
    try json.objectField("start");
    try json.write(timestamps.start);
    if (timestamps.end) |end| {
        try json.objectField("end");
        try json.write(end);
    }
    try json.endObject();
}

fn processId() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .windows => std.os.windows.GetCurrentProcessId(),
        else => 0,
    };
}

fn newNonce(io: Io) [36]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = std.fmt.bytesToHex(&bytes, .lower);
    var out: [36]u8 = undefined;
    @memcpy(out[0..8], hex[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex[20..32]);
    return out;
}

test "nonce is uuid v4 shaped" {
    const nonce = newNonce(std.testing.io);

    try std.testing.expectEqual(@as(usize, 36), nonce.len);
    try std.testing.expectEqual(@as(u8, '-'), nonce[8]);
    try std.testing.expectEqual(@as(u8, '-'), nonce[13]);
    try std.testing.expectEqual(@as(u8, '-'), nonce[18]);
    try std.testing.expectEqual(@as(u8, '-'), nonce[23]);
    try std.testing.expectEqual(@as(u8, '4'), nonce[14]);
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", nonce[19]) != null);
}

test "clear activity frame encodes null activity" {
    const frame = try clearActivityFrameJson(std.testing.allocator);
    defer std.testing.allocator.free(frame);
    const normalized = try normalizePidForTest(std.testing.allocator, frame);
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings(
        "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":0,\"activity\":null},\"nonce\":\"nonce\"}",
        normalized,
    );
}

test "activity frame encodes Discord payload shape" {
    const frame = try activityFrameJson(std.testing.allocator, .{
        .details = "Track",
        .state = "Album (2024)",
        .assets = .{
            .large_image = "logo-dark",
            .large_text = "Artist",
            .small_image = "playing",
            .small_text = "Playing",
        },
        .timestamps = .{ .start = 1000, .end = 2000 },
    });
    defer std.testing.allocator.free(frame);
    const normalized = try normalizePidForTest(std.testing.allocator, frame);
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings(
        "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":0,\"activity\":{\"type\":2," ++
            "\"details\":\"Track\",\"state\":\"Album (2024)\",\"assets\":{" ++
            "\"large_image\":\"logo-dark\",\"large_text\":\"Artist\"," ++
            "\"small_image\":\"playing\",\"small_text\":\"Playing\"}," ++
            "\"timestamps\":{\"start\":1000,\"end\":2000}}},\"nonce\":\"nonce\"}",
        normalized,
    );
}

fn normalizePidForTest(allocator: Allocator, input: []const u8) ![]u8 {
    const prefix = "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":";
    const suffix_start = std.mem.indexOf(u8, input, ",\"activity\"") orelse return error.TestUnexpectedPayload;
    if (!std.mem.startsWith(u8, input, prefix)) return error.TestUnexpectedPayload;
    return std.fmt.allocPrint(allocator, "{s}0{s}", .{ prefix, input[suffix_start..] });
}
