const std = @import("std");

pub const audible_id = "audible";

pub const AccountIdentity = struct {
    provider_id: []const u8,
    account_id: []const u8,

    pub fn validate(self: AccountIdentity) !void {
        try validateId(self.provider_id);
        try validateId(self.account_id);
    }
};

pub const ItemIdentity = struct {
    provider_id: []const u8,
    item_id: []const u8,

    pub fn validate(self: ItemIdentity) !void {
        try validateId(self.provider_id);
        try validateId(self.item_id);
    }
};

pub const Account = struct {
    identity: AccountIdentity,
    display_name: []const u8,
    marketplace: ?[]const u8 = null,
    locale: ?[]const u8 = null,
    metadata_json: ?[]const u8 = null,
};

pub const LibraryItem = struct {
    identity: ItemIdentity,
    title: []const u8,
    subtitle: ?[]const u8 = null,
    creators_json: []const u8 = "[]",
    narrators_json: []const u8 = "[]",
    cover_url: ?[]const u8 = null,
    duration_seconds: ?i64 = null,
    release_date: ?[]const u8 = null,
    metadata_json: ?[]const u8 = null,
};

pub const Capabilities = packed struct {
    authentication: bool = false,
    library: bool = false,
    search: bool = false,
    downloads: bool = false,
    wishlist: bool = false,
    annotations: bool = false,
    _reserved: u10 = 0,
};

pub fn validateId(value: []const u8) !void {
    if (value.len == 0 or value.len > 256) return error.InvalidProviderIdentity;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidProviderIdentity;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidProviderIdentity;
}

test "provider identities are opaque but bounded and printable" {
    try (AccountIdentity{ .provider_id = "yoto", .account_id = "family:primary" }).validate();
    try (ItemIdentity{ .provider_id = audible_id, .item_id = "B012345678" }).validate();
    try std.testing.expectError(error.InvalidProviderIdentity, validateId(""));
    try std.testing.expectError(error.InvalidProviderIdentity, validateId("bad\nidentity"));
}
