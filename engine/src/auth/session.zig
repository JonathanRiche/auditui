const std = @import("std");

/// Auth-file formats emitted by audible 0.12.0. Inspection only considers the
/// document shape and never returns, formats, or logs credential values.
pub const AuthFileKind = enum {
    plain_json,
    encrypted_json,
    encrypted_bytes,
    unrecognized_json,
};

pub const max_auth_file_bytes: usize = 16 * 1024 * 1024;
pub const max_unix_expiry: i64 = 253_402_300_799; // 9999-12-31T23:59:59Z

/// Mirrors upstream detection: an object with `adp_token` is plain, one with
/// `ciphertext` is JSON-encrypted, and non-JSON input is bytes-encrypted.
pub fn detectAuthFileKind(allocator: std.mem.Allocator, bytes: []const u8) !AuthFileKind {
    if (bytes.len == 0) return error.EmptyAuthFile;
    if (bytes.len > max_auth_file_bytes) return error.AuthFileTooLarge;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return .encrypted_bytes;
    defer parsed.deinit();
    if (parsed.value != .object) return .unrecognized_json;
    if (parsed.value.object.contains("adp_token")) return .plain_json;
    if (parsed.value.object.contains("ciphertext")) return .encrypted_json;
    return .unrecognized_json;
}

pub fn detectAuthFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !AuthFileKind {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size == 0) return error.EmptyAuthFile;
    if (stat.size > max_auth_file_bytes) return error.AuthFileTooLarge;
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.readAlloc(allocator, @intCast(stat.size));
    defer allocator.free(bytes);
    return detectAuthFileKind(allocator, bytes);
}

/// Accepts the numeric or numeric-string expiry forms supported upstream, but
/// rejects non-finite, fractional, negative, and implausibly large timestamps.
pub fn parseExpiryValue(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |number| validateExpiry(number),
        .float => |number| blk: {
            if (!std.math.isFinite(number) or @floor(number) != number) return error.InvalidExpiry;
            if (number < 0 or number > @as(f64, @floatFromInt(max_unix_expiry))) return error.InvalidExpiry;
            break :blk @intFromFloat(number);
        },
        .string => |text| blk: {
            if (text.len == 0 or text.len > 20) return error.InvalidExpiry;
            const number = std.fmt.parseInt(i64, text, 10) catch return error.InvalidExpiry;
            break :blk try validateExpiry(number);
        },
        else => error.InvalidExpiry,
    };
}

fn validateExpiry(value: i64) !i64 {
    if (value < 0 or value > max_unix_expiry) return error.InvalidExpiry;
    return value;
}

pub fn parseTokenExpiry(allocator: std.mem.Allocator, document: []const u8) !i64 {
    if (document.len > max_auth_file_bytes) return error.AuthFileTooLarge;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, document, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthFile;
    const value = parsed.value.object.get("expires") orelse return error.MissingExpiry;
    return parseExpiryValue(value);
}

pub fn tokenNeedsRefresh(expires_at: i64, now: i64, requested_skew_seconds: u32) bool {
    const skew: i64 = @intCast(@min(requested_skew_seconds, 300));
    return expires_at <= now or expires_at -| now <= skew;
}

/// Writes in the destination directory, fsyncs the private temporary file, and
/// atomically renames it over the destination. No credential data is logged.
pub fn atomicWriteCredentials(allocator: std.mem.Allocator, io: std.Io, destination: []const u8, data: []const u8) !void {
    if (data.len == 0) return error.EmptyCredentialData;
    if (data.len > max_auth_file_bytes) return error.AuthFileTooLarge;

    var nonce: u64 = undefined;
    try io.randomSecure(std.mem.asBytes(&nonce));
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp-{x}", .{ destination, nonce });
    defer allocator.free(temporary);
    var promoted = false;
    defer if (!promoted) std.Io.Dir.cwd().deleteFile(io, temporary) catch {};

    const permissions: std.Io.File.Permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600);
    const file = try std.Io.Dir.cwd().createFile(io, temporary, .{
        .read = true,
        .exclusive = true,
        .permissions = permissions,
    });
    defer file.close(io);
    try file.writeStreamingAll(io, data);
    try file.sync(io);
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), destination, io);
    promoted = true;
}

test "detects upstream plain and encrypted shapes without exposing values" {
    try std.testing.expectEqual(.plain_json, try detectAuthFileKind(std.testing.allocator, "{\"adp_token\":\"do-not-log\",\"expires\":1}"));
    try std.testing.expectEqual(.encrypted_json, try detectAuthFileKind(std.testing.allocator, "{\"ciphertext\":\"do-not-log\",\"salt\":\"x\"}"));
    try std.testing.expectEqual(.encrypted_bytes, try detectAuthFileKind(std.testing.allocator, "Salted__\x00\xff"));
    try std.testing.expectEqual(.unrecognized_json, try detectAuthFileKind(std.testing.allocator, "{\"profile\":\"test\"}"));
}

test "expiry parsing and refresh skew are bounded" {
    try std.testing.expectEqual(@as(i64, 1_900_000_000), try parseTokenExpiry(std.testing.allocator, "{\"expires\":\"1900000000\"}"));
    try std.testing.expectError(error.InvalidExpiry, parseTokenExpiry(std.testing.allocator, "{\"expires\":-1}"));
    try std.testing.expectError(error.InvalidExpiry, parseTokenExpiry(std.testing.allocator, "{\"expires\":1.5}"));
    try std.testing.expect(tokenNeedsRefresh(1_200, 1_000, 10_000));
    try std.testing.expect(!tokenNeedsRefresh(1_301, 1_000, 10_000));
}

test "atomic credential write creates a mode 0600 replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const destination = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    defer std.testing.allocator.free(destination);
    try atomicWriteCredentials(std.testing.allocator, std.testing.io, destination, "{\"fixture\":true}");
    try atomicWriteCredentials(std.testing.allocator, std.testing.io, destination, "{\"fixture\":false}");
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, destination, .{});
    if (@import("builtin").os.tag != .windows) try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, destination, .{});
    defer file.close(std.testing.io);
    var buffer: [64]u8 = undefined;
    var reader = file.reader(std.testing.io, &buffer);
    const contents = try reader.interface.allocRemaining(std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("{\"fixture\":false}", contents);
}
