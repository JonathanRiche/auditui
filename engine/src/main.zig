const std = @import("std");
const engine = @import("audible_engine");

const help =
    \\Usage: audible [OPTIONS] COMMAND [ARGS]...
    \\
    \\The native provider engine for Auditui (Audible and Yoto).
    \\
    \\Global options:
    \\  -P, --profile NAME       Select profile
    \\  -v, --verbose            Increase diagnostic verbosity
    \\  --version                Show version
    \\  --help                   Show this help
    \\
    \\Commands:
    \\  activation-bytes         Retrieve activation bytes
    \\  api                      Make an authenticated API request
    \\  download                 Download owned titles and metadata
    \\  library list|export|refresh
    \\                            Browse, export, or sync the library
    \\  wishlist list|export|add|remove
    \\  manage auth-file|config|profile
    \\  quickstart               Configure a profile interactively
    \\  auth login --provider yoto
    \\                            Connect Yoto with browser OAuth + PKCE
    \\  player status|toggle|pause|play|next|previous|forward|back
    \\                            Inspect or drive the active player (desktop widgets)
    \\  internal health|rpc      Machine-facing integration
    \\
    \\Quickstart options:
    \\  --no-encryption          Store the profile as private mode-0600 JSON
;

fn writeHealth(writer: *std.Io.Writer) !void {
    try std.json.Stringify.value(.{ .status = "ok", .engine = "audible-zig", .version = "0.3.0", .protocolVersion = engine.rpc.version }, .{}, writer);
    try writer.writeByte('\n');
}

fn profileList(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, writer: *std.Io.Writer) !void {
    const found = try engine.profiles.discoverAll(allocator, io, environ);
    defer engine.profiles.deinitProfiles(allocator, found);
    for (found) |profile| try writer.print("{s}\t{s}\n", .{ profile.name, if (profile.secure_permissions) "secure" else "unsafe-permissions" });
}

fn optionValue(args: []const []const u8, long: []const u8, short: []const u8) ?[]const u8 {
    return engine.cli_support.optionValue(args, long, short);
}

fn effectiveProfileName(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, args: []const []const u8) ![]u8 {
    if (optionValue(args, "--profile", "-P")) |explicit| return allocator.dupe(u8, explicit);
    const app_paths = try engine.paths.resolve(allocator, environ);
    defer app_paths.deinit(allocator);
    try engine.paths.ensure(app_paths, io);
    const database_path = try std.fs.path.join(allocator, &.{ app_paths.state, "audible-tui.db" });
    defer allocator.free(database_path);
    var database = try engine.database.Database.open(allocator, io, database_path);
    defer database.deinit();
    return (try database.getSelectedProfile(allocator)) orelse allocator.dupe(u8, "default");
}

fn hasOption(args: []const []const u8, name: []const u8) bool {
    return engine.cli_support.hasOption(args, name);
}

fn selectedProfile(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, args: []const []const u8) !engine.profiles.Profile {
    const name = try effectiveProfileName(allocator, io, environ, args);
    defer allocator.free(name);
    const found = try engine.profiles.discoverAll(allocator, io, environ);
    defer engine.profiles.deinitProfiles(allocator, found);
    for (found) |profile| if (std.mem.eql(u8, profile.name, name)) return .{
        .name = try allocator.dupe(u8, profile.name),
        .path = try allocator.dupe(u8, profile.path),
        .secure_permissions = profile.secure_permissions,
    };
    return error.ProfileNotFound;
}

fn deinitProfile(allocator: std.mem.Allocator, profile: engine.profiles.Profile) void {
    allocator.free(profile.name);
    allocator.free(profile.path);
}

fn loadSelectedDocument(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, args: []const []const u8) !std.json.Parsed(std.json.Value) {
    const profile = try selectedProfile(allocator, io, environ, args);
    defer deinitProfile(allocator, profile);
    const source = try readPrivateProfile(allocator, io, profile);
    defer {
        std.crypto.secureZero(u8, source);
        allocator.free(source);
    }
    return switch (try engine.session.detectAuthFileKind(allocator, source)) {
        .plain_json => std.json.parseFromSlice(std.json.Value, allocator, source, .{ .allocate = .alloc_always }) catch error.InvalidAuthProfile,
        .encrypted_json, .encrypted_bytes => blk: {
            var password = try engine.password_prompt.read(allocator, io, "Profile passphrase: ");
            defer password.deinit();
            var plaintext = try engine.encrypted_profile.decryptAlloc(allocator, source, password.bytes);
            defer plaintext.deinit();
            break :blk std.json.parseFromSlice(std.json.Value, allocator, plaintext.bytes, .{ .allocate = .alloc_always }) catch error.InvalidAuthProfile;
        },
        .unrecognized_json => error.InvalidAuthProfile,
    };
}

fn parseMethod(value: ?[]const u8) !std.http.Method {
    const method = value orelse "GET";
    if (std.ascii.eqlIgnoreCase(method, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(method, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(method, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(method, "DELETE")) return .DELETE;
    return error.InvalidHttpMethod;
}

fn apiCommand(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, writer: *std.Io.Writer, endpoint_arg: []const u8, args: []const []const u8) !void {
    if (endpoint_arg.len == 0 or std.mem.startsWith(u8, endpoint_arg, "-")) return error.MissingEndpoint;
    try engine.cli_support.validateEndpoint(endpoint_arg);
    var document = try loadSelectedDocument(allocator, io, environ, args);
    defer document.deinit();
    const method = try parseMethod(optionValue(args, "--method", "-m"));
    const body = optionValue(args, "--body", "-b");
    if (body) |value| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, value, .{}) catch return error.InvalidJsonBody;
        parsed.deinit();
    }
    var endpoint: std.Io.Writer.Allocating = .init(allocator);
    defer endpoint.deinit();
    try endpoint.writer.writeAll(endpoint_arg);
    const params = try engine.cli_support.optionValues(allocator, args, "--param", "-p");
    defer allocator.free(params);
    for (params, 0..) |parameter, index| {
        if (std.mem.indexOfScalar(u8, parameter, '=') == null or std.mem.indexOfAny(u8, parameter, "\r\n") != null) return error.InvalidQueryParameter;
        try endpoint.writer.writeByte(if (index == 0 and std.mem.indexOfScalar(u8, endpoint_arg, '?') == null) '?' else '&');
        try endpoint.writer.writeAll(parameter);
    }
    const response = try engine.api_account.requestDocument(allocator, io, document.value, .{ .method = method, .endpoint = endpoint.written(), .body = body });
    defer response.deinit(allocator);
    // API output is deliberately the response body only; auth headers and URLs
    // never enter human diagnostics.
    if (optionValue(args, "--output", "-o")) |destination| {
        const file = try std.Io.Dir.cwd().createFile(io, destination, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, response.body);
        try writer.print("Output saved to {s}\n", .{destination});
    } else {
        try writer.writeAll(response.body);
        if (response.body.len == 0 or response.body[response.body.len - 1] != '\n') try writer.writeByte('\n');
    }
}

fn activationBytesCommand(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, writer: *std.Io.Writer, args: []const []const u8) !void {
    var document = try loadSelectedDocument(allocator, io, environ, args);
    defer document.deinit();
    if (!hasOption(args, "--reload") and !hasOption(args, "-r") and document.value == .object) {
        if (document.value.object.get("activation_bytes")) |cached| {
            if (cached == .string and cached.string.len == 8) {
                try writer.print("{s}\n", .{cached.string});
                return;
            }
        }
    }
    const value = try engine.api_account.fetchActivation(allocator, io, document.value);
    try writer.print("{s}\n", .{&value});
}

fn wishlistCommand(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, writer: *std.Io.Writer, subcommand: []const u8, args: []const []const u8) !void {
    var document = try loadSelectedDocument(allocator, io, environ, args);
    defer document.deinit();
    if (std.mem.eql(u8, subcommand, "list") or std.mem.eql(u8, subcommand, "export")) {
        const endpoint = try engine.api_account.wishlistEndpoint(allocator, null);
        defer allocator.free(endpoint);
        const response = try engine.api_account.requestDocument(allocator, io, document.value, .{ .endpoint = endpoint });
        defer response.deinit(allocator);
        const page = try engine.api_account.parseWishlist(allocator, response.body);
        defer page.deinit();
        if (std.mem.eql(u8, subcommand, "list")) {
            for (page.value.products) |item| try writer.print("{s}: {s}\n", .{ item.asin, item.title });
            return;
        }
        var mapped: std.ArrayList(engine.library.Item) = .empty;
        defer mapped.deinit(allocator);
        try engine.api_sync.appendMapped(allocator, &mapped, page.value.products);
        const items = try mapped.toOwnedSlice(allocator);
        defer engine.api_sync.deinitMapped(allocator, items);
        const format = try engine.cli_support.parseFormat(optionValue(args, "--format", "-f"));
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        if (format == .json) {
            try std.json.Stringify.value(items, .{}, &output.writer);
            try output.writer.writeByte('\n');
        } else try writeTabularLibrary(&output.writer, items, if (format == .csv) ',' else '\t', null, null);
        const requested = optionValue(args, "--output", "-o") orelse "wishlist.{format}";
        const destination = try engine.cli_support.replaceFormatExtension(allocator, requested, format);
        defer allocator.free(destination);
        const file = try std.Io.Dir.cwd().createFile(io, destination, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, output.written());
        try writer.print("Exported {s}\n", .{destination});
        return;
    }
    const asins = try engine.cli_support.optionValues(allocator, args, "--asin", "-a");
    defer allocator.free(asins);
    if (asins.len == 0) return error.AsinRequired;
    if (!hasOption(args, "--yes")) return error.ConfirmationRequired;
    for (asins) |asin| {
        const endpoint = if (std.mem.eql(u8, subcommand, "remove"))
            try engine.api_account.wishlistEndpoint(allocator, asin)
        else
            try allocator.dupe(u8, "wishlist");
        defer allocator.free(endpoint);
        const body = if (std.mem.eql(u8, subcommand, "add")) try std.fmt.allocPrint(allocator, "{{\"asin\":\"{s}\"}}", .{asin}) else null;
        defer if (body) |value| allocator.free(value);
        const method: std.http.Method = if (std.mem.eql(u8, subcommand, "add")) .POST else if (std.mem.eql(u8, subcommand, "remove")) .DELETE else return error.UnknownWishlistCommand;
        const response = try engine.api_account.requestDocument(allocator, io, document.value, .{ .method = method, .endpoint = endpoint, .body = body });
        response.deinit(allocator);
        try writer.print("{s}\t{s}\n", .{ asin, if (method == .POST) "added" else "removed" });
    }
}

fn downloadCommand(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, writer: *std.Io.Writer, args: []const []const u8) !void {
    if (hasOption(args, "--aax") and !hasOption(args, "--aax-fallback")) return error.LegacyAaxUnavailable;
    const xdg = try engine.paths.resolve(allocator, environ);
    defer xdg.deinit(allocator);
    const cache_path = try std.fs.path.join(allocator, &.{ xdg.cache, "library.json" });
    defer allocator.free(cache_path);
    var cache = try engine.library.loadCache(allocator, io, cache_path);
    defer cache.deinit();
    const asins = try engine.cli_support.optionValues(allocator, args, "--asin", "-a");
    defer allocator.free(asins);
    const titles = try engine.cli_support.optionValues(allocator, args, "--title", "-t");
    defer allocator.free(titles);
    if (!hasOption(args, "--all") and asins.len == 0 and titles.len == 0) return error.DownloadSelectionRequired;
    const output_dir = optionValue(args, "--output-dir", "-o") orelse ".";
    try std.Io.Dir.cwd().createDirPath(io, output_dir);
    const profile = try effectiveProfileName(allocator, io, environ, args);
    defer allocator.free(profile);
    var queued: usize = 0;
    for (cache.value.items) |item| {
        var selected = hasOption(args, "--all");
        for (asins) |asin| if (std.mem.eql(u8, asin, item.asin)) {
            selected = true;
            break;
        };
        if (!selected) for (titles) |title| if (std.ascii.indexOfIgnoreCase(item.title, title) != null) {
            selected = true;
            break;
        };
        if (!selected) continue;
        var request: std.Io.Writer.Allocating = .init(allocator);
        defer request.deinit();
        try std.json.Stringify.value(.{
            .v = engine.rpc.version,
            .id = item.asin,
            .method = "downloads.start",
            .params = .{ .profile = profile, .asin = item.asin, .itemId = item.asin, .format = "aaxc", .outputDir = output_dir },
        }, .{}, &request.writer);
        var response: std.Io.Writer.Allocating = .init(allocator);
        defer response.deinit();
        var runtime: engine.rpc.Runtime = .{};
        defer runtime.deinit(io);
        try engine.rpc.handleLine(allocator, io, environ, &runtime, &response.writer, request.written());
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.written(), .{}) catch return error.DownloadQueueFailed;
        defer parsed.deinit();
        const ok = parsed.value == .object and parsed.value.object.get("ok") != null and parsed.value.object.get("ok").? == .bool and parsed.value.object.get("ok").?.bool;
        if (!ok) return error.DownloadQueueFailed;
        queued += 1;
        try writer.print("Queued {s}: {s}\n", .{ item.asin, item.title });
    }
    if (queued == 0) return error.NoMatchingTitles;
    try writer.print("{d} download{s} queued. Use the Downloads screen to monitor, cancel, or retry.\n", .{ queued, if (queued == 1) "" else "s" });
}

fn runExternalLogin(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, writer: *std.Io.Writer, args: []const []const u8) !void {
    const profile = optionValue(args, "--profile", "-P") orelse "default";
    const country = optionValue(args, "--country-code", "-cc") orelse "us";
    const no_encryption = hasOption(args, "--no-encryption");
    const directory = try engine.profiles.appProfilesDirectory(allocator, environ);
    defer allocator.free(directory);
    const destination = try engine.profiles.profilePath(allocator, environ, profile);
    defer allocator.free(destination);
    if (std.Io.Dir.cwd().statFile(io, destination, .{ .follow_symlinks = false })) |_| {
        return error.ProfileAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    var pending = try engine.external_auth.begin(allocator, io, profile, country);
    defer pending.deinit(allocator);
    var passphrase: ?engine.password_prompt.Secret = null;
    defer if (passphrase) |*secret| secret.deinit();
    if (no_encryption) {
        try writer.writeAll("WARNING: profile encryption is disabled; credentials will rely on owner-only file permissions.\n");
        try writer.flush();
    } else {
        passphrase = try engine.password_prompt.read(allocator, io, "New profile passphrase: ");
        var confirmation = try engine.password_prompt.read(allocator, io, "Confirm profile passphrase: ");
        defer confirmation.deinit();
        if (!std.mem.eql(u8, passphrase.?.bytes, confirmation.bytes)) return error.PassphraseConfirmationMismatch;
    }
    const login_url = try engine.external_auth.loginUrl(allocator, &pending);
    defer allocator.free(login_url);
    try writer.print("Open this URL in your browser and finish signing in:\n{s}\n", .{login_url});
    try writer.flush();
    if (@import("builtin").os.tag == .linux) {
        var browser = std.process.spawn(io, .{ .argv = &.{ "xdg-open", login_url }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch null;
        if (browser) |*child| _ = child.wait(io) catch {};
    }
    var callback = try engine.password_prompt.readVisible(allocator, io, "Paste the final browser URL (visible): ");
    defer callback.deinit();
    const auth_json = engine.external_auth.register(allocator, io, &pending, callback.bytes) catch |err| {
        std.debug.print("Audible authorization failed ({s}). No credential file was written.\n", .{@errorName(err)});
        return err;
    };
    defer {
        std.crypto.secureZero(u8, auth_json);
        allocator.free(auth_json);
    }
    try engine.profiles.ensurePrivateDirectory(io, directory);
    if (std.Io.Dir.cwd().statFile(io, destination, .{ .follow_symlinks = false })) |_| {
        return error.ProfileAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    if (no_encryption) {
        try engine.session.atomicWriteCredentials(allocator, io, destination, auth_json);
        try writer.print("Authorized profile {s}. Credentials were stored unencrypted with owner-only permissions.\n", .{profile});
    } else {
        try engine.credential_store.writeEncrypted(allocator, io, destination, auth_json, passphrase.?.bytes);
        try writer.print("Authorized profile {s}. Credentials were encrypted and stored with private permissions.\n", .{profile});
    }
}

fn itemInDateRange(item: engine.library.Item, start: ?[]const u8, end: ?[]const u8) bool {
    const date = item.releaseDate orelse return start == null and end == null;
    if (start) |value| if (std.mem.order(u8, date, value) == .lt) return false;
    if (end) |value| if (std.mem.order(u8, date, value) == .gt) return false;
    return true;
}

fn validateDate(value: ?[]const u8) !void {
    const date = value orelse return;
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return error.InvalidDate;
    for (date, 0..) |byte, index| if (index != 4 and index != 7 and !std.ascii.isDigit(byte)) return error.InvalidDate;
    const month = std.fmt.parseInt(u8, date[5..7], 10) catch return error.InvalidDate;
    const day = std.fmt.parseInt(u8, date[8..10], 10) catch return error.InvalidDate;
    if (month == 0 or month > 12 or day == 0 or day > 31) return error.InvalidDate;
}

fn writeJoined(writer: *std.Io.Writer, values: []const []const u8) !void {
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(value);
    }
}

fn writeTabularLibrary(writer: *std.Io.Writer, items: []const engine.library.Item, separator: u8, start: ?[]const u8, end: ?[]const u8) !void {
    try writer.print("asin{c}title{c}authors{c}narrators{c}runtime_seconds{c}percent_complete{c}release_date{c}cover_url\n", .{ separator, separator, separator, separator, separator, separator, separator });
    for (items) |item| {
        if (!itemInDateRange(item, start, end)) continue;
        try engine.cli_support.csvField(writer, item.asin, separator);
        try writer.writeByte(separator);
        try engine.cli_support.csvField(writer, item.title, separator);
        try writer.writeByte(separator);
        var joined: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer joined.deinit();
        try writeJoined(&joined.writer, item.authors);
        try engine.cli_support.csvField(writer, joined.written(), separator);
        joined.clearRetainingCapacity();
        try writer.writeByte(separator);
        try writeJoined(&joined.writer, item.narrators);
        try engine.cli_support.csvField(writer, joined.written(), separator);
        try writer.print("{c}{d:.0}{c}{d:.2}{c}", .{ separator, item.durationSeconds, separator, if (item.durationSeconds > 0) item.positionSeconds / item.durationSeconds * 100 else 0, separator });
        try engine.cli_support.csvField(writer, item.releaseDate orelse "", separator);
        try writer.writeByte(separator);
        try engine.cli_support.csvField(writer, item.coverUrl orelse "", separator);
        try writer.writeByte('\n');
    }
}

fn libraryCommand(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, writer: *std.Io.Writer, export_data: bool, args: []const []const u8) !void {
    const provider = optionValue(args, "--provider", "") orelse "audible";
    const account = optionValue(args, "--account", "") orelse optionValue(args, "--profile", "-P") orelse "default";
    const cache_path = if (std.mem.eql(u8, provider, "yoto"))
        try engine.yoto.provider.cachePath(allocator, environ, account)
    else blk: {
        if (!std.mem.eql(u8, provider, "audible")) return error.UnknownProvider;
        const xdg = try engine.paths.resolve(allocator, environ);
        defer xdg.deinit(allocator);
        break :blk try std.fs.path.join(allocator, &.{ xdg.cache, "library.json" });
    };
    defer allocator.free(cache_path);
    const cached = engine.library.loadCache(allocator, io, cache_path) catch |err| switch (err) {
        error.FileNotFound => {
            if (export_data) try writer.writeAll("[]\n");
            return;
        },
        else => return err,
    };
    defer cached.deinit();
    const start = optionValue(args, "--start-date", "");
    const end = optionValue(args, "--end-date", "");
    try validateDate(start);
    try validateDate(end);
    if (start != null and end != null and std.mem.order(u8, start.?, end.?) == .gt) return error.InvalidDateRange;
    if (!export_data) {
        for (cached.value.items) |item| {
            if (itemInDateRange(item, start, end)) try writer.print("{s}: {s}\n", .{ if (item.asin.len != 0) item.asin else item.id, item.title });
        }
        return;
    }
    const format = try engine.cli_support.parseFormat(optionValue(args, "--format", "-f"));
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    if (format == .json) {
        var filtered: std.ArrayList(engine.library.Item) = .empty;
        defer filtered.deinit(allocator);
        for (cached.value.items) |item| if (itemInDateRange(item, start, end)) try filtered.append(allocator, item);
        try std.json.Stringify.value(filtered.items, .{}, &output.writer);
        try output.writer.writeByte('\n');
    } else try writeTabularLibrary(&output.writer, cached.value.items, if (format == .csv) ',' else '\t', start, end);
    const requested = optionValue(args, "--output", "-o") orelse "library.{format}";
    const destination = try engine.cli_support.replaceFormatExtension(allocator, requested, format);
    defer allocator.free(destination);
    const file = try std.Io.Dir.cwd().createFile(io, destination, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, output.written());
    try writer.print("Exported {s}\n", .{destination});
}

fn readPrivateProfile(allocator: std.mem.Allocator, io: std.Io, profile: engine.profiles.Profile) ![]u8 {
    try engine.profiles.safeToRead(profile);
    const stat = try std.Io.Dir.cwd().statFile(io, profile.path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size == 0 or stat.size > engine.session.max_auth_file_bytes) return error.InvalidAuthProfile;
    const file = try std.Io.Dir.cwd().openFile(io, profile.path, .{ .follow_symlinks = false });
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.readAlloc(allocator, @intCast(stat.size));
}

fn libraryRefreshCommand(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, writer: *std.Io.Writer, args: []const []const u8) !void {
    const provider = optionValue(args, "--provider", "") orelse "audible";
    if (std.mem.eql(u8, provider, "yoto")) {
        const account = optionValue(args, "--account", "") orelse optionValue(args, "--profile", "-P") orelse "default";
        const result = try engine.yoto.provider.refreshLibrary(allocator, io, environ, account);
        try writer.print("Refreshed {d} Yoto titles for account {s}.\n", .{ result.item_count, account });
        if (result.group_count == 0) try writer.print("{s}\n", .{engine.yoto.provider.no_groups_hint});
        if (result.forbidden_count > 0) try writer.print("Skipped {d} group cards. {s}\n", .{ result.forbidden_count, engine.yoto.provider.forbidden_hint });
        return;
    }
    if (!std.mem.eql(u8, provider, "audible")) return error.UnknownProvider;
    const profile_name = try effectiveProfileName(allocator, io, environ, args);
    defer allocator.free(profile_name);
    const found = try engine.profiles.discoverAll(allocator, io, environ);
    defer engine.profiles.deinitProfiles(allocator, found);
    var selected: ?engine.profiles.Profile = null;
    for (found) |profile| if (std.mem.eql(u8, profile.name, profile_name)) {
        selected = profile;
        break;
    };
    const profile = selected orelse return error.ProfileNotFound;
    const xdg = try engine.paths.resolve(allocator, environ);
    defer xdg.deinit(allocator);
    const cache_path = try std.fs.path.join(allocator, &.{ xdg.cache, "library.json" });
    defer allocator.free(cache_path);
    const source = try readPrivateProfile(allocator, io, profile);
    defer {
        std.crypto.secureZero(u8, source);
        allocator.free(source);
    }
    const kind = try engine.session.detectAuthFileKind(allocator, source);
    const result = switch (kind) {
        .plain_json => try engine.api_sync.refreshProfile(allocator, io, environ, profile_name, cache_path),
        .unrecognized_json => return error.InvalidAuthProfile,
        .encrypted_json, .encrypted_bytes => blk: {
            var password = try engine.password_prompt.read(allocator, io, "Profile passphrase: ");
            defer password.deinit();
            var plaintext = try engine.encrypted_profile.decryptAlloc(allocator, source, password.bytes);
            defer plaintext.deinit();
            var document = std.json.parseFromSlice(std.json.Value, allocator, plaintext.bytes, .{ .allocate = .alloc_always }) catch return error.InvalidAuthProfile;
            defer document.deinit();
            const synced = try engine.api_sync.refreshDocument(allocator, io, &document, cache_path);
            if (synced.token_refreshed) {
                var encoded: std.Io.Writer.Allocating = .init(allocator);
                defer {
                    std.crypto.secureZero(u8, encoded.written());
                    encoded.deinit();
                }
                try std.json.Stringify.value(document.value, .{}, &encoded.writer);
                try engine.credential_store.writeEncrypted(allocator, io, profile.path, encoded.written(), password.bytes);
            }
            break :blk synced;
        },
    };
    try writer.print("Refreshed {d} library titles for profile {s}.\n", .{ result.item_count, profile_name });
}

fn yotoLoginCommand(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, writer: *std.Io.Writer, args: []const []const u8) !void {
    const provider = optionValue(args, "--provider", "") orelse "audible";
    if (!std.mem.eql(u8, provider, "yoto")) return error.UnknownProvider;
    const account = optionValue(args, "--account", "") orelse optionValue(args, "--profile", "-P") orelse "default";
    const explicit_client = optionValue(args, "--client-id", "");
    const allocated_client = if (explicit_client == null) environ.getAlloc(allocator, "YOTO_CLIENT_ID") catch null else null;
    defer if (allocated_client) |value| allocator.free(value);
    const client_id = explicit_client orelse allocated_client orelse return error.YotoClientIdRequired;
    try engine.yoto.provider.connect(allocator, io, environ, account, client_id, writer);
    const result = try engine.yoto.provider.refreshLibrary(allocator, io, environ, account);
    try writer.print("Loaded {d} Yoto titles.\n", .{result.item_count});
    if (result.group_count == 0) try writer.print("{s}\n", .{engine.yoto.provider.no_groups_hint});
    if (result.forbidden_count > 0) try writer.print("Skipped {d} group cards. {s}\n", .{ result.forbidden_count, engine.yoto.provider.forbidden_hint });
}

fn profileImport(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, writer: *std.Io.Writer, source: []const u8, name: []const u8) !void {
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null) return error.InvalidProfileName;
    const xdg = try engine.paths.resolve(allocator, environ);
    defer xdg.deinit(allocator);
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{name});
    defer allocator.free(filename);
    const destination = try std.fs.path.join(allocator, &.{ xdg.config, "profiles", filename });
    defer allocator.free(destination);
    try engine.profiles.importFile(io, source, destination);
    try writer.print("Imported profile {s}\n", .{name});
}

fn profileRemove(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, writer: *std.Io.Writer, args: []const []const u8) !void {
    if (!hasOption(args, "--yes")) return error.ConfirmationRequired;
    const names = try engine.cli_support.optionValues(allocator, args, "--profile", "-P");
    defer allocator.free(names);
    if (names.len == 0) return error.ProfileRequired;
    for (names) |name| {
        if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidProfileName;
        const path = try engine.profiles.profilePath(allocator, environ, name);
        defer allocator.free(path);
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        if (stat.kind != .file) return error.InvalidAuthProfile;
        try std.Io.Dir.cwd().deleteFile(io, path);
        try writer.print("Removed local profile {s}. Audible device registration was not changed.\n", .{name});
    }
}

fn authFileTransform(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, args: []const []const u8, encrypt: bool) !void {
    const path = optionValue(args, "--auth-file", "-f") orelse return error.AuthFileRequired;
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size == 0 or stat.size > engine.session.max_auth_file_bytes) return error.InvalidAuthProfile;
    if (@import("builtin").os.tag != .windows and (stat.permissions.toMode() & 0o077) != 0) return error.UnsafeCredentialPermissions;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    var read_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const source = try reader.interface.readAlloc(allocator, @intCast(stat.size));
    defer {
        std.crypto.secureZero(u8, source);
        allocator.free(source);
    }
    const kind = try engine.session.detectAuthFileKind(allocator, source);
    if (encrypt) {
        if (kind != .plain_json) return error.AuthFileAlreadyEncrypted;
        var password = try engine.password_prompt.read(allocator, io, "New auth-file passphrase: ");
        defer password.deinit();
        var confirmation = try engine.password_prompt.read(allocator, io, "Confirm auth-file passphrase: ");
        defer confirmation.deinit();
        if (!std.mem.eql(u8, password.bytes, confirmation.bytes)) return error.PassphraseConfirmationMismatch;
        try engine.credential_store.writeEncrypted(allocator, io, path, source, password.bytes);
        try writer.writeAll("Auth file encrypted.\n");
    } else {
        if (kind == .plain_json) return error.AuthFileAlreadyPlaintext;
        var password = try engine.password_prompt.read(allocator, io, "Auth-file passphrase: ");
        defer password.deinit();
        var plaintext = try engine.encrypted_profile.decryptAlloc(allocator, source, password.bytes);
        defer plaintext.deinit();
        // Validate before replacing the only copy. CBC interoperability has no
        // authenticity tag, so a successful JSON parse is mandatory.
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, plaintext.bytes, .{}) catch return error.InvalidPasswordOrCiphertext;
        defer parsed.deinit();
        if (parsed.value != .object or !parsed.value.object.contains("adp_token")) return error.InvalidPasswordOrCiphertext;
        try engine.session.atomicWriteCredentials(allocator, io, path, plaintext.bytes);
        try writer.writeAll("Auth file decrypted with owner-only permissions.\n");
    }
}

fn authFileRemove(io: std.Io, writer: *std.Io.Writer, args: []const []const u8) !void {
    if (!hasOption(args, "--yes")) return error.ConfirmationRequired;
    const path = optionValue(args, "--auth-file", "-f") orelse return error.AuthFileRequired;
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.InvalidAuthProfile;
    try std.Io.Dir.cwd().deleteFile(io, path);
    try writer.writeAll("Removed the local auth file. Audible device registration was not changed.\n");
}

fn configEdit(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !void {
    const paths = try engine.paths.resolve(allocator, environ);
    defer paths.deinit(allocator);
    try engine.paths.ensure(paths, io);
    const config_path = try std.fs.path.join(allocator, &.{ paths.config, "config.toml" });
    defer allocator.free(config_path);
    if (std.Io.Dir.cwd().statFile(io, config_path, .{})) |_| {} else |err| switch (err) {
        error.FileNotFound => {
            const config = try std.Io.Dir.cwd().createFile(io, config_path, .{ .permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600) });
            config.close(io);
        },
        else => return err,
    }
    const editor = environ.getAlloc(allocator, "EDITOR") catch try allocator.dupe(u8, "vi");
    defer allocator.free(editor);
    if (editor.len == 0 or std.mem.indexOfAny(u8, editor, " \t\r\n") != null) return error.InvalidEditor;
    var child = try std.process.spawn(io, .{ .argv = &.{ editor, config_path } });
    const status = try child.wait(io);
    if (status != .exited or status.exited != 0) return error.EditorFailed;
}

fn rpcLoop(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, writer: *std.Io.Writer) !void {
    const app_paths = try engine.paths.resolve(allocator, environ);
    defer app_paths.deinit(allocator);
    try engine.paths.ensure(app_paths, io);
    const database_path = try std.fs.path.join(allocator, &.{ app_paths.state, "audible-tui.db" });
    defer allocator.free(database_path);
    var database = try engine.database.Database.open(allocator, io, database_path);
    defer database.deinit();
    try engine.rpc.recoverDownloads(allocator, io, environ);
    var runtime: engine.rpc.Runtime = .{ .database = &database };
    defer runtime.deinit(io);
    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    while (try stdin_reader.interface.takeDelimiter('\n')) |raw| {
        const line = std.mem.trim(u8, raw, "\r \t");
        if (line.len == 0) continue;
        try engine.rpc.handleLine(allocator, io, environ, &runtime, writer, line);
        try writer.flush();
    }
}

fn rootCommandIndex(args: []const []const u8) !usize {
    var index: usize = 1;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--password") or std.mem.eql(u8, arg, "-p")) return error.PasswordArgumentForbidden;
        if (std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--verbosity") or std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--log-file")) {
            if (index + 1 >= args.len) return error.MissingOptionValue;
            index += 2;
            continue;
        }
        return index;
    }
    return error.MissingCommand;
}

fn validateRequiredOptionValues(args: []const []const u8) !void {
    const requiring_value = [_][]const u8{
        "--profile",         "-P",          "--country-code", "-cc",            "--method",     "-m",         "--param",
        "--body",            "-b",          "--output",       "-o",             "--format",     "-f",         "--start-date",
        "--end-date",        "--auth-file", "--asin",         "-a",             "--title",      "-t",         "--output-dir",
        "--quality",         "-q",          "--cover-size",   "--chapter-type", "--jobs",       "-j",         "--filename-mode",
        "--filename-length", "-l",          "--timeout",      "--page-size",    "--bunch-size", "--provider", "--account",
        "--client-id",
    };
    for (args, 0..) |arg, index| {
        for (requiring_value) |option| if (std.mem.eql(u8, arg, option)) {
            if (index + 1 >= args.len or std.mem.startsWith(u8, args[index + 1], "-")) return error.MissingOptionValue;
        };
    }
}

/// `player status` prints one JSON snapshot for desktop integrations; the
/// other verbs drive mpv over its IPC socket and then print the new snapshot.
fn playerCommand(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, writer: *std.Io.Writer, args: []const []const u8) !void {
    const state_dir = try engine.now_playing.stateDir(allocator, environ);
    defer allocator.free(state_dir);
    if (std.mem.eql(u8, args[0], "status")) return engine.now_playing.writeSnapshot(allocator, io, state_dir, writer);
    const action = engine.now_playing.Action.parse(args[0]) orelse {
        std.debug.print("audible-zig: unknown player action '{s}' (expected status, toggle, pause, play, next, previous, forward, back)\n", .{args[0]});
        return error.UnknownPlayerAction;
    };
    var seconds = engine.now_playing.default_seek_seconds;
    if (args.len >= 2 and !std.mem.startsWith(u8, args[1], "-")) {
        seconds = std.fmt.parseFloat(f64, args[1]) catch return error.InvalidSeekSeconds;
        if (!(seconds > 0 and seconds <= 3600)) return error.InvalidSeekSeconds;
    }
    engine.now_playing.control(allocator, io, state_dir, writer, action, seconds) catch |err| switch (err) {
        error.NoActivePlayer => {
            try writer.writeAll("{\"state\":\"stopped\"}\n");
            return;
        },
        else => return err,
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};

    if (args.len <= 1) return stdout.writeAll(help ++ "\n");
    for (args[1..]) |arg| if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return stdout.writeAll(help ++ "\n");
    if (std.mem.eql(u8, args[1], "--version")) return stdout.writeAll("audible-zig 0.3.0\n");
    try validateRequiredOptionValues(args[1..]);
    const command_index = try rootCommandIndex(args);
    const command = args[command_index];
    const tail = args[command_index + 1 ..];
    const all_options = args[1..];
    if (std.mem.eql(u8, command, "internal") and tail.len >= 1 and std.mem.eql(u8, tail[0], "health")) return writeHealth(stdout);
    if (std.mem.eql(u8, command, "internal") and tail.len >= 2 and std.mem.eql(u8, tail[0], "download-worker")) return engine.rpc.runDownloadWorker(allocator, init.io, init.minimal.environ, stdout, tail[1]);
    if (std.mem.eql(u8, command, "internal") and tail.len >= 1 and std.mem.eql(u8, tail[0], "rpc")) return rpcLoop(allocator, init.io, init.minimal.environ, stdout);
    if (std.mem.eql(u8, command, "player") and tail.len >= 1) return playerCommand(allocator, init.io, init.minimal.environ, stdout, tail);
    if (std.mem.eql(u8, command, "auth") and tail.len >= 1 and std.mem.eql(u8, tail[0], "login")) return yotoLoginCommand(allocator, init.io, init.minimal.environ, stdout, tail[1..]);
    if (std.mem.eql(u8, command, "api") and tail.len >= 1) return apiCommand(allocator, init.io, init.minimal.environ, stdout, tail[0], all_options);
    if (std.mem.eql(u8, command, "activation-bytes")) return activationBytesCommand(allocator, init.io, init.minimal.environ, stdout, all_options);
    if (std.mem.eql(u8, command, "library") and tail.len >= 1 and std.mem.eql(u8, tail[0], "list")) return libraryCommand(allocator, init.io, init.minimal.environ, stdout, false, tail[1..]);
    if (std.mem.eql(u8, command, "library") and tail.len >= 1 and std.mem.eql(u8, tail[0], "export")) return libraryCommand(allocator, init.io, init.minimal.environ, stdout, true, tail[1..]);
    if (std.mem.eql(u8, command, "library") and tail.len >= 1 and std.mem.eql(u8, tail[0], "refresh")) return libraryRefreshCommand(allocator, init.io, init.minimal.environ, stdout, all_options);
    if (std.mem.eql(u8, command, "manage") and tail.len >= 2 and std.mem.eql(u8, tail[0], "profile") and (std.mem.eql(u8, tail[1], "list") or std.mem.eql(u8, tail[1], "status"))) return profileList(allocator, init.io, init.minimal.environ, stdout);
    if (std.mem.eql(u8, command, "manage") and tail.len >= 4 and std.mem.eql(u8, tail[0], "profile") and (std.mem.eql(u8, tail[1], "import") or std.mem.eql(u8, tail[1], "add"))) return profileImport(allocator, init.io, init.minimal.environ, stdout, tail[2], tail[3]);
    if (std.mem.eql(u8, command, "manage") and tail.len >= 2 and std.mem.eql(u8, tail[0], "profile") and std.mem.eql(u8, tail[1], "remove")) return profileRemove(allocator, init.io, init.minimal.environ, stdout, tail[2..]);
    if (std.mem.eql(u8, command, "manage") and tail.len >= 2 and std.mem.eql(u8, tail[0], "config") and std.mem.eql(u8, tail[1], "edit")) return configEdit(allocator, init.io, init.minimal.environ);
    if (std.mem.eql(u8, command, "manage") and tail.len >= 2 and std.mem.eql(u8, tail[0], "auth-file") and std.mem.eql(u8, tail[1], "encrypt")) return authFileTransform(allocator, init.io, stdout, tail[2..], true);
    if (std.mem.eql(u8, command, "manage") and tail.len >= 2 and std.mem.eql(u8, tail[0], "auth-file") and std.mem.eql(u8, tail[1], "decrypt")) return authFileTransform(allocator, init.io, stdout, tail[2..], false);
    if (std.mem.eql(u8, command, "manage") and tail.len >= 2 and std.mem.eql(u8, tail[0], "auth-file") and std.mem.eql(u8, tail[1], "remove")) return authFileRemove(init.io, stdout, tail[2..]);
    if (std.mem.eql(u8, command, "wishlist") and tail.len >= 1) return wishlistCommand(allocator, init.io, init.minimal.environ, stdout, tail[0], all_options);
    if (std.mem.eql(u8, command, "download")) return downloadCommand(allocator, init.io, init.minimal.environ, stdout, all_options);
    if (std.mem.eql(u8, command, "quickstart")) return runExternalLogin(allocator, init.io, init.minimal.environ, stdout, all_options);
    if (std.mem.eql(u8, command, "manage") and tail.len >= 2 and std.mem.eql(u8, tail[0], "auth-file") and std.mem.eql(u8, tail[1], "add")) return runExternalLogin(allocator, init.io, init.minimal.environ, stdout, all_options);
    std.debug.print("audible-zig: command is recognized for compatibility but is not implemented in this MVP\n", .{});
    return error.CommandNotImplemented;
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        const message = switch (err) {
            error.ProfileNotFound => "profile not found; open Settings or run `audible-zig quickstart`",
            error.ProfilePasswordRequired => "encrypted profile requires the secure terminal passphrase prompt",
            error.Unauthorized => "Unauthorized: the provider rejected this session; reconnect the account (Audible: reconnect the profile; Yoto: run `auth login --provider yoto` again)",
            error.YotoSessionExpired => "YotoSessionExpired: the Yoto session expired and this application has no offline_access approval; run `audible-zig auth login --provider yoto --client-id YOUR_CLIENT_ID` again",
            error.ConfirmationRequired => "confirmation required; review the action and repeat with --yes",
            error.PasswordArgumentForbidden => "passwords are never accepted in argv; use the hidden prompt",
            error.CommandNotImplemented => "unknown command; run --help",
            error.AsinRequired => "at least one --asin is required",
            error.MissingEndpoint => "API endpoint is required",
            error.UnsafeCredentialPermissions => "credential file permissions are unsafe; set them to 0600",
            error.LegacyAaxUnavailable => "LegacyAaxUnavailable: legacy AAX output is unavailable; use --aaxc or explicitly allow --aax-fallback",
            error.DownloadSelectionRequired => "DownloadSelectionRequired: choose titles with --all, --asin, or --title",
            error.NoMatchingTitles => "NoMatchingTitles: no cached library titles matched the requested selection; refresh the library and try again",
            error.DownloadQueueFailed => "DownloadQueueFailed: the download could not be queued; open Downloads for details and retry",
            error.InvalidDate => "InvalidDate: dates must use YYYY-MM-DD",
            error.InvalidDateRange => "InvalidDateRange: --start-date must not be later than --end-date",
            error.InvalidHttpMethod => "InvalidHttpMethod: HTTP method must be GET, POST, PUT, or DELETE",
            error.InvalidJsonBody => "InvalidJsonBody: --body must contain valid JSON",
            error.InvalidQueryParameter => "InvalidQueryParameter: each --param must be a single key=value without newlines",
            error.UnknownProvider => "unknown provider; choose audible or yoto",
            error.YotoClientIdRequired => "Yoto setup is one command: auditui auth login --provider yoto --client-id YOUR_CLIENT_ID",
            error.MissingOptionValue => "MissingOptionValue: an option is missing its value; run --help for usage",
            else => @errorName(err),
        };
        std.debug.print("audible-zig: {s}\n", .{message});
        std.process.exit(1);
    };
}
