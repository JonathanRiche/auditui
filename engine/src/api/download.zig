const std = @import("std");
const client_api = @import("client.zig");
const sync = @import("sync.zig");
const profiles = @import("../auth/profiles.zig");
const signing = @import("../auth/signing.zig");

pub const max_license_bytes: usize = 4 * 1024 * 1024;
pub const max_artifact_bytes: usize = 8 * 1024 * 1024;

pub const License = struct {
    allocator: std.mem.Allocator,
    media_url: []u8,
    content_format: []u8,
    response: []u8,
    pdf_url: ?[]u8 = null,

    pub fn deinit(self: License) void {
        std.crypto.secureZero(u8, self.media_url);
        self.allocator.free(self.media_url);
        self.allocator.free(self.content_format);
        std.crypto.secureZero(u8, self.response);
        self.allocator.free(self.response);
        if (self.pdf_url) |value| {
            std.crypto.secureZero(u8, value);
            self.allocator.free(value);
        }
    }

    pub fn extension(self: License) []const u8 {
        return if (std.ascii.eqlIgnoreCase(self.content_format, "mpeg")) ".mp3" else ".aaxc";
    }
};

pub const Voucher = struct {
    allocator: std.mem.Allocator,
    key: []u8,
    iv: []u8,

    pub fn deinit(self: Voucher) void {
        std.crypto.secureZero(u8, self.key);
        self.allocator.free(self.key);
        std.crypto.secureZero(u8, self.iv);
        self.allocator.free(self.iv);
    }
};

pub const ArtifactDocuments = struct {
    allocator: std.mem.Allocator,
    chapters: ?[]u8 = null,
    annotations: ?[]u8 = null,

    pub fn deinit(self: ArtifactDocuments) void {
        if (self.chapters) |value| self.allocator.free(value);
        if (self.annotations) |value| self.allocator.free(value);
    }
};

fn validAsin(asin: []const u8) bool {
    if (asin.len == 0 or asin.len > 32) return false;
    for (asin) |byte| if (!std.ascii.isAlphanumeric(byte)) return false;
    return true;
}

fn requiredObject(object: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    const value = object.get(key) orelse return error.InvalidLicenseResponse;
    return if (value == .object) value.object else error.InvalidLicenseResponse;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidLicenseResponse;
    if (value != .string or value.string.len == 0) return error.InvalidLicenseResponse;
    return value.string;
}

fn containsSecretField(value: std.json.Value) bool {
    return switch (value) {
        .object => |object| blk: {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.ascii.eqlIgnoreCase(key, "license_response") or
                    std.ascii.eqlIgnoreCase(key, "content_license") or
                    std.ascii.eqlIgnoreCase(key, "adp_token") or
                    std.ascii.eqlIgnoreCase(key, "refresh_token") or
                    std.ascii.eqlIgnoreCase(key, "device_private_key") or
                    std.ascii.eqlIgnoreCase(key, "access_token") or
                    containsSecretField(entry.value_ptr.*)) break :blk true;
            }
            break :blk false;
        },
        .array => |array| blk: {
            for (array.items) |item| if (containsSecretField(item)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// Re-encodes a bounded JSON sidecar only after recursively rejecting fields
/// which could turn an innocent metadata artifact into credential storage.
pub fn safeJsonArtifact(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    if (body.len == 0 or body.len > max_artifact_bytes) return error.InvalidArtifact;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch return error.InvalidArtifact;
    defer parsed.deinit();
    if (containsSecretField(parsed.value)) return error.SensitiveArtifact;
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    errdefer encoded.deinit();
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &encoded.writer);
    try encoded.writer.writeByte('\n');
    return encoded.toOwnedSlice();
}

fn signedArtifactGet(
    allocator: std.mem.Allocator,
    io: std.Io,
    credentials: sync.ProfileView,
    url: []const u8,
    signing_path: []const u8,
) !?[]u8 {
    var date_buffer: [40]u8 = undefined;
    const date = try signing.formatDate(&date_buffer, std.Io.Clock.real.now(io).toSeconds());
    const signed = try signing.signedHeaders(allocator, "GET", signing_path, "", credentials.adp_token, credentials.device_private_key, date);
    defer signed.deinit();
    const response = try client_api.fetch(allocator, io, .GET, url, null, null, &.{
        .{ .name = "x-adp-token", .value = credentials.adp_token },
        .{ .name = "x-adp-alg", .value = "SHA256withRSA:1.0" },
        .{ .name = "x-adp-signature", .value = signed.signature },
    }, max_artifact_bytes);
    defer response.deinit(allocator);
    if (response.status == 404 or response.status == 204) return null;
    if (response.status == 401 or response.status == 403) return error.Unauthorized;
    if (response.status == 429) return error.RateLimited;
    if (response.status < 200 or response.status >= 300) return error.ArtifactRequestRejected;
    return try safeJsonArtifact(allocator, response.body);
}

/// Fetches non-secret Audible sidecars independently of the license response.
/// Missing or unsupported sidecars are represented as null and never prevent
/// the already licensed media from completing.
pub fn artifactsForProfile(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, profile_name: []const u8, asin: []const u8) !ArtifactDocuments {
    if (!validAsin(asin)) return error.InvalidAsin;
    const discovered = try profiles.discoverAll(allocator, io, environ);
    defer profiles.deinitProfiles(allocator, discovered);
    var selected: ?profiles.Profile = null;
    for (discovered) |profile| if (std.mem.eql(u8, profile.name, profile_name)) {
        selected = profile;
        break;
    };
    const profile = selected orelse return error.ProfileNotFound;
    try profiles.safeToRead(profile);
    var document = try sync.loadProfileDocument(allocator, io, profile.path);
    defer document.deinit();
    const credentials = try sync.profileView(document.value);
    const locale = client_api.Locale.forMarketplace(credentials.marketplace);
    const endpoints = try client_api.Endpoints.init(allocator, locale);
    defer endpoints.deinit(allocator);

    const chapter_path = try std.fmt.allocPrint(allocator, "/1.0/content/{s}/metadata?response_groups=last_position_heard%2Ccontent_reference%2Cchapter_info&quality=High&drm_type=Adrm&chapter_titles_type=Tree", .{asin});
    defer allocator.free(chapter_path);
    const chapter_url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ endpoints.api_origin, chapter_path });
    defer allocator.free(chapter_url);
    const annotation_path = try std.fmt.allocPrint(allocator, "/FionaCDEServiceEngine/sidecar?type=AUDI&key={s}", .{asin});
    defer allocator.free(annotation_path);
    const annotation_url = try std.fmt.allocPrint(allocator, "https://cde-ta-g7g.amazon.com{s}", .{annotation_path});
    defer allocator.free(annotation_url);

    var result: ArtifactDocuments = .{ .allocator = allocator };
    errdefer result.deinit();
    result.chapters = signedArtifactGet(allocator, io, credentials, chapter_url, chapter_path) catch null;
    result.annotations = signedArtifactGet(allocator, io, credentials, annotation_url, annotation_path) catch null;
    return result;
}

fn decryptCbc(allocator: std.mem.Allocator, ciphertext: []const u8, key: [16]u8, iv: [16]u8) ![]u8 {
    if (ciphertext.len == 0 or ciphertext.len % 16 != 0) return error.InvalidVoucher;
    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plaintext);
    const cipher = std.crypto.core.aes.Aes128.initDec(key);
    var previous = iv;
    var offset: usize = 0;
    while (offset < ciphertext.len) : (offset += 16) {
        const block = ciphertext[offset..][0..16].*;
        var decrypted: [16]u8 = undefined;
        cipher.decrypt(&decrypted, &block);
        for (&decrypted, previous) |*byte, prior| byte.* ^= prior;
        @memcpy(plaintext[offset..][0..16], &decrypted);
        previous = block;
    }
    return plaintext;
}

fn isHexSecret(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn decryptVoucherDocuments(allocator: std.mem.Allocator, profile: std.json.Value, license: std.json.Value) !Voucher {
    if (profile != .object or license != .object) return error.InvalidVoucher;
    const device = try requiredObject(profile.object, "device_info");
    const customer = try requiredObject(profile.object, "customer_info");
    const device_type = try requiredString(device, "device_type");
    const serial = try requiredString(device, "device_serial_number");
    const user_id = try requiredString(customer, "user_id");
    const content_license = try requiredObject(license.object, "content_license");
    const asin = try requiredString(content_license, "asin");
    const encrypted = try requiredString(content_license, "license_response");
    var derivation: std.Io.Writer.Allocating = .init(allocator);
    defer {
        std.crypto.secureZero(u8, derivation.written());
        derivation.deinit();
    }
    try derivation.writer.print("{s}{s}{s}{s}", .{ device_type, serial, user_id, asin });
    var digest: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &digest);
    std.crypto.hash.sha2.Sha256.hash(derivation.written(), &digest, .{});
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encrypted) catch return error.InvalidVoucher;
    const ciphertext = try allocator.alloc(u8, decoded_len);
    defer {
        std.crypto.secureZero(u8, ciphertext);
        allocator.free(ciphertext);
    }
    std.base64.standard.Decoder.decode(ciphertext, encrypted) catch return error.InvalidVoucher;
    const plaintext = try decryptCbc(allocator, ciphertext, digest[0..16].*, digest[16..32].*);
    defer {
        std.crypto.secureZero(u8, plaintext);
        allocator.free(plaintext);
    }
    const trimmed = std.mem.trimEnd(u8, plaintext, "\x00");
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return error.InvalidVoucher;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidVoucher;
    const key = try requiredString(parsed.value.object, "key");
    const iv_value = try requiredString(parsed.value.object, "iv");
    if (!isHexSecret(key) or !isHexSecret(iv_value)) return error.InvalidVoucher;
    return .{ .allocator = allocator, .key = try allocator.dupe(u8, key), .iv = try allocator.dupe(u8, iv_value) };
}

pub fn voucherForProfile(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, profile_name: []const u8, voucher_path: []const u8) !Voucher {
    const discovered = try profiles.discoverAll(allocator, io, environ);
    defer profiles.deinitProfiles(allocator, discovered);
    var selected: ?profiles.Profile = null;
    for (discovered) |profile| if (std.mem.eql(u8, profile.name, profile_name)) {
        selected = profile;
        break;
    };
    const profile = selected orelse return error.ProfileNotFound;
    try profiles.safeToRead(profile);
    var profile_document = try sync.loadProfileDocument(allocator, io, profile.path);
    defer profile_document.deinit();
    const stat = try std.Io.Dir.cwd().statFile(io, voucher_path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size == 0 or stat.size > max_license_bytes) return error.InvalidVoucher;
    if (@import("builtin").os.tag != .windows and (stat.permissions.toMode() & 0o077) != 0) return error.UnsafeVoucherPermissions;
    const file = try std.Io.Dir.cwd().openFile(io, voucher_path, .{ .follow_symlinks = false });
    defer file.close(io);
    var read_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const bytes = try reader.interface.readAlloc(allocator, @intCast(stat.size));
    defer {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
    }
    var license_document = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always }) catch return error.InvalidVoucher;
    defer license_document.deinit();
    return decryptVoucherDocuments(allocator, profile_document.value, license_document.value);
}

pub fn parseLicense(allocator: std.mem.Allocator, response: []const u8) !License {
    if (response.len == 0 or response.len > max_license_bytes) return error.InvalidLicenseResponse;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return error.InvalidLicenseResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidLicenseResponse;
    const content_license = try requiredObject(parsed.value.object, "content_license");
    const status = try requiredString(content_license, "status_code");
    if (!std.mem.eql(u8, status, "Granted")) return error.LicenseDenied;
    const metadata = try requiredObject(content_license, "content_metadata");
    const content_url = try requiredObject(metadata, "content_url");
    const media_url = try requiredString(content_url, "offline_url");
    if (!std.mem.startsWith(u8, media_url, "https://")) return error.InsecureMediaUrl;
    const reference = try requiredObject(metadata, "content_reference");
    const format = try requiredString(reference, "content_format");
    if (format.len > 32) return error.InvalidLicenseResponse;
    for (format) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidLicenseResponse;
    const pdf_url = blk: {
        const candidates = [_]?std.json.Value{ metadata.get("pdf_url"), content_license.get("pdf_url"), reference.get("pdf_url") };
        for (candidates) |candidate| if (candidate) |value| if (value == .string and std.mem.startsWith(u8, value.string, "https://")) break :blk value.string;
        break :blk null;
    };
    return .{
        .allocator = allocator,
        .media_url = try allocator.dupe(u8, media_url),
        .content_format = try allocator.dupe(u8, format),
        .response = try allocator.dupe(u8, response),
        .pdf_url = if (pdf_url) |value| try allocator.dupe(u8, value) else null,
    };
}

pub fn requestForProfile(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, profile_name: []const u8, asin: []const u8) !License {
    if (!validAsin(asin)) return error.InvalidAsin;
    const discovered = try profiles.discoverAll(allocator, io, environ);
    defer profiles.deinitProfiles(allocator, discovered);
    var selected: ?profiles.Profile = null;
    for (discovered) |profile| if (std.mem.eql(u8, profile.name, profile_name)) {
        selected = profile;
        break;
    };
    const profile = selected orelse return error.ProfileNotFound;
    try profiles.safeToRead(profile);
    var document = try sync.loadProfileDocument(allocator, io, profile.path);
    defer document.deinit();
    const credentials = try sync.profileView(document.value);
    const locale = client_api.Locale.forMarketplace(credentials.marketplace);
    const endpoints = try client_api.Endpoints.init(allocator, locale);
    defer endpoints.deinit(allocator);

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/1.0/content/{s}/licenserequest", .{ endpoints.api_origin, asin });
    defer allocator.free(endpoint);
    const path_start = std.mem.indexOfPos(u8, endpoint, "https://".len, "/") orelse return error.InvalidLicenseRequest;
    const body = "{\"supported_drm_types\":[\"Mpeg\",\"Adrm\"],\"quality\":\"High\",\"consumption_type\":\"Download\",\"response_groups\":\"last_position_heard, pdf_url, content_reference\"}";
    var date_buffer: [40]u8 = undefined;
    const date = try signing.formatDate(&date_buffer, std.Io.Clock.real.now(io).toSeconds());
    const signed = try signing.signedHeaders(allocator, "POST", endpoint[path_start..], body, credentials.adp_token, credentials.device_private_key, date);
    defer signed.deinit();
    var request_id_bytes: [20]u8 = undefined;
    try io.randomSecure(&request_id_bytes);
    var request_id: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&request_id, "{X}", .{request_id_bytes}) catch unreachable;
    const response = try client_api.fetch(allocator, io, .POST, endpoint, body, "application/json", &.{
        .{ .name = "x-adp-token", .value = credentials.adp_token },
        .{ .name = "x-adp-alg", .value = "SHA256withRSA:1.0" },
        .{ .name = "x-adp-signature", .value = signed.signature },
        .{ .name = "x-amzn-requestid", .value = &request_id },
        .{ .name = "x-adp-sw", .value = "37801821" },
        .{ .name = "x-adp-transport", .value = "WIFI" },
        .{ .name = "x-adp-lto", .value = "120" },
        .{ .name = "x-device-type-id", .value = "A2CZJZGLK2JJVM" },
        .{ .name = "device_idiom", .value = "phone" },
    }, max_license_bytes);
    defer response.deinit(allocator);
    if (response.status == 401 or response.status == 403) return error.Unauthorized;
    if (response.status == 429) return error.RateLimited;
    if (response.status < 200 or response.status >= 300) return error.LicenseRequestRejected;
    return parseLicense(allocator, response.body);
}

test "license response requires a granted HTTPS media URL" {
    const granted =
        \\{"content_license":{"status_code":"Granted","content_metadata":{"content_url":{"offline_url":"https://example.invalid/signed"},"content_reference":{"content_format":"MPEG"}}}}
    ;
    const license = try parseLicense(std.testing.allocator, granted);
    defer license.deinit();
    try std.testing.expectEqualStrings(".mp3", license.extension());
    try std.testing.expectError(error.LicenseDenied, parseLicense(std.testing.allocator, "{\"content_license\":{\"status_code\":\"Denied\"}}"));
}

test "license parser rejects insecure URLs and invalid ASINs" {
    const insecure =
        \\{"content_license":{"status_code":"Granted","content_metadata":{"content_url":{"offline_url":"http://example.invalid/media"},"content_reference":{"content_format":"AAC_44_128"}}}}
    ;
    try std.testing.expectError(error.InsecureMediaUrl, parseLicense(std.testing.allocator, insecure));
    try std.testing.expect(!validAsin("../not-an-asin"));
}

test "AES CBC decrypt matches the NIST SP 800-38A vector" {
    var key: [16]u8 = undefined;
    var iv: [16]u8 = undefined;
    var ciphertext: [16]u8 = undefined;
    var expected: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, "2b7e151628aed2a6abf7158809cf4f3c");
    _ = try std.fmt.hexToBytes(&iv, "000102030405060708090a0b0c0d0e0f");
    _ = try std.fmt.hexToBytes(&ciphertext, "7649abac8119b246cee98e9b12e9197d");
    _ = try std.fmt.hexToBytes(&expected, "6bc1bee22e409f96e93d7e117393172a");
    const plaintext = try decryptCbc(std.testing.allocator, &ciphertext, key, iv);
    defer std.testing.allocator.free(plaintext);
    try std.testing.expectEqualSlices(u8, &expected, plaintext);
}

test "metadata sidecars are canonical JSON and reject license credentials" {
    const safe = try safeJsonArtifact(std.testing.allocator, "{\"content_metadata\":{\"chapter_info\":{\"chapters\":[]}}}");
    defer std.testing.allocator.free(safe);
    try std.testing.expect(std.mem.indexOf(u8, safe, "chapter_info") != null);
    try std.testing.expectError(error.SensitiveArtifact, safeJsonArtifact(std.testing.allocator, "{\"content_license\":{\"license_response\":\"secret\"}}"));
    try std.testing.expectError(error.SensitiveArtifact, safeJsonArtifact(std.testing.allocator, "{\"items\":[{\"refresh_token\":\"secret\"}]}"));
    try std.testing.expectError(error.InvalidArtifact, safeJsonArtifact(std.testing.allocator, "not-json"));
}
