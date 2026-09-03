const std = @import("std");

pub const max_concurrent: usize = 2;

pub const Kind = enum { audible, local };
pub const State = enum { queued, active, completed, failed, cancelled };

pub const Record = struct {
    jobId: []const u8,
    itemId: []const u8,
    asin: []const u8 = "",
    title: []const u8,
    profile: []const u8 = "",
    kind: Kind,
    source: ?[]const u8 = null,
    outputDir: []const u8,
    destination: ?[]const u8 = null,
    state: State = .queued,
    received: u64 = 0,
    total: ?u64 = null,
    path: ?[]const u8 = null,
    coverPath: ?[]const u8 = null,
    pdfPath: ?[]const u8 = null,
    metadataPath: ?[]const u8 = null,
    chaptersPath: ?[]const u8 = null,
    annotationsPath: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    attempts: u16 = 0,
    pid: ?i64 = null,
    createdAt: i64,
    updatedAt: i64,
};

pub const Loaded = struct {
    parsed: std.json.Parsed(Record),
    pub fn deinit(self: *Loaded) void {
        self.parsed.deinit();
    }
    pub fn value(self: *Loaded) *Record {
        return &self.parsed.value;
    }
};

fn filename(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &digest, .{});
    return std.fmt.allocPrint(allocator, "{x}.json", .{digest});
}

pub fn ensure(io: std.Io, directory: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, directory);
    if (@import("builtin").os.tag != .windows) {
        const dir = try std.Io.Dir.cwd().openFile(io, directory, .{ .allow_directory = true });
        defer dir.close(io);
        try dir.setPermissions(io, .fromMode(0o700));
    }
}

pub fn pathFor(allocator: std.mem.Allocator, directory: []const u8, id: []const u8) ![]u8 {
    const name = try filename(allocator, id);
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ directory, name });
}

fn cancelPath(allocator: std.mem.Allocator, directory: []const u8, id: []const u8) ![]u8 {
    const path = try pathFor(allocator, directory, id);
    defer allocator.free(path);
    return std.fmt.allocPrint(allocator, "{s}.cancel", .{path});
}

pub fn requestCancel(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, id: []const u8) !void {
    const path = try cancelPath(allocator, directory, id);
    defer allocator.free(path);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    if (@import("builtin").os.tag != .windows) try file.setPermissions(io, .fromMode(0o600));
}

pub fn clearCancel(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, id: []const u8) !void {
    const path = try cancelPath(allocator, directory, id);
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn isCancelled(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, id: []const u8) bool {
    const path = cancelPath(allocator, directory, id) catch return false;
    defer allocator.free(path);
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

pub fn save(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, record: Record) !void {
    try ensure(io, directory);
    const path = try pathFor(allocator, directory, record.jobId);
    defer allocator.free(path);
    // RPC and detached worker processes may persist the same record at nearly
    // the same time (for example cancellation racing a progress callback).
    // Per-process staging names prevent one writer from renaming or truncating
    // the other's temporary file.
    const process_id: i64 = if (@import("builtin").os.tag == .linux) @intCast(std.os.linux.getpid()) else 0;
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, process_id });
    defer allocator.free(temporary);
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    try std.json.Stringify.value(record, .{}, &encoded.writer);
    const file = try std.Io.Dir.cwd().createFile(io, temporary, .{ .truncate = true });
    defer file.close(io);
    if (@import("builtin").os.tag != .windows) try file.setPermissions(io, .fromMode(0o600));
    var buffer: [8192]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(encoded.written());
    try writer.interface.flush();
    try file.sync(io);
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, io);
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, id: []const u8) !Loaded {
    const path = try pathFor(allocator, directory, id);
    defer allocator.free(path);
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > 1024 * 1024) return error.InvalidJob;
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.readAlloc(allocator, @intCast(stat.size));
    defer allocator.free(bytes);
    return .{ .parsed = std.json.parseFromSlice(Record, allocator, bytes, .{ .allocate = .alloc_always }) catch return error.InvalidJob };
}

pub fn list(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) ![]Loaded {
    try ensure(io, directory);
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var result: std.ArrayList(Loaded) = .empty;
    errdefer {
        for (result.items) |*job| job.deinit();
        result.deinit(allocator);
    }
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const path = try std.fs.path.join(allocator, &.{ directory, entry.name });
        defer allocator.free(path);
        const file = std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false }) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;
        if (stat.size > 1024 * 1024) continue;
        var buffer: [8192]u8 = undefined;
        var reader = file.reader(io, &buffer);
        const bytes = reader.interface.readAlloc(allocator, @intCast(stat.size)) catch continue;
        defer allocator.free(bytes);
        const parsed = std.json.parseFromSlice(Record, allocator, bytes, .{ .allocate = .alloc_always }) catch continue;
        try result.append(allocator, .{ .parsed = parsed });
    }
    return result.toOwnedSlice(allocator);
}

pub fn deinitList(allocator: std.mem.Allocator, values: []Loaded) void {
    for (values) |*job| job.deinit();
    allocator.free(values);
}

test "persistent jobs survive reload and filenames cannot traverse" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const directory = buffer[0..length];
    const now: i64 = 42;
    try save(std.testing.allocator, std.testing.io, directory, .{
        .jobId = "../../opaque job",
        .itemId = "item",
        .title = "Book",
        .kind = .local,
        .source = "/tmp/source",
        .outputDir = "/tmp/out",
        .createdAt = now,
        .updatedAt = now,
    });
    var loaded = try load(std.testing.allocator, std.testing.io, directory, "../../opaque job");
    defer loaded.deinit();
    try std.testing.expectEqualStrings("../../opaque job", loaded.value().jobId);
    const values = try list(std.testing.allocator, std.testing.io, directory);
    defer deinitList(std.testing.allocator, values);
    try std.testing.expectEqual(@as(usize, 1), values.len);
}
