const std = @import("std");
const http_client = @import("../api/client.zig");
const session = @import("../auth/session.zig");

pub const authorize_url = "https://login.yotoplay.com/authorize";
pub const token_url = "https://login.yotoplay.com/oauth/token";
pub const api_audience = "https://api.yotoplay.com";
pub const recommended_loopback_redirect = "http://127.0.0.1:8787/callback";
pub const max_credential_bytes: usize = 1024 * 1024;

pub const Config = struct {
    /// Public-client identifier issued at https://dashboard.yoto.dev/.
    client_id: []const u8,
    redirect_uri: []const u8 = recommended_loopback_redirect,
    scopes: []const u8 = default_scopes,
    /// Send `prompt=login` so a stale developer-dashboard session is never
    /// reused silently. Disabled for an immediate retry right after the user
    /// has just signed in.
    force_login: bool = true,

    pub const default_scopes = "user:content:view family:library:view offline_access";
    /// Used when Yoto has not approved `offline_access` for this application.
    /// Tokens then expire without a refresh token and the user signs in again.
    pub const scopes_without_offline_access = "user:content:view family:library:view";

    pub fn validate(self: Config) !void {
        if (self.client_id.len == 0) return error.MissingClientId;
        if (!std.mem.startsWith(u8, self.redirect_uri, "http://127.0.0.1:")) return error.NonLoopbackRedirect;
        if (!std.mem.endsWith(u8, self.redirect_uri, "/callback")) return error.InvalidRedirectPath;
        if (self.scopes.len == 0) return error.MissingScopes;
    }

    pub fn requestsOfflineAccess(self: Config) bool {
        return containsScope(self.scopes, "offline_access");
    }

    pub fn withoutOfflineAccess(self: Config) Config {
        var copy = self;
        copy.scopes = scopes_without_offline_access;
        copy.force_login = false;
        return copy;
    }
};

fn containsScope(scopes: []const u8, wanted: []const u8) bool {
    var iterator = std.mem.tokenizeScalar(u8, scopes, ' ');
    while (iterator.next()) |scope| if (std.mem.eql(u8, scope, wanted)) return true;
    return false;
}

pub const PendingAuthorization = struct {
    verifier: [64]u8,
    state: [32]u8,

    pub fn generate(io: std.Io) !PendingAuthorization {
        var verifier_entropy: [48]u8 = undefined;
        var state_entropy: [24]u8 = undefined;
        try io.randomSecure(&verifier_entropy);
        try io.randomSecure(&state_entropy);
        var pending: PendingAuthorization = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&pending.verifier, &verifier_entropy);
        _ = std.base64.url_safe_no_pad.Encoder.encode(&pending.state, &state_entropy);
        return pending;
    }

    pub fn challenge(self: PendingAuthorization) [43]u8 {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&self.verifier, &digest, .{});
        var encoded: [43]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &digest);
        return encoded;
    }
};

fn formEncode(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try writer.writeByte(byte),
        ' ' => try writer.writeByte('+'),
        else => try writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 15] }),
    };
}

fn appendQueryField(writer: *std.Io.Writer, first: *bool, name: []const u8, value: []const u8) !void {
    try writer.writeByte(if (first.*) '?' else '&');
    first.* = false;
    try writer.writeAll(name);
    try writer.writeByte('=');
    try formEncode(writer, value);
}

/// Rejection text is attacker-influenced (it arrives via the browser), so
/// collapse control characters before it reaches a terminal.
fn sanitizeDescription(value: []u8) []u8 {
    for (value) |*byte| if (byte.* < 0x20 or byte.* == 0x7f) {
        byte.* = ' ';
    };
    return value;
}

fn constantTimeSliceEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var difference: u8 = 0;
    for (a, b) |left, right| difference |= left ^ right;
    return difference == 0;
}

pub fn buildAuthorizationUrl(allocator: std.mem.Allocator, config: Config, pending: PendingAuthorization) ![]u8 {
    try config.validate();
    const challenge = pending.challenge();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(authorize_url);
    var first = true;
    try appendQueryField(&output.writer, &first, "audience", api_audience);
    try appendQueryField(&output.writer, &first, "scope", config.scopes);
    try appendQueryField(&output.writer, &first, "response_type", "code");
    try appendQueryField(&output.writer, &first, "client_id", config.client_id);
    try appendQueryField(&output.writer, &first, "code_challenge", &challenge);
    try appendQueryField(&output.writer, &first, "code_challenge_method", "S256");
    try appendQueryField(&output.writer, &first, "redirect_uri", config.redirect_uri);
    try appendQueryField(&output.writer, &first, "state", &pending.state);
    // A developer may be signed into the dashboard with an account that does
    // not own the Yoto family being connected. Never silently reuse that
    // browser session, especially when connecting multiple accounts.
    if (config.force_login) try appendQueryField(&output.writer, &first, "prompt", "login");
    return output.toOwnedSlice();
}

pub const Callback = struct {
    allocator: std.mem.Allocator,
    code: []u8,

    pub fn deinit(self: Callback) void {
        std.crypto.secureZero(u8, self.code);
        self.allocator.free(self.code);
    }
};

/// Parses the request target from a loopback HTTP request. The integration
/// listener must bind only 127.0.0.1 and pass the first request line here.
pub fn parseLoopbackRequest(allocator: std.mem.Allocator, request_line: []const u8, expected_state: []const u8) !Callback {
    var ignored: ?[]u8 = null;
    defer if (ignored) |value| allocator.free(value);
    return parseLoopbackRequestDetailed(allocator, request_line, expected_state, &ignored);
}

/// Like parseLoopbackRequest, but when the authorization server rejects the
/// request its human-readable `error_description` is returned through
/// `description_out` (caller frees). Only rejection text is captured; codes
/// and state are never copied there.
pub fn parseLoopbackRequestDetailed(allocator: std.mem.Allocator, request_line: []const u8, expected_state: []const u8, description_out: *?[]u8) !Callback {
    if (request_line.len > 16 * 1024) return error.CallbackTooLarge;
    if (expected_state.len == 0) return error.InvalidExpectedState;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    if (!std.mem.eql(u8, parts.next() orelse return error.InvalidCallback, "GET")) return error.InvalidCallbackMethod;
    const target = parts.next() orelse return error.InvalidCallback;
    if (!std.mem.startsWith(u8, target, "/callback?")) return error.InvalidCallbackPath;
    const query = target["/callback?".len..];
    var code: ?[]u8 = null;
    errdefer if (code) |value| allocator.free(value);
    var state_valid = false;
    var state_seen = false;
    var authorization_error: ?[]u8 = null;
    errdefer if (authorization_error) |value| allocator.free(value);
    var description: ?[]u8 = null;
    errdefer if (description) |value| allocator.free(value);
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        const separator = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const name = field[0..separator];
        const raw = field[separator + 1 ..];
        const decoded = try allocator.dupe(u8, raw);
        defer allocator.free(decoded);
        _ = std.mem.replaceScalar(u8, decoded, '+', ' ');
        const value = std.Uri.percentDecodeInPlace(decoded);
        if (std.mem.eql(u8, name, "code")) {
            if (value.len == 0 or code != null) return error.InvalidAuthorizationCode;
            code = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, name, "state")) {
            if (state_seen) return error.DuplicateState;
            state_seen = true;
            state_valid = constantTimeSliceEqual(value, expected_state);
        } else if (std.mem.eql(u8, name, "error")) {
            if (authorization_error != null) return error.DuplicateAuthorizationError;
            authorization_error = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, name, "error_description")) {
            if (description != null) return error.DuplicateAuthorizationError;
            if (value.len > 0 and value.len <= 1024) description = try allocator.dupe(u8, sanitizeDescription(value));
        }
    }
    if (!state_valid) return error.StateMismatch;
    if (authorization_error) |rejection| {
        authorization_error = null;
        defer allocator.free(rejection);
        if (description_out.* == null) {
            description_out.* = description;
            description = null;
        }
        if (std.mem.eql(u8, rejection, "invalid_scope")) return error.InvalidScope;
        if (std.mem.eql(u8, rejection, "access_denied")) return error.AccessDenied;
        if (std.mem.eql(u8, rejection, "unauthorized_client")) return error.UnauthorizedClient;
        if (std.mem.eql(u8, rejection, "invalid_request")) return error.InvalidAuthorizationRequest;
        if (std.mem.eql(u8, rejection, "temporarily_unavailable")) return error.AuthorizationTemporarilyUnavailable;
        if (std.mem.eql(u8, rejection, "server_error")) return error.AuthorizationServerError;
        return error.AuthorizationRejected;
    }
    return .{ .allocator = allocator, .code = code orelse return error.MissingAuthorizationCode };
}

/// Waits for one OAuth callback on the exact loopback address documented by
/// Yoto. Call this concurrently with opening/printing buildAuthorizationUrl.
/// The supplied Io can be cancelled by the caller to enforce its own timeout.
pub fn waitForLoopbackCallback(allocator: std.mem.Allocator, io: std.Io, expected_state: []const u8) !Callback {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8787);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var stream = try listener.accept(io);
    defer stream.close(io);

    var receive_buffer: [16 * 1024]u8 = undefined;
    var send_buffer: [1024]u8 = undefined;
    var connection_reader = stream.reader(io, &receive_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);
    var request = try server.receiveHead();
    if (request.head.method != .GET) {
        try request.respond("Yoto sign-in callback must use GET. You can close this tab.", .{ .status = .method_not_allowed });
        return error.InvalidCallbackMethod;
    }
    const request_line = try std.fmt.allocPrint(allocator, "GET {s} HTTP/1.1", .{request.head.target});
    defer allocator.free(request_line);
    const callback = parseLoopbackRequest(allocator, request_line, expected_state) catch |err| {
        try request.respond("Yoto sign-in could not be verified. Return to the terminal and try again.", .{ .status = .bad_request });
        return err;
    };
    errdefer callback.deinit();
    try request.respond("Yoto sign-in complete. You can close this tab and return to the terminal.", .{ .status = .ok });
    return callback;
}

pub const TokenSet = struct {
    allocator: std.mem.Allocator,
    access_token: []u8,
    refresh_token: []u8,
    token_type: []u8,
    scope: []u8,
    expires_in: u32,
    expires_at: i64,

    pub fn deinit(self: TokenSet) void {
        std.crypto.secureZero(u8, self.access_token);
        std.crypto.secureZero(u8, self.refresh_token);
        self.allocator.free(self.access_token);
        self.allocator.free(self.refresh_token);
        self.allocator.free(self.token_type);
        self.allocator.free(self.scope);
    }
};

const WireTokenSet = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    token_type: []const u8 = "Bearer",
    scope: []const u8 = "",
    expires_in: u32,
    expires_at: ?i64 = null,
};

pub fn parseTokenResponse(allocator: std.mem.Allocator, body: []const u8, now: i64) !TokenSet {
    if (body.len == 0 or body.len > max_credential_bytes) return error.InvalidTokenResponse;
    const parsed = std.json.parseFromSlice(WireTokenSet, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.InvalidTokenResponse;
    defer parsed.deinit();
    // Without the offline_access scope Yoto issues no refresh token; the
    // session then simply expires and the user signs in again.
    const refresh_token = parsed.value.refresh_token orelse "";
    if (parsed.value.access_token.len == 0 or parsed.value.expires_in == 0 or parsed.value.expires_in > 86_400) return error.InvalidTokenResponse;
    if (!std.ascii.eqlIgnoreCase(parsed.value.token_type, "Bearer")) return error.UnsupportedTokenType;
    const expires_at = parsed.value.expires_at orelse now + @as(i64, parsed.value.expires_in);
    if (expires_at <= now) return error.InvalidTokenResponse;
    const access_token = try allocator.dupe(u8, parsed.value.access_token);
    errdefer allocator.free(access_token);
    const owned_refresh_token = try allocator.dupe(u8, refresh_token);
    errdefer allocator.free(owned_refresh_token);
    const token_type = try allocator.dupe(u8, parsed.value.token_type);
    errdefer allocator.free(token_type);
    const scope = try allocator.dupe(u8, parsed.value.scope);
    errdefer allocator.free(scope);
    return .{
        .allocator = allocator,
        .access_token = access_token,
        .refresh_token = owned_refresh_token,
        .token_type = token_type,
        .scope = scope,
        .expires_in = parsed.value.expires_in,
        .expires_at = expires_at,
    };
}

pub fn authorizationCodeBody(allocator: std.mem.Allocator, config: Config, code: []const u8, verifier: []const u8) ![]u8 {
    try config.validate();
    if (code.len == 0 or verifier.len < 43 or verifier.len > 128) return error.InvalidAuthorizationExchange;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var first = true;
    inline for (.{
        .{ "grant_type", "authorization_code" }, .{ "client_id", config.client_id },       .{ "code_verifier", verifier },
        .{ "code", code },                       .{ "redirect_uri", config.redirect_uri },
    }) |field| {
        if (!first) try output.writer.writeByte('&');
        first = false;
        try output.writer.writeAll(field[0]);
        try output.writer.writeByte('=');
        try formEncode(&output.writer, field[1]);
    }
    return output.toOwnedSlice();
}

pub fn refreshTokenBody(allocator: std.mem.Allocator, config: Config, refresh_token: []const u8) ![]u8 {
    try config.validate();
    if (refresh_token.len == 0) return error.MissingRefreshToken;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("grant_type=refresh_token&client_id=");
    try formEncode(&output.writer, config.client_id);
    try output.writer.writeAll("&refresh_token=");
    try formEncode(&output.writer, refresh_token);
    return output.toOwnedSlice();
}

fn exchangeBody(allocator: std.mem.Allocator, io: std.Io, body: []u8, now: i64) !TokenSet {
    defer {
        std.crypto.secureZero(u8, body);
        allocator.free(body);
    }
    const response = try http_client.fetch(allocator, io, .POST, token_url, body, "application/x-www-form-urlencoded", &.{}, max_credential_bytes);
    defer response.deinit(allocator);
    if (response.status < 200 or response.status >= 300) return error.TokenExchangeRejected;
    return parseTokenResponse(allocator, response.body, now);
}

pub fn exchangeAuthorizationCode(allocator: std.mem.Allocator, io: std.Io, config: Config, code: []const u8, verifier: []const u8, now: i64) !TokenSet {
    return exchangeBody(allocator, io, try authorizationCodeBody(allocator, config, code, verifier), now);
}

/// Yoto refresh tokens are rotating/single-use. Call saveCredentials with the
/// returned TokenSet before issuing another refresh.
pub fn refreshTokens(allocator: std.mem.Allocator, io: std.Io, config: Config, refresh_token: []const u8, now: i64) !TokenSet {
    return exchangeBody(allocator, io, try refreshTokenBody(allocator, config, refresh_token), now);
}

/// Refreshes and atomically persists the replacement token set before it is
/// returned. This is the safe default for Yoto's single-use refresh tokens.
pub fn refreshAndSave(allocator: std.mem.Allocator, io: std.Io, config: Config, path: []const u8, refresh_token: []const u8, now: i64) !TokenSet {
    var tokens = try refreshTokens(allocator, io, config, refresh_token, now);
    errdefer tokens.deinit();
    try saveCredentials(allocator, io, path, config.client_id, tokens);
    return tokens;
}

pub fn saveCredentials(allocator: std.mem.Allocator, io: std.Io, path: []const u8, client_id: []const u8, tokens: TokenSet) !void {
    if (client_id.len == 0) return error.MissingClientId;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer {
        std.crypto.secureZero(u8, @constCast(output.written()));
        output.deinit();
    }
    try std.json.Stringify.value(.{
        .version = @as(u8, 1),
        .client_id = client_id,
        .access_token = tokens.access_token,
        .refresh_token = tokens.refresh_token,
        .token_type = tokens.token_type,
        .scope = tokens.scope,
        .expires_at = tokens.expires_at,
    }, .{}, &output.writer);
    try session.atomicWriteCredentials(allocator, io, path, output.written());
}

pub const StoredCredentials = struct {
    version: u8,
    client_id: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    token_type: []const u8,
    scope: []const u8,
    expires_at: i64,
};

pub const LoadedCredentials = struct {
    parsed: std.json.Parsed(StoredCredentials),
    pub fn deinit(self: *LoadedCredentials) void {
        std.crypto.secureZero(u8, @constCast(self.parsed.value.access_token));
        std.crypto.secureZero(u8, @constCast(self.parsed.value.refresh_token));
        self.parsed.deinit();
    }
};

pub fn loadCredentials(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !LoadedCredentials {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (@import("builtin").os.tag != .windows and stat.permissions.toMode() & 0o077 != 0) return error.InsecureCredentialPermissions;
    if (stat.size == 0 or stat.size > max_credential_bytes) return error.InvalidCredentialFile;
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.readAlloc(allocator, @intCast(stat.size));
    defer {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
    }
    const parsed = std.json.parseFromSlice(StoredCredentials, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return error.InvalidCredentialFile;
    if (parsed.value.version != 1 or parsed.value.client_id.len == 0 or parsed.value.access_token.len == 0) {
        var invalid = parsed;
        invalid.deinit();
        return error.InvalidCredentialFile;
    }
    return .{ .parsed = parsed };
}

test "PKCE challenge and authorization URL use S256 and encoded public-client fields" {
    var pending: PendingAuthorization = undefined;
    pending.verifier = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_".*;
    pending.state = "0123456789abcdefghijklmnopqrstuv".*;
    const url = try buildAuthorizationUrl(std.testing.allocator, .{ .client_id = "public client" }, pending);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, authorize_url));
    try std.testing.expect(std.mem.indexOf(u8, url, "client_id=public+client") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A8787%2Fcallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "offline_access") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "profile") == null);
    try std.testing.expect(std.mem.indexOf(u8, url, "prompt=login") != null);

    const fallback: Config = (Config{ .client_id = "public client" }).withoutOfflineAccess();
    try std.testing.expect(!fallback.requestsOfflineAccess());
    const retry_url = try buildAuthorizationUrl(std.testing.allocator, fallback, pending);
    defer std.testing.allocator.free(retry_url);
    try std.testing.expect(std.mem.indexOf(u8, retry_url, "offline_access") == null);
    try std.testing.expect(std.mem.indexOf(u8, retry_url, "prompt=") == null);
    try std.testing.expect(std.mem.indexOf(u8, retry_url, "scope=user%3Acontent%3Aview+family%3Alibrary%3Aview&") != null);
}

test "loopback callback requires exact state and handles percent encoding" {
    const callback = try parseLoopbackRequest(std.testing.allocator, "GET /callback?code=one%2Ftwo&state=expected HTTP/1.1", "expected");
    defer callback.deinit();
    try std.testing.expectEqualStrings("one/two", callback.code);
    try std.testing.expectError(error.StateMismatch, parseLoopbackRequest(std.testing.allocator, "GET /callback?code=x&state=wrong HTTP/1.1", "expected"));
    try std.testing.expectError(error.AccessDenied, parseLoopbackRequest(std.testing.allocator, "GET /callback?error=access_denied&state=expected HTTP/1.1", "expected"));
    try std.testing.expectError(error.InvalidScope, parseLoopbackRequest(std.testing.allocator, "GET /callback?error=invalid_scope&state=expected HTTP/1.1", "expected"));
    try std.testing.expectError(error.UnauthorizedClient, parseLoopbackRequest(std.testing.allocator, "GET /callback?error=unauthorized_client&state=expected HTTP/1.1", "expected"));
    try std.testing.expectError(error.StateMismatch, parseLoopbackRequest(std.testing.allocator, "GET /callback?error=access_denied&state=wrong HTTP/1.1", "expected"));
}

test "loopback callback surfaces the server's error_description" {
    var description: ?[]u8 = null;
    defer if (description) |value| std.testing.allocator.free(value);
    try std.testing.expectError(error.AccessDenied, parseLoopbackRequestDetailed(std.testing.allocator, "GET /callback?error=access_denied&error_description=Please%20verify%20your%20email%0Abefore+continuing&state=expected HTTP/1.1", "expected", &description));
    try std.testing.expectEqualStrings("Please verify your email before continuing", description.?);
    var none: ?[]u8 = null;
    const ok = try parseLoopbackRequestDetailed(std.testing.allocator, "GET /callback?code=abc&state=expected HTTP/1.1", "expected", &none);
    defer ok.deinit();
    try std.testing.expect(none == null);
}

test "token parsing tolerates a missing refresh token" {
    var tokens = try parseTokenResponse(std.testing.allocator,
        \\{"access_token":"synthetic-access","refresh_token":"synthetic-rotated","token_type":"Bearer","scope":"offline_access","expires_in":3600}
    , 1_000);
    defer tokens.deinit();
    try std.testing.expectEqualStrings("synthetic-rotated", tokens.refresh_token);
    try std.testing.expectEqual(@as(i64, 4_600), tokens.expires_at);
    var short_lived = try parseTokenResponse(std.testing.allocator,
        \\{"access_token":"synthetic-access","token_type":"Bearer","expires_in":3600}
    , 1_000);
    defer short_lived.deinit();
    try std.testing.expectEqualStrings("", short_lived.refresh_token);
    try std.testing.expectError(error.MissingRefreshToken, refreshTokenBody(std.testing.allocator, .{ .client_id = "c" }, short_lived.refresh_token));
}

test "token request bodies are form encoded" {
    const config: Config = .{ .client_id = "client/id" };
    const authorization = try authorizationCodeBody(std.testing.allocator, config, "code+value", "0123456789abcdefghijklmnopqrstuvwxyzABCDEFG");
    defer std.testing.allocator.free(authorization);
    try std.testing.expect(std.mem.indexOf(u8, authorization, "client_id=client%2Fid") != null);
    try std.testing.expect(std.mem.indexOf(u8, authorization, "code=code%2Bvalue") != null);
    const refresh = try refreshTokenBody(std.testing.allocator, config, "old/token");
    defer std.testing.allocator.free(refresh);
    try std.testing.expectEqualStrings("grant_type=refresh_token&client_id=client%2Fid&refresh_token=old%2Ftoken", refresh);
}

test "credential replacement is mode 0600 and round trips rotated tokens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/yoto.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    var tokens = try parseTokenResponse(std.testing.allocator,
        \\{"access_token":"synthetic-new-access","refresh_token":"synthetic-new-refresh","token_type":"Bearer","scope":"offline_access","expires_in":3600}
    , 100);
    defer tokens.deinit();
    try saveCredentials(std.testing.allocator, std.testing.io, path, "public-client", tokens);
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    if (@import("builtin").os.tag != .windows) try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    var loaded = try loadCredentials(std.testing.allocator, std.testing.io, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("synthetic-new-refresh", loaded.parsed.value.refresh_token);
    try std.testing.expectEqual(@as(i64, 3_700), loaded.parsed.value.expires_at);
}
