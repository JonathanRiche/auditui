const std = @import("std");

const max_rsa_bits = 4096;
const Modulus = std.crypto.ff.Modulus(max_rsa_bits);
const sha256_digest_info_prefix = [_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
    0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
};

const DerReader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn length(self: *DerReader) !usize {
        if (self.offset >= self.bytes.len) return error.InvalidPrivateKey;
        const first = self.bytes[self.offset];
        self.offset += 1;
        if (first & 0x80 == 0) return first;
        const count = first & 0x7f;
        if (count == 0 or count > @sizeOf(usize) or self.offset + count > self.bytes.len) return error.InvalidPrivateKey;
        var result: usize = 0;
        for (self.bytes[self.offset .. self.offset + count]) |byte| result = (result << 8) | byte;
        self.offset += count;
        return result;
    }

    fn element(self: *DerReader, tag: u8) ![]const u8 {
        if (self.offset >= self.bytes.len or self.bytes[self.offset] != tag) return error.InvalidPrivateKey;
        self.offset += 1;
        const len = try self.length();
        if (len > self.bytes.len - self.offset) return error.InvalidPrivateKey;
        const value = self.bytes[self.offset .. self.offset + len];
        self.offset += len;
        return value;
    }
};

const PrivateParts = struct { modulus: []const u8, private_exponent: []const u8 };

fn positiveInteger(bytes: []const u8) ![]const u8 {
    if (bytes.len == 0 or bytes[0] & 0x80 != 0) return error.InvalidPrivateKey;
    var value = bytes;
    while (value.len > 1 and value[0] == 0) value = value[1..];
    return value;
}

fn parsePkcs1(der: []const u8) !PrivateParts {
    var outer: DerReader = .{ .bytes = der };
    const sequence = try outer.element(0x30);
    if (outer.offset != der.len) return error.InvalidPrivateKey;
    var fields: DerReader = .{ .bytes = sequence };
    const version = try positiveInteger(try fields.element(0x02));
    if (version.len != 1 or version[0] != 0) return error.UnsupportedPrivateKey;
    const modulus = try positiveInteger(try fields.element(0x02));
    _ = try positiveInteger(try fields.element(0x02)); // public exponent
    const private_exponent = try positiveInteger(try fields.element(0x02));
    if (modulus.len < 128 or modulus.len > max_rsa_bits / 8 or private_exponent.len > modulus.len) return error.UnsupportedPrivateKey;
    return .{ .modulus = modulus, .private_exponent = private_exponent };
}

fn decodePem(allocator: std.mem.Allocator, pem: []const u8) ![]u8 {
    const begin = "-----BEGIN RSA PRIVATE KEY-----";
    const end = "-----END RSA PRIVATE KEY-----";
    const begin_at = std.mem.indexOf(u8, pem, begin) orelse return error.InvalidPrivateKey;
    const encoded_start = begin_at + begin.len;
    const end_at = std.mem.indexOfPos(u8, pem, encoded_start, end) orelse return error.InvalidPrivateKey;
    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(allocator);
    for (pem[encoded_start..end_at]) |byte| switch (byte) {
        ' ', '\t', '\r', '\n' => {},
        else => try compact.append(allocator, byte),
    };
    const size = std.base64.standard.Decoder.calcSizeForSlice(compact.items) catch return error.InvalidPrivateKey;
    const der = try allocator.alloc(u8, size);
    errdefer allocator.free(der);
    std.base64.standard.Decoder.decode(der, compact.items) catch return error.InvalidPrivateKey;
    return der;
}

pub fn signPkcs1Sha256(allocator: std.mem.Allocator, private_key_pem: []const u8, message: []const u8) ![]u8 {
    const der = try decodePem(allocator, private_key_pem);
    defer {
        std.crypto.secureZero(u8, der);
        allocator.free(der);
    }
    const parts = try parsePkcs1(der);
    const modulus = try Modulus.fromBytes(parts.modulus, .big);
    const encoded_len = parts.modulus.len;
    const digest_info_len = sha256_digest_info_prefix.len + std.crypto.hash.sha2.Sha256.digest_length;
    if (encoded_len < digest_info_len + 11) return error.UnsupportedPrivateKey;
    const encoded = try allocator.alloc(u8, encoded_len);
    defer {
        std.crypto.secureZero(u8, encoded);
        allocator.free(encoded);
    }
    encoded[0] = 0;
    encoded[1] = 1;
    const separator = encoded_len - digest_info_len - 1;
    @memset(encoded[2..separator], 0xff);
    encoded[separator] = 0;
    @memcpy(encoded[separator + 1 ..][0..sha256_digest_info_prefix.len], &sha256_digest_info_prefix);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &digest);
    std.crypto.hash.sha2.Sha256.hash(message, &digest, .{});
    @memcpy(encoded[encoded_len - digest.len ..], &digest);

    const field_element = try Modulus.Fe.fromBytes(modulus, encoded, .big);
    const signed = try modulus.powWithEncodedExponent(field_element, parts.private_exponent, .big);
    const signature = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(signature);
    try signed.toBytes(signature, .big);
    return signature;
}

pub fn formatDate(buffer: *[40]u8, epoch_seconds: i64) ![]const u8 {
    if (epoch_seconds < 0) return error.InvalidTimestamp;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(epoch_seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000000+00:00Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

pub const SignedHeaders = struct {
    allocator: std.mem.Allocator,
    signature: []u8,

    pub fn deinit(self: SignedHeaders) void {
        std.crypto.secureZero(u8, self.signature);
        self.allocator.free(self.signature);
    }
};

pub fn signedHeaders(
    allocator: std.mem.Allocator,
    method: []const u8,
    path_and_query: []const u8,
    body: []const u8,
    adp_token: []const u8,
    private_key_pem: []const u8,
    date: []const u8,
) !SignedHeaders {
    if (method.len == 0 or path_and_query.len == 0 or path_and_query[0] != '/' or adp_token.len == 0) return error.InvalidSigningInput;
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer {
        std.crypto.secureZero(u8, payload.written());
        payload.deinit();
    }
    try payload.writer.print("{s}\n{s}\n{s}\n{s}\n{s}", .{ method, path_and_query, date, body, adp_token });
    const raw_signature = try signPkcs1Sha256(allocator, private_key_pem, payload.written());
    defer {
        std.crypto.secureZero(u8, raw_signature);
        allocator.free(raw_signature);
    }
    const encoded_len = std.base64.standard.Encoder.calcSize(raw_signature.len);
    const signature = try allocator.alloc(u8, encoded_len + 1 + date.len);
    errdefer allocator.free(signature);
    _ = std.base64.standard.Encoder.encode(signature[0..encoded_len], raw_signature);
    signature[encoded_len] = ':';
    @memcpy(signature[encoded_len + 1 ..], date);
    return .{ .allocator = allocator, .signature = signature };
}

test "formats the upstream UTC signing timestamp" {
    var buffer: [40]u8 = undefined;
    try std.testing.expectEqualStrings("2026-09-02T17:00:00.000000+00:00Z", try formatDate(&buffer, 1_788_368_400));
}

test "RSA PKCS1 SHA256 signing matches an independent OpenSSL vector" {
    const private_key =
        \\-----BEGIN RSA PRIVATE KEY-----
        \\MIICXQIBAAKBgQDX6wS7Wj62zD6GsSfr1HHSkeA+KukXBJtngUqXRek2H+rL7bJN
        \\YQwQMFHhem+bscx0idg+HbvcttPv3SRswEwJsqusjBM85h3zv7fgxJAAxyG+DmWZ
        \\JiKBPZ5brmRdLs2Fe/5fjtVccyvjXXPtOs0dIdDD+25Kuf9ZjLxXg6t2XQIDAQAB
        \\AoGAY9YQjwyQWPehpaf+fIXzx1iaJkSzGGiR7s8SjVXPGq6xY2/Z9Pt9l3KwOaDi
        \\QEx67BvcuAQJnGmRH6TSNdLIlQ14Yal6kD6XW3acTmw4oFvuu9ir/ZDttmg88Eji
        \\taPKNI4s1HwIuzSDhDnPFNZxsqufK53nKQ2I/inMDDzyb4ECQQD7Sqj8sguRfZhA
        \\Tnf505qi4DYhUueddvNK/mlYcKVJmlhyYPd6MJu1JC2dmofrGtE6cNSNPwsCJO6B
        \\I+cySlX9AkEA2/avp9fbEzmr4XpqNxb07NYVJeMjPH35ghpUGPuYjIoT4naquDzH
        \\/0BHr540Gw1qbqVGRnsWSIQ5xRQB6TFf4QJAZpaFRJxfMqdGd8JRIpGriKDmGFaj
        \\Ldq42j3gvfVG1TSItTE29xBPEPVTFgtXP7jz/9q+O2eoU9jF8by5jwNf9QJBAMCo
        \\EvfmRtpS4+msZ4Vy1PjvFTzG8aDVEYlTeB8dlmJZucrbdvHBQsadTWxTG34qRPM+
        \\TQwEWOMQ9OxZdscBWOECQQDlX9/QZO0kKMmRITGDPJBS8BoV8dhIKvU+pWAL8m5T
        \\VXbSIanJBdQWBeGw0rrWka4XHDpxkQtFI/g2DbSX8Vqe
        \\-----END RSA PRIVATE KEY-----
    ;
    const message = "GET\n/1.0/library?page=1\n2026-09-02T17:00:00.000000+00:00Z\n\nsynthetic-adp";
    const signature = try signPkcs1Sha256(std.testing.allocator, private_key, message);
    defer {
        std.crypto.secureZero(u8, signature);
        std.testing.allocator.free(signature);
    }
    var encoded: [172]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, signature);
    try std.testing.expectEqualStrings(
        "rzStiJ8qVM1Q2Gf2gUjtzvEjPWPXq9uEQS7RZK756YLhmP5wGdSpQQvIJ4LW/5HY0QzvGel94tzlFC4uX1WPqPm6iyq+VDXAXMh68JxYjqdqmC9OQX/s1N/z1USf5G0RlMlFWITQdwzILNd4+7FZiunSUs8SAwjGN5JvuO+ToTo=",
        &encoded,
    );
}

test "rejects malformed private keys without retaining allocations" {
    try std.testing.expectError(error.InvalidPrivateKey, signPkcs1Sha256(std.testing.allocator, "not-a-key", "payload"));
}
