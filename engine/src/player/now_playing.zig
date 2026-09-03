//! Now-playing snapshot shared with desktop integrations (for example the
//! Omarchy bar widget). The engine writes a small metadata file when playback
//! starts and removes it when playback stops; `auditui player status` merges
//! that metadata with live mpv IPC state so a widget never has to speak RPC.
//!
//! Security: this file is read by other processes, so it carries only
//! display metadata. Media sources (local paths or signed streaming URLs) are
//! never written; the only path is an optional local cover image.
const std = @import("std");
const mpv = @import("mpv.zig");
const paths = @import("../storage/paths.zig");

pub const file_name = "now-playing.json";
pub const socket_name = "mpv.sock";
pub const default_seek_seconds: f64 = 15;

pub const Meta = struct {
    provider: []const u8,
    account: []const u8,
    itemId: []const u8,
    title: []const u8,
    coverPath: ?[]const u8 = null,
    startedAt: i64,
    /// Engine process that owns mpv. Lets `status` report `stopped` even when
    /// the engine was killed hard and left an orphaned mpv socket behind.
    enginePid: ?i64 = null,
};

pub const Snapshot = struct {
    state: []const u8,
    provider: ?[]const u8 = null,
    account: ?[]const u8 = null,
    itemId: ?[]const u8 = null,
    title: ?[]const u8 = null,
    chapterIndex: i64 = 0,
    chapterTitle: ?[]const u8 = null,
    chapterCount: usize = 0,
    positionSeconds: f64 = 0,
    durationSeconds: f64 = 0,
    speed: f64 = 1,
    coverPath: ?[]const u8 = null,
};

pub const Action = enum {
    toggle,
    pause,
    play,
    next,
    previous,
    forward,
    back,

    pub fn parse(name: []const u8) ?Action {
        inline for (@typeInfo(Action).@"enum".fields) |field| {
            if (std.mem.eql(u8, name, field.name)) return @field(Action, field.name);
        }
        if (std.mem.eql(u8, name, "play-pause") or std.mem.eql(u8, name, "playpause")) return .toggle;
        if (std.mem.eql(u8, name, "resume")) return .play;
        if (std.mem.eql(u8, name, "prev")) return .previous;
        return null;
    }

    pub fn command(self: Action, seconds: f64) mpv.Command {
        return switch (self) {
            .toggle => .pause_toggle,
            .pause => .{ .pause = true },
            .play => .{ .pause = false },
            .next => .{ .chapter_relative = 1 },
            .previous => .{ .chapter_relative = -1 },
            .forward => .{ .seek_relative = seconds },
            .back => .{ .seek_relative = -seconds },
        };
    }
};

pub fn filePath(allocator: std.mem.Allocator, state_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ state_dir, file_name });
}

pub fn socketPath(allocator: std.mem.Allocator, state_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ state_dir, socket_name });
}

/// Audible downloads keep artwork next to the media as `<stem>.cover.jpg`.
/// Returns the candidate path; callers verify it exists before publishing it.
pub fn coverCandidate(allocator: std.mem.Allocator, media_path: []const u8) ![]u8 {
    const extension = std.fs.path.extension(media_path);
    const stem = media_path[0 .. media_path.len - extension.len];
    return std.fmt.allocPrint(allocator, "{s}.cover.jpg", .{stem});
}

pub fn existingCover(allocator: std.mem.Allocator, io: std.Io, media_path: []const u8) ?[]u8 {
    const candidate = coverCandidate(allocator, media_path) catch return null;
    const stat = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch {
        allocator.free(candidate);
        return null;
    };
    if (stat.kind != .file) {
        allocator.free(candidate);
        return null;
    }
    return candidate;
}

/// Atomically publish metadata for the current title (mode 0600).
pub fn write(allocator: std.mem.Allocator, io: std.Io, state_dir: []const u8, meta: Meta) !void {
    try std.Io.Dir.cwd().createDirPath(io, state_dir);
    const path = try filePath(allocator, state_dir);
    defer allocator.free(path);
    const process_id: i64 = if (@import("builtin").os.tag == .linux) @intCast(std.os.linux.getpid()) else 0;
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, process_id });
    defer allocator.free(temporary);
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    try std.json.Stringify.value(meta, .{ .emit_null_optional_fields = false }, &encoded.writer);
    try encoded.writer.writeByte('\n');
    const file = try std.Io.Dir.cwd().createFile(io, temporary, .{ .truncate = true });
    defer file.close(io);
    if (@import("builtin").os.tag != .windows) try file.setPermissions(io, .fromMode(0o600));
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(encoded.written());
    try writer.interface.flush();
    try file.sync(io);
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, io);
}

/// Remove the published metadata. Missing files are not an error.
pub fn clear(io: std.Io, state_dir: []const u8) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ state_dir, file_name }) catch return;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

pub const LoadedMeta = std.json.Parsed(Meta);

pub fn load(allocator: std.mem.Allocator, io: std.Io, state_dir: []const u8) !LoadedMeta {
    const path = try filePath(allocator, state_dir);
    defer allocator.free(path);
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > 64 * 1024) return error.InvalidNowPlaying;
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.readAlloc(allocator, @intCast(stat.size));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(Meta, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch error.InvalidNowPlaying;
}

/// Combine published metadata with live mpv state. Any failure to reach mpv
/// (engine exited, socket removed) reports `stopped`, so a killed TUI can
/// never leave a stale "playing" indicator behind.
pub fn writeSnapshot(allocator: std.mem.Allocator, io: std.Io, state_dir: []const u8, writer: *std.Io.Writer) !void {
    var loaded = load(allocator, io, state_dir) catch return writeStopped(writer);
    defer loaded.deinit();
    const meta = loaded.value;
    if (meta.enginePid) |pid| if (!processAlive(io, pid)) return writeStopped(writer);

    const socket_path = try socketPath(allocator, state_dir);
    defer allocator.free(socket_path);
    // A non-null fallback path lets queryState flag mpv's idle state (file
    // finished and unloaded) as ended, so a finished book hides the widget.
    const live = mpv.queryState(allocator, io, socket_path, .{ .path = "" }) catch return writeStopped(writer);

    const chapters = mpv.queryChapters(allocator, io, socket_path) catch &.{};
    defer mpv.deinitChapters(allocator, chapters);
    const chapter_title: ?[]const u8 = if (live.chapter >= 0 and @as(usize, @intCast(live.chapter)) < chapters.len)
        chapters[@intCast(live.chapter)].title
    else
        null;

    const snapshot: Snapshot = .{
        .state = if (live.ended) "stopped" else if (live.paused) "paused" else "playing",
        .provider = meta.provider,
        .account = meta.account,
        .itemId = meta.itemId,
        .title = meta.title,
        .chapterIndex = @max(0, live.chapter),
        .chapterTitle = chapter_title,
        .chapterCount = chapters.len,
        .positionSeconds = live.time_pos,
        .durationSeconds = live.duration,
        .speed = live.speed,
        .coverPath = meta.coverPath,
    };
    try std.json.Stringify.value(snapshot, .{ .emit_null_optional_fields = false }, writer);
    try writer.writeByte('\n');
}

/// Linux-only liveness probe via procfs; other platforms assume alive.
fn processAlive(io: std.Io, pid: i64) bool {
    if (@import("builtin").os.tag != .linux) return true;
    if (pid <= 0) return false;
    var buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "/proc/{d}", .{pid}) catch return false;
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

pub fn currentPid() ?i64 {
    if (@import("builtin").os.tag != .linux) return null;
    return @intCast(std.os.linux.getpid());
}

/// Compact stopped snapshot; widgets only need `state` to hide themselves.
pub fn writeStopped(writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"state\":\"stopped\"}\n");
}

/// Drive the active player, then print the resulting snapshot.
pub fn control(allocator: std.mem.Allocator, io: std.Io, state_dir: []const u8, writer: *std.Io.Writer, action: Action, seconds: f64) !void {
    const socket_path = try socketPath(allocator, state_dir);
    defer allocator.free(socket_path);
    mpv.send(io, socket_path, action.command(seconds)) catch return error.NoActivePlayer;
    try writeSnapshot(allocator, io, state_dir, writer);
}

pub fn stateDir(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    const resolved = try paths.resolve(allocator, environ);
    defer resolved.deinit(allocator);
    return allocator.dupe(u8, resolved.state);
}

test "actions map to mpv commands and accept aliases" {
    try std.testing.expectEqual(Action.toggle, Action.parse("toggle").?);
    try std.testing.expectEqual(Action.toggle, Action.parse("play-pause").?);
    try std.testing.expectEqual(Action.previous, Action.parse("prev").?);
    try std.testing.expectEqual(Action.play, Action.parse("resume").?);
    try std.testing.expect(Action.parse("stop") == null);
    try std.testing.expect(Action.parse("") == null);
    try std.testing.expectEqual(@as(f64, -15), Action.back.command(15).seek_relative);
    try std.testing.expectEqual(@as(i64, 1), Action.next.command(0).chapter_relative);
}

test "cover candidates sit next to the media file" {
    const cover = try coverCandidate(std.testing.allocator, "/lib/Book-AAX_44_128.aaxc");
    defer std.testing.allocator.free(cover);
    try std.testing.expectEqualStrings("/lib/Book-AAX_44_128.cover.jpg", cover);
    const plain = try coverCandidate(std.testing.allocator, "/lib/noext");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("/lib/noext.cover.jpg", plain);
}

test "metadata round-trips, is private, never names the media source, and clears" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const directory = buffer[0..length];

    try write(std.testing.allocator, std.testing.io, directory, .{
        .provider = "yoto",
        .account = "default",
        .itemId = "card-1",
        .title = "Spidey",
        .startedAt = 7,
    });
    const path = try filePath(std.testing.allocator, directory);
    defer std.testing.allocator.free(path);
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buffer);
    const bytes = try reader.interface.readAlloc(std.testing.allocator, @intCast(stat.size));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"title\":\"Spidey\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "coverPath") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "http") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "source") == null);

    var loaded = try load(std.testing.allocator, std.testing.io, directory);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("card-1", loaded.value.itemId);
    try std.testing.expect(loaded.value.coverPath == null);

    clear(std.testing.io, directory);
    try std.testing.expectError(error.FileNotFound, load(std.testing.allocator, std.testing.io, directory));
}

test "snapshot reports stopped when the recorded engine process is gone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const dir = path_buffer[0..length];
    try write(std.testing.allocator, std.testing.io, dir, .{ .provider = "audible", .account = "a", .itemId = "i", .title = "t", .startedAt = 1, .enginePid = 2147480000 });
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeSnapshot(std.testing.allocator, std.testing.io, dir, &out.writer);
    try std.testing.expectEqualStrings("{\"state\":\"stopped\"}\n", out.written());
}

test "snapshot reports stopped without metadata and without a live mpv socket" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const directory = buffer[0..length];

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeSnapshot(std.testing.allocator, std.testing.io, directory, &out.writer);
    try std.testing.expectEqualStrings("{\"state\":\"stopped\"}\n", out.written());

    try write(std.testing.allocator, std.testing.io, directory, .{ .provider = "audible", .account = "default", .itemId = "B0", .title = "Book", .startedAt = 1 });
    out.clearRetainingCapacity();
    try writeSnapshot(std.testing.allocator, std.testing.io, directory, &out.writer);
    try std.testing.expectEqualStrings("{\"state\":\"stopped\"}\n", out.written());

    try std.testing.expectError(error.NoActivePlayer, control(std.testing.allocator, std.testing.io, directory, &out.writer, .toggle, 15));
}
