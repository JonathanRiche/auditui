const std = @import("std");
const http_client = @import("../api/client.zig");

pub const api_origin = "https://api.yotoplay.com";
pub const mine_url = api_origin ++ "/content/mine";
pub const family_groups_url = api_origin ++ "/card/family/library/groups";
pub const max_api_response_bytes: usize = 16 * 1024 * 1024;

pub const Cover = struct { imageL: ?[]const u8 = null };
pub const Media = struct {
    duration: f64 = 0,
    fileSize: u64 = 0,
    hasStreams: bool = false,
};
pub const Metadata = struct {
    author: ?[]const u8 = null,
    authors: []const []const u8 = &.{},
    narrators: []const []const u8 = &.{},
    category: ?[]const u8 = null,
    description: ?[]const u8 = null,
    cover: Cover = .{},
    media: Media = .{},
};
pub const Track = struct {
    key: []const u8 = "",
    title: []const u8 = "",
    format: []const u8 = "",
    type: []const u8 = "",
    trackUrl: ?[]const u8 = null,
};
pub const Chapter = struct {
    key: []const u8 = "",
    title: []const u8 = "",
    duration: f64 = 0,
    fileSize: u64 = 0,
    hasStreams: bool = false,
    tracks: []const Track = &.{},
};
pub const Content = struct {
    activity: ?[]const u8 = null,
    version: ?[]const u8 = null,
    chapters: []const Chapter = &.{},
};
pub const Card = struct {
    cardId: []const u8,
    title: []const u8,
    slug: ?[]const u8 = null,
    availability: ?[]const u8 = null,
    createdAt: ?[]const u8 = null,
    updatedAt: ?[]const u8 = null,
    deleted: bool = false,
    metadata: Metadata = .{},
    content: Content = .{},
};

pub const MineResponse = struct { cards: []const Card = &.{} };
pub const ContentResponse = struct { card: Card };
pub const GroupItem = struct {
    contentId: []const u8,
    addedAt: ?[]const u8 = null,
};
pub const FamilyGroup = struct {
    id: []const u8,
    familyId: []const u8,
    name: []const u8,
    imageId: ?[]const u8 = null,
    imageUrl: ?[]const u8 = null,
    createdAt: ?[]const u8 = null,
    lastModifiedAt: ?[]const u8 = null,
    items: []const GroupItem = &.{},
    cards: []const Card = &.{},
};

pub const MineDocument = struct {
    parsed: std.json.Parsed(MineResponse),
    pub fn deinit(self: *MineDocument) void {
        self.parsed.deinit();
    }
};
pub const ContentDocument = struct {
    parsed: std.json.Parsed(ContentResponse),
    pub fn deinit(self: *ContentDocument) void {
        self.parsed.deinit();
    }
};
pub const GroupsDocument = struct {
    parsed: std.json.Parsed([]const FamilyGroup),
    pub fn deinit(self: *GroupsDocument) void {
        self.parsed.deinit();
    }
};
/// One group fetched through the documented "get a group" operation. Unlike
/// the list operation, Yoto expands every available item into `cards` here,
/// which is the only documented way to read purchased cards' metadata.
pub const GroupDocument = struct {
    parsed: std.json.Parsed(FamilyGroup),
    pub fn deinit(self: *GroupDocument) void {
        self.parsed.deinit();
    }
};

pub fn parseMine(allocator: std.mem.Allocator, body: []const u8) !MineDocument {
    if (body.len == 0 or body.len > max_api_response_bytes) return error.InvalidMineResponse;
    return .{ .parsed = std.json.parseFromSlice(MineResponse, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidMineResponse };
}

pub fn parsePlayableContent(allocator: std.mem.Allocator, body: []const u8) !ContentDocument {
    if (body.len == 0 or body.len > max_api_response_bytes) return error.InvalidContentResponse;
    const parsed = std.json.parseFromSlice(ContentResponse, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidContentResponse;
    if (parsed.value.card.cardId.len == 0 or parsed.value.card.title.len == 0) {
        var invalid = parsed;
        invalid.deinit();
        return error.InvalidContentResponse;
    }
    return .{ .parsed = parsed };
}

pub fn parseFamilyGroup(allocator: std.mem.Allocator, body: []const u8) !GroupDocument {
    if (body.len == 0 or body.len > max_api_response_bytes) return error.InvalidGroupResponse;
    const parsed = std.json.parseFromSlice(FamilyGroup, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidGroupResponse;
    if (parsed.value.id.len == 0) {
        var invalid = parsed;
        invalid.deinit();
        return error.InvalidGroupResponse;
    }
    return .{ .parsed = parsed };
}

pub fn familyGroupUrl(allocator: std.mem.Allocator, group_id: []const u8) ![]u8 {
    if (group_id.len == 0) return error.MissingGroupId;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(family_groups_url ++ "/");
    try percentEncode(&output.writer, group_id);
    return output.toOwnedSlice();
}

pub fn parseFamilyGroups(allocator: std.mem.Allocator, body: []const u8) !GroupsDocument {
    if (body.len == 0 or body.len > max_api_response_bytes) return error.InvalidGroupsResponse;
    return .{ .parsed = std.json.parseFromSlice([]const FamilyGroup, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidGroupsResponse };
}

fn percentEncode(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try writer.writeByte(byte),
        else => try writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 15] }),
    };
}

/// Official Content API request for signed, directly playable S3 URLs.
pub fn playableContentUrl(allocator: std.mem.Allocator, content_id: []const u8, timezone: ?[]const u8) ![]u8 {
    if (content_id.len == 0) return error.MissingContentId;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(api_origin ++ "/content/");
    try percentEncode(&output.writer, content_id);
    try output.writer.writeAll("?playable=true&signingType=s3");
    if (timezone) |value| {
        if (value.len == 0) return error.InvalidTimezone;
        try output.writer.writeAll("&timezone=");
        try percentEncode(&output.writer, value);
    }
    return output.toOwnedSlice();
}

/// Card endpoint on the official API host. It is not listed in the public
/// reference, but it is what resolves a family's purchased cards to signed
/// playback URLs when the documented content operation answers 403. It is
/// only ever called with the user's own token for cards in their library.
pub fn cardUrl(allocator: std.mem.Allocator, card_id: []const u8) ![]u8 {
    if (card_id.len == 0) return error.MissingContentId;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(api_origin ++ "/card/");
    try percentEncode(&output.writer, card_id);
    return output.toOwnedSlice();
}

pub fn contentMetadataUrl(allocator: std.mem.Allocator, content_id: []const u8) ![]u8 {
    if (content_id.len == 0) return error.MissingContentId;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(api_origin ++ "/content/");
    try percentEncode(&output.writer, content_id);
    return output.toOwnedSlice();
}

fn bearerValue(allocator: std.mem.Allocator, access_token: []const u8) ![]u8 {
    if (access_token.len == 0) return error.MissingAccessToken;
    if (std.mem.indexOfAny(u8, access_token, "\r\n") != null) return error.InvalidAccessToken;
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
}

fn fetchAuthenticated(allocator: std.mem.Allocator, io: std.Io, url: []const u8, access_token: []const u8) !http_client.HttpResponse {
    const authorization = try bearerValue(allocator, access_token);
    defer {
        std.crypto.secureZero(u8, authorization);
        allocator.free(authorization);
    }
    return http_client.fetch(allocator, io, .GET, url, null, null, &.{.{ .name = "authorization", .value = authorization }}, max_api_response_bytes);
}

pub fn fetchMine(allocator: std.mem.Allocator, io: std.Io, access_token: []const u8) !MineDocument {
    const response = try fetchAuthenticated(allocator, io, mine_url, access_token);
    defer response.deinit(allocator);
    if (response.status == 401 or response.status == 403) return error.Unauthorized;
    if (response.status < 200 or response.status >= 300) return error.MineRequestFailed;
    return parseMine(allocator, response.body);
}

pub fn fetchPlayableContent(allocator: std.mem.Allocator, io: std.Io, access_token: []const u8, content_id: []const u8, timezone: ?[]const u8) !ContentDocument {
    const url = try playableContentUrl(allocator, content_id, timezone);
    defer allocator.free(url);
    const response = try fetchAuthenticated(allocator, io, url, access_token);
    defer response.deinit(allocator);
    if (response.status == 401) return error.Unauthorized;
    // Yoto answers 403 for cards the token may not read (e.g. purchased cards
    // when only MYO access is granted); callers skip these individually.
    if (response.status == 403) return error.ContentForbidden;
    if (response.status == 404) return error.ContentNotFound;
    if (response.status < 200 or response.status >= 300) return error.ContentRequestFailed;
    return parsePlayableContent(allocator, response.body);
}

/// Fetches card metadata without requesting signed playable URLs. This is used
/// to hydrate family-library references during refresh.
pub fn fetchCard(allocator: std.mem.Allocator, io: std.Io, access_token: []const u8, card_id: []const u8) !ContentDocument {
    const url = try cardUrl(allocator, card_id);
    defer allocator.free(url);
    const response = try fetchAuthenticated(allocator, io, url, access_token);
    defer response.deinit(allocator);
    if (response.status == 401) return error.Unauthorized;
    if (response.status == 403) return error.ContentForbidden;
    if (response.status == 404) return error.ContentNotFound;
    if (response.status < 200 or response.status >= 300) return error.ContentRequestFailed;
    return parsePlayableContent(allocator, response.body);
}

pub fn fetchContentMetadata(allocator: std.mem.Allocator, io: std.Io, access_token: []const u8, content_id: []const u8) !ContentDocument {
    const url = try contentMetadataUrl(allocator, content_id);
    defer allocator.free(url);
    const response = try fetchAuthenticated(allocator, io, url, access_token);
    defer response.deinit(allocator);
    if (response.status == 401) return error.Unauthorized;
    // Yoto answers 403 for cards the token may not read (e.g. purchased cards
    // when only MYO access is granted); callers skip these individually.
    if (response.status == 403) return error.ContentForbidden;
    if (response.status == 404) return error.ContentNotFound;
    if (response.status < 200 or response.status >= 300) return error.ContentRequestFailed;
    return parsePlayableContent(allocator, response.body);
}

pub fn fetchFamilyGroups(allocator: std.mem.Allocator, io: std.Io, access_token: []const u8) !GroupsDocument {
    const response = try fetchAuthenticated(allocator, io, family_groups_url, access_token);
    defer response.deinit(allocator);
    if (response.status == 401 or response.status == 403) return error.Unauthorized;
    if (response.status < 200 or response.status >= 300) return error.GroupsRequestFailed;
    return parseFamilyGroups(allocator, response.body);
}

pub fn fetchFamilyGroup(allocator: std.mem.Allocator, io: std.Io, access_token: []const u8, group_id: []const u8) !GroupDocument {
    const url = try familyGroupUrl(allocator, group_id);
    defer allocator.free(url);
    const response = try fetchAuthenticated(allocator, io, url, access_token);
    defer response.deinit(allocator);
    if (response.status == 401) return error.Unauthorized;
    if (response.status == 403 or response.status == 404) return error.GroupNotFound;
    if (response.status < 200 or response.status >= 300) return error.GroupRequestFailed;
    return parseFamilyGroup(allocator, response.body);
}

test "content mine fixture parses documented card metadata without chapters" {
    var document = try parseMine(std.testing.allocator, @embedFile("fixtures/content-mine.json"));
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 1), document.parsed.value.cards.len);
    const card = document.parsed.value.cards[0];
    try std.testing.expectEqualStrings("37KwQ", card.cardId);
    try std.testing.expectEqualStrings("Yoto", card.metadata.author.?);
    try std.testing.expectEqual(@as(usize, 0), card.content.chapters.len);
}

test "playable content URL uses only documented query fields and escapes identifiers" {
    const url = try playableContentUrl(std.testing.allocator, "card/id", "America/Toronto");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.yotoplay.com/content/card%2Fid?playable=true&signingType=s3&timezone=America%2FToronto", url);
}

test "metadata content URL never requests signed playback" {
    const url = try contentMetadataUrl(std.testing.allocator, "card/id");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.yotoplay.com/content/card%2Fid", url);
    const card = try cardUrl(std.testing.allocator, "card/id");
    defer std.testing.allocator.free(card);
    try std.testing.expectEqualStrings("https://api.yotoplay.com/card/card%2Fid", card);
    try std.testing.expect(std.mem.indexOf(u8, url, "playable") == null);
}

test "playable content fixture retains signed track URLs" {
    var document = try parsePlayableContent(std.testing.allocator, @embedFile("fixtures/content-playable.json"));
    defer document.deinit();
    const track = document.parsed.value.card.content.chapters[0].tracks[0];
    try std.testing.expectEqualStrings("track-1", track.key);
    try std.testing.expect(std.mem.startsWith(u8, track.trackUrl.?, "https://signed.example/"));
}

test "single group fixture expands purchased cards with authors and narrators" {
    var document = try parseFamilyGroup(std.testing.allocator, @embedFile("fixtures/family-group-detail.json"));
    defer document.deinit();
    const group = document.parsed.value;
    try std.testing.expectEqualStrings("group-1", group.id);
    try std.testing.expectEqual(@as(usize, 2), group.items.len);
    try std.testing.expectEqual(@as(usize, 2), group.cards.len);
    const card = group.cards[0];
    try std.testing.expectEqualStrings("04kgK", card.cardId);
    try std.testing.expectEqualStrings("Marvel Press", card.metadata.authors[0]);
    try std.testing.expectEqualStrings("Nezar Alderazi", card.metadata.narrators[0]);
    try std.testing.expectEqual(@as(f64, 4037), card.metadata.media.duration);
    try std.testing.expectEqual(@as(usize, 1), card.content.chapters.len);
    const url = try familyGroupUrl(std.testing.allocator, "group/1");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.yotoplay.com/card/family/library/groups/group%2F1", url);
    try std.testing.expectError(error.InvalidGroupResponse, parseFamilyGroup(std.testing.allocator, "{}"));
}

test "family groups fixture parses items and expanded cards" {
    var document = try parseFamilyGroups(std.testing.allocator, @embedFile("fixtures/family-groups.json"));
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 1), document.parsed.value.len);
    try std.testing.expectEqualStrings("My Favourites", document.parsed.value[0].name);
    try std.testing.expectEqualStrings("37KwQ", document.parsed.value[0].items[0].contentId);
    try std.testing.expectEqualStrings("Bedtime", document.parsed.value[0].cards[0].title);
}

test "bearer header rejects injection" {
    try std.testing.expectError(error.InvalidAccessToken, bearerValue(std.testing.allocator, "token\r\nmalicious: yes"));
}
