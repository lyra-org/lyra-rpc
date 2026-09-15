// This Source Code Form is subject to the terms of the Lyra Public License,
// v1.0. If a copy of the Lyra Public License was not distributed with this
// file, You can obtain one here:
// www.meshiplaw.com/lyra.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = std.log.scoped(.discord);

pub const client_id = "1474543583473176846";

/// Discord accepts only asset names or absolute URLs.
pub const paused_image = "https://files.catbox.moe/ibpq2d.png";

/// Only `.listening` renders "Listening to".
pub const ActivityType = enum(u8) {
    playing = 0,
    streaming = 1,
    listening = 2,
    watching = 3,
    custom = 4,
    competing = 5,
};

const Opcode = enum(u32) {
    handshake = 0,
    frame = 1,
    close = 2,
    ping = 3,
    pong = 4,
};

pub const Assets = struct {
    large_image: []const u8 = "",
    large_text: []const u8 = "",
    small_image: []const u8 = "",
    small_text: []const u8 = "",
};

/// Unix timestamps in milliseconds. Discord renders a progress bar when
/// both are set.
pub const Timestamps = struct {
    start: u64,
    end: ?u64 = null,
};

pub const Activity = struct {
    type: ActivityType = .listening,
    details: []const u8 = "",
    state: []const u8 = "",
    assets: Assets = .{},
    timestamps: ?Timestamps = null,
};

pub const Client = struct {
    alloc: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,

    conn: ?IpcConn = null,

    pub const ConnectError = error{
        IpcSocketNotFound,
        IpcConnectFailed,
    } || Allocator.Error || Io.Dir.AccessError;

    /// Transport errors are logged before returning `WriteFailed` or `ReadFailed`.
    pub const Error = error{
        NotConnected,
        EmptyResponse,
        InvalidResponse,
        CommandRejected,
        ConnectionClosed,
        FrameTooLarge,
    } || Allocator.Error || Io.Writer.Error || Io.Reader.Error;

    pub const LoginError = ConnectError || Error;

    pub fn init(alloc: Allocator, io: Io, environ_map: *std.process.Environ.Map) Client {
        return .{
            .alloc = alloc,
            .io = io,
            .environ_map = environ_map,
        };
    }

    /// No-op if already logged in.
    pub fn login(self: *Client, app_client_id: []const u8) LoginError!void {
        if (self.conn != null) return;
        var conn = try IpcConn.connect(self.alloc, self.io, self.environ_map);
        errdefer conn.close(self.io);

        const payload = try handshakeJson(self.alloc, app_client_id);
        defer self.alloc.free(payload);
        const response = try conn.exchange(self.alloc, self.io, .handshake, payload);
        defer self.alloc.free(response);
        try validateResponse(self.alloc, response, null);
        self.conn = conn;
    }

    pub fn logout(self: *Client) void {
        if (self.conn) |*conn| conn.close(self.io);
        self.conn = null;
    }

    /// Requires an established connection.
    pub fn setActivity(self: *Client, activity: Activity) Error!void {
        const conn = if (self.conn) |*conn| conn else return error.NotConnected;
        const nonce = newNonce(self.io);
        const payload = try activityFrameJson(self.alloc, activity, &nonce);
        defer self.alloc.free(payload);
        errdefer |err| {
            if (err != error.CommandRejected) self.logout();
        }
        try conn.command(self.alloc, self.io, payload, &nonce);
    }

    /// Requires an established connection.
    pub fn clearActivity(self: *Client) Error!void {
        const conn = if (self.conn) |*conn| conn else return error.NotConnected;
        const nonce = newNonce(self.io);
        const payload = try clearActivityFrameJson(self.alloc, &nonce);
        defer self.alloc.free(payload);
        errdefer |err| {
            if (err != error.CommandRejected) self.logout();
        }
        try conn.command(self.alloc, self.io, payload, &nonce);
    }
};

const IpcConn = union(enum) {
    stream: Io.net.Stream,
    file: Io.File,

    // Two little-endian u32s (opcode, length), followed by the JSON payload.
    const frame_header_len = 8;
    // Local resource limit, comfortably above READY and activity responses.
    const max_frame_len = 1024 * 1024;

    const Frame = struct {
        opcode: Opcode,
        payload: []const u8,
    };

    fn connect(
        alloc: Allocator,
        io: Io,
        environ_map: *std.process.Environ.Map,
    ) Client.ConnectError!IpcConn {
        switch (builtin.os.tag) {
            .windows => return connectWindows(alloc, io),
            else => {
                const socket_path = try ipcSocketPath(alloc, io, environ_map);
                defer alloc.free(socket_path);
                const address = Io.net.UnixAddress.init(socket_path) catch |err| {
                    log.warn("invalid ipc socket path path={s} err={}", .{ socket_path, err });
                    return error.IpcConnectFailed;
                };
                const stream = address.connect(io) catch |err| {
                    log.warn("ipc connect failed path={s} err={}", .{ socket_path, err });
                    return error.IpcConnectFailed;
                };
                return .{ .stream = stream };
            },
        }
    }

    fn connectWindows(alloc: Allocator, io: Io) Client.ConnectError!IpcConn {
        for (0..10) |index| {
            const pipe_name = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\discord-ipc-{}", .{index});
            defer alloc.free(pipe_name);
            const file = Io.Dir.openFileAbsolute(io, pipe_name, .{
                .mode = .read_write,
                .allow_directory = false,
            }) catch |err| {
                log.debug("ipc pipe unavailable pipe={s} err={}", .{ pipe_name, err });
                continue;
            };
            return .{ .file = file };
        }
        return error.IpcConnectFailed;
    }

    fn close(self: *IpcConn, io: Io) void {
        switch (self.*) {
            .stream => |*stream| stream.close(io),
            .file => |file| file.close(io),
        }
        self.* = undefined;
    }

    fn command(self: *IpcConn, alloc: Allocator, io: Io, payload: []const u8, nonce: []const u8) Client.Error!void {
        const response = try self.exchange(alloc, io, .frame, payload);
        defer alloc.free(response);
        try validateResponse(alloc, response, nonce);
    }

    /// Caller owns the reply payload.
    fn exchange(
        self: *IpcConn,
        alloc: Allocator,
        io: Io,
        opcode: Opcode,
        payload: []const u8,
    ) Client.Error![]const u8 {
        if (payload.len > max_frame_len) return error.FrameTooLarge;
        var header: [frame_header_len]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intFromEnum(opcode), .little);
        std.mem.writeInt(u32, header[4..8], @intCast(payload.len), .little);

        try self.writeFrame(io, &header, payload);
        while (true) {
            const response = try self.readFrame(alloc, io);
            switch (response.opcode) {
                .frame => return response.payload,
                .ping => {
                    defer alloc.free(response.payload);
                    std.mem.writeInt(u32, header[0..4], @intFromEnum(Opcode.pong), .little);
                    std.mem.writeInt(u32, header[4..8], @intCast(response.payload.len), .little);
                    try self.writeFrame(io, &header, response.payload);
                },
                .close => {
                    alloc.free(response.payload);
                    return error.ConnectionClosed;
                },
                else => {
                    alloc.free(response.payload);
                    return error.InvalidResponse;
                },
            }
        }
    }

    fn writeFrame(
        self: *IpcConn,
        io: Io,
        header: []const u8,
        payload: []const u8,
    ) Io.Writer.Error!void {
        var buffer: [1024]u8 = undefined;
        switch (self.*) {
            .stream => |stream| {
                var writer = stream.writer(io, &buffer);
                writeFrameTo(&writer.interface, header, payload) catch |err| {
                    log.warn("ipc write failed err={?}", .{writer.err});
                    return err;
                };
            },
            .file => |file| {
                var writer = file.writerStreaming(io, &buffer);
                writeFrameTo(&writer.interface, header, payload) catch |err| {
                    log.warn("ipc write failed err={?}", .{writer.err});
                    return err;
                };
            },
        }
    }

    fn readFrame(self: *IpcConn, alloc: Allocator, io: Io) Client.Error!Frame {
        // A fresh reader must not read ahead into the next frame.
        var buffer: [0]u8 = .{};
        switch (self.*) {
            .stream => |stream| {
                var reader = stream.reader(io, &buffer);
                return readFrameFrom(alloc, &reader.interface) catch |err| {
                    log.warn("ipc read failed err={?}", .{reader.err});
                    return err;
                };
            },
            .file => |file| {
                var reader = file.readerStreaming(io, &buffer);
                return readFrameFrom(alloc, &reader.interface) catch |err| {
                    log.warn("ipc read failed err={?}", .{reader.err});
                    return err;
                };
            },
        }
    }

    fn writeFrameTo(writer: *Io.Writer, header: []const u8, payload: []const u8) Io.Writer.Error!void {
        try writer.writeAll(header);
        try writer.writeAll(payload);
        try writer.flush();
    }

    fn readFrameFrom(alloc: Allocator, reader: *Io.Reader) Client.Error!Frame {
        var header: [frame_header_len]u8 = undefined;
        try reader.readSliceAll(&header);

        const opcode = std.enums.fromInt(Opcode, std.mem.readInt(u32, header[0..4], .little)) orelse
            return error.InvalidResponse;
        const length = std.mem.readInt(u32, header[4..8], .little);
        if (length > max_frame_len) return error.FrameTooLarge;

        const payload = try alloc.alloc(u8, length);
        errdefer alloc.free(payload);
        try reader.readSliceAll(payload);
        return .{ .opcode = opcode, .payload = payload };
    }
};

/// A handshake expects READY; a command expects its matching successful reply.
fn validateResponse(alloc: Allocator, payload: []const u8, nonce: ?[]const u8) Client.Error!void {
    if (payload.len == 0) return error.EmptyResponse;
    const Response = struct {
        cmd: []const u8,
        evt: ?[]const u8 = null,
        nonce: ?[]const u8 = null,
        data: std.json.Value,
    };
    const parsed = std.json.parseFromSlice(Response, alloc, payload, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    const response = parsed.value;
    if (nonce) |expected| {
        if (!std.mem.eql(u8, response.cmd, "SET_ACTIVITY")) return error.InvalidResponse;
        const actual = response.nonce orelse return error.InvalidResponse;
        if (!std.mem.eql(u8, actual, expected)) return error.InvalidResponse;
        if (response.evt) |event| {
            if (std.mem.eql(u8, event, "ERROR")) return error.CommandRejected;
            return error.InvalidResponse;
        }
    } else {
        if (response.evt) |event| {
            if (std.mem.eql(u8, event, "ERROR")) return error.CommandRejected;
        }
        if (!std.mem.eql(u8, response.cmd, "DISPATCH") or
            !std.mem.eql(u8, response.evt orelse return error.InvalidResponse, "READY") or
            response.nonce != null or response.data != .object)
            return error.InvalidResponse;
    }
    if (response.data != .object and response.data != .null) return error.InvalidResponse;
}

fn ipcSocketPath(
    alloc: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
) Client.ConnectError![]u8 {
    if (environ_map.get("XDG_RUNTIME_DIR")) |base| {
        if (try ipcPathInBase(alloc, io, base)) |path| return path;
        const snap_base = try std.fs.path.join(alloc, &.{ base, "snap.discord" });
        defer alloc.free(snap_base);
        if (try ipcPathInBase(alloc, io, snap_base)) |path| return path;
        const flatpak_base = try std.fs.path.join(alloc, &.{ base, ".flatpak/com.discordapp.Discord/xdg-run" });
        defer alloc.free(flatpak_base);
        if (try ipcPathInBase(alloc, io, flatpak_base)) |path| return path;
    }

    inline for (.{ "TMPDIR", "TMP", "TEMP" }) |env_name| {
        if (environ_map.get(env_name)) |base| {
            if (try ipcPathInBase(alloc, io, base)) |path| return path;
        }
    }

    if (try ipcPathInBase(alloc, io, "/tmp")) |path| return path;
    return error.IpcSocketNotFound;
}

fn ipcPathInBase(alloc: Allocator, io: Io, base: []const u8) Client.ConnectError!?[]u8 {
    if (base.len == 0) return null;
    const path = try std.fs.path.join(alloc, &.{ base, "discord-ipc-0" });
    errdefer alloc.free(path);
    Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            alloc.free(path);
            return null;
        },
        else => return err,
    };
    return path;
}

const JsonError = Allocator.Error || Io.Writer.Error;

fn handshakeJson(alloc: Allocator, app_client_id: []const u8) JsonError![]u8 {
    var out: Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.write(.{
        .v = 1,
        .client_id = app_client_id,
    });
    return out.toOwnedSlice();
}

fn clearActivityFrameJson(alloc: Allocator, nonce: []const u8) JsonError![]u8 {
    var out: Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try writeSetActivityFrame(&json, null, nonce);
    return out.toOwnedSlice();
}

fn activityFrameJson(
    alloc: Allocator,
    activity: Activity,
    nonce: []const u8,
) JsonError![]u8 {
    var out: Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try writeSetActivityFrame(&json, activity, nonce);
    return out.toOwnedSlice();
}

fn writeSetActivityFrame(
    json: *std.json.Stringify,
    activity: ?Activity,
    nonce: []const u8,
) Io.Writer.Error!void {
    try json.beginObject();
    try json.objectField("cmd");
    try json.write("SET_ACTIVITY");
    try json.objectField("args");
    try json.beginObject();
    try json.objectField("pid");
    try json.write(processId());
    try json.objectField("activity");
    if (activity) |value| try writeActivity(json, value) else try json.write(null);
    try json.endObject();
    try json.objectField("nonce");
    try json.write(nonce);
    try json.endObject();
}

fn writeActivity(json: *std.json.Stringify, activity: Activity) Io.Writer.Error!void {
    try json.beginObject();
    try json.objectField("type");
    try json.write(@intFromEnum(activity.type));
    try writeStringIfSet(json, "details", activity.details);
    try writeStringIfSet(json, "state", activity.state);
    try json.objectField("assets");
    try writeAssets(json, activity.assets);
    if (activity.timestamps) |timestamps| {
        try json.objectField("timestamps");
        try writeTimestamps(json, timestamps);
    }
    try json.endObject();
}

fn writeAssets(json: *std.json.Stringify, assets: Assets) Io.Writer.Error!void {
    try json.beginObject();
    try writeStringIfSet(json, "large_image", assets.large_image);
    try writeStringIfSet(json, "large_text", assets.large_text);
    try writeStringIfSet(json, "small_image", assets.small_image);
    try writeStringIfSet(json, "small_text", assets.small_text);
    try json.endObject();
}

fn writeTimestamps(json: *std.json.Stringify, timestamps: Timestamps) Io.Writer.Error!void {
    try json.beginObject();
    try json.objectField("start");
    try json.write(timestamps.start);
    if (timestamps.end) |end| {
        try json.objectField("end");
        try json.write(end);
    }
    try json.endObject();
}

/// Discord rejects empty strings for most fields, so omit them instead.
fn writeStringIfSet(json: *std.json.Stringify, name: []const u8, value: []const u8) Io.Writer.Error!void {
    if (value.len == 0) return;
    try json.objectField(name);
    try json.write(value);
}

fn processId() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .windows => std.os.windows.GetCurrentProcessId(),
        else => 0,
    };
}

/// A random UUID v4, which is what Discord expects for the `nonce` field.
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

test "newNonce: uuid v4 shape" {
    const nonce = newNonce(std.testing.io);

    try std.testing.expectEqual(36, nonce.len);
    try std.testing.expectEqual('-', nonce[8]);
    try std.testing.expectEqual('-', nonce[13]);
    try std.testing.expectEqual('-', nonce[18]);
    try std.testing.expectEqual('-', nonce[23]);
    try std.testing.expectEqual('4', nonce[14]);
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", nonce[19]) != null);
}

test "handshakeJson" {
    const frame = try handshakeJson(std.testing.allocator, "123");
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqualStrings("{\"v\":1,\"client_id\":\"123\"}", frame);
}

test "clearActivityFrameJson: encodes null activity" {
    const frame = try clearActivityFrameJson(std.testing.allocator, "nonce");
    defer std.testing.allocator.free(frame);
    const normalized = try normalizePidForTest(std.testing.allocator, frame);
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings(
        "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":0,\"activity\":null},\"nonce\":\"nonce\"}",
        normalized,
    );
}

test "activityFrameJson: encodes the Discord payload shape" {
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
    }, "nonce");
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

fn normalizePidForTest(alloc: Allocator, input: []const u8) ![]u8 {
    const prefix = "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":";
    const suffix_start = std.mem.indexOf(u8, input, ",\"activity\"") orelse return error.TestUnexpectedPayload;
    if (!std.mem.startsWith(u8, input, prefix)) return error.TestUnexpectedPayload;
    return std.fmt.allocPrint(alloc, "{s}0{s}", .{ prefix, input[suffix_start..] });
}

test "readFrame: consecutive frames survive fresh transport readers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{
        .sub_path = "frames",
        .data = "\x01\x00\x00\x00\x03\x00\x00\x00one" ++
            "\x01\x00\x00\x00\x03\x00\x00\x00two",
    });
    var conn: IpcConn = .{ .file = try tmp.dir.openFile(io, "frames", .{}) };
    defer conn.close(io);
    const first = try conn.readFrame(std.testing.allocator, io);
    defer std.testing.allocator.free(first.payload);
    const second = try conn.readFrame(std.testing.allocator, io);
    defer std.testing.allocator.free(second.payload);
    try std.testing.expectEqual(.frame, first.opcode);
    try std.testing.expectEqualStrings("one", first.payload);
    try std.testing.expectEqualStrings("two", second.payload);
}

test "readFrameFrom: rejects oversized unknown and truncated frames" {
    var oversized = Io.Reader.fixed("\x01\x00\x00\x00\x01\x00\x10\x00");
    try std.testing.expectError(error.FrameTooLarge, IpcConn.readFrameFrom(std.testing.allocator, &oversized));
    var unknown = Io.Reader.fixed("\xff\x00\x00\x00\x00\x00\x00\x00");
    try std.testing.expectError(error.InvalidResponse, IpcConn.readFrameFrom(std.testing.allocator, &unknown));
    var truncated = Io.Reader.fixed("\x01\x00\x00\x00\x03\x00\x00\x00a");
    try std.testing.expectError(error.EndOfStream, IpcConn.readFrameFrom(std.testing.allocator, &truncated));
}

test "ipcPathInBase: missing socket frees its path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path_buffer);
    try std.testing.expectEqual(null, try ipcPathInBase(std.testing.allocator, std.testing.io, path_buffer[0..length]));
}

test "validateResponse: requires READY or the matching successful command" {
    const alloc = std.testing.allocator;
    try validateResponse(alloc, "{\"cmd\":\"DISPATCH\",\"evt\":\"READY\",\"data\":{}}", null);
    try validateResponse(alloc, "{\"cmd\":\"SET_ACTIVITY\",\"nonce\":\"abc\",\"data\":{}}", "abc");
    try validateResponse(alloc, "{\"cmd\":\"SET_ACTIVITY\",\"nonce\":\"abc\",\"evt\":null,\"data\":null}", "abc");
    try std.testing.expectError(error.CommandRejected, validateResponse(alloc, "{\"cmd\":\"SET_ACTIVITY\",\"nonce\":\"abc\",\"evt\":\"ERROR\",\"data\":{\"code\":4000}}", "abc"));
    try std.testing.expectError(error.InvalidResponse, validateResponse(alloc, "{\"cmd\":\"SET_ACTIVITY\",\"nonce\":\"other\",\"data\":{}}", "abc"));
    try std.testing.expectError(error.InvalidResponse, validateResponse(alloc, "{\"cmd\":\"DISPATCH\",\"evt\":\"READY\",\"data\":{}}", "abc"));
    try std.testing.expectError(error.InvalidResponse, validateResponse(alloc, "{\"cmd\":\"SET_ACTIVITY\",\"nonce\":\"abc\",\"data\":{}}", null));
    try std.testing.expectError(error.InvalidResponse, validateResponse(alloc, "not json", "abc"));
    try std.testing.expectError(error.InvalidResponse, validateResponse(alloc, "{}", "abc"));
    try std.testing.expectError(error.EmptyResponse, validateResponse(alloc, "", null));
}

test "exchange: socket preserves consecutive frames and answers ping" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &path_buffer);
    const path = try std.fs.path.join(alloc, &.{ path_buffer[0..length], "ipc" });
    defer alloc.free(path);
    const address = try Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var conn: IpcConn = .{ .stream = try address.connect(io) };
    defer conn.close(io);
    var peer: IpcConn = .{ .stream = try server.accept(io) };
    defer peer.close(io);
    try peer.writeFrame(io, "\x03\x00\x00\x00\x04\x00\x00\x00", "ping");
    try peer.writeFrame(io, "\x01\x00\x00\x00\x03\x00\x00\x00", "one");
    try peer.writeFrame(io, "\x01\x00\x00\x00\x03\x00\x00\x00", "two");
    const response = try conn.exchange(alloc, io, .frame, "request");
    defer alloc.free(response);
    try std.testing.expectEqualStrings("one", response);
    const second = try conn.readFrame(alloc, io);
    defer alloc.free(second.payload);
    try std.testing.expectEqualStrings("two", second.payload);
    const request = try peer.readFrame(alloc, io);
    defer alloc.free(request.payload);
    try std.testing.expectEqualStrings("request", request.payload);
    const pong = try peer.readFrame(alloc, io);
    defer alloc.free(pong.payload);
    try std.testing.expectEqual(.pong, pong.opcode);
    try std.testing.expectEqualStrings("ping", pong.payload);
}

test "Client: command rejection retains connection but malformed reply closes it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &path_buffer);
    const path = try std.fs.path.join(alloc, &.{ path_buffer[0..length], "ipc" });
    defer alloc.free(path);
    const address = try Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var environ = std.process.Environ.Map.init(alloc);
    defer environ.deinit();
    var client = Client.init(alloc, io, &environ);
    defer client.logout();
    client.conn = .{ .stream = try address.connect(io) };
    const peer = try server.accept(io);
    const Peer = struct {
        fn respond(stream: Io.net.Stream) !void {
            var conn: IpcConn = .{ .stream = stream };
            defer conn.close(std.testing.io);
            const request = try conn.readFrame(std.testing.allocator, std.testing.io);
            defer std.testing.allocator.free(request.payload);
            const parsed = try std.json.parseFromSlice(struct { nonce: []const u8 }, std.testing.allocator, request.payload, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            const response = try std.fmt.allocPrint(std.testing.allocator, "{{\"cmd\":\"SET_ACTIVITY\",\"nonce\":\"{s}\",\"evt\":\"ERROR\",\"data\":{{\"code\":4000}}}}", .{parsed.value.nonce});
            defer std.testing.allocator.free(response);
            var header: [8]u8 = undefined;
            std.mem.writeInt(u32, header[0..4], 1, .little);
            std.mem.writeInt(u32, header[4..8], @intCast(response.len), .little);
            try conn.writeFrame(std.testing.io, &header, response);
            const retry = try conn.readFrame(std.testing.allocator, std.testing.io);
            defer std.testing.allocator.free(retry.payload);
            try conn.writeFrame(std.testing.io, "\x01\x00\x00\x00\x03\x00\x00\x00", "bad");
        }
    };
    var task = io.concurrent(Peer.respond, .{peer}) catch |err| {
        peer.close(io);
        return err;
    };
    defer task.cancel(io) catch {};
    try std.testing.expectError(error.CommandRejected, client.setActivity(.{}));
    try std.testing.expect(client.conn != null);
    try std.testing.expectError(error.InvalidResponse, client.clearActivity());
    try std.testing.expectEqual(null, client.conn);
    try std.testing.expectError(error.NotConnected, client.setActivity(.{}));
    try task.await(io);
}
