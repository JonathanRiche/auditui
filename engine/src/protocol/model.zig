const provider = @import("../providers/model.zig");

pub const ProviderRef = struct {
    provider: []const u8,
};

pub const AccountRef = struct {
    provider: []const u8,
    account: []const u8,

    pub fn identity(self: AccountRef) provider.AccountIdentity {
        return .{ .provider_id = self.provider, .account_id = self.account };
    }
};

pub const ItemRef = struct {
    provider: []const u8,
    account: []const u8,
    itemId: []const u8,

    pub fn itemIdentity(self: ItemRef) provider.ItemIdentity {
        return .{ .provider_id = self.provider, .item_id = self.itemId };
    }

    pub fn accountIdentity(self: ItemRef) provider.AccountIdentity {
        return .{ .provider_id = self.provider, .account_id = self.account };
    }
};

/// Compatibility normalization for protocol-v1 Audible fields. New callers
/// send provider/account/itemId; legacy callers may keep profile/asin.
pub fn normalizeItem(provider_id: ?[]const u8, account_id: ?[]const u8, item_id: ?[]const u8, profile: ?[]const u8, asin: ?[]const u8) !ItemRef {
    const result: ItemRef = .{
        .provider = provider_id orelse provider.audible_id,
        .account = account_id orelse profile orelse return error.MissingAccount,
        .itemId = item_id orelse asin orelse return error.MissingItem,
    };
    try result.accountIdentity().validate();
    try result.itemIdentity().validate();
    return result;
}

test "legacy Audible and neutral identities normalize identically" {
    const legacy = try normalizeItem(null, null, null, "reader", "B012345678");
    const neutral = try normalizeItem("audible", "reader", "B012345678", null, null);
    try @import("std").testing.expectEqualDeep(legacy, neutral);
}
