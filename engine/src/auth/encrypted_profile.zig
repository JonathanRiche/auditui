const std = @import("std");

const Aes256 = std.crypto.core.aes.Aes256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64_decoder = std.base64.standard.Decoder;
const b64_encoder = std.base64.standard.Encoder;

pub const block_size: usize = 16;
pub const key_size: usize = 32;
pub const default_kdf_iterations: u16 = 1000;
pub const max_encrypted_bytes: usize = 16 * 1024 * 1024;

/// Owned plaintext which is wiped before release. Callers should keep its
/// lifetime short and must call `deinit`.
pub const SecretBuffer = struct {
    allocator: std.mem.Allocator,
    allocation: []u8,
    bytes: []u8,

    pub fn deinit(self: *SecretBuffer) void {
        std.crypto.secureZero(u8, self.allocation);
        self.allocator.free(self.allocation);
        self.* = undefined;
    }
};

const Decryption = struct {
    allocation: []u8,
    plaintext: []u8,
};

const Envelope = struct {
    salt: []const u8,
    iv: []const u8,
    ciphertext: []const u8,
};

const SaltParams = struct {
    salt: []const u8,
    iterations: u16,
};

const EncryptedParts = struct {
    packed_salt: []u8,
    iv: []u8,
    ciphertext: []u8,
};

fn unpackSalt(packed_salt: []const u8) !SaltParams {
    if (packed_salt.len != block_size) return error.InvalidSalt;

    // audible 0.12.0 wraps the big-endian iteration count in '$'. Older
    // files without the marker use the entire block and the default count.
    if (packed_salt[0] == '$' and packed_salt[3] == '$') {
        const iterations = std.mem.readInt(u16, packed_salt[1..3], .big);
        if (iterations == 0) return error.InvalidKdfIterations;
        return .{ .salt = packed_salt[4..], .iterations = iterations };
    }
    return .{ .salt = packed_salt, .iterations = default_kdf_iterations };
}

fn deriveKey(password: []const u8, params: SaltParams) ![key_size]u8 {
    var key: [key_size]u8 = undefined;
    errdefer std.crypto.secureZero(u8, &key);
    try std.crypto.pwhash.pbkdf2(&key, password, params.salt, params.iterations, HmacSha256);
    return key;
}

fn decryptCbcAlloc(allocator: std.mem.Allocator, ciphertext: []const u8, iv: [block_size]u8, key: [key_size]u8) !Decryption {
    if (ciphertext.len == 0 or ciphertext.len % block_size != 0) return error.InvalidCiphertext;
    if (ciphertext.len > max_encrypted_bytes) return error.EncryptedProfileTooLarge;

    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer {
        std.crypto.secureZero(u8, plaintext);
        allocator.free(plaintext);
    }
    const aes = Aes256.initDec(key);
    var previous = iv;
    var offset: usize = 0;
    while (offset < ciphertext.len) : (offset += block_size) {
        const source: *const [block_size]u8 = ciphertext[offset..][0..block_size];
        const destination: *[block_size]u8 = plaintext[offset..][0..block_size];
        aes.decrypt(destination, source);
        for (destination, previous) |*byte, chain| byte.* ^= chain;
        previous = source.*;
    }

    const padding = plaintext[plaintext.len - 1];
    if (padding == 0 or padding > block_size or padding > plaintext.len) return error.InvalidPasswordOrCiphertext;
    const start = plaintext.len - padding;
    for (plaintext[start..]) |byte| {
        if (byte != padding) return error.InvalidPasswordOrCiphertext;
    }
    // Keep one allocation so the entire decrypted capacity can be wiped.
    return .{ .allocation = plaintext, .plaintext = plaintext[0..start] };
}

fn encryptCbcAlloc(allocator: std.mem.Allocator, plaintext: []const u8, iv: [block_size]u8, key: [key_size]u8) ![]u8 {
    if (plaintext.len > max_encrypted_bytes - block_size) return error.ProfileTooLarge;
    const padding: u8 = @intCast(block_size - (plaintext.len % block_size));
    const padded_len = plaintext.len + padding;
    const padded = try allocator.alloc(u8, padded_len);
    defer {
        std.crypto.secureZero(u8, padded);
        allocator.free(padded);
    }
    @memcpy(padded[0..plaintext.len], plaintext);
    @memset(padded[plaintext.len..], padding);

    const ciphertext = try allocator.alloc(u8, padded_len);
    errdefer allocator.free(ciphertext);
    const aes = Aes256.initEnc(key);
    var previous = iv;
    var offset: usize = 0;
    while (offset < padded_len) : (offset += block_size) {
        var chained: [block_size]u8 = undefined;
        defer std.crypto.secureZero(u8, &chained);
        for (padded[offset..][0..block_size], previous, 0..) |byte, chain, index| chained[index] = byte ^ chain;
        const destination: *[block_size]u8 = ciphertext[offset..][0..block_size];
        aes.encrypt(destination, &chained);
        previous = destination.*;
    }
    return ciphertext;
}

fn decodeBase64Alloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const size = b64_decoder.calcSizeForSlice(encoded) catch return error.InvalidEncryptedEnvelope;
    const result = try allocator.alloc(u8, size);
    errdefer allocator.free(result);
    b64_decoder.decode(result, encoded) catch return error.InvalidEncryptedEnvelope;
    return result;
}

fn encodeBase64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, b64_encoder.calcSize(bytes.len));
    _ = b64_encoder.encode(result, bytes);
    return result;
}

fn copyRawParts(allocator: std.mem.Allocator, input: []const u8) !EncryptedParts {
    const packed_salt = try allocator.dupe(u8, input[0..block_size]);
    errdefer allocator.free(packed_salt);
    const iv = try allocator.dupe(u8, input[block_size .. block_size * 2]);
    errdefer allocator.free(iv);
    const ciphertext = try allocator.dupe(u8, input[block_size * 2 ..]);
    return .{ .packed_salt = packed_salt, .iv = iv, .ciphertext = ciphertext };
}

fn splitEncryptedInput(allocator: std.mem.Allocator, input: []const u8) !EncryptedParts {
    if (input.len == 0) return error.EmptyEncryptedProfile;
    if (input.len > max_encrypted_bytes) return error.EncryptedProfileTooLarge;

    var parsed = std.json.parseFromSlice(Envelope, allocator, input, .{ .ignore_unknown_fields = true }) catch {
        if (input.len < block_size * 3 or input.len % block_size != 0) return error.InvalidEncryptedProfile;
        return copyRawParts(allocator, input);
    };
    defer parsed.deinit();

    const packed_salt = try decodeBase64Alloc(allocator, parsed.value.salt);
    errdefer allocator.free(packed_salt);
    const iv = try decodeBase64Alloc(allocator, parsed.value.iv);
    errdefer allocator.free(iv);
    const ciphertext = try decodeBase64Alloc(allocator, parsed.value.ciphertext);
    return .{ .packed_salt = packed_salt, .iv = iv, .ciphertext = ciphertext };
}

/// Decrypts both JSON-envelope and raw-byte files emitted by audible 0.12.0.
/// CBC is retained solely for interoperability; required-field JSON parsing
/// must follow because this legacy format has no authentication tag.
pub fn decryptAlloc(allocator: std.mem.Allocator, input: []const u8, password: []const u8) !SecretBuffer {
    if (password.len == 0) return error.EmptyPassword;
    const pieces = try splitEncryptedInput(allocator, input);
    defer {
        std.crypto.secureZero(u8, pieces.packed_salt);
        std.crypto.secureZero(u8, pieces.iv);
        std.crypto.secureZero(u8, pieces.ciphertext);
        allocator.free(pieces.packed_salt);
        allocator.free(pieces.iv);
        allocator.free(pieces.ciphertext);
    }
    if (pieces.packed_salt.len != block_size or pieces.iv.len != block_size) return error.InvalidEncryptedProfile;
    const params = try unpackSalt(pieces.packed_salt);
    var key = try deriveKey(password, params);
    defer std.crypto.secureZero(u8, &key);
    const decrypted = try decryptCbcAlloc(allocator, pieces.ciphertext, pieces.iv[0..block_size].*, key);
    return .{ .allocator = allocator, .allocation = decrypted.allocation, .bytes = decrypted.plaintext };
}

fn encryptRawWithMaterials(allocator: std.mem.Allocator, plaintext: []const u8, password: []const u8, salt: [12]u8, iv: [block_size]u8) ![]u8 {
    if (password.len == 0) return error.EmptyPassword;
    var packed_salt: [block_size]u8 = undefined;
    packed_salt[0] = '$';
    std.mem.writeInt(u16, packed_salt[1..3], default_kdf_iterations, .big);
    packed_salt[3] = '$';
    @memcpy(packed_salt[4..], &salt);
    const params = try unpackSalt(&packed_salt);
    var key = try deriveKey(password, params);
    defer std.crypto.secureZero(u8, &key);
    const ciphertext = try encryptCbcAlloc(allocator, plaintext, iv, key);
    defer allocator.free(ciphertext);
    const result = try allocator.alloc(u8, block_size * 2 + ciphertext.len);
    @memcpy(result[0..block_size], &packed_salt);
    @memcpy(result[block_size .. block_size * 2], &iv);
    @memcpy(result[block_size * 2 ..], ciphertext);
    return result;
}

pub fn encryptBytesAlloc(allocator: std.mem.Allocator, io: std.Io, plaintext: []const u8, password: []const u8) ![]u8 {
    var salt: [12]u8 = undefined;
    var iv: [block_size]u8 = undefined;
    try io.randomSecure(&salt);
    try io.randomSecure(&iv);
    return encryptRawWithMaterials(allocator, plaintext, password, salt, iv);
}

pub fn encryptJsonAlloc(allocator: std.mem.Allocator, io: std.Io, plaintext: []const u8, password: []const u8) ![]u8 {
    const raw = try encryptBytesAlloc(allocator, io, plaintext, password);
    defer {
        std.crypto.secureZero(u8, raw);
        allocator.free(raw);
    }
    const salt = try encodeBase64Alloc(allocator, raw[0..block_size]);
    defer allocator.free(salt);
    const iv = try encodeBase64Alloc(allocator, raw[block_size .. block_size * 2]);
    defer allocator.free(iv);
    const ciphertext = try encodeBase64Alloc(allocator, raw[block_size * 2 ..]);
    defer allocator.free(ciphertext);
    return std.fmt.allocPrint(
        allocator,
        "{{\"salt\":\"{s}\",\"iv\":\"{s}\",\"ciphertext\":\"{s}\",\"info\":\"base64-encoded AES-CBC-256 of JSON object\"}}",
        .{ salt, iv, ciphertext },
    );
}

test "decrypts pinned upstream-compatible JSON and bytes vectors" {
    const plaintext = "{\"adp_token\":\"synthetic-adp\",\"device_private_key\":\"synthetic-key\",\"refresh_token\":\"synthetic-refresh\",\"locale_code\":\"ca\"}";
    const password = "fixture-password";
    const salt = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const iv = [_]u8{ 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 };
    const raw = try encryptRawWithMaterials(std.testing.allocator, plaintext, password, salt, iv);
    defer std.testing.allocator.free(raw);
    var expected_buffer: [160]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&expected_buffer, "2403e824000102030405060708090a0b101112131415161718191a1b1c1d1e1f" ++
        "2ef34ca3b74625eb2f48bfd5ad3ab8c668a32ffce63de4dd159a30ab1dcc5f39" ++
        "b83bd2c4cee8fd130b8d5f9519299a83ef408545ffc0fc6e3ff3277bd360101a" ++
        "eacfa6b0ec0f4c1e61c377f56860ad1a2a57094923a05366e15019b81ba53ac9" ++
        "10760b26a241922763f2ca69429489c55ee47543124683804f142a4246f346ab");
    try std.testing.expectEqualSlices(u8, expected, raw);

    var from_bytes = try decryptAlloc(std.testing.allocator, raw, password);
    defer from_bytes.deinit();
    try std.testing.expectEqualStrings(plaintext, from_bytes.bytes);

    const salt_b64 = try encodeBase64Alloc(std.testing.allocator, raw[0..block_size]);
    defer std.testing.allocator.free(salt_b64);
    const iv_b64 = try encodeBase64Alloc(std.testing.allocator, raw[block_size .. block_size * 2]);
    defer std.testing.allocator.free(iv_b64);
    const ciphertext_b64 = try encodeBase64Alloc(std.testing.allocator, raw[block_size * 2 ..]);
    defer std.testing.allocator.free(ciphertext_b64);
    const envelope = try std.fmt.allocPrint(std.testing.allocator, "{{\"salt\":\"{s}\",\"iv\":\"{s}\",\"ciphertext\":\"{s}\"}}", .{ salt_b64, iv_b64, ciphertext_b64 });
    defer std.testing.allocator.free(envelope);
    var from_json = try decryptAlloc(std.testing.allocator, envelope, password);
    defer from_json.deinit();
    try std.testing.expectEqualStrings(plaintext, from_json.bytes);
}

test "rejects wrong password and malformed envelopes" {
    const raw = try encryptRawWithMaterials(std.testing.allocator, "{\"fixture\":true}", "right", [_]u8{0x11} ** 12, [_]u8{0x22} ** block_size);
    defer std.testing.allocator.free(raw);
    try std.testing.expectError(error.InvalidPasswordOrCiphertext, decryptAlloc(std.testing.allocator, raw, "wrong"));
    try std.testing.expectError(error.InvalidEncryptedProfile, decryptAlloc(std.testing.allocator, "not an envelope", "password"));
    try std.testing.expectError(error.EmptyPassword, decryptAlloc(std.testing.allocator, raw, ""));
}

test "PBKDF2 matches RFC 7914 SHA-256 vector" {
    var key: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try std.crypto.pwhash.pbkdf2(&key, "passwd", "salt", 1, HmacSha256);
    var expected_buffer: [32]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&expected_buffer, "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc");
    try std.testing.expectEqualSlices(u8, expected, &key);
}
