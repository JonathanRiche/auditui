const std = @import("std");
const client_api = @import("client.zig");
const library = @import("library.zig");
const profiles = @import("../auth/profiles.zig");
const session = @import("../auth/session.zig");

pub const max_page_size: u16 = 1000;
pub const max_pages: u16 = 10_000;
pub const max_page_bytes: usize = 32 * 1024 * 1024;

// Kept in the same order as audible-cli 0.6.0's library command. Whitespace
// is removed because it is insignificant to the API and makes a canonical URL.
pub const response_groups = "contributors,media,price,product_attrs,product_desc,product_extended_attrs,product_plan_details,product_plans,rating,sample,sku,series,reviews,ws4v,origin,relationships,review_attrs,categories,badge_types,category_ladders,claim_code_url,is_downloaded,is_finished,is_returnable,origin_asin,pdf_url,percent_complete,provided_review";

pub const Contributor = struct { name: []const u8 = "" };
pub const ProductImages = struct { @"500": ?[]const u8 = null };
pub const Position = struct { position_ms: f64 = 0 };

pub const WireItem = struct {
    asin: []const u8,
    title: []const u8,
    authors: []const Contributor = &.{},
    narrators: []const Contributor = &.{},
    runtime_length_min: f64 = 0,
    percent_complete: f64 = 0,
    product_images: ?ProductImages = null,
    product_desc: ?[]const u8 = null,
    extended_product_description: ?[]const u8 = null,
    publisher_summary: ?[]const u8 = null,
    short_description: ?[]const u8 = null,
    release_date: ?[]const u8 = null,
    last_position_heard: ?Position = null,
};

pub const WirePage = struct { items: []const WireItem = &.{} };

pub fn parsePage(allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(WirePage) {
    if (body.len == 0 or body.len > max_page_bytes) return error.InvalidLibraryResponse;
    const parsed = std.json.parseFromSlice(WirePage, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidLibraryResponse;
    errdefer parsed.deinit();
    for (parsed.value.items) |item| {
        if (item.asin.len == 0 or item.title.len == 0) return error.InvalidLibraryResponse;
    }
    return parsed;
}

pub fn appendMapped(allocator: std.mem.Allocator, destination: *std.ArrayList(library.Item), wire_items: []const WireItem) !void {
    for (wire_items) |wire| {
        var authors: std.ArrayList([]const u8) = .empty;
        defer authors.deinit(allocator);
        for (wire.authors) |author| if (author.name.len != 0) try authors.append(allocator, try allocator.dupe(u8, author.name));
        var narrators: std.ArrayList([]const u8) = .empty;
        defer narrators.deinit(allocator);
        for (wire.narrators) |narrator| if (narrator.name.len != 0) try narrators.append(allocator, try allocator.dupe(u8, narrator.name));
        const description = firstNonEmpty(&.{
            wire.extended_product_description,
            wire.publisher_summary,
            wire.product_desc,
            wire.short_description,
        });
        try destination.append(allocator, .{
            .id = try allocator.dupe(u8, wire.asin),
            .asin = try allocator.dupe(u8, wire.asin),
            .title = try allocator.dupe(u8, wire.title),
            .authors = try authors.toOwnedSlice(allocator),
            .narrators = try narrators.toOwnedSlice(allocator),
            .durationSeconds = @max(0, wire.runtime_length_min * 60),
            .positionSeconds = if (wire.last_position_heard) |position|
                @max(0, position.position_ms / 1000)
            else
                @max(0, wire.runtime_length_min * 60 * @min(100, wire.percent_complete) / 100),
            .coverUrl = if (wire.product_images) |images| if (images.@"500") |value| try allocator.dupe(u8, value) else null else null,
            .description = if (description) |value| try allocator.dupe(u8, value) else null,
            .releaseDate = if (wire.release_date) |value| try allocator.dupe(u8, value) else null,
        });
    }
}

fn firstNonEmpty(values: []const ?[]const u8) ?[]const u8 {
    for (values) |value| if (value) |text| {
        if (std.mem.trim(u8, text, " \t\r\n").len != 0) return text;
    };
    return null;
}

fn deinitMappedElements(allocator: std.mem.Allocator, items: []library.Item) void {
    for (items) |item| {
        allocator.free(item.id);
        allocator.free(item.asin);
        allocator.free(item.title);
        for (item.authors) |author| allocator.free(author);
        allocator.free(item.authors);
        for (item.narrators) |narrator| allocator.free(narrator);
        allocator.free(item.narrators);
        if (item.coverUrl) |value| allocator.free(value);
        if (item.description) |value| allocator.free(value);
        if (item.releaseDate) |value| allocator.free(value);
        if (item.localPath) |value| allocator.free(value);
    }
}

pub fn deinitMapped(allocator: std.mem.Allocator, items: []library.Item) void {
    deinitMappedElements(allocator, items);
    allocator.free(items);
}

pub fn libraryUrl(allocator: std.mem.Allocator, api_origin: []const u8, page: u16, page_size: u16) ![]u8 {
    if (!std.mem.startsWith(u8, api_origin, "https://api.audible.") or page == 0 or page_size == 0 or page_size > max_page_size) return error.InvalidLibraryRequest;
    const encoded_groups = try std.mem.replaceOwned(u8, allocator, response_groups, ",", "%2C");
    defer allocator.free(encoded_groups);
    return std.fmt.allocPrint(
        allocator,
        "{s}/1.0/library?page={d}&num_results={d}&response_groups={s}",
        .{ api_origin, page, page_size, encoded_groups },
    );
}

pub const SyncedLibrary = struct {
    items: []library.Item,

    pub fn deinit(self: SyncedLibrary, allocator: std.mem.Allocator) void {
        deinitMapped(allocator, self.items);
    }
};

/// Fetches every owned-library page with Audible's supported access-token
/// header. The credential is kept in the privileged header set and redirects
/// are disabled by the HTTP layer.
pub fn fetchAll(allocator: std.mem.Allocator, io: std.Io, api_origin: []const u8, access_token: []const u8, page_size: u16) !SyncedLibrary {
    if (access_token.len == 0) return error.MissingAccessToken;
    var items: std.ArrayList(library.Item) = .empty;
    errdefer {
        deinitMappedElements(allocator, items.items);
        items.deinit(allocator);
    }
    var page: u16 = 1;
    while (page <= max_pages) : (page += 1) {
        const url = try libraryUrl(allocator, api_origin, page, page_size);
        defer allocator.free(url);
        const response = try client_api.fetch(
            allocator,
            io,
            .GET,
            url,
            null,
            "application/json",
            &.{
                .{ .name = "x-amz-access-token", .value = access_token },
            },
            max_page_bytes,
        );
        defer response.deinit(allocator);
        if (response.status == 401 or response.status == 403) return error.Unauthorized;
        if (response.status == 429) return error.RateLimited;
        if (response.status < 200 or response.status >= 300) return error.LibraryRequestRejected;
        const parsed = try parsePage(allocator, response.body);
        defer parsed.deinit();
        try appendMapped(allocator, &items, parsed.value.items);
        if (parsed.value.items.len < page_size) return .{ .items = try items.toOwnedSlice(allocator) };
    }
    return error.TooManyLibraryPages;
}

pub const ProfileView = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8,
    adp_token: []const u8,
    device_private_key: []const u8,
    expires: i64,
    marketplace: client_api.Marketplace,
};

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidAuthProfile;
    if (value != .string or value.string.len == 0) return error.InvalidAuthProfile;
    return value.string;
}

pub fn profileView(document: std.json.Value) !ProfileView {
    if (document != .object) return error.InvalidAuthProfile;
    const country_code = if (document.object.get("locale_code")) |locale_code|
        if (locale_code == .string and locale_code.string.len != 0) locale_code.string else return error.InvalidAuthProfile
    else blk: {
        const locale_value = document.object.get("locale") orelse return error.InvalidAuthProfile;
        if (locale_value != .object) return error.InvalidAuthProfile;
        break :blk try requiredString(locale_value.object, "country_code");
    };
    const access_token = try requiredString(document.object, "access_token");
    const adp_token = try requiredString(document.object, "adp_token");
    const device_private_key = try requiredString(document.object, "device_private_key");
    const refresh_token = if (document.object.get("refresh_token")) |value|
        if (value == .string and value.string.len != 0) value.string else null
    else
        null;
    const expires_value = document.object.get("expires") orelse return error.InvalidAuthProfile;
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .adp_token = adp_token,
        .device_private_key = device_private_key,
        .expires = try session.parseExpiryValue(expires_value),
        .marketplace = try client_api.Marketplace.parse(country_code),
    };
}

pub fn loadProfileDocument(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.Parsed(std.json.Value) {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.InvalidAuthProfile;
    if (@import("builtin").os.tag != .windows and (stat.permissions.toMode() & 0o077) != 0) return error.UnsafeCredentialPermissions;
    if (stat.size == 0 or stat.size > session.max_auth_file_bytes) return error.InvalidAuthProfile;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.readAlloc(allocator, @intCast(stat.size));
    defer allocator.free(bytes);
    switch (try session.detectAuthFileKind(allocator, bytes)) {
        .plain_json => {},
        .encrypted_json, .encrypted_bytes => return error.ProfilePasswordRequired,
        .unrecognized_json => return error.InvalidAuthProfile,
    }
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always }) catch error.InvalidAuthProfile;
}

pub const RefreshResult = struct {
    item_count: usize,
    token_refreshed: bool,
};

/// Refreshes and syncs an already-decoded upstream auth document. If a token
/// rotates, the document is updated in its own arena so the caller can safely
/// serialize and re-encrypt it after this function returns.
pub fn refreshDocument(allocator: std.mem.Allocator, io: std.Io, document: *std.json.Parsed(std.json.Value), cache_path: []const u8) !RefreshResult {
    var credentials = try profileView(document.value);
    const locale = client_api.Locale.forMarketplace(credentials.marketplace);
    const endpoints = try client_api.Endpoints.init(allocator, locale);
    defer endpoints.deinit(allocator);
    const now = std.Io.Clock.real.now(io).toSeconds();
    var refreshed: ?client_api.RefreshedToken = null;
    defer if (refreshed) |token| token.deinit();
    var did_refresh = false;
    if (session.tokenNeedsRefresh(credentials.expires, now, 60)) {
        const refresh_token = credentials.refresh_token orelse return error.RefreshTokenRequired;
        refreshed = try client_api.refreshAccessToken(allocator, io, endpoints.oauth_token_url, refresh_token);
        const document_allocator = document.arena.allocator();
        const stable_access_token = try document_allocator.dupe(u8, refreshed.?.access_token);
        credentials.access_token = stable_access_token;
        const expires: i64 = now + @as(i64, @intCast(refreshed.?.expires_in));
        try document.value.object.put(document_allocator, "access_token", .{ .string = stable_access_token });
        try document.value.object.put(document_allocator, "expires", .{ .integer = expires });
        did_refresh = true;
    }
    const synced = fetchAll(allocator, io, endpoints.api_origin, credentials.access_token, max_page_size) catch |err| switch (err) {
        // Rotate a rejected access token once and retry this idempotent GET.
        error.Unauthorized => retry: {
            if (did_refresh) return error.Unauthorized;
            const refresh_token = credentials.refresh_token orelse return error.RefreshTokenRequired;
            refreshed = try client_api.refreshAccessToken(allocator, io, endpoints.oauth_token_url, refresh_token);
            const document_allocator = document.arena.allocator();
            const stable_access_token = try document_allocator.dupe(u8, refreshed.?.access_token);
            credentials.access_token = stable_access_token;
            const expires: i64 = now + @as(i64, @intCast(refreshed.?.expires_in));
            try document.value.object.put(document_allocator, "access_token", .{ .string = stable_access_token });
            try document.value.object.put(document_allocator, "expires", .{ .integer = expires });
            did_refresh = true;
            break :retry try fetchAll(allocator, io, endpoints.api_origin, credentials.access_token, max_page_size);
        },
        else => return err,
    };
    defer synced.deinit(allocator);
    // A remote refresh replaces metadata, but a verified local download must
    // remain playable. Carry those paths forward by ASIN only while the file
    // still exists as a regular file.
    if (library.loadCache(allocator, io, cache_path)) |previous| {
        defer previous.deinit();
        for (synced.items) |*fresh| {
            for (previous.value.items) |old| {
                if (!old.downloaded or old.localPath == null or !std.mem.eql(u8, fresh.asin, old.asin)) continue;
                const stat = std.Io.Dir.cwd().statFile(io, old.localPath.?, .{ .follow_symlinks = false }) catch continue;
                if (stat.kind != .file) continue;
                fresh.localPath = try allocator.dupe(u8, old.localPath.?);
                fresh.downloaded = true;
                break;
            }
        }
    } else |_| {}
    try writeCache(allocator, io, cache_path, synced.items);
    return .{ .item_count = synced.items.len, .token_refreshed = did_refresh };
}

/// Loads a named profile, refreshes an expired bearer token when possible,
/// fetches all library pages, and atomically publishes the new cache. Existing
/// cache data remains untouched if any network or parsing step fails.
pub fn refreshProfile(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, profile_name: []const u8, cache_path: []const u8) !RefreshResult {
    const discovered = try profiles.discoverAll(allocator, io, environ);
    defer profiles.deinitProfiles(allocator, discovered);
    var selected: ?profiles.Profile = null;
    for (discovered) |profile| if (std.mem.eql(u8, profile.name, profile_name)) {
        selected = profile;
        break;
    };
    const profile = selected orelse return error.ProfileNotFound;
    try profiles.safeToRead(profile);
    var document = try loadProfileDocument(allocator, io, profile.path);
    defer document.deinit();
    const result = try refreshDocument(allocator, io, &document, cache_path);
    if (result.token_refreshed) {
        var encoded: std.Io.Writer.Allocating = .init(allocator);
        defer {
            std.crypto.secureZero(u8, encoded.written());
            encoded.deinit();
        }
        try std.json.Stringify.value(document.value, .{}, &encoded.writer);
        try session.atomicWriteCredentials(allocator, io, profile.path, encoded.written());
    }
    return result;
}

pub fn writeCache(allocator: std.mem.Allocator, io: std.Io, path: []const u8, items: []const library.Item) !void {
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    try std.json.Stringify.value(.{ .items = items }, .{}, &encoded.writer);
    if (encoded.written().len > 64 * 1024 * 1024) return error.CacheTooLarge;
    const parent = std.fs.path.dirname(path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(io, parent);
    var nonce: u64 = undefined;
    try io.randomSecure(std.mem.asBytes(&nonce));
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp-{x}", .{ path, nonce });
    defer allocator.free(temporary);
    var promoted = false;
    defer if (!promoted) std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
    const file = try std.Io.Dir.cwd().createFile(io, temporary, .{ .read = true, .exclusive = true });
    defer file.close(io);
    if (@import("builtin").os.tag != .windows) try file.setPermissions(io, .fromMode(0o600));
    try file.writeStreamingAll(io, encoded.written());
    try file.sync(io);
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, io);
    promoted = true;
}

test "library URL follows upstream version and pagination" {
    const url = try libraryUrl(std.testing.allocator, "https://api.audible.ca", 2, 1000);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, "https://api.audible.ca/1.0/library?page=2&num_results=1000&response_groups=contributors%2Cmedia"));
    try std.testing.expectError(error.InvalidLibraryRequest, libraryUrl(std.testing.allocator, "http://api.audible.ca", 1, 10));
}

test "synthetic upstream page maps current publisher summary without retaining response memory" {
    const body =
        \\{"items":[{"asin":"B001","title":"A Book","authors":[{"name":"A. Writer"}],"narrators":[{"name":"N. Voice"}],"runtime_length_min":10,"percent_complete":25,"product_images":{"500":"https://example.invalid/cover.jpg"},"publisher_summary":"<p>Description</p>","release_date":"2020-01-02"}]}
    ;
    const parsed = try parsePage(std.testing.allocator, body);
    defer parsed.deinit();
    var mapped: std.ArrayList(library.Item) = .empty;
    try appendMapped(std.testing.allocator, &mapped, parsed.value.items);
    const owned = try mapped.toOwnedSlice(std.testing.allocator);
    defer deinitMapped(std.testing.allocator, owned);
    try std.testing.expectEqualStrings("B001", owned[0].asin);
    try std.testing.expectEqualStrings("A. Writer", owned[0].authors[0]);
    try std.testing.expectEqual(@as(f64, 600), owned[0].durationSeconds);
    try std.testing.expectEqual(@as(f64, 150), owned[0].positionSeconds);
    try std.testing.expectEqualStrings("<p>Description</p>", owned[0].description.?);
}

test "synthetic profile selects pinned marketplace and signing fields" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"access_token":"fixture-access","refresh_token":"fixture-refresh","adp_token":"fixture-adp","device_private_key":"fixture-key","expires":"1900000000","locale":{"country_code":"ca","domain":"attacker.invalid"}}
    , .{});
    defer parsed.deinit();
    const view = try profileView(parsed.value);
    try std.testing.expectEqual(client_api.Marketplace.ca, view.marketplace);
    try std.testing.expectEqualStrings("fixture-access", view.access_token);
    try std.testing.expectEqualStrings("fixture-adp", view.adp_token);
    // The untrusted domain is ignored; endpoints are selected from pinned data.
    try std.testing.expectEqualStrings("ca", client_api.Locale.forMarketplace(view.marketplace).domain);
}

test "encrypted profile is reported as password-required" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "locked.json", .data = "{\"ciphertext\":\"fixture\",\"salt\":\"fixture\"}" });
    if (@import("builtin").os.tag != .windows) {
        const file = try tmp.dir.openFile(std.testing.io, "locked.json", .{});
        defer file.close(std.testing.io);
        try file.setPermissions(std.testing.io, .fromMode(0o600));
    }
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/locked.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.ProfilePasswordRequired, loadProfileDocument(std.testing.allocator, std.testing.io, path));
}

test "cache replacement is parseable by offline library" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/library.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const items = [_]library.Item{.{ .id = "B001", .asin = "B001", .title = "Cached" }};
    try writeCache(std.testing.allocator, std.testing.io, path, &items);
    const cached = try library.loadCache(std.testing.allocator, std.testing.io, path);
    defer cached.deinit();
    try std.testing.expectEqualStrings("Cached", cached.value.items[0].title);
}
