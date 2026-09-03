const model = @import("model.zig");

/// Provider-neutral capability boundary. Network/auth implementations own
/// their concrete context and expose only stable identity and capability data
/// to the engine core. Future operation vtables can be versioned without
/// leaking provider-specific credential or HTTP types into persistence/RPC.
pub const Adapter = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        id: *const fn (*anyopaque) []const u8,
        displayName: *const fn (*anyopaque) []const u8,
        capabilities: *const fn (*anyopaque) model.Capabilities,
    };

    pub fn id(self: Adapter) []const u8 {
        return self.vtable.id(self.context);
    }

    pub fn displayName(self: Adapter) []const u8 {
        return self.vtable.displayName(self.context);
    }

    pub fn capabilities(self: Adapter) model.Capabilities {
        return self.vtable.capabilities(self.context);
    }
};

test "adapter erases concrete provider implementations" {
    const Example = struct {
        name: []const u8,
        fn id(raw: *anyopaque) []const u8 {
            _ = raw;
            return "example";
        }
        fn displayName(raw: *anyopaque) []const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.name;
        }
        fn capabilities(_: *anyopaque) model.Capabilities {
            return .{ .library = true, .downloads = true };
        }
        const vtable: Adapter.VTable = .{ .id = id, .displayName = displayName, .capabilities = capabilities };
    };
    var example = Example{ .name = "Example Books" };
    const adapter = Adapter{ .context = &example, .vtable = &Example.vtable };
    try @import("std").testing.expectEqualStrings("example", adapter.id());
    try @import("std").testing.expectEqualStrings("Example Books", adapter.displayName());
    try @import("std").testing.expect(adapter.capabilities().downloads);
}
