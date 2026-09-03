const std = @import("std");
const library = @import("../api/library.zig");
const app_paths = @import("../storage/paths.zig");
const session = @import("../auth/session.zig");
const auth = @import("auth.zig");
const api = @import("api.zig");

pub const id = "yoto";

pub const RefreshResult = struct { item_count: usize, group_count: usize, token_refreshed: bool };

/// Yoto's public API exposes purchased cards only through Library groups.
pub const no_groups_hint =
    "Only Make Your Own cards were found. Yoto's public API lists purchased cards only through Library groups: " ++
    "in the Yoto app open Library, create a group (for example \"Auditui\"), add the cards you want, then run `library refresh --provider yoto`.";
pub const Account = struct { id: []const u8, secure_permissions: bool };

fn validAccount(value: []const u8) bool {
    if (value.len == 0 or value.len > 128 or value[0] == '.') return false;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return false;
    return true;
}

pub fn credentialsPath(allocator: std.mem.Allocator, environ: std.process.Environ, account: []const u8) ![]u8 {
    if (!validAccount(account)) return error.InvalidAccountName;
    const paths = try app_paths.resolve(allocator, environ);
    defer paths.deinit(allocator);
    const directory = try std.fs.path.join(allocator, &.{ paths.config, "yoto" });
    defer allocator.free(directory);
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{account});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ directory, filename });
}

pub fn cachePath(allocator: std.mem.Allocator, environ: std.process.Environ, account: []const u8) ![]u8 {
    if (!validAccount(account)) return error.InvalidAccountName;
    const paths = try app_paths.resolve(allocator, environ);
    defer paths.deinit(allocator);
    const filename = try std.fmt.allocPrint(allocator, "library-yoto-{s}.json", .{account});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ paths.cache, filename });
}

pub fn ensureCredentialDirectory(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !void {
    const paths = try app_paths.resolve(allocator, environ);
    defer paths.deinit(allocator);
    try app_paths.ensure(paths, io);
    const directory = try std.fs.path.join(allocator, &.{ paths.config, "yoto" });
    defer allocator.free(directory);
    try std.Io.Dir.cwd().createDirPath(io, directory);
    if (@import("builtin").os.tag != .windows) {
        const handle = try std.Io.Dir.cwd().openFile(io, directory, .{ .allow_directory = true });
        defer handle.close(io);
        try handle.setPermissions(io, .fromMode(0o700));
    }
}

pub fn discoverAccounts(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) ![]Account {
    const paths = try app_paths.resolve(allocator, environ);
    defer paths.deinit(allocator);
    const directory = try std.fs.path.join(allocator, &.{ paths.config, "yoto" });
    defer allocator.free(directory);
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var result: std.ArrayList(Account) = .empty;
    errdefer {
        for (result.items) |account| allocator.free(account.id);
        result.deinit(allocator);
    }
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const id_value = entry.name[0 .. entry.name.len - 5];
        if (!validAccount(id_value)) continue;
        const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        const secure = if (@import("builtin").os.tag == .windows) true else (stat.permissions.toMode() & 0o077) == 0;
        try result.append(allocator, .{ .id = try allocator.dupe(u8, id_value), .secure_permissions = secure });
    }
    return result.toOwnedSlice(allocator);
}

pub fn deinitAccounts(allocator: std.mem.Allocator, accounts: []Account) void {
    for (accounts) |account| allocator.free(account.id);
    allocator.free(accounts);
}

const offline_access_notice =
    "Yoto has not approved offline_access for this application, so Auditui is connecting without a refresh token. " ++
    "A second sign-in tab has opened; approve it to finish. You will need to run this login again when the session expires (usually a few hours).";

pub fn connect(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, account: []const u8, client_id: []const u8, writer: *std.Io.Writer) !void {
    if (!validAccount(account)) return error.InvalidAccountName;
    try ensureCredentialDirectory(allocator, io, environ);
    var config: auth.Config = .{ .client_id = client_id };
    try config.validate();

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(8787) };
    var server = try address.listen(io, .{ .kernel_backlog = 1, .reuse_address = true });
    defer server.deinit(io);

    const tokens = authorizeOnce(allocator, io, &server, config, writer) catch |err| switch (err) {
        error.OfflineAccessNotApproved => blk: {
            try writer.print("{s}\n\n", .{offline_access_notice});
            try writer.flush();
            config = config.withoutOfflineAccess();
            break :blk try authorizeOnce(allocator, io, &server, config, writer);
        },
        else => return err,
    };
    defer tokens.deinit();

    const credential_path = try credentialsPath(allocator, environ, account);
    defer allocator.free(credential_path);
    try auth.saveCredentials(allocator, io, credential_path, client_id, tokens);
    try writer.print("Connected Yoto account {s}.\n", .{account});
    if (tokens.refresh_token.len == 0) try writer.writeAll("This session cannot be refreshed automatically; rerun this login when Yoto reports the session expired.\n");
}

fn respondPlain(io: std.Io, stream: std.Io.net.Stream, status_line: []const u8, body: []const u8) void {
    var write_buffer: [1024]u8 = undefined;
    var response: std.Io.net.Stream.Writer = .init(stream, io, &write_buffer);
    response.interface.print("{s}\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}", .{ status_line, body.len, body }) catch {};
    response.interface.flush() catch {};
}

/// Runs one browser authorization round trip on the already-bound loopback
/// listener and exchanges the code for tokens. Returns
/// error.OfflineAccessNotApproved when Yoto's only complaint is that the
/// application lacks approval for the offline_access scope, so the caller
/// can retry without it.
fn authorizeOnce(allocator: std.mem.Allocator, io: std.Io, server: anytype, config: auth.Config, writer: *std.Io.Writer) !auth.TokenSet {
    var pending = try auth.PendingAuthorization.generate(io);
    defer {
        std.crypto.secureZero(u8, &pending.verifier);
        std.crypto.secureZero(u8, &pending.state);
    }
    const login_url = try auth.buildAuthorizationUrl(allocator, config, pending);
    defer allocator.free(login_url);

    try writer.writeAll("Open this URL in your browser to connect Yoto:\n");
    try writer.print("{s}\n\nWaiting for Yoto authorization on 127.0.0.1:8787…\n", .{login_url});
    try writer.flush();
    if (std.process.spawn(io, .{ .argv = &.{ "xdg-open", login_url }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore })) |child_value| {
        var child = child_value;
        _ = child.wait(io) catch {};
    } else |_| {}

    // Browsers request /favicon.ico (and similar) after rendering the page we
    // serve to an earlier tab. Answer those and keep waiting for the real
    // callback instead of aborting and closing the port under the browser.
    var read_buffer: [16 * 1024]u8 = undefined;
    var stream: std.Io.net.Stream = undefined;
    var clean_line: []const u8 = undefined;
    while (true) {
        stream = try server.accept(io);
        var reader: std.Io.net.Stream.Reader = .init(stream, io, &read_buffer);
        const request_line = (reader.interface.takeDelimiter('\n') catch null) orelse {
            stream.close(io);
            continue;
        };
        clean_line = std.mem.trimEnd(u8, request_line, "\r");
        if (auth.isCallbackRequestLine(clean_line)) break;
        respondPlain(io, stream, "HTTP/1.1 404 Not Found", "Not found");
        stream.close(io);
    }
    defer stream.close(io);
    var rejection_description: ?[]u8 = null;
    defer if (rejection_description) |value| allocator.free(value);
    const callback = auth.parseLoopbackRequestDetailed(allocator, clean_line, &pending.state, &rejection_description) catch |err| {
        const unapproved_scopes = rejection_description != null and std.mem.indexOf(u8, rejection_description.?, "pre-approved") != null;
        if (err == error.AccessDenied and unapproved_scopes and config.requestsOfflineAccess() and std.mem.indexOf(u8, rejection_description.?, "offline_access") != null) {
            respondPlain(io, stream, "HTTP/1.1 200 OK", offline_access_notice);
            return error.OfflineAccessNotApproved;
        }
        const guidance: []const u8 = if (unapproved_scopes)
            "Yoto denied the login because a requested scope is not enabled on your application. Open https://dashboard.yoto.dev/, edit the application, tick family:library:view and user:content:view under Scopes, save, then retry."
        else switch (err) {
            error.InvalidScope => "Yoto rejected a requested scope. In the developer dashboard, enable family:library:view and user:content:view, save the application, then retry.",
            error.AccessDenied => "Yoto denied this account. Retry and sign in with the adult account that owns the Yoto family, then approve the unverified-app consent screen.",
            error.UnauthorizedClient => "Yoto rejected this client. Confirm it is a Public Client and its callback is exactly http://127.0.0.1:8787/callback.",
            error.StateMismatch => "The callback did not belong to this login attempt. Close older Yoto login tabs and retry using only the newly opened tab.",
            error.AuthorizationTemporarilyUnavailable, error.AuthorizationServerError => "Yoto's authorization service is temporarily unavailable. Retry shortly.",
            else => "Yoto rejected the authorization request. Verify the Public Client, callback URL, and read-only scopes, then retry.",
        };
        writer.print("{s}\n", .{guidance}) catch {};
        if (rejection_description) |description| writer.print("Yoto's exact reason: {s}\n", .{description}) catch {};
        writer.flush() catch {};
        respondPlain(io, stream, "HTTP/1.1 400 Bad Request", guidance);
        return err;
    };
    defer callback.deinit();
    const tokens = try auth.exchangeAuthorizationCode(allocator, io, config, callback.code, &pending.verifier, std.Io.Clock.real.now(io).toSeconds());
    respondPlain(io, stream, "HTTP/1.1 200 OK", "Yoto is connected to Auditui. You can close this tab.");
    return tokens;
}

pub const Access = struct {
    allocator: std.mem.Allocator,
    token: []u8,
    refreshed: bool,

    pub fn deinit(self: Access) void {
        std.crypto.secureZero(u8, self.token);
        self.allocator.free(self.token);
    }
};

pub fn accessToken(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, account: []const u8, force_refresh: bool) !Access {
    const credential_path = try credentialsPath(allocator, environ, account);
    defer allocator.free(credential_path);
    var loaded = try auth.loadCredentials(allocator, io, credential_path);
    defer loaded.deinit();
    const stored = loaded.parsed.value;
    const now = std.Io.Clock.real.now(io).toSeconds();
    if (!force_refresh and stored.expires_at > now + 30)
        return .{ .allocator = allocator, .token = try allocator.dupe(u8, stored.access_token), .refreshed = false };
    if (stored.refresh_token.len == 0) return error.YotoSessionExpired;
    const rotated = try auth.refreshTokens(allocator, io, .{ .client_id = stored.client_id }, stored.refresh_token, now);
    defer rotated.deinit();
    try auth.saveCredentials(allocator, io, credential_path, stored.client_id, rotated);
    return .{ .allocator = allocator, .token = try allocator.dupe(u8, rotated.access_token), .refreshed = true };
}

fn writeCard(writer: *std.Io.Writer, card: api.Card, account: []const u8) !void {
    var author_storage: [1][]const u8 = undefined;
    const authors: []const []const u8 = if (card.metadata.author) |author| blk: {
        author_storage[0] = author;
        break :blk &author_storage;
    } else &.{};
    try std.json.Stringify.value(.{
        .id = card.cardId,
        .asin = "",
        .provider = id,
        .account = account,
        .title = card.title,
        .authors = authors,
        .narrators = &[_][]const u8{},
        .durationSeconds = card.metadata.media.duration,
        .positionSeconds = @as(f64, 0),
        .coverUrl = card.metadata.cover.imageL,
        .description = card.metadata.description,
        .releaseDate = card.updatedAt orelse card.createdAt,
        .localPath = @as(?[]const u8, null),
        .downloaded = false,
        .streamable = true,
        .downloadable = false,
    }, .{}, writer);
}

fn writeLibraryCache(allocator: std.mem.Allocator, io: std.Io, path: []const u8, account: []const u8, mine: *const api.MineDocument, groups: *const api.GroupsDocument, hydrated: []const api.ContentDocument) !usize {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var count: usize = 0;
    try output.writer.writeAll("{\"items\":[");
    for (mine.parsed.value.cards) |card| {
        if (card.deleted or card.cardId.len == 0 or card.title.len == 0 or seen.contains(card.cardId)) continue;
        try seen.put(allocator, card.cardId, {});
        if (count != 0) try output.writer.writeByte(',');
        try writeCard(&output.writer, card, account);
        count += 1;
    }
    for (groups.parsed.value) |group| for (group.cards) |card| {
        if (card.deleted or card.cardId.len == 0 or card.title.len == 0 or seen.contains(card.cardId)) continue;
        try seen.put(allocator, card.cardId, {});
        if (count != 0) try output.writer.writeByte(',');
        try writeCard(&output.writer, card, account);
        count += 1;
    };
    for (hydrated) |document| {
        const card = document.parsed.value.card;
        if (card.deleted or card.cardId.len == 0 or card.title.len == 0 or seen.contains(card.cardId)) continue;
        try seen.put(allocator, card.cardId, {});
        if (count != 0) try output.writer.writeByte(',');
        try writeCard(&output.writer, card, account);
        count += 1;
    }
    try output.writer.writeAll("]}");
    try session.atomicWriteCredentials(allocator, io, path, output.written());
    return count;
}

pub fn refreshLibrary(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, account: []const u8) anyerror!RefreshResult {
    const access = try accessToken(allocator, io, environ, account, false);
    defer access.deinit();
    var mine = try api.fetchMine(allocator, io, access.token);
    defer mine.deinit();
    var groups = try api.fetchFamilyGroups(allocator, io, access.token);
    defer groups.deinit();
    var hydrated: std.ArrayList(api.ContentDocument) = .empty;
    defer {
        for (hydrated.items) |*document| document.deinit();
        hydrated.deinit(allocator);
    }
    var known: std.StringHashMapUnmanaged(void) = .empty;
    defer known.deinit(allocator);
    for (mine.parsed.value.cards) |card| if (card.cardId.len != 0) try known.put(allocator, card.cardId, {});
    for (groups.parsed.value) |group| {
        for (group.cards) |card| if (card.cardId.len != 0) try known.put(allocator, card.cardId, {});
        for (group.items) |item| {
            if (item.contentId.len == 0 or known.contains(item.contentId)) continue;
            var document = api.fetchContentMetadata(allocator, io, access.token, item.contentId) catch |err| switch (err) {
                error.ContentNotFound => continue,
                else => return err,
            };
            errdefer document.deinit();
            try known.put(allocator, document.parsed.value.card.cardId, {});
            try hydrated.append(allocator, document);
        }
    }
    const path = try cachePath(allocator, environ, account);
    defer allocator.free(path);
    return .{ .item_count = try writeLibraryCache(allocator, io, path, account, &mine, &groups, hydrated.items), .group_count = groups.parsed.value.len, .token_refreshed = access.refreshed };
}

pub fn loadCache(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, account: []const u8) !std.json.Parsed(library.Cache) {
    const path = try cachePath(allocator, environ, account);
    defer allocator.free(path);
    return library.loadCache(allocator, io, path);
}

fn appendEdlPart(writer: *std.Io.Writer, url: []const u8, first: *bool) !void {
    if (!std.mem.startsWith(u8, url, "https://") or std.mem.indexOfAny(u8, url, "\r\n") != null) return error.InvalidPlayableUrl;
    if (!first.*) try writer.writeByte(';');
    first.* = false;
    try writer.print("%{d}%{s}", .{ url.len, url });
}

pub fn playableSource(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, account: []const u8, content_id: []const u8) anyerror![]u8 {
    const access = try accessToken(allocator, io, environ, account, false);
    defer access.deinit();
    var document = try api.fetchPlayableContent(allocator, io, access.token, content_id, null);
    defer document.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("edl://");
    var first = true;
    for (document.parsed.value.card.content.chapters) |chapter| for (chapter.tracks) |track|
        if (track.trackUrl) |url| try appendEdlPart(&output.writer, url, &first);
    if (first) return error.NoPlayableTracks;
    return output.toOwnedSlice();
}

test "Yoto accounts reject traversal" {
    try std.testing.expect(validAccount("family"));
    try std.testing.expect(validAccount("family-2_main"));
    try std.testing.expect(!validAccount("../escape"));
    try std.testing.expect(!validAccount("nested/account"));
}

test "multi-track sources use an in-memory length-delimited mpv EDL" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try output.writer.writeAll("edl://");
    var first = true;
    try appendEdlPart(&output.writer, "https://media.example/one?a=1;b=2", &first);
    try appendEdlPart(&output.writer, "https://media.example/two", &first);
    try std.testing.expectEqualStrings("edl://%33%https://media.example/one?a=1;b=2;%25%https://media.example/two", output.written());
    try std.testing.expectError(error.InvalidPlayableUrl, appendEdlPart(&output.writer, "http://unsafe.example", &first));
}
