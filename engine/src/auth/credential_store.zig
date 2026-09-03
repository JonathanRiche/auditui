const std = @import("std");
const credentials = @import("credentials.zig");
const encrypted_profile = @import("encrypted_profile.zig");
const password_prompt = @import("password_prompt.zig");
const session = @import("session.zig");

/// Encrypts an upstream-compatible JSON envelope and atomically installs it
/// with owner-only permissions. The encrypted staging allocation is wiped.
pub fn writeEncrypted(allocator: std.mem.Allocator, io: std.Io, destination: []const u8, plaintext_json: []const u8, password: []const u8) !void {
    const encrypted = try encrypted_profile.encryptJsonAlloc(allocator, io, plaintext_json, password);
    defer {
        std.crypto.secureZero(u8, encrypted);
        allocator.free(encrypted);
    }
    try session.atomicWriteCredentials(allocator, io, destination, encrypted);
}

/// Interactive encrypted persistence. No password parameter can accidentally
/// be sourced from an argument or environment variable at this API boundary.
pub fn promptAndWriteEncrypted(allocator: std.mem.Allocator, io: std.Io, destination: []const u8, plaintext_json: []const u8) !void {
    var password = try password_prompt.read(allocator, io, "Profile passphrase: ");
    defer password.deinit();
    try writeEncrypted(allocator, io, destination, plaintext_json, password.bytes);
}

/// Loads a regular, non-symlink credential file only when other users have no
/// permissions. The encrypted source buffer and decrypted JSON are wiped.
pub fn loadEncrypted(allocator: std.mem.Allocator, io: std.Io, path: []const u8, password: []const u8) !credentials.Credentials {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.InvalidCredentialFileType;
    if (@import("builtin").os.tag != .windows and (stat.permissions.toMode() & 0o077) != 0) return error.UnsafeCredentialPermissions;
    if (stat.size == 0) return error.EmptyEncryptedProfile;
    if (stat.size > encrypted_profile.max_encrypted_bytes) return error.EncryptedProfileTooLarge;

    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    var reader_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    const encrypted = try reader.interface.readAlloc(allocator, @intCast(stat.size));
    defer {
        std.crypto.secureZero(u8, encrypted);
        allocator.free(encrypted);
    }
    return credentials.decryptAndParse(allocator, encrypted, password);
}

test "encrypted atomic write is private and reloadable" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const destination = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/profile.json", .{temporary.sub_path});
    defer std.testing.allocator.free(destination);
    const fixture = "{\"adp_token\":\"synthetic-adp\",\"device_private_key\":\"synthetic-key\",\"refresh_token\":\"synthetic-refresh\",\"locale_code\":\"us\"}";
    try writeEncrypted(std.testing.allocator, std.testing.io, destination, fixture, "fixture-password");
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, destination, .{});
    if (@import("builtin").os.tag != .windows) try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    var loaded = try loadEncrypted(std.testing.allocator, std.testing.io, destination, "fixture-password");
    defer loaded.deinit();
    try std.testing.expectEqualStrings("synthetic-adp", loaded.adp_token);
    try std.testing.expectEqualStrings("us", loaded.locale_code);
}
