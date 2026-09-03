const std = @import("std");

pub const Paths = struct {
    config: []const u8,
    data: []const u8,
    state: []const u8,
    cache: []const u8,

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.config);
        allocator.free(self.data);
        allocator.free(self.state);
        allocator.free(self.cache);
    }
};

fn base(allocator: std.mem.Allocator, environ: std.process.Environ, direct_name: []const u8, name: []const u8, fallback: []const u8) ![]u8 {
    if (environ.getAlloc(allocator, direct_name)) |value| return value else |_| {}
    if (environ.getAlloc(allocator, name)) |value| {
        defer allocator.free(value);
        return std.fs.path.join(allocator, &.{ value, "audible-tui" });
    } else |_| {}
    const home = try environ.getAlloc(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, fallback, "audible-tui" });
}

pub fn resolve(allocator: std.mem.Allocator, environ: std.process.Environ) !Paths {
    const config = try base(allocator, environ, "AUDIBLE_CONFIG_DIR", "XDG_CONFIG_HOME", ".config");
    errdefer allocator.free(config);
    const data = try base(allocator, environ, "AUDIBLE_DATA_DIR", "XDG_DATA_HOME", ".local/share");
    errdefer allocator.free(data);
    const state = try base(allocator, environ, "AUDIBLE_STATE_DIR", "XDG_STATE_HOME", ".local/state");
    errdefer allocator.free(state);
    const cache = try base(allocator, environ, "AUDIBLE_CACHE_DIR", "XDG_CACHE_HOME", ".cache");
    return .{ .config = config, .data = data, .state = state, .cache = cache };
}

pub fn ensure(paths: Paths, io: std.Io) !void {
    for ([_][]const u8{ paths.config, paths.data, paths.state, paths.cache }) |path| {
        try std.Io.Dir.cwd().createDirPath(io, path);
        if (@import("builtin").os.tag != .windows) {
            const dir_file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = true });
            defer dir_file.close(io);
            try dir_file.setPermissions(io, .fromMode(0o700));
        }
    }
}
