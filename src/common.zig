/// Represents an error when writing CSV data
pub const CsvWriteError = error{
    CharacterNotWrittern,
    InvalidValueType,
};

/// Represents an error when reading CSV data
pub const CsvReadError = error{
    InternalLimitReached,
    UnexpectedEndOfFile,
    InvalidLineEnding,
    QuotePrematurelyTerminated,
    UnexpectedQuote,
};

/// Represents errors when parsing booleans
const ParseBoolError = error{
    InvalidBoolInput,
};

/// Options for Partial Field Stream
pub const ParserLimitOpts = struct {
    max_iter: usize = 65_536,
};

const std = @import("std");

/// Unquotes a quoted CSV field
/// Assumes the field is a valid CSV field
pub fn unquoteQuoted(data: []const u8) []const u8 {
    if (data.len > 1 and data[0] == '"') {
        return data[1..(data.len - 1)];
    } else {
        return data;
    }
}

test "unquoteQuoted" {
    const test_cases = [_]struct {
        in: []const u8,
        out: []const u8,
    }{
        .{ .in = "", .out = "" },
        .{ .in = "\"hello\"", .out = "hello" },
        .{ .in = "hello", .out = "hello" },
        .{ .in = "\"hello\"\"world\"", .out = "hello\"\"world" },
    };

    for (test_cases) |tc| {
        try std.testing.expectEqualStrings(tc.out, unquoteQuoted(tc.in));
    }
}

/// Determines whether a CSV field is null
pub fn isNull(data: []const u8) bool {
    return data.len == 0 or std.mem.eql(u8, data, "-");
}

test "isNull" {
    const test_cases = [_]struct {
        in: []const u8,
        out: bool,
    }{
        .{ .in = "", .out = true },
        .{ .in = "-", .out = true },
        .{ .in = " ", .out = false },
        .{ .in = "hello", .out = false },
    };

    for (test_cases) |tc| {
        try std.testing.expectEqual(tc.out, isNull(tc.in));
    }
}

/// Tries to decode CSV field as int
/// Will use isNull to detect null values
pub fn asInt(
    data: []const u8,
    comptime T: type,
    base: u8,
) std.fmt.ParseIntError!?T {
    if (isNull(data)) {
        return null;
    }

    const ti = @typeInfo(T);
    // Zig 0.13.0 uses SnakeCase
    // Zig 0.14.0-dev uses lower_case
    if (@hasField(@TypeOf(ti), "Int")) {
        if (comptime ti.Int.signedness == .unsigned) {
            const v: T = try std.fmt.parseUnsigned(T, data, base);
            return v;
        } else {
            const v: T = try std.fmt.parseInt(T, data, base);
            return v;
        }
    } else {
        if (comptime ti.int.signedness == .unsigned) {
            const v: T = try std.fmt.parseUnsigned(T, data, base);
            return v;
        } else {
            const v: T = try std.fmt.parseInt(T, data, base);
            return v;
        }
    }
}

test "asInt" {
    const test_cases = [_]struct {
        in: []const u8,
        out: ?i64,
    }{
        .{ .in = "", .out = null },
        .{ .in = "-", .out = null },
        .{ .in = "1", .out = 1 },
        .{ .in = "-1", .out = -1 },
    };

    for (test_cases) |tc| {
        try std.testing.expectEqual(tc.out, try asInt(tc.in, i64, 10));
    }
}

/// Tries to decode CSV field as float
/// Will use isNull to detect null values
pub fn asFloat(data: []const u8, comptime T: type) std.fmt.ParseIntError!?T {
    if (isNull(data)) {
        return null;
    }
    const v = try std.fmt.parseFloat(T, data);
    return v;
}

test "asFloat" {
    const test_cases = [_]struct {
        in: []const u8,
        out: ?f64,
    }{
        .{ .in = "", .out = null },
        .{ .in = "-", .out = null },
        .{ .in = "1", .out = 1 },
        .{ .in = "-1", .out = -1 },
        .{ .in = "1.0", .out = 1 },
        .{ .in = "-1.0", .out = -1 },
        .{ .in = "1e5", .out = 100_000 },
        .{ .in = "-1e5", .out = -100_000 },
    };

    for (test_cases) |tc| {
        try std.testing.expectEqual(tc.out, try asFloat(tc.in, f64));
    }
}

/// Tries to decode CSV field as a boolean
/// Will use isNull to detect null values
/// Truthy values (case insensitive):
///     yes, y, true, t, 1
/// Falsey values (case insensitive):
///     no, n, false, f, 0
pub fn asBool(data: []const u8) ParseBoolError!?bool {
    if (isNull(data)) {
        return null;
    }
    if (std.mem.eql(u8, "1", data)) {
        return true;
    }
    if (std.mem.eql(u8, "0", data)) {
        return false;
    }

    var lower: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
    var end: usize = 0;
    for (0..lower.len) |i| {
        end = i;
        if (i >= data.len) {
            break;
        }
        lower[i] = data[i] | 0b0100000;
    }

    const l = lower[0..end];

    if (std.mem.eql(u8, "y", l)) {
        return true;
    }
    if (std.mem.eql(u8, "n", l)) {
        return false;
    }
    if (std.mem.eql(u8, "no", l)) {
        return false;
    }
    if (std.mem.eql(u8, "yes", l)) {
        return true;
    }
    if (std.mem.eql(u8, "true", l)) {
        return true;
    }
    if (std.mem.eql(u8, "false", l)) {
        return false;
    }

    return ParseBoolError.InvalidBoolInput;
}

test "asBool" {
    const test_cases = [_]struct {
        in: []const u8,
        out: ?bool,
    }{
        .{ .in = "", .out = null },
        .{ .in = "-", .out = null },
        .{ .in = "1", .out = true },
        .{ .in = "y", .out = true },
        .{ .in = "yes", .out = true },
        .{ .in = "true", .out = true },
        .{ .in = "0", .out = false },
        .{ .in = "n", .out = false },
        .{ .in = "no", .out = false },
        .{ .in = "false", .out = false },
    };

    for (test_cases) |tc| {
        try std.testing.expectEqual(tc.out, try asBool(tc.in));
    }
}

/// Decodes the array CSV data into a writer
/// This will remove surrounding quotes and unescape escaped quotes
pub fn decode(field: []const u8, writer: anytype) !void {
    if (field.len < 2 or field[0] != '"') {
        try writer.writeAll(field);
        return;
    }

    const data = unquoteQuoted(field);
    var nextChar: ?u8 = if (1 < data.len) data[1] else null;
    var curChar: ?u8 = if (0 < data.len) data[0] else null;
    var ni: usize = 1;

    while (curChar) |c| {
        defer {
            ni += 1;
            curChar = nextChar;
            nextChar = if (ni < data.len) data[ni] else null;
        }
        if (c != '"') {
            try writer.writeByte(c);
            continue;
        }

        if (nextChar == '"') {
            defer {
                ni += 1;
                curChar = nextChar;
                nextChar = if (ni < data.len) data[ni] else null;
            }
            try writer.writeByte(c);
        }
    }
}

test "decode" {
    const test_cases = [_]struct {
        in: []const u8,
        out: []const u8,
    }{
        .{ .in = "", .out = "" },
        .{ .in = "\"hello\"", .out = "hello" },
        .{ .in = "hello", .out = "hello" },
        .{ .in = "\"\"\"\"", .out = "\"" },
        .{ .in = "\"hello\"\"world\"", .out = "hello\"world" },
    };

    for (test_cases) |tc| {
        var b: [64]u8 = undefined;
        var buff = std.io.fixedBufferStream(&b);
        try decode(tc.in, buff.writer());
        try std.testing.expectEqualStrings(tc.out, buff.getWritten());
    }
}
