const std = @import("std");

pub const Marketplace = enum {
    ca,
    us,
    uk,
    de,
    fr,
    it,
    au,
    in,
    jp,
    es,
    br,

    pub fn parse(code: []const u8) !Marketplace {
        inline for (std.meta.fields(Marketplace)) |field| {
            if (std.ascii.eqlIgnoreCase(code, field.name)) return @enumFromInt(field.value);
        }
        return error.UnsupportedMarketplace;
    }
};

pub const Locale = struct {
    marketplace: Marketplace,
    country_code: []const u8,
    domain: []const u8,
    marketplace_id: []const u8,

    pub fn forMarketplace(marketplace: Marketplace) Locale {
        return switch (marketplace) {
            .ca => .{ .marketplace = .ca, .country_code = "ca", .domain = "ca", .marketplace_id = "A2CQZ5RBY40XE" },
            .us => .{ .marketplace = .us, .country_code = "us", .domain = "com", .marketplace_id = "AF2M0KC94RCEA" },
            .uk => .{ .marketplace = .uk, .country_code = "uk", .domain = "co.uk", .marketplace_id = "A2I9A3Q2GNFNGQ" },
            .de => .{ .marketplace = .de, .country_code = "de", .domain = "de", .marketplace_id = "AN7V1F1VY261K" },
            .fr => .{ .marketplace = .fr, .country_code = "fr", .domain = "fr", .marketplace_id = "A2728XDNODOQ8T" },
            .it => .{ .marketplace = .it, .country_code = "it", .domain = "it", .marketplace_id = "A2N7FU2W2BU2ZC" },
            .au => .{ .marketplace = .au, .country_code = "au", .domain = "com.au", .marketplace_id = "AN7EY7DTAW63G" },
            .in => .{ .marketplace = .in, .country_code = "in", .domain = "in", .marketplace_id = "AJO3FBRUE6J4S" },
            .jp => .{ .marketplace = .jp, .country_code = "jp", .domain = "co.jp", .marketplace_id = "A1QAP3MOU4173J" },
            .es => .{ .marketplace = .es, .country_code = "es", .domain = "es", .marketplace_id = "ALMIKO4SZCSAR" },
            .br => .{ .marketplace = .br, .country_code = "br", .domain = "com.br", .marketplace_id = "A10J1VAYUDTYRN" },
        };
    }
};

pub const Endpoints = struct {
    api_origin: []u8,
    website_origin: []u8,
    oauth_token_url: []u8,

    pub fn init(allocator: std.mem.Allocator, locale: Locale) !Endpoints {
        return .{
            .api_origin = try std.fmt.allocPrint(allocator, "https://api.audible.{s}", .{locale.domain}),
            .website_origin = try std.fmt.allocPrint(allocator, "https://www.audible.{s}", .{locale.domain}),
            .oauth_token_url = try std.fmt.allocPrint(allocator, "https://api.amazon.{s}/auth/token", .{locale.domain}),
        };
    }

    pub fn deinit(self: Endpoints, allocator: std.mem.Allocator) void {
        allocator.free(self.api_origin);
        allocator.free(self.website_origin);
        allocator.free(self.oauth_token_url);
    }
};

/// Exact form fields used by audible 0.12.0 for Login With Amazon refresh.
/// The returned buffer contains a credential and must never be logged.
pub fn refreshRequestBody(allocator: std.mem.Allocator, refresh_token: []const u8) ![]u8 {
    if (refresh_token.len == 0) return error.MissingRefreshToken;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("app_name=Audible&app_version=3.56.2&source_token=");
    try formEncode(&output.writer, refresh_token);
    try output.writer.writeAll("&requested_token_type=access_token&source_token_type=refresh_token");
    return output.toOwnedSlice();
}

fn formEncode(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try writer.writeByte(byte),
        ' ' => try writer.writeByte('+'),
        else => try writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 15] }),
    };
}

pub const RefreshedToken = struct {
    allocator: std.mem.Allocator,
    access_token: []u8,
    expires_in: u32,

    pub fn deinit(self: RefreshedToken) void {
        std.crypto.secureZero(u8, self.access_token);
        self.allocator.free(self.access_token);
    }
};

const WireRefreshedToken = struct { access_token: []const u8, expires_in: u32 };

pub fn parseRefreshResponse(allocator: std.mem.Allocator, body: []const u8) !RefreshedToken {
    if (body.len == 0 or body.len > 1024 * 1024) return error.InvalidTokenResponse;
    const parsed = std.json.parseFromSlice(WireRefreshedToken, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidTokenResponse;
    defer parsed.deinit();
    if (parsed.value.access_token.len == 0 or parsed.value.expires_in == 0 or parsed.value.expires_in > 86_400) {
        return error.InvalidTokenResponse;
    }
    return .{ .allocator = allocator, .access_token = try allocator.dupe(u8, parsed.value.access_token), .expires_in = parsed.value.expires_in };
}

pub const HttpResponse = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: HttpResponse, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.body);
        allocator.free(self.body);
    }
};

/// Performs a bounded HTTPS request. Sensitive header values and response
/// bodies are deliberately never formatted or logged by this layer.
pub fn fetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    content_type: ?[]const u8,
    privileged_headers: []const std.http.Header,
    max_response_bytes: usize,
) !HttpResponse {
    if (!std.mem.startsWith(u8, url, "https://")) return error.InsecureTransport;
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    if (max_response_bytes == 0 or max_response_bytes > 64 * 1024 * 1024) return error.InvalidResponseLimit;
    const response_buffer = try allocator.alloc(u8, max_response_bytes);
    defer allocator.free(response_buffer);
    var output: std.Io.Writer = .fixed(response_buffer);
    // Zig 0.16's Request currently tracks privileged_headers for redirect
    // stripping but sendHead emits only extra_headers. Redirects are disabled
    // for this request, so merge them here to ensure auth is actually sent.
    const wire_headers = try allocator.alloc(std.http.Header, 2 + privileged_headers.len);
    defer allocator.free(wire_headers);
    wire_headers[0] = .{ .name = "accept", .value = "application/json" };
    wire_headers[1] = .{ .name = "accept-charset", .value = "utf-8" };
    @memcpy(wire_headers[2..], privileged_headers);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        // Authenticated endpoint redirects are not needed and can create a
        // credential-forwarding ambiguity even with privileged headers.
        .redirect_behavior = .unhandled,
        .response_writer = &output,
        .headers = .{
            .content_type = if (content_type) |value| .{ .override = value } else .default,
            .user_agent = .{ .override = "audible-zig/0.3.2" },
        },
        .extra_headers = wire_headers,
    });
    return .{ .status = @intFromEnum(result.status), .body = try allocator.dupe(u8, output.buffered()) };
}

pub fn refreshAccessToken(allocator: std.mem.Allocator, io: std.Io, endpoint: []const u8, refresh_token: []const u8) !RefreshedToken {
    const body = try refreshRequestBody(allocator, refresh_token);
    defer {
        std.crypto.secureZero(u8, body);
        allocator.free(body);
    }
    const response = try fetch(allocator, io, .POST, endpoint, body, "application/x-www-form-urlencoded", &.{}, 1024 * 1024);
    defer response.deinit(allocator);
    if (response.status < 200 or response.status >= 300) return error.TokenRefreshRejected;
    return parseRefreshResponse(allocator, response.body);
}

pub const Header = struct { name: []const u8, value: []const u8 };
pub const redacted_value = "[REDACTED]";

pub fn isSensitiveHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "proxy-authorization") or
        std.ascii.eqlIgnoreCase(name, "cookie") or
        std.ascii.eqlIgnoreCase(name, "set-cookie") or
        std.ascii.eqlIgnoreCase(name, "x-amz-access-token") or
        std.ascii.startsWithIgnoreCase(name, "x-adp-") or
        std.ascii.indexOfIgnoreCase(name, "signature") != null or
        std.ascii.indexOfIgnoreCase(name, "token") != null;
}

pub fn sanitizedHeader(header: Header) Header {
    return .{ .name = header.name, .value = if (isSensitiveHeader(header.name)) redacted_value else header.value };
}

pub const RetryAction = enum { stop, refresh_and_retry, backoff_and_retry };

pub const RetryPolicy = struct {
    max_attempts: u8 = 3,
    max_delay_seconds: u16 = 30,

    pub fn init(max_attempts: u8, max_delay_seconds: u16) !RetryPolicy {
        if (max_attempts == 0 or max_attempts > 5) return error.InvalidRetryLimit;
        if (max_delay_seconds == 0 or max_delay_seconds > 300) return error.InvalidRetryDelay;
        return .{ .max_attempts = max_attempts, .max_delay_seconds = max_delay_seconds };
    }

    /// `attempt` starts at one and represents the request that just completed.
    pub fn decide(self: RetryPolicy, method: []const u8, status: u16, attempt: u8, refreshed: bool) RetryAction {
        if (attempt == 0 or attempt >= self.max_attempts or !isRetrySafeMethod(method)) return .stop;
        if ((status == 401 or status == 403) and !refreshed) return .refresh_and_retry;
        if (status == 408 or status == 429 or status >= 500) return .backoff_and_retry;
        return .stop;
    }

    pub fn backoffMillis(self: RetryPolicy, attempt: u8, jitter_millis: u16) u64 {
        const exponent: u6 = @intCast(@min(if (attempt == 0) @as(u8, 0) else attempt - 1, 15));
        const base_seconds = @min(@as(u64, 1) << exponent, self.max_delay_seconds);
        return base_seconds * 1000 + @min(jitter_millis, 999);
    }
};

pub fn isRetrySafeMethod(method: []const u8) bool {
    return std.ascii.eqlIgnoreCase(method, "GET") or
        std.ascii.eqlIgnoreCase(method, "HEAD") or
        std.ascii.eqlIgnoreCase(method, "OPTIONS") or
        std.ascii.eqlIgnoreCase(method, "PUT") or
        std.ascii.eqlIgnoreCase(method, "DELETE");
}

pub fn parseRetryAfterSeconds(value: []const u8, cap_seconds: u16) !u16 {
    if (value.len == 0 or value.len > 5 or cap_seconds == 0 or cap_seconds > 300) return error.InvalidRetryAfter;
    const seconds = std.fmt.parseInt(u16, value, 10) catch return error.InvalidRetryAfter;
    return @min(seconds, cap_seconds);
}

test "Canadian locale has pinned upstream endpoints" {
    const locale = Locale.forMarketplace(try Marketplace.parse("CA"));
    try std.testing.expectEqualStrings("A2CQZ5RBY40XE", locale.marketplace_id);
    const endpoints = try Endpoints.init(std.testing.allocator, locale);
    defer endpoints.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("https://api.audible.ca", endpoints.api_origin);
    try std.testing.expectEqualStrings("https://www.audible.ca", endpoints.website_origin);
    try std.testing.expectEqualStrings("https://api.amazon.ca/auth/token", endpoints.oauth_token_url);
}

test "refresh form matches upstream and encodes credential bytes" {
    const body = try refreshRequestBody(std.testing.allocator, "Atnr|a+b c/=");
    defer {
        std.crypto.secureZero(u8, body);
        std.testing.allocator.free(body);
    }
    try std.testing.expectEqualStrings(
        "app_name=Audible&app_version=3.56.2&source_token=Atnr%7Ca%2Bb+c%2F%3D&requested_token_type=access_token&source_token_type=refresh_token",
        body,
    );
}

test "refresh response is bounded and validated" {
    const parsed = try parseRefreshResponse(std.testing.allocator, "{\"access_token\":\"fixture\",\"expires_in\":3600,\"ignored\":true}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("fixture", parsed.access_token);
    try std.testing.expectError(error.InvalidTokenResponse, parseRefreshResponse(std.testing.allocator, "{\"access_token\":\"\",\"expires_in\":3600}"));
}

test "authorization and signing headers are always redacted" {
    for ([_][]const u8{ "Authorization", "x-amz-access-token", "x-adp-token", "x-adp-signature", "Cookie" }) |name| {
        const safe = sanitizedHeader(.{ .name = name, .value = "secret-fixture-value" });
        try std.testing.expectEqualStrings(redacted_value, safe.value);
    }
    try std.testing.expectEqualStrings("application/json", sanitizedHeader(.{ .name = "Accept", .value = "application/json" }).value);
}

test "retry decisions are safe and bounded" {
    const policy = try RetryPolicy.init(3, 30);
    try std.testing.expectEqual(.refresh_and_retry, policy.decide("GET", 401, 1, false));
    try std.testing.expectEqual(.stop, policy.decide("GET", 401, 2, true));
    try std.testing.expectEqual(.backoff_and_retry, policy.decide("GET", 429, 2, false));
    try std.testing.expectEqual(.stop, policy.decide("POST", 503, 1, false));
    try std.testing.expectEqual(.stop, policy.decide("GET", 503, 3, false));
    try std.testing.expectEqual(@as(u64, 30_999), policy.backoffMillis(20, 65_535));
    try std.testing.expectEqual(@as(u16, 30), try parseRetryAfterSeconds("999", 30));
    try std.testing.expectError(error.InvalidRetryAfter, parseRetryAfterSeconds("tomorrow", 30));
}
