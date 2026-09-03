const std = @import("std");

pub const State = enum { queued, active, paused, completed, failed, cancelled };
pub const Job = struct {
    id: []const u8,
    asin: []const u8,
    destination: []const u8,
    received: u64 = 0,
    total: ?u64 = null,
    state: State = .queued,
};

pub fn partPath(allocator: std.mem.Allocator, destination: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.part", .{destination});
}

pub fn resumeOffset(io: std.Io, path: []const u8) !u64 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    return stat.size;
}

pub fn sanitizeFilename(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var last_space = false;
    for (input) |c| {
        const invalid = c < 0x20 or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", c) != null;
        const mapped: u8 = if (invalid) '_' else c;
        const space = std.ascii.isWhitespace(mapped);
        if (space and last_space) continue;
        try out.append(allocator, if (space) ' ' else mapped);
        last_space = space;
    }
    const trimmed = std.mem.trim(u8, out.items, " .");
    const safe = if (trimmed.len == 0) "untitled" else trimmed;
    const max = @min(safe.len, 180);
    return allocator.dupe(u8, safe[0..max]);
}

pub fn finalize(io: std.Io, destination: []const u8) !void {
    if (std.Io.Dir.cwd().statFile(io, destination, .{})) |_| return error.AlreadyExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const allocator = std.heap.page_allocator;
    const partial = try partPath(allocator, destination);
    defer allocator.free(partial);
    try std.Io.Dir.cwd().rename(partial, std.Io.Dir.cwd(), destination, io);
}

pub const DownloadResult = struct { received: u64, resumed_from: u64 };

/// A transfer observer is deliberately synchronous: callbacks must be cheap,
/// must not retain paths or URLs, and may return `error.Cancelled` to stop a
/// transfer while preserving its `.part` file for a later retry.
pub const Observer = struct {
    context: ?*anyopaque,
    update: *const fn (?*anyopaque, u64, ?u64) anyerror!void,
};

fn notify(observer: ?Observer, received: u64, total: ?u64) !void {
    if (observer) |value| try value.update(value.context, received, total);
}

const ObservedWriter = struct {
    interface: std.Io.Writer,
    sink: *std.Io.Writer,
    observer: ?Observer,
    received: u64,
    callback_error: ?anyerror = null,

    fn init(sink: *std.Io.Writer, observer: ?Observer, offset: u64) ObservedWriter {
        return .{ .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} }, .sink = sink, .observer = observer, .received = offset };
    }

    fn writePart(self: *ObservedWriter, bytes: []const u8) std.Io.Writer.Error!void {
        self.sink.writeAll(bytes) catch return error.WriteFailed;
        self.received += bytes.len;
        notify(self.observer, self.received, null) catch |err| {
            self.callback_error = err;
            return error.WriteFailed;
        };
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ObservedWriter = @alignCast(@fieldParentPtr("interface", writer));
        if (writer.end != 0) {
            try self.writePart(writer.buffer[0..writer.end]);
            writer.end = 0;
        }
        var consumed: usize = 0;
        for (data, 0..) |bytes, index| {
            const repeats = if (index + 1 == data.len) splat else 1;
            for (0..repeats) |_| try self.writePart(bytes);
            consumed += bytes.len * repeats;
        }
        return consumed;
    }
};

fn fetchInto(allocator: std.mem.Allocator, io: std.Io, url: []const u8, partial: []const u8, offset: u64, observer: ?Observer) !std.http.Status {
    const file = try std.Io.Dir.cwd().createFile(io, partial, .{ .read = true, .truncate = offset == 0 });
    defer file.close(io);
    if (@import("builtin").os.tag != .windows) try file.setPermissions(io, .fromMode(0o600));
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    if (offset != 0) try file_writer.seekTo(offset);
    var observed = ObservedWriter.init(&file_writer.interface, observer, offset);
    try notify(observer, offset, null);
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const range = if (offset == 0) null else try std.fmt.allocPrint(allocator, "bytes={d}-", .{offset});
    defer if (range) |value| allocator.free(value);
    const headers: []const std.http.Header = if (range) |value| &.{.{ .name = "range", .value = value }} else &.{};
    const response = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &observed.interface,
        .extra_headers = headers,
    }) catch |err| {
        if (observed.callback_error) |callback_error| return callback_error;
        return err;
    };
    try file_writer.flush();
    try file.sync(io);
    return response.status;
}

/// Downloads a URL into `destination.part`, resumes with an HTTP Range request,
/// and atomically promotes the result. It intentionally never logs the URL.
pub fn downloadUrlObserved(allocator: std.mem.Allocator, io: std.Io, url: []const u8, destination: []const u8, observer: ?Observer) !DownloadResult {
    if (!std.mem.startsWith(u8, url, "https://")) return error.InsecureTransport;
    if (std.Io.Dir.cwd().statFile(io, destination, .{})) |_| return error.AlreadyExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const partial = try partPath(allocator, destination);
    defer allocator.free(partial);
    var offset = try resumeOffset(io, partial);
    var status = try fetchInto(allocator, io, url, partial, offset, observer);
    if (offset > 0 and status == .ok) {
        // The origin ignored Range. Discard only the incomplete file and retry.
        const file = try std.Io.Dir.cwd().createFile(io, partial, .{ .truncate = true });
        file.close(io);
        offset = 0;
        status = try fetchInto(allocator, io, url, partial, 0, observer);
    }
    if (status != .ok and status != .partial_content) return error.HttpStatusFailure;
    const received = try resumeOffset(io, partial);
    try finalize(io, destination);
    return .{ .received = received, .resumed_from = offset };
}

pub fn downloadUrl(allocator: std.mem.Allocator, io: std.Io, url: []const u8, destination: []const u8) !DownloadResult {
    return downloadUrlObserved(allocator, io, url, destination, null);
}

/// Resumable local-file transfer used by the offline MVP and integration tests.
pub fn copyLocalObserved(allocator: std.mem.Allocator, io: std.Io, source: []const u8, destination: []const u8, observer: ?Observer) !DownloadResult {
    if (std.mem.eql(u8, source, destination)) return error.SameFile;
    if (std.Io.Dir.cwd().statFile(io, destination, .{})) |_| return error.AlreadyExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const partial = try partPath(allocator, destination);
    defer allocator.free(partial);
    const source_file = try std.Io.Dir.cwd().openFile(io, source, .{});
    defer source_file.close(io);
    const source_stat = try source_file.stat(io);
    var offset = try resumeOffset(io, partial);
    if (offset > source_stat.size) {
        const stale = try std.Io.Dir.cwd().createFile(io, partial, .{ .truncate = true });
        stale.close(io);
        offset = 0;
    }
    const destination_file = try std.Io.Dir.cwd().createFile(io, partial, .{ .read = true, .truncate = offset == 0 });
    defer destination_file.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var write_buffer: [64 * 1024]u8 = undefined;
    var reader = source_file.reader(io, &read_buffer);
    var writer = destination_file.writer(io, &write_buffer);
    try reader.seekTo(offset);
    try writer.seekTo(offset);
    try notify(observer, offset, source_stat.size);
    var received = offset;
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const amount = try reader.interface.readSliceShort(&chunk);
        if (amount == 0) break;
        try writer.interface.writeAll(chunk[0..amount]);
        try writer.interface.flush();
        received += amount;
        try notify(observer, received, source_stat.size);
    }
    try writer.flush();
    const actual_received = try resumeOffset(io, partial);
    if (actual_received != source_stat.size) return error.IncompleteTransfer;
    try finalize(io, destination);
    return .{ .received = actual_received, .resumed_from = offset };
}

pub fn copyLocal(allocator: std.mem.Allocator, io: std.Io, source: []const u8, destination: []const u8) !DownloadResult {
    return copyLocalObserved(allocator, io, source, destination, null);
}

test "filename sanitizer produces stable safe names" {
    const actual = try sanitizeFilename(std.testing.allocator, "  Dune: Part / One?.aaxc  ");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("Dune_ Part _ One_.aaxc", actual);
}

test "HTTP downloader rejects malformed URLs without promoting a file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const destination = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/book.aax", .{tmp.sub_path});
    defer std.testing.allocator.free(destination);
    _ = downloadUrl(std.testing.allocator, std.testing.io, "://invalid", destination) catch return;
    return error.ExpectedDownloadFailure;
}

test "local transfer resumes a part file and promotes atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.m4b", .data = "0123456789" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dest.m4b.part", .data = "0123" });
    const source = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/source.m4b", .{tmp.sub_path});
    defer std.testing.allocator.free(source);
    const destination = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dest.m4b", .{tmp.sub_path});
    defer std.testing.allocator.free(destination);
    const result = try copyLocal(std.testing.allocator, std.testing.io, source, destination);
    try std.testing.expectEqual(@as(u64, 4), result.resumed_from);
    try std.testing.expectEqual(@as(u64, 10), result.received);
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, destination, .{});
    try std.testing.expectEqual(@as(u64, 10), stat.size);
}

test "observed local transfer reports bytes and preserves partial on cancellation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.m4b", .data = "0123456789" });
    const source = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/source.m4b", .{tmp.sub_path});
    defer std.testing.allocator.free(source);
    const destination = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dest.m4b", .{tmp.sub_path});
    defer std.testing.allocator.free(destination);
    const Callback = struct {
        fn update(_: ?*anyopaque, received: u64, _: ?u64) !void {
            if (received > 0) return error.Cancelled;
        }
    };
    try std.testing.expectError(error.Cancelled, copyLocalObserved(std.testing.allocator, std.testing.io, source, destination, .{ .context = null, .update = Callback.update }));
    const partial = try partPath(std.testing.allocator, destination);
    defer std.testing.allocator.free(partial);
    try std.testing.expect((try resumeOffset(std.testing.io, partial)) > 0);
}
