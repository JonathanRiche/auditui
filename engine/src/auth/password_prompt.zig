const std = @import("std");
const builtin = @import("builtin");

pub const max_password_bytes: usize = 4096;

pub const Secret = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *Secret) void {
        std.crypto.secureZero(u8, self.bytes);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

fn readHidden(allocator: std.mem.Allocator, io: std.Io, input: std.Io.File, output: std.Io.File, prompt: []const u8) !Secret {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;

    const original = try std.posix.tcgetattr(input.handle);
    var hidden = original;
    hidden.lflag.ECHO = false;
    hidden.lflag.ECHONL = false;
    try std.posix.tcsetattr(input.handle, .NOW, hidden);
    defer std.posix.tcsetattr(input.handle, .NOW, original) catch {};

    try output.writeStreamingAll(io, prompt);
    defer output.writeStreamingAll(io, "\n") catch {};
    var reader_buffer: [256]u8 = undefined;
    var reader = input.readerStreaming(io, &reader_buffer);
    var buffer: [max_password_bytes + 1]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var length: usize = 0;
    while (true) {
        const byte = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (byte == '\n') break;
        if (byte == '\r') continue;
        if (length == max_password_bytes) return error.PasswordTooLong;
        buffer[length] = byte;
        length += 1;
    }
    if (length == 0) return error.EmptyPassword;
    return .{ .allocator = allocator, .bytes = try allocator.dupe(u8, buffer[0..length]) };
}

/// Reads a passphrase from the controlling terminal with echo disabled. If
/// `/dev/tty` is unavailable, stdin is accepted only when it is itself a TTY.
/// Passwords are never accepted through argv or environment variables.
pub fn read(allocator: std.mem.Allocator, io: std.Io, prompt: []const u8) !Secret {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;
    if (std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write })) |terminal| {
        defer terminal.close(io);
        return readHidden(allocator, io, terminal, terminal, prompt);
    } else |_| {
        // tcgetattr inside readHidden rejects redirected/piped stdin.
        return readHidden(allocator, io, .stdin(), .stderr(), prompt) catch |err| switch (err) {
            error.NotATerminal => error.PasswordTerminalUnavailable,
            else => err,
        };
    }
}

fn readEchoed(allocator: std.mem.Allocator, io: std.Io, input: std.Io.File, output: std.Io.File, prompt: []const u8) !Secret {
    try output.writeStreamingAll(io, prompt);
    var reader_buffer: [256]u8 = undefined;
    var reader = input.readerStreaming(io, &reader_buffer);
    var buffer: [max_password_bytes + 1]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var length: usize = 0;
    while (true) {
        const byte = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (byte == '\n') break;
        if (byte == '\r') continue;
        if (length == max_password_bytes) return error.InputTooLong;
        buffer[length] = byte;
        length += 1;
    }
    if (length == 0) return error.EmptyInput;
    return .{ .allocator = allocator, .bytes = try allocator.dupe(u8, buffer[0..length]) };
}

/// Reads a sensitive but user-visible value from the controlling terminal.
/// This is used for the one-time browser callback so users can verify that a
/// long URL pasted correctly. The returned mutable buffer is still wiped.
pub fn readVisible(allocator: std.mem.Allocator, io: std.Io, prompt: []const u8) !Secret {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;
    if (std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write })) |terminal| {
        defer terminal.close(io);
        return readEchoed(allocator, io, terminal, terminal, prompt);
    } else |_| {
        return readEchoed(allocator, io, .stdin(), .stderr(), prompt);
    }
}

test "owned password buffers are explicitly mutable" {
    var secret = Secret{ .allocator = std.testing.allocator, .bytes = try std.testing.allocator.dupe(u8, "synthetic-only") };
    try std.testing.expectEqualStrings("synthetic-only", secret.bytes);
    secret.deinit();
}
