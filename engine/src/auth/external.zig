const std = @import("std");
const session = @import("session.zig");

pub const device_type = "A2CZJZGLK2JJVM";

pub const Locale = struct {
    country_code: []const u8,
    domain: []const u8,
    marketplace_id: []const u8,
};

const locales = [_]Locale{
    .{ .country_code = "de", .domain = "de", .marketplace_id = "AN7V1F1VY261K" },
    .{ .country_code = "us", .domain = "com", .marketplace_id = "AF2M0KC94RCEA" },
    .{ .country_code = "uk", .domain = "co.uk", .marketplace_id = "A2I9A3Q2GNFNGQ" },
    .{ .country_code = "fr", .domain = "fr", .marketplace_id = "A2728XDNODOQ8T" },
    .{ .country_code = "ca", .domain = "ca", .marketplace_id = "A2CQZ5RBY40XE" },
    .{ .country_code = "it", .domain = "it", .marketplace_id = "A2N7FU2W2BU2ZC" },
    .{ .country_code = "au", .domain = "com.au", .marketplace_id = "AN7EY7DTAW63G" },
    .{ .country_code = "in", .domain = "in", .marketplace_id = "AJO3FBRUE6J4S" },
    .{ .country_code = "jp", .domain = "co.jp", .marketplace_id = "A1QAP3MOU4173J" },
    .{ .country_code = "es", .domain = "es", .marketplace_id = "ALMIKO4SZCSAR" },
    .{ .country_code = "br", .domain = "com.br", .marketplace_id = "A10J1VAYUDTYRN" },
};

pub fn localeFor(country_code: []const u8) !Locale {
    for (locales) |locale| if (std.ascii.eqlIgnoreCase(country_code, locale.country_code)) return locale;
    return error.UnsupportedMarketplace;
}

pub const PendingLogin = struct {
    profile: []u8,
    locale: Locale,
    serial: [32]u8,
    verifier: [43]u8,

    pub fn deinit(self: *PendingLogin, allocator: std.mem.Allocator) void {
        allocator.free(self.profile);
        std.crypto.secureZero(u8, &self.verifier);
        self.* = undefined;
    }
};

fn validProfileName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or name[0] == '.') return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

pub fn begin(allocator: std.mem.Allocator, io: std.Io, profile: []const u8, country_code: []const u8) !PendingLogin {
    if (!validProfileName(profile)) return error.InvalidProfileName;
    const locale = try localeFor(country_code);
    var random_serial: [16]u8 = undefined;
    var random_verifier: [32]u8 = undefined;
    try io.randomSecure(&random_serial);
    try io.randomSecure(&random_verifier);

    var pending: PendingLogin = .{
        .profile = try allocator.dupe(u8, profile),
        .locale = locale,
        .serial = undefined,
        .verifier = undefined,
    };
    errdefer pending.deinit(allocator);
    _ = std.fmt.bufPrint(&pending.serial, "{X}", .{random_serial}) catch unreachable;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&pending.verifier, &random_verifier);
    std.crypto.secureZero(u8, &random_verifier);
    return pending;
}

fn writeEncoded(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~')
            try writer.writeByte(byte)
        else
            try writer.print("%{X:0>2}", .{byte});
    }
}

fn parameter(writer: *std.Io.Writer, first: *bool, key: []const u8, value: []const u8) !void {
    try writer.writeByte(if (first.*) '?' else '&');
    first.* = false;
    try writeEncoded(writer, key);
    try writer.writeByte('=');
    try writeEncoded(writer, value);
}

pub fn loginUrl(allocator: std.mem.Allocator, pending: *const PendingLogin) ![]u8 {
    var client_id_raw: [32 + 1 + device_type.len]u8 = undefined;
    const raw = std.fmt.bufPrint(&client_id_raw, "{s}#{s}", .{ pending.serial, device_type }) catch unreachable;
    var client_id: [client_id_raw.len * 2]u8 = undefined;
    _ = std.fmt.bufPrint(&client_id, "{x}", .{raw}) catch unreachable;

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&pending.verifier, &digest, .{});
    var challenge: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge, &digest);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("https://www.amazon.{s}/ap/signin", .{pending.locale.domain});
    var first = true;
    const return_to = try std.fmt.allocPrint(allocator, "https://www.amazon.{s}/ap/maplanding", .{pending.locale.domain});
    defer allocator.free(return_to);
    const assoc = try std.fmt.allocPrint(allocator, "amzn_audible_ios_{s}", .{pending.locale.country_code});
    defer allocator.free(assoc);
    const device_client = try std.fmt.allocPrint(allocator, "device:{s}", .{client_id});
    defer allocator.free(device_client);
    const params = [_][2][]const u8{
        .{ "openid.oa2.response_type", "code" },                                        .{ "openid.oa2.code_challenge_method", "S256" },
        .{ "openid.oa2.code_challenge", &challenge },                                   .{ "openid.return_to", return_to },
        .{ "openid.assoc_handle", assoc },                                              .{ "openid.identity", "http://specs.openid.net/auth/2.0/identifier_select" },
        .{ "pageId", "amzn_audible_ios" },                                              .{ "accountStatusPolicy", "P1" },
        .{ "openid.claimed_id", "http://specs.openid.net/auth/2.0/identifier_select" }, .{ "openid.mode", "checkid_setup" },
        .{ "openid.ns.oa2", "http://www.amazon.com/ap/ext/oauth/2" },                   .{ "openid.oa2.client_id", device_client },
        .{ "openid.ns.pape", "http://specs.openid.net/extensions/pape/1.0" },           .{ "marketPlaceId", pending.locale.marketplace_id },
        .{ "openid.oa2.scope", "device_auth_access" },                                  .{ "forceMobileLayout", "true" },
        .{ "openid.ns", "http://specs.openid.net/auth/2.0" },                           .{ "openid.pape.max_auth_age", "0" },
    };
    for (params) |item| try parameter(&out.writer, &first, item[0], item[1]);
    return out.toOwnedSlice();
}

pub fn authorizationCode(allocator: std.mem.Allocator, pending: *const PendingLogin, callback_url: []const u8) ![]u8 {
    if (callback_url.len == 0 or callback_url.len > 16 * 1024 or std.mem.indexOfScalar(u8, callback_url, '\n') != null) return error.InvalidCallbackUrl;
    const expected = try std.fmt.allocPrint(allocator, "https://www.amazon.{s}/ap/maplanding?", .{pending.locale.domain});
    defer allocator.free(expected);
    if (!std.mem.startsWith(u8, callback_url, expected)) return error.InvalidCallbackUrl;
    const query = callback_url[expected.len..];
    var result: ?[]u8 = null;
    errdefer if (result) |value| allocator.free(value);
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..equals], "openid.oa2.authorization_code")) continue;
        if (result != null or equals + 1 == pair.len) return error.InvalidCallbackUrl;
        const encoded = pair[equals + 1 ..];
        var decoded = try allocator.dupe(u8, encoded);
        const value = std.Uri.percentDecodeInPlace(decoded);
        if (value.ptr != decoded.ptr) std.mem.copyForwards(u8, decoded, value);
        decoded = try allocator.realloc(decoded, value.len);
        result = decoded;
    }
    return result orelse error.MissingAuthorizationCode;
}

fn requiredObject(root: std.json.Value, keys: []const []const u8) !std.json.ObjectMap {
    var current = root;
    for (keys) |key| {
        if (current != .object) return error.InvalidRegistrationResponse;
        current = current.object.get(key) orelse return error.InvalidRegistrationResponse;
    }
    if (current != .object) return error.InvalidRegistrationResponse;
    return current.object;
}

/// Completes device registration and returns upstream-compatible plain auth JSON.
/// The callback URL, authorization code, PKCE verifier, and response are never logged.
pub fn register(allocator: std.mem.Allocator, io: std.Io, pending: *const PendingLogin, callback_url: []const u8) ![]u8 {
    const code = try authorizationCode(allocator, pending, callback_url);
    defer {
        std.crypto.secureZero(u8, code);
        allocator.free(code);
    }
    var client_id_raw: [32 + 1 + device_type.len]u8 = undefined;
    const raw = std.fmt.bufPrint(&client_id_raw, "{s}#{s}", .{ pending.serial, device_type }) catch unreachable;
    var client_id: [client_id_raw.len * 2]u8 = undefined;
    _ = std.fmt.bufPrint(&client_id, "{x}", .{raw}) catch unreachable;

    var payload_writer: std.Io.Writer.Allocating = .init(allocator);
    defer {
        std.crypto.secureZero(u8, payload_writer.written());
        payload_writer.deinit();
    }
    const cookie_domain = try std.fmt.allocPrint(allocator, ".amazon.{s}", .{pending.locale.domain});
    defer allocator.free(cookie_domain);
    try std.json.Stringify.value(.{
        .requested_token_type = &.{ "bearer", "mac_dms", "website_cookies", "store_authentication_cookie" },
        .cookies = .{ .website_cookies = &.{}, .domain = cookie_domain },
        .registration_data = .{ .domain = "Device", .app_version = "3.56.2", .device_serial = &pending.serial, .device_type = device_type, .device_name = "%FIRST_NAME%%FIRST_NAME_POSSESSIVE_STRING%%DUPE_STRATEGY_1ST%Audible for iPhone", .os_version = "15.0.0", .software_version = "35602678", .device_model = "iPhone", .app_name = "Audible" },
        .auth_data = .{ .client_id = &client_id, .authorization_code = code, .code_verifier = &pending.verifier, .code_algorithm = "SHA-256", .client_domain = "DeviceLegacy" },
        .requested_extensions = &.{ "device_info", "customer_info" },
    }, .{}, &payload_writer.writer);

    const endpoint = try std.fmt.allocPrint(allocator, "https://api.amazon.{s}/auth/register", .{pending.locale.domain});
    defer allocator.free(endpoint);
    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer {
        std.crypto.secureZero(u8, response_writer.written());
        response_writer.deinit();
    }
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload_writer.written(),
        .response_writer = &response_writer.writer,
        .headers = .{ .content_type = .{ .override = "application/json" } },
    });
    if (result.status != .ok) return error.RegistrationRejected;
    if (response_writer.written().len > session.max_auth_file_bytes) return error.RegistrationResponseTooLarge;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_writer.written(), .{}) catch return error.InvalidRegistrationResponse;
    defer parsed.deinit();
    const success = try requiredObject(parsed.value, &.{ "response", "success" });
    const tokens_value = success.get("tokens") orelse return error.InvalidRegistrationResponse;
    const tokens = try requiredObject(tokens_value, &.{});
    const bearer_value = tokens.get("bearer") orelse return error.InvalidRegistrationResponse;
    const bearer = try requiredObject(bearer_value, &.{});
    const mac_value = tokens.get("mac_dms") orelse return error.InvalidRegistrationResponse;
    const mac = try requiredObject(mac_value, &.{});
    const extensions_value = success.get("extensions") orelse return error.InvalidRegistrationResponse;
    const extensions = try requiredObject(extensions_value, &.{});
    const access = bearer.get("access_token") orelse return error.InvalidRegistrationResponse;
    const refresh = bearer.get("refresh_token") orelse return error.InvalidRegistrationResponse;
    const expires_in = bearer.get("expires_in") orelse return error.InvalidRegistrationResponse;
    const adp = mac.get("adp_token") orelse return error.InvalidRegistrationResponse;
    const private_key = mac.get("device_private_key") orelse return error.InvalidRegistrationResponse;
    if (access != .string or refresh != .string or adp != .string or private_key != .string) return error.InvalidRegistrationResponse;
    const expires_seconds: i64 = switch (expires_in) {
        .integer => |v| v,
        .string => |v| std.fmt.parseInt(i64, v, 10) catch return error.InvalidRegistrationResponse,
        else => return error.InvalidRegistrationResponse,
    };
    if (expires_seconds <= 0 or expires_seconds > 31_536_000) return error.InvalidRegistrationResponse;
    const expires = std.Io.Clock.real.now(io).toSeconds() + expires_seconds;

    var website_cookies: ?std.json.Value = null;
    if (tokens.get("website_cookies")) |raw_cookies| {
        if (raw_cookies != .array) return error.InvalidRegistrationResponse;
        var cookie_map: std.json.ObjectMap = .empty;
        const arena = parsed.arena.allocator();
        for (raw_cookies.array.items) |cookie| {
            if (cookie != .object) return error.InvalidRegistrationResponse;
            const name = cookie.object.get("Name") orelse return error.InvalidRegistrationResponse;
            const value = cookie.object.get("Value") orelse return error.InvalidRegistrationResponse;
            if (name != .string or value != .string or name.string.len == 0) return error.InvalidRegistrationResponse;
            try cookie_map.put(arena, name.string, .{ .string = value.string });
        }
        website_cookies = .{ .object = cookie_map };
    }

    var auth: std.Io.Writer.Allocating = .init(allocator);
    errdefer auth.deinit();
    try std.json.Stringify.value(.{
        .adp_token = adp.string,
        .device_private_key = private_key.string,
        .access_token = access.string,
        .refresh_token = refresh.string,
        .expires = expires,
        .website_cookies = website_cookies,
        .store_authentication_cookie = tokens.get("store_authentication_cookie"),
        .device_info = extensions.get("device_info"),
        .customer_info = extensions.get("customer_info"),
        .locale_code = pending.locale.country_code,
        .with_username = false,
    }, .{}, &auth.writer);
    return auth.toOwnedSlice();
}

test "marketplaces and PKCE login URL match upstream shape" {
    var pending = try begin(std.testing.allocator, std.testing.io, "Jonathan", "ca");
    defer pending.deinit(std.testing.allocator);
    const url = try loginUrl(std.testing.allocator, &pending);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, "https://www.amazon.ca/ap/signin?"));
    try std.testing.expect(std.mem.indexOf(u8, url, "openid.oa2.code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "marketPlaceId=A2CQZ5RBY40XE") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, &pending.verifier) == null);
}

test "callback is origin-bound and extracts one authorization code" {
    var pending = try begin(std.testing.allocator, std.testing.io, "test", "us");
    defer pending.deinit(std.testing.allocator);
    const code = try authorizationCode(std.testing.allocator, &pending, "https://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=a%2Fb%2Bc");
    defer std.testing.allocator.free(code);
    try std.testing.expectEqualStrings("a/b+c", code);
    try std.testing.expectError(error.InvalidCallbackUrl, authorizationCode(std.testing.allocator, &pending, "https://evil.example/ap/maplanding?openid.oa2.authorization_code=x"));
    try std.testing.expectError(error.MissingAuthorizationCode, authorizationCode(std.testing.allocator, &pending, "https://www.amazon.com/ap/maplanding?x=y"));
}

test "invalid profile and marketplace fail before creating a login" {
    try std.testing.expectError(error.InvalidProfileName, begin(std.testing.allocator, std.testing.io, "../bad", "ca"));
    try std.testing.expectError(error.UnsupportedMarketplace, begin(std.testing.allocator, std.testing.io, "valid", "xx"));
}
