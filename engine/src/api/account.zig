const std = @import("std");
const client = @import("client.zig");
const sync = @import("sync.zig");
const signing = @import("../auth/signing.zig");

pub const max_response_bytes: usize = 32 * 1024 * 1024;

pub const Request = struct {
    method: std.http.Method = .GET,
    endpoint: []const u8,
    body: ?[]const u8 = null,
};

pub fn apiUrl(allocator: std.mem.Allocator, api_origin: []const u8, endpoint: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, api_origin, "https://api.audible.")) return error.InvalidApiOrigin;
    if (endpoint.len == 0 or std.mem.indexOfAny(u8, endpoint, "\r\n\x00") != null) return error.InvalidEndpoint;
    if (std.mem.startsWith(u8, endpoint, "http://")) return error.InsecureTransport;
    if (std.mem.startsWith(u8, endpoint, "https://")) {
        if (!std.mem.startsWith(u8, endpoint, api_origin) or (endpoint.len > api_origin.len and endpoint[api_origin.len] != '/')) return error.CrossOriginEndpoint;
        return allocator.dupe(u8, endpoint);
    }
    const clean = std.mem.trimStart(u8, endpoint, "/");
    if (std.mem.startsWith(u8, clean, "1.0/") or std.mem.startsWith(u8, clean, "0.0/"))
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ api_origin, clean });
    return std.fmt.allocPrint(allocator, "{s}/1.0/{s}", .{ api_origin, clean });
}

pub fn requestDocument(allocator: std.mem.Allocator, io: std.Io, document: std.json.Value, request: Request) !client.HttpResponse {
    const credentials = try sync.profileView(document);
    const locale = client.Locale.forMarketplace(credentials.marketplace);
    const endpoints = try client.Endpoints.init(allocator, locale);
    defer endpoints.deinit(allocator);
    const url = try apiUrl(allocator, endpoints.api_origin, request.endpoint);
    defer allocator.free(url);
    const path_at = std.mem.indexOfPos(u8, url, "https://".len, "/") orelse return error.InvalidEndpoint;
    const method_name = @tagName(request.method);
    const body = request.body orelse "";
    var date_buffer: [40]u8 = undefined;
    const date = try signing.formatDate(&date_buffer, std.Io.Clock.real.now(io).toSeconds());
    const signed = try signing.signedHeaders(allocator, method_name, url[path_at..], body, credentials.adp_token, credentials.device_private_key, date);
    defer signed.deinit();
    const response = try client.fetch(allocator, io, request.method, url, request.body, if (request.body != null) "application/json" else null, &.{
        .{ .name = "x-adp-token", .value = credentials.adp_token },
        .{ .name = "x-adp-alg", .value = "SHA256withRSA:1.0" },
        .{ .name = "x-adp-signature", .value = signed.signature },
    }, max_response_bytes);
    if (response.status == 401 or response.status == 403) {
        response.deinit(allocator);
        return error.Unauthorized;
    }
    if (response.status == 429) {
        response.deinit(allocator);
        return error.RateLimited;
    }
    if (response.status < 200 or response.status >= 300) {
        response.deinit(allocator);
        return error.ApiRequestRejected;
    }
    return response;
}

pub fn wishlistEndpoint(allocator: std.mem.Allocator, asin: ?[]const u8) ![]u8 {
    if (asin) |value| {
        if (value.len == 0 or value.len > 32) return error.InvalidAsin;
        for (value) |byte| if (!std.ascii.isAlphanumeric(byte)) return error.InvalidAsin;
        return std.fmt.allocPrint(allocator, "wishlist/{s}", .{value});
    }
    return allocator.dupe(u8, "wishlist?page=0&num_results=50&response_groups=contributors%2Cmedia%2Cproduct_desc%2Cseries%2Ccustomer_rights");
}

pub const WireWishlist = struct { products: []const sync.WireItem = &.{} };

pub fn parseWishlist(allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(WireWishlist) {
    if (body.len == 0 or body.len > max_response_bytes) return error.InvalidWishlistResponse;
    return std.json.parseFromSlice(WireWishlist, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch error.InvalidWishlistResponse;
}

/// Extracts the four-byte little-endian Audible activation value from the
/// bounded license blob. The blob itself is never logged or persisted here.
pub fn extractActivationBytes(blob: []const u8) ![8]u8 {
    if (blob.len < 0x238 or std.mem.indexOf(u8, blob, "group_id") == null or std.mem.indexOf(u8, blob, "BAD_LOGIN") != null or std.mem.indexOf(u8, blob, "Whoops") != null)
        return error.InvalidActivationBlob;
    const tail = blob[blob.len - 0x238 ..];
    var compact: [560]u8 = undefined;
    var output: usize = 0;
    for (tail, 0..) |byte, index| {
        if ((index + 1) % 71 == 0) continue;
        if (output >= compact.len) return error.InvalidActivationBlob;
        compact[output] = byte;
        output += 1;
    }
    if (output != compact.len) return error.InvalidActivationBlob;
    const value = std.mem.readInt(u32, compact[0..4], .little);
    var result: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x:0>8}", .{value}) catch unreachable;
    return result;
}

pub fn fetchActivation(allocator: std.mem.Allocator, io: std.Io, document: std.json.Value) ![8]u8 {
    const credentials = try sync.profileView(document);
    const path = "/license/token?player_manuf=Audible%2CiPhone&action=register&player_model=iPhone";
    const url = "https://www.audible.com" ++ path;
    var date_buffer: [40]u8 = undefined;
    const date = try signing.formatDate(&date_buffer, std.Io.Clock.real.now(io).toSeconds());
    const signed = try signing.signedHeaders(allocator, "GET", path, "", credentials.adp_token, credentials.device_private_key, date);
    defer signed.deinit();
    const response = try client.fetch(allocator, io, .GET, url, null, null, &.{
        .{ .name = "x-adp-token", .value = credentials.adp_token },
        .{ .name = "x-adp-alg", .value = "SHA256withRSA:1.0" },
        .{ .name = "x-adp-signature", .value = signed.signature },
    }, 1024 * 1024);
    defer response.deinit(allocator);
    if (response.status == 401 or response.status == 403) return error.Unauthorized;
    if (response.status < 200 or response.status >= 300) return error.ActivationRequestRejected;
    return extractActivationBytes(response.body);
}

test "API paths are versioned and pinned to the profile origin" {
    const relative = try apiUrl(std.testing.allocator, "https://api.audible.ca", "wishlist?num_results=5");
    defer std.testing.allocator.free(relative);
    try std.testing.expectEqualStrings("https://api.audible.ca/1.0/wishlist?num_results=5", relative);
    const versioned = try apiUrl(std.testing.allocator, "https://api.audible.ca", "/1.0/library");
    defer std.testing.allocator.free(versioned);
    try std.testing.expectEqualStrings("https://api.audible.ca/1.0/library", versioned);
    try std.testing.expectError(error.CrossOriginEndpoint, apiUrl(std.testing.allocator, "https://api.audible.ca", "https://evil.invalid/1.0/library"));
}

test "wishlist mutation path validates ASIN" {
    const endpoint = try wishlistEndpoint(std.testing.allocator, "B012345678");
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings("wishlist/B012345678", endpoint);
    try std.testing.expectError(error.InvalidAsin, wishlistEndpoint(std.testing.allocator, "bad/asin"));
}

test "activation extraction strips record separators" {
    var blob: [0x238 + 16]u8 = @splat('x');
    @memcpy(blob[0..8], "group_id");
    const start = blob.len - 0x238;
    blob[start + 0] = 0x78;
    blob[start + 1] = 0x56;
    blob[start + 2] = 0x34;
    blob[start + 3] = 0x12;
    for (0..8) |record| blob[start + record * 71 + 70] = '\n';
    try std.testing.expectEqualStrings("12345678", &(try extractActivationBytes(&blob)));
}
