const std = @import("std");

pub const State = struct {
    path: ?[]const u8 = null,
    time_pos: f64 = 0,
    duration: f64 = 0,
    paused: bool = true,
    chapter: i64 = 0,
    speed: f64 = 1,
    volume: f64 = 100,
    ended: bool = false,
};

pub const Chapter = struct {
    index: usize,
    title: []const u8,
    start_seconds: f64,
};

pub fn deinitChapters(allocator: std.mem.Allocator, chapters: []const Chapter) void {
    for (chapters) |chapter| allocator.free(chapter.title);
    if (chapters.len != 0) allocator.free(chapters);
}

pub fn parseChapters(allocator: std.mem.Allocator, response: []const u8) ![]Chapter {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidChapterList;
    const data = parsed.value.object.get("data") orelse return error.InvalidChapterList;
    if (data != .array) return error.InvalidChapterList;
    var chapters: std.ArrayList(Chapter) = .empty;
    errdefer {
        for (chapters.items) |chapter| allocator.free(chapter.title);
        chapters.deinit(allocator);
    }
    const limit = @min(data.array.items.len, 1000);
    for (data.array.items[0..limit], 0..) |value, index| {
        if (value != .object) continue;
        const title_value = value.object.get("title");
        const title = if (title_value != null and title_value.? == .string and title_value.?.string.len != 0)
            try allocator.dupe(u8, title_value.?.string)
        else
            try std.fmt.allocPrint(allocator, "Chapter {d}", .{index + 1});
        errdefer allocator.free(title);
        const time_value = value.object.get("time");
        try chapters.append(allocator, .{
            .index = index,
            .title = title,
            .start_seconds = if (time_value) |time| jsonNumber(time) orelse 0 else 0,
        });
    }
    return chapters.toOwnedSlice(allocator);
}

pub fn queryChapters(allocator: std.mem.Allocator, io: std.Io, socket_path: []const u8) ![]Chapter {
    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(io);
    defer stream.close(io);
    var write_buffer: [256]u8 = undefined;
    var stream_writer: std.Io.net.Stream.Writer = .init(stream, io, &write_buffer);
    try stream_writer.interface.writeAll("{\"command\":[\"get_property\",\"chapter-list\"],\"request_id\":41}\n");
    try stream_writer.interface.flush();
    const read_buffer = try allocator.alloc(u8, 512 * 1024);
    defer allocator.free(read_buffer);
    var stream_reader: std.Io.net.Stream.Reader = .init(stream, io, read_buffer);
    const line = (try stream_reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;
    return parseChapters(allocator, line);
}

/// Read a coherent snapshot from mpv's JSON IPC socket. Each request carries
/// an id because asynchronous mpv events can be interleaved with replies.
/// Unavailable properties leave the supplied fallback value unchanged; this
/// is expected briefly while a newly loaded file is being demuxed.
pub fn queryState(allocator: std.mem.Allocator, io: std.Io, socket_path: []const u8, fallback: State) !State {
    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(io);
    defer stream.close(io);

    var write_buffer: [2048]u8 = undefined;
    var stream_writer: std.Io.net.Stream.Writer = .init(stream, io, &write_buffer);
    try stream_writer.interface.writeAll(
        "{\"command\":[\"get_property\",\"time-pos\"],\"request_id\":1}\n" ++
            "{\"command\":[\"get_property\",\"duration\"],\"request_id\":2}\n" ++
            "{\"command\":[\"get_property\",\"pause\"],\"request_id\":3}\n" ++
            "{\"command\":[\"get_property\",\"chapter\"],\"request_id\":4}\n" ++
            "{\"command\":[\"get_property\",\"speed\"],\"request_id\":5}\n" ++
            "{\"command\":[\"get_property\",\"volume\"],\"request_id\":6}\n" ++
            "{\"command\":[\"get_property\",\"eof-reached\"],\"request_id\":7}\n" ++
            "{\"command\":[\"get_property\",\"idle-active\"],\"request_id\":8}\n",
    );
    try stream_writer.interface.flush();

    var state = fallback;
    var read_buffer: [4096]u8 = undefined;
    var stream_reader: std.Io.net.Stream.Reader = .init(stream, io, &read_buffer);
    var received: u16 = 0;
    var lines: u8 = 0;
    while (received != 0xff and lines < 32) : (lines += 1) {
        const line = (try stream_reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const id_value = parsed.value.object.get("request_id") orelse continue;
        if (id_value != .integer or id_value.integer < 1 or id_value.integer > 8) continue;
        const id: u4 = @intCast(id_value.integer);
        received |= @as(u16, 1) << @intCast(id - 1);
        const data = parsed.value.object.get("data") orelse continue;
        switch (id) {
            1 => if (jsonNumber(data)) |value| {
                state.time_pos = @max(0, value);
            },
            2 => if (jsonNumber(data)) |value| {
                state.duration = @max(0, value);
            },
            3 => if (data == .bool) {
                state.paused = data.bool;
            },
            4 => if (data == .integer) {
                state.chapter = data.integer;
            },
            5 => if (jsonNumber(data)) |value| {
                state.speed = value;
            },
            6 => if (jsonNumber(data)) |value| {
                state.volume = value;
            },
            7 => if (data == .bool) {
                state.ended = data.bool;
            },
            8 => if (data == .bool and data.bool and state.path != null) {
                state.ended = true;
            },
            else => unreachable,
        }
    }
    return state;
}

fn jsonNumber(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => null,
    };
}

/// Send one command to mpv's JSON IPC socket and wait for its acknowledgement.
pub fn send(io: std.Io, socket_path: []const u8, command: Command) !void {
    var encoded: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer {
        std.crypto.secureZero(u8, encoded.written());
        encoded.deinit();
    }
    try writeCommand(&encoded.writer, command);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(io);
    defer stream.close(io);
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.net.Stream.Writer = .init(stream, io, &buffer);
    try writer.interface.writeAll(encoded.written());
    try writer.interface.flush();

    var read_buffer: [4096]u8 = undefined;
    var reader: std.Io.net.Stream.Reader = .init(stream, io, &read_buffer);
    var lines: u8 = 0;
    while (lines < 16) : (lines += 1) {
        const line = (try reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const request_id = parsed.value.object.get("request_id") orelse continue;
        if (request_id != .integer or request_id.integer != 1) continue;
        const result = parsed.value.object.get("error") orelse return error.MpvCommandFailed;
        if (result != .string or !std.mem.eql(u8, result.string, "success")) return error.MpvCommandFailed;
        return;
    }
    return error.MpvCommandResponseMissing;
}

pub fn resumePosition(position: f64, duration: f64) f64 {
    if (duration > 0 and duration - position <= 30) return 0;
    return @max(position, 0);
}

pub const Command = union(enum) {
    loadfile: []const u8,
    demuxer_options: []const u8,
    pause: bool,
    pause_toggle,
    seek_relative: f64,
    seek_absolute: f64,
    chapter: i64,
    chapter_relative: i64,
    speed: f64,
    volume: f64,
};

pub fn writeCommand(writer: *std.Io.Writer, command: Command) !void {
    switch (command) {
        .loadfile => |path| try std.json.Stringify.value(.{ .command = .{ "loadfile", path, "replace" }, .request_id = 1 }, .{}, writer),
        .demuxer_options => |value| try std.json.Stringify.value(.{ .command = .{ "set_property", "demuxer-lavf-o", value }, .request_id = 1 }, .{}, writer),
        .pause => |value| try std.json.Stringify.value(.{ .command = .{ "set_property", "pause", value }, .request_id = 1 }, .{}, writer),
        .pause_toggle => try std.json.Stringify.value(.{ .command = .{ "cycle", "pause" }, .request_id = 1 }, .{}, writer),
        .seek_relative => |seconds| try std.json.Stringify.value(.{ .command = .{ "seek", seconds, "relative" }, .request_id = 1 }, .{}, writer),
        .seek_absolute => |seconds| try std.json.Stringify.value(.{ .command = .{ "seek", seconds, "absolute" }, .request_id = 1 }, .{}, writer),
        .chapter => |value| try std.json.Stringify.value(.{ .command = .{ "set_property", "chapter", value }, .request_id = 1 }, .{}, writer),
        .chapter_relative => |value| try std.json.Stringify.value(.{ .command = .{ "add", "chapter", value }, .request_id = 1 }, .{}, writer),
        .speed => |value| try std.json.Stringify.value(.{ .command = .{ "set_property", "speed", value }, .request_id = 1 }, .{}, writer),
        .volume => |value| try std.json.Stringify.value(.{ .command = .{ "set_property", "volume", value }, .request_id = 1 }, .{}, writer),
    }
    try writer.writeByte('\n');
}

test "completed books reset and in-progress books resume" {
    try std.testing.expectEqual(@as(f64, 0), resumePosition(995, 1000));
    try std.testing.expectEqual(@as(f64, 250), resumePosition(250, 1000));
}

test "mpv commands are JSON IPC lines and paths are escaped" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeCommand(&out.writer, .{ .loadfile = "a \"book\".m4b" });
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\\\"book\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "loadfile") != null);
}

test "chapter list parsing preserves titles, times, and safe fallbacks" {
    const chapters = try parseChapters(std.testing.allocator,
        \\{"request_id":41,"error":"success","data":[{"title":"Opening","time":0},{"time":12.5}]}
    );
    defer deinitChapters(std.testing.allocator, chapters);
    try std.testing.expectEqual(@as(usize, 2), chapters.len);
    try std.testing.expectEqualStrings("Opening", chapters[0].title);
    try std.testing.expectEqualStrings("Chapter 2", chapters[1].title);
    try std.testing.expectEqual(@as(f64, 12.5), chapters[1].start_seconds);
}
