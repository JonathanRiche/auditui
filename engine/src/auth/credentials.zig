const std = @import("std");
const encrypted_profile = @import("encrypted_profile.zig");
const session = @import("session.zig");

/// The minimal credential subset needed for signed API requests and token
/// refresh. Unrelated account metadata and cookies are deliberately ignored.
pub const Credentials = struct {
    allocator: std.mem.Allocator,
    adp_token: []u8,
    device_private_key: []u8,
    refresh_token: []u8,
    access_token: ?[]u8,
    locale_code: []u8,
    expires: ?i64,
    with_username: bool,

    pub fn deinit(self: *Credentials) void {
        wipeFree(self.allocator, self.adp_token);
        wipeFree(self.allocator, self.device_private_key);
        wipeFree(self.allocator, self.refresh_token);
        if (self.access_token) |token| wipeFree(self.allocator, token);
        wipeFree(self.allocator, self.locale_code);
        self.* = undefined;
    }
};

const WireCredentials = struct {
    adp_token: ?[]const u8 = null,
    device_private_key: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
    locale_code: ?[]const u8 = null,
    expires: ?std.json.Value = null,
    with_username: bool = false,
};

fn wipeFree(allocator: std.mem.Allocator, value: []u8) void {
    std.crypto.secureZero(u8, value);
    allocator.free(value);
}

fn wipeWire(value: *WireCredentials) void {
    if (value.adp_token) |secret| std.crypto.secureZero(u8, @constCast(secret));
    if (value.device_private_key) |secret| std.crypto.secureZero(u8, @constCast(secret));
    if (value.refresh_token) |secret| std.crypto.secureZero(u8, @constCast(secret));
    if (value.access_token) |secret| std.crypto.secureZero(u8, @constCast(secret));
}

fn required(value: ?[]const u8) ![]const u8 {
    const present = value orelse return error.MissingRequiredCredential;
    if (present.len == 0) return error.EmptyRequiredCredential;
    return present;
}

/// Parses only the fields used by the native authentication path. The source
/// may be wiped during this call, so callers must pass owned secret storage.
pub fn parse(allocator: std.mem.Allocator, plaintext: []u8) !Credentials {
    var parsed = std.json.parseFromSlice(WireCredentials, allocator, plaintext, .{ .ignore_unknown_fields = true }) catch return error.InvalidCredentialJson;
    defer parsed.deinit();
    defer wipeWire(&parsed.value);

    const adp_token = try required(parsed.value.adp_token);
    const private_key = try required(parsed.value.device_private_key);
    const refresh_token = try required(parsed.value.refresh_token);
    const locale_code = try required(parsed.value.locale_code);
    if (locale_code.len != 2 or !std.ascii.isAlphabetic(locale_code[0]) or !std.ascii.isAlphabetic(locale_code[1])) return error.InvalidLocaleCode;

    const expires = if (parsed.value.expires) |expiry| try session.parseExpiryValue(expiry) else null;
    const owned_adp = try allocator.dupe(u8, adp_token);
    errdefer wipeFree(allocator, owned_adp);
    const owned_key = try allocator.dupe(u8, private_key);
    errdefer wipeFree(allocator, owned_key);
    const owned_refresh = try allocator.dupe(u8, refresh_token);
    errdefer wipeFree(allocator, owned_refresh);
    const owned_access = if (parsed.value.access_token) |token| if (token.len == 0) null else try allocator.dupe(u8, token) else null;
    errdefer if (owned_access) |token| wipeFree(allocator, token);
    const owned_locale = try allocator.dupe(u8, locale_code);
    errdefer wipeFree(allocator, owned_locale);

    return .{
        .allocator = allocator,
        .adp_token = owned_adp,
        .device_private_key = owned_key,
        .refresh_token = owned_refresh,
        .access_token = owned_access,
        .locale_code = owned_locale,
        .expires = expires,
        .with_username = parsed.value.with_username,
    };
}

pub fn decryptAndParse(allocator: std.mem.Allocator, encrypted: []const u8, password: []const u8) !Credentials {
    var plaintext = try encrypted_profile.decryptAlloc(allocator, encrypted, password);
    defer plaintext.deinit();
    return parse(allocator, plaintext.bytes);
}

test "parses only the credential subset and owns its secrets" {
    const source = "{\"adp_token\":\"adp-fixture\",\"device_private_key\":\"key-fixture\",\"refresh_token\":\"refresh-fixture\",\"access_token\":\"access-fixture\",\"locale_code\":\"ca\",\"expires\":2000000000,\"with_username\":false,\"customer_info\":{\"ignored\":true}}";
    const mutable = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(mutable);
    var credentials = try parse(std.testing.allocator, mutable);
    defer credentials.deinit();
    try std.testing.expectEqualStrings("adp-fixture", credentials.adp_token);
    try std.testing.expectEqualStrings("ca", credentials.locale_code);
    try std.testing.expectEqual(@as(?i64, 2_000_000_000), credentials.expires);
}

test "rejects incomplete credentials without retaining allocations" {
    const incomplete = try std.testing.allocator.dupe(u8, "{\"adp_token\":\"only-one-field\"}");
    defer std.testing.allocator.free(incomplete);
    try std.testing.expectError(error.MissingRequiredCredential, parse(std.testing.allocator, incomplete));
}
