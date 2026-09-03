const std = @import("std");

pub const Item = struct {
    id: []const u8 = "",
    asin: []const u8 = "",
    provider: []const u8 = "audible",
    account: []const u8 = "default",
    title: []const u8,
    authors: []const []const u8 = &.{},
    narrators: []const []const u8 = &.{},
    durationSeconds: f64 = 0,
    positionSeconds: f64 = 0,
    coverUrl: ?[]const u8 = null,
    description: ?[]const u8 = null,
    releaseDate: ?[]const u8 = null,
    localPath: ?[]const u8 = null,
    downloaded: bool = false,
    streamable: bool = false,
    downloadable: bool = true,
};

pub const Page = struct {
    items: []const Item,
    nextCursor: ?[]const u8 = null,
    source: []const u8 = "cache",
};

pub const Cache = struct { items: []Item = &.{} };

pub const ScannedLibrary = struct {
    items: []Item,

    pub fn deinit(self: ScannedLibrary, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            allocator.free(item.id);
            allocator.free(item.asin);
            allocator.free(item.title);
            if (item.localPath) |path| allocator.free(path);
        }
        allocator.free(self.items);
    }
};

fn isAudioFile(name: []const u8) bool {
    const extension = std.fs.path.extension(name);
    for ([_][]const u8{ ".m4b", ".mp3", ".m4a", ".ogg", ".opus", ".flac", ".wav", ".aax", ".aaxc" }) |supported| {
        if (std.ascii.eqlIgnoreCase(extension, supported)) return true;
    }
    return false;
}

fn lessThan(_: void, lhs: Item, rhs: Item) bool {
    return std.ascii.lessThanIgnoreCase(lhs.title, rhs.title);
}

/// Non-recursively discovers playable local books without opening their media.
pub fn scanDirectory(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !ScannedLibrary {
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    var items: std.ArrayList(Item) = .empty;
    errdefer {
        for (items.items) |item| {
            allocator.free(item.id);
            allocator.free(item.asin);
            allocator.free(item.title);
            if (item.localPath) |path| allocator.free(path);
        }
        items.deinit(allocator);
    }
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !isAudioFile(entry.name)) continue;
        const id = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(id);
        const asin = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(asin);
        const extension = std.fs.path.extension(entry.name);
        const title = try allocator.dupe(u8, entry.name[0 .. entry.name.len - extension.len]);
        errdefer allocator.free(title);
        const local_path = try std.fs.path.join(allocator, &.{ directory, entry.name });
        errdefer allocator.free(local_path);
        try items.append(allocator, .{
            .id = id,
            .asin = asin,
            .title = title,
            .localPath = local_path,
            .downloaded = true,
        });
    }
    std.mem.sort(Item, items.items, {}, lessThan);
    return .{ .items = try items.toOwnedSlice(allocator) };
}

pub fn loadCache(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.Parsed(Cache) {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > 32 * 1024 * 1024) return error.CacheTooLarge;
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.readAlloc(allocator, @intCast(stat.size));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(Cache, allocator, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub fn matches(item: Item, query: []const u8) bool {
    if (query.len == 0) return true;
    if (std.ascii.indexOfIgnoreCase(item.title, query) != null or std.ascii.indexOfIgnoreCase(item.asin, query) != null) return true;
    for (item.authors) |author| if (std.ascii.indexOfIgnoreCase(author, query) != null) return true;
    for (item.narrators) |narrator| if (std.ascii.indexOfIgnoreCase(narrator, query) != null) return true;
    return false;
}

pub fn search(allocator: std.mem.Allocator, items: []const Item, query: []const u8) ![]Item {
    var found: std.ArrayList(Item) = .empty;
    defer found.deinit(allocator);
    for (items) |item| if (matches(item, query)) try found.append(allocator, item);
    return allocator.dupe(Item, found.items);
}

test "library search is case insensitive over useful fields" {
    const items = [_]Item{
        .{ .asin = "B001", .title = "Dune", .authors = &.{"Frank Herbert"} },
        .{ .asin = "B002", .title = "Leviathan Wakes", .narrators = &.{"Jefferson Mays"} },
    };
    const found = try search(std.testing.allocator, &items, "HERBERT");
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("B001", found[0].asin);
}

test "local scan includes supported regular files only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Zeta.M4B", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Alpha.mp3", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cover.jpg", .data = "" });
    try tmp.dir.createDir(std.testing.io, "nested", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nested/ignored.flac", .data = "" });
    const directory = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(directory);
    const scanned = try scanDirectory(std.testing.allocator, std.testing.io, directory);
    defer scanned.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), scanned.items.len);
    try std.testing.expectEqualStrings("Alpha", scanned.items[0].title);
    try std.testing.expect(scanned.items[0].downloaded);
    try std.testing.expect(scanned.items[0].localPath != null);
    try std.testing.expectEqualStrings("Zeta", scanned.items[1].title);
}
