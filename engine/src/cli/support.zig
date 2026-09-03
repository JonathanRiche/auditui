const std = @import("std");

pub const OutputFormat = enum { tsv, csv, json };

pub fn optionValue(args: []const []const u8, long: []const u8, short: []const u8) ?[]const u8 {
    for (args, 0..) |arg, index| {
        if ((std.mem.eql(u8, arg, long) or std.mem.eql(u8, arg, short)) and index + 1 < args.len) return args[index + 1];
    }
    return null;
}

pub fn optionValues(allocator: std.mem.Allocator, args: []const []const u8, long: []const u8, short: []const u8) ![][]const u8 {
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(allocator);
    for (args, 0..) |arg, index| {
        if ((std.mem.eql(u8, arg, long) or std.mem.eql(u8, arg, short)) and index + 1 < args.len) try values.append(allocator, args[index + 1]);
    }
    return values.toOwnedSlice(allocator);
}

pub fn hasOption(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}

pub fn parseFormat(value: ?[]const u8) !OutputFormat {
    const name = value orelse "tsv";
    if (std.ascii.eqlIgnoreCase(name, "tsv")) return .tsv;
    if (std.ascii.eqlIgnoreCase(name, "csv")) return .csv;
    if (std.ascii.eqlIgnoreCase(name, "json")) return .json;
    return error.InvalidOutputFormat;
}

pub fn validAsin(value: []const u8) bool {
    if (value.len == 0 or value.len > 32) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte)) return false;
    return true;
}

pub fn validateEndpoint(value: []const u8) !void {
    if (value.len == 0 or value.len > 4096) return error.InvalidEndpoint;
    if (std.mem.indexOfAny(u8, value, "\r\n\x00") != null) return error.InvalidEndpoint;
    if (std.mem.startsWith(u8, value, "http://")) return error.InsecureTransport;
    if (std.mem.startsWith(u8, value, "https://")) return;
    if (std.mem.startsWith(u8, value, "/")) return;
    for (value) |byte| if (std.ascii.isWhitespace(byte)) return error.InvalidEndpoint;
}

pub fn csvField(writer: *std.Io.Writer, value: []const u8, separator: u8) !void {
    const quote = std.mem.indexOfAny(u8, value, &.{ separator, '"', '\r', '\n' }) != null;
    if (!quote) return writer.writeAll(value);
    try writer.writeByte('"');
    for (value) |byte| {
        if (byte == '"') try writer.writeByte('"');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}

pub fn replaceFormatExtension(allocator: std.mem.Allocator, path: []const u8, format: OutputFormat) ![]u8 {
    const needle = ".{format}";
    const suffix = switch (format) {
        .tsv => ".tsv",
        .csv => ".csv",
        .json => ".json",
    };
    if (!std.mem.endsWith(u8, path, needle)) return allocator.dupe(u8, path);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ path[0 .. path.len - needle.len], suffix });
}

test "CLI options retain repeated selectors" {
    const args = [_][]const u8{ "--asin", "A1", "-a", "A2", "--other" };
    const values = try optionValues(std.testing.allocator, &args, "--asin", "-a");
    defer std.testing.allocator.free(values);
    try std.testing.expectEqualSlices([]const u8, &.{ "A1", "A2" }, values);
}

test "CSV quoting and format extension are deterministic" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try csvField(&out.writer, "a, b \"quoted\"", ',');
    try std.testing.expectEqualStrings("\"a, b \"\"quoted\"\"\"", out.written());
    const path = try replaceFormatExtension(std.testing.allocator, "library.{format}", .json);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("library.json", path);
}

test "generic endpoints reject plaintext and control characters" {
    try validateEndpoint("library?num_results=10");
    try validateEndpoint("https://api.audible.ca/1.0/library");
    try std.testing.expectError(error.InsecureTransport, validateEndpoint("http://api.audible.ca"));
    try std.testing.expectError(error.InvalidEndpoint, validateEndpoint("library\nheader: bad"));
}
