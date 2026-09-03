const std = @import("std");

const markers = [_][]const u8{ "token", "cookie", "authorization", "private_key", "voucher", "password", "signed_url" };

pub fn isSensitiveKey(key: []const u8) bool {
    for (markers) |marker| if (std.ascii.indexOfIgnoreCase(key, marker) != null) return true;
    return false;
}

pub fn sanitizeUrl(url: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, url, '?')) |i| url[0..i] else url;
}

test "detects secret keys and strips URL query" {
    try std.testing.expect(isSensitiveKey("access_token"));
    try std.testing.expect(isSensitiveKey("Authorization"));
    try std.testing.expect(!isSensitiveKey("profile_name"));
    try std.testing.expectEqualStrings("https://example.test/file", sanitizeUrl("https://example.test/file?sig=secret"));
}
