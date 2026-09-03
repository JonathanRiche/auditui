const std = @import("std");

pub const Profile = struct {
    name: []const u8,
    path: []const u8,
    secure_permissions: bool,
};

pub fn audibleHome(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    const home = try environ.getAlloc(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".audible" });
}

/// Credential profiles created by this native client. Legacy ~/.audible files
/// remain read-only and are searched only after this directory.
pub fn appProfilesDirectory(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    if (environ.getAlloc(allocator, "AUDIBLE_CONFIG_DIR")) |base| {
        defer allocator.free(base);
        return std.fs.path.join(allocator, &.{ base, "profiles" });
    } else |_| {}
    if (environ.getAlloc(allocator, "XDG_CONFIG_HOME")) |base| {
        defer allocator.free(base);
        return std.fs.path.join(allocator, &.{ base, "audible-tui", "profiles" });
    } else |_| {}
    const home = try environ.getAlloc(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".config", "audible-tui", "profiles" });
}

pub fn ensurePrivateDirectory(io: std.Io, directory: []const u8) !void {
    if (std.Io.Dir.cwd().statFile(io, directory, .{ .follow_symlinks = false })) |stat| {
        if (stat.kind != .directory) return error.UnsafeCredentialDirectory;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try std.Io.Dir.cwd().createDirPath(io, directory);
    if (@import("builtin").os.tag != .windows) {
        const file = try std.Io.Dir.cwd().openFile(io, directory, .{ .allow_directory = true });
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o700));
    }
}

pub fn profilePath(allocator: std.mem.Allocator, environ: std.process.Environ, name: []const u8) ![]u8 {
    const directory = try appProfilesDirectory(allocator, environ);
    defer allocator.free(directory);
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{name});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ directory, filename });
}

pub fn discover(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) ![]Profile {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var result: std.ArrayList(Profile) = .empty;
    errdefer {
        for (result.items) |profile| {
            allocator.free(profile.name);
            allocator.free(profile.path);
        }
        result.deinit(allocator);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const name = try allocator.dupe(u8, entry.name[0 .. entry.name.len - 5]);
        errdefer allocator.free(name);
        const path = try std.fs.path.join(allocator, &.{ directory, entry.name });
        const stat = try dir.statFile(io, entry.name, .{});
        const secure = if (@import("builtin").os.tag == .windows) true else (stat.permissions.toMode() & 0o077) == 0;
        try result.append(allocator, .{ .name = name, .path = path, .secure_permissions = secure });
    }
    return result.toOwnedSlice(allocator);
}

pub fn deinitProfiles(allocator: std.mem.Allocator, profiles: []Profile) void {
    for (profiles) |profile| {
        allocator.free(profile.name);
        allocator.free(profile.path);
    }
    allocator.free(profiles);
}

/// Discovers native profiles first, then non-shadowed legacy profiles.
pub fn discoverAll(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) ![]Profile {
    const native_dir = try appProfilesDirectory(allocator, environ);
    defer allocator.free(native_dir);
    const legacy_dir = try audibleHome(allocator, environ);
    defer allocator.free(legacy_dir);
    const native = try discover(allocator, io, native_dir);
    defer deinitProfiles(allocator, native);
    const legacy = try discover(allocator, io, legacy_dir);
    defer deinitProfiles(allocator, legacy);
    var result: std.ArrayList(Profile) = .empty;
    errdefer {
        for (result.items) |profile| {
            allocator.free(profile.name);
            allocator.free(profile.path);
        }
        result.deinit(allocator);
    }
    for (native) |profile| try result.append(allocator, .{
        .name = try allocator.dupe(u8, profile.name),
        .path = try allocator.dupe(u8, profile.path),
        .secure_permissions = profile.secure_permissions,
    });
    for (legacy) |profile| {
        var shadowed = false;
        for (native) |candidate| if (std.mem.eql(u8, candidate.name, profile.name)) {
            shadowed = true;
            break;
        };
        if (!shadowed) try result.append(allocator, .{
            .name = try allocator.dupe(u8, profile.name),
            .path = try allocator.dupe(u8, profile.path),
            .secure_permissions = profile.secure_permissions,
        });
    }
    return result.toOwnedSlice(allocator);
}

pub fn safeToRead(profile: Profile) !void {
    if (!profile.secure_permissions) return error.UnsafeCredentialPermissions;
}

/// Imports an auth file without parsing or exposing its contents. Existing files
/// are never overwritten and the destination is restricted to the current user.
pub fn importFile(io: std.Io, source: []const u8, destination: []const u8) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, source, .{});
    if (@import("builtin").os.tag != .windows and (stat.permissions.toMode() & 0o077) != 0) return error.UnsafeCredentialPermissions;
    const permissions: std.Io.File.Permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600);
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), source, std.Io.Dir.cwd(), destination, io, .{ .permissions = permissions, .make_path = true, .replace = false });
}
