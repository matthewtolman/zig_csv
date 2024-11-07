const CsvReadError = @import("../common.zig").CsvReadError;
const ParseBoolError = @import("../common.zig").ParseBoolError;
const common = @import("../common.zig");
const std = @import("std");
const assert = std.debug.assert;

pub const Field = struct {
    data: []const u8,
    row_end: bool,

    /// Decodes the array CSV data into a writer
    /// This will remove surrounding quotes and unescape escaped quotes
    pub fn decode(self: Field, writer: anytype) !void {
        try common.decode(self.data, writer);
    }

    /// Returns whether a field is "null"
    /// "null" includes empty strings and the string "-"
    pub fn isNull(self: Field) bool {
        return common.isNull(common.unquoteQuoted(self.data));
    }

    /// Tries to decode the field as an integer
    /// Will remove surrounding quotes before attempting
    pub fn asInt(
        self: Field,
        comptime T: type,
        base: u8,
    ) std.fmt.ParseIntError!?T {
        // unquote quoted text
        return common.asInt(common.unquoteQuoted(self.data), T, base);
    }

    /// Tries to decode the field as a float
    /// Will remove surrounding quotes before attempting
    pub fn asFloat(
        self: Field,
        comptime T: type,
    ) std.fmt.ParseFloatError!?T {
        return common.asFloat(common.unquoteQuoted(self.data), T);
    }

    /// Tries to decode the field as a boolean
    /// Truthy values (case insensitive):
    ///     yes, y, true, t, 1
    /// Falsey values (case insensitive):
    ///     no, n, false, f, 0
    pub fn asBool(self: Field) ParseBoolError!?bool {
        return common.asBool(common.unquoteQuoted(self.data));
    }
};

// DO NOT CHANGE
const chunk_size = 64;
const quotes: @Vector(chunk_size, u8) = @splat(@as(u8, '"'));

const ParserState = struct {
    prev_quote: u64 = 0,
    prev_cr: u64 = 0,
    prev_quote_ends: u64 = 0,
    prev_field_seps: u64 = 1 << (chunk_size - 1),
    field_separators: u64 = 0,
    start_chunk: u64 = 0,
    start_chunk_pos: u32 = 0,
    end_chunk: u64 = 0,
    next_chunk: u64 = 0,
    field_start: bool = true,
    skip: bool = false,
};

/// Fast fields parser
/// Parses individual fields and marks fields at the end of a row
pub const Parser = struct {
    _text: []const u8,
    err: ?CsvReadError = null,
    _opts: common.ParserLimitOpts,
    _state: ParserState = .{},

    /// Initializes a parser
    pub fn init(text: []const u8, opts: common.ParserLimitOpts) Parser {
        return Parser{
            ._text = text,
            ._opts = opts,
            .err = null,
        };
    }

    /// Gets the current start position
    pub fn startPos(self: *const Parser) u64 {
        const base = self._state.start_chunk * 64 + self._state.start_chunk_pos;
        if (self._state.skip) {
            return base + 1;
        }
        return base;
    }

    /// Returns if a parser is done
    pub fn done(self: *const Parser) bool {
        return self.startPos() >= self._text.len or self.err != null;
    }

    /// Returns whether has next chunk
    fn hasNextChunk(self: *const Parser) bool {
        return self._state.next_chunk * 64 < self._text.len;
    }

    /// reates match bit string
    fn match(ch: u8, slice: []const u8) u64 {
        var res: u64 = 0;
        for (slice, 0..) |c, i| {
            res |= @as(u64, @intFromBool(c == ch)) << @truncate(i);
        }
        return res;
    }

    /// Gets the next CSV field
    /// Errors are stored in the `err` property
    pub fn next(self: *Parser) ?Field {
        if (self.done()) {
            if (self._state.field_start) {
                self._state.field_start = false;
                return Field{ .data = self._text[self._text.len..], .row_end = true };
            }
            return null;
        }
        self._state.field_start = false;
        assert(self.startPos() < self._text.len);
        assert(self.err == null);

        // This means we need to find our next field ending
        const MAX_CHUNK_LEN = self._opts.max_iter;
        var index: usize = 0;
        while (self._state.field_separators == 0 and self.hasNextChunk() and index < MAX_CHUNK_LEN) {
            defer {
                index += 1;
                self._state.end_chunk = self._state.next_chunk;
                self._state.next_chunk += 1;
            }

            const next_chunk_start = self._state.next_chunk * 64;
            assert(next_chunk_start < self._text.len);

            const sub_text = self._text[next_chunk_start..];
            const extract = @min(chunk_size, sub_text.len);
            assert(extract <= sub_text.len);

            const chunk = sub_text[0..extract];

            const match_quotes: u64 = match('"', chunk);

            const match_commas = match(',', chunk);

            const match_crs = match('\r', chunk);
            defer self._state.prev_cr = match_crs;

            var match_lfs = match('\n', chunk);

            const len: u8 = extract;

            if (len < chunk_size) {
                match_lfs |= @as(u64, 1) << @truncate(len);
            }

            const carry: u64 = @bitCast(-%@as(
                i64,
                @bitCast(self._state.prev_quote >> (chunk_size - 1)),
            ));
            const quoted = Parser.quotedRegions(match_quotes) ^ carry;
            defer self._state.prev_quote = quoted;

            const unquoted = ~quoted;

            const field_commas = match_commas & unquoted;
            const field_crs = match_crs & unquoted;
            const field_lfs = match_lfs & unquoted;

            const expected_lfs = (match_crs << 1) | (self._state.prev_cr >> (chunk_size - 1));
            const masked_lfs = expected_lfs & field_lfs;

            if (@popCount(expected_lfs) != @popCount(masked_lfs)) {
                self.err = CsvReadError.InvalidLineEnding;
                return null;
            }

            const field_seps = field_commas | field_crs | field_lfs;

            self._state.field_separators = field_seps;
            defer {
                // if we ended on a CR previously, make sure to clear it from the
                // field separators, otherwise we end up getting a bad start position
                // We don't remove it from field_seps since we need it for line
                // ending validation
                if (self._state.prev_cr & (1 << (chunk_size - 1)) != 0) {
                    self._state.field_separators &= ~@as(u64, 1);
                }
                self._state.prev_field_seps = field_seps;
            }

            const quote_strings = match_quotes | quoted;

            // Sometimes this gets the starting/ending bits wrong when an
            // escaped quote happens on a boundary
            const quote_starts = quote_strings & ~(quote_strings << 1);
            const quote_ends = quote_strings & ~(quote_strings >> 1);
            const expected_starts = quote_starts & ~(self._state.prev_quote_ends >> (chunk_size - 1));
            defer self._state.prev_quote_ends = quote_ends;

            const at_end = self.startPos() + chunk_size >= self._text.len;

            if (at_end) {
                const last_bit_quoted = (quoted >> @truncate(chunk_size - 1)) & 1;
                const last_quote_end = (quote_ends >> @truncate(chunk_size - 1)) & 1;
                if (last_bit_quoted == 1 and last_quote_end != 0) {
                    self.err = CsvReadError.UnexpectedEndOfFile;
                    return null;
                }

                if (self._text[self._text.len - 1] == '\r') {
                    self.err = CsvReadError.InvalidLineEnding;
                    return null;
                }
            }

            const expected_end_seps = ((quote_ends << 1) | (self._state.prev_quote_ends >> (chunk_size - 1))) & (~quote_starts);
            const field_seps_start = (self._state.field_separators << 1) | (self._state.prev_field_seps >> (chunk_size - 1));

            const masked_end_seps = self._state.field_separators & expected_end_seps;
            const masked_sep_start = field_seps_start & expected_starts;

            if (!at_end and @popCount(expected_end_seps) != @popCount(masked_end_seps)) {
                self.err = CsvReadError.QuotePrematurelyTerminated;
                return null;
            }

            if (@popCount(masked_sep_start) != @popCount(expected_starts)) {
                self.err = CsvReadError.UnexpectedQuote;
                return null;
            }
        }

        if (index >= MAX_CHUNK_LEN) {
            self.err = CsvReadError.InternalLimitReached;
            return null;
        }

        const chunk_end = @ctz(self._state.field_separators);
        const t_end = (self._state.end_chunk * 64) + chunk_end;
        const end_pos = @min(self._text.len - 1, t_end);
        assert(self._state.end_chunk >= self._state.start_chunk);

        const field_end = @min(self._text.len, t_end);
        assert(self.startPos() < self._text.len);
        assert(field_end <= self._text.len);

        const field = self._text[self.startPos()..field_end];
        const row_end = if (t_end >= self._text.len) true else self._text[end_pos] == '\r' or self._text[end_pos] == '\n';

        self._state.skip = false;
        self._state.start_chunk = self._state.end_chunk;
        self._state.start_chunk_pos = chunk_end + 1;
        self._state.field_separators ^= @as(u64, 1) << @truncate(chunk_end);

        if (end_pos < self._text.len and self._text[end_pos] == '\r') {
            if (chunk_end + 1 < chunk_size - 1) {
                self._state.field_separators ^= @as(u64, 1) << @truncate(chunk_end + 1);
                self._state.start_chunk_pos = chunk_end + 2;
            } else {
                // Handle the edge case we end a chunk on a CR
                // In this case, we need to go through the loop again to
                // hit the LF
                // Additionally, we need to not output an empty field on the LF
                self._state.field_separators = 0;
                self._state.skip = true;
            }
        }

        if (self.done() and self._text[self._text.len - 1] == ',') {
            self._state.field_start = true;
            return Field{
                .data = field,
                .row_end = false,
            };
        }

        return Field{
            .data = field,
            .row_end = row_end,
        };
    }

    /// Calculates quoted region mask
    fn quotedRegions(m: u64) u64 {
        var x: u64 = m;
        var res: u64 = x;
        while (x != 0) {
            const x1: u64 = @bitCast(-%@as(i64, @bitCast(x)));
            res = res ^ (x1 ^ x);
            x = x & x - 1;
        }
        return res;
    }
};

/// Initializes parser
pub fn init(text: []const u8, opts: common.ParserLimitOpts) Parser {
    return Parser.init(text, opts);
}

test "simd array" {
    const testing = @import("std").testing;
    const csv =
        \\c1,c2,c3,c4,c5
        \\r1,"ff1,ff2",,ff3,ff4
        \\r2," "," "," "," "
        \\r3,1  ,2  ,3  ,4  
        \\r4,   ,   ,   ,   
        \\r5,abc,def,geh,""""
        \\r6,""""," "" ",hello,"b b b"
    ;
    var parser = init(csv, .{});

    const expected_fields: usize = 35;
    const expected_lines: usize = 7;
    var fields: usize = 0;
    var lines: usize = 0;

    const expected_decoded = [35][]const u8{
        "c1", "c2",      "c3",   "c4",    "c5",
        "r1", "ff1,ff2", "",     "ff3",   "ff4",
        "r2", " ",       " ",    " ",     " ",
        "r3", "1  ",     "2  ",  "3  ",   "4  ",
        "r4", "   ",     "   ",  "   ",   "   ",
        "r5", "abc",     "def",  "geh",   "\"",
        "r6", "\"",      " \" ", "hello", "b b b",
    };

    var decode_buff: [64]u8 = undefined;
    var fb_stream = std.io.fixedBufferStream(&decode_buff);

    while (parser.next()) |f| {
        fb_stream.reset();
        defer {
            fields += 1;
            if (f.row_end) lines += 1;
        }
        try f.decode(fb_stream.writer());
        try testing.expectEqualStrings(expected_decoded[fields], fb_stream.getWritten());
    }

    if (parser.err) |err| {
        try testing.expectFmt("", "Unexpected error {any}\n", .{err});
    }

    try testing.expectEqual(expected_lines, lines);
    try testing.expectEqual(expected_fields, fields);
}

test "array field streamer" {
    // get our writer
    var buff = std.ArrayList(u8).init(std.testing.allocator);
    defer buff.deinit();

    const input =
        \\userid,name,"age",active,
        \\1,"John Doe",23,no,
        \\12,"Robert ""Bobby"" Junior",98,yes,
        \\21,"Bob",24,yes,
        \\31,"New
        \\York",43,no,
        \\4,,,no,
    ;
    var parser = init(input, .{});

    const expected = [_][]const u8{
        "userid", "name",                    "age", "active", "",
        "1",      "John Doe",                "23",  "no",     "",
        "12",     "Robert \"Bobby\" Junior", "98",  "yes",    "",
        "21",     "Bob",                     "24",  "yes",    "",
        "31",     "New\nYork",               "43",  "no",     "",
        "4",      "",                        "",    "no",     "",
    };

    var ei: usize = 0;

    while (parser.next()) |f| {
        defer {
            buff.clearRetainingCapacity();
            ei += 1;
        }
        try f.decode(buff.writer());
        const atEnd = ei % 5 == 4;
        const field = buff.items;
        try std.testing.expectEqualStrings(expected[ei], field);
        try std.testing.expectEqual(atEnd, f.row_end);
    }

    if (parser.err) |err| {
        try std.testing.expectFmt("", "Unexpected error {any}\n", .{err});
    }

    try std.testing.expectEqual(expected.len, ei);
}

test "slice streamer" {
    // get our writer
    var buff = std.ArrayList(u8).init(std.testing.allocator);
    defer buff.deinit();

    const input =
        \\userid,name,"age",active,
        \\1,"John Doe",23,no,
        \\12,"Robert ""Bobby"" Junior",98,yes,
        \\21,"Bob",24,yes,
        \\31,"New
        \\York",43,no,
        \\33,"hello""world""",400,yes,
        \\34,"""world""",2,yes,
        \\35,"""""""""",1,no,
    ;

    var parser = init(input, .{});
    const expected = [_][]const u8{
        "userid", "name",                    "age", "active", "",
        "1",      "John Doe",                "23",  "no",     "",
        "12",     "Robert \"Bobby\" Junior", "98",  "yes",    "",
        "21",     "Bob",                     "24",  "yes",    "",
        "31",     "New\nYork",               "43",  "no",     "",
        "33",     "hello\"world\"",          "400", "yes",    "",
        "34",     "\"world\"",               "2",   "yes",    "",
        "35",     "\"\"\"\"",                "1",   "no",     "",
    };

    var ei: usize = 0;

    while (parser.next()) |f| {
        defer {
            buff.clearRetainingCapacity();
            ei += 1;
        }
        try f.decode(buff.writer());
        const atEnd = ei % 5 == 4;
        const field = buff.items;
        try std.testing.expectEqualStrings(expected[ei], field);
        try std.testing.expectEqual(atEnd, f.row_end);
    }

    try std.testing.expectEqual(expected.len, ei);
}

test "slice iterator" {
    const testing = @import("std").testing;

    const tests = [_]struct {
        input: []const u8,
        count: usize,
        err: ?CsvReadError = null,
    }{
        .{
            .input = "c1,c2,c3\r\nv1,v2,v3\na,b,c",
            .count = 9,
        },
        .{
            .input = "c1,c2,c3\r\nv1,v2,v3\na,b,c\r\n",
            .count = 9,
        },
        .{
            .input = "c1,c2,c3\r\nv1,v2,v3\na,b,c\n",
            .count = 9,
        },
        .{
            .input = "\",,\",",
            .count = 2,
        },
        .{
            .input =
            \\abc,"def",
            \\"def""geh",
            ,
            .count = 5,
        },
        .{
            .input =
            \\abc,"def",
            \\abc"def""geh",
            ,
            .count = 0,
            .err = CsvReadError.UnexpectedQuote,
        },
        .{
            .input =
            \\abc,"def",
            \\"def"geh",
            ,
            .count = 0,
            .err = CsvReadError.UnexpectedEndOfFile,
        },
        .{
            .input =
            \\abc,"def",
            \\"def""geh,
            ,
            .count = 0,
            .err = CsvReadError.UnexpectedEndOfFile,
        },
        .{
            .input = "abc,serkj\r",
            .count = 0,
            .err = CsvReadError.InvalidLineEnding,
        },
        .{
            .input = "abc,serkj\r1232,232",
            .count = 0,
            .err = CsvReadError.InvalidLineEnding,
        },
    };

    for (tests) |testCase| {
        var iterator = Parser.init(testCase.input, .{});
        var cnt: usize = 0;
        while (iterator.next()) |_| {
            cnt += 1;
        }

        try testing.expectEqual(testCase.err, iterator.err);
        try testing.expectEqual(testCase.count, cnt);
    }
}

test "row and field iterator" {
    const testing = @import("std").testing;

    const input =
        \\userid,name,age
        \\1,"Jonny",23
        \\2,Jack,32
    ;

    const fieldCount = 9;

    var parser = Parser.init(input, .{});
    var cnt: usize = 0;
    while (parser.next()) |_| {
        cnt += 1;
    }

    try testing.expectEqual(fieldCount, cnt);
}

test "crlf, at 63" {
    const testing = @import("std").testing;

    const input =
        ",012345,,8901234,678901,34567890123456,890123456789012345678,,,\r\n" ++
        ",,012345678901234567890123456789012345678901234567890123456789\r\n" ++
        ",012345678901234567890123456789012345678901234567890123456789\r\n,";

    const fieldCount = 17;

    var parser = Parser.init(input, .{});
    var b: [100]u8 = undefined;
    var buff = std.io.fixedBufferStream(&b);
    var cnt: usize = 0;
    while (parser.next()) |_| {
        buff.reset();
        cnt += 1;
        try testing.expectEqual(null, std.mem.indexOf(u8, buff.getWritten(), "\n"));
    }

    try testing.expectEqual(fieldCount, cnt);
}

test "crlf\", at 63" {
    const testing = @import("std").testing;

    const input =
        ",012345,,8901234,678901,34567890123456,890123456789012345678,,,\r\n" ++
        "\"\",,012345678901234567890123456789012345678901234567890123456789\r\n" ++
        ",012345678901234567890123456789012345678901234567890123456789\r\n,";

    const fieldCount = 17;

    var parser = Parser.init(input, .{});
    var cnt: usize = 0;
    while (parser.next()) |_| {
        cnt += 1;
    }

    try testing.expectEqual(fieldCount, cnt);
}

test "crlfa, at 63" {
    const testing = @import("std").testing;

    const input =
        ",012345,,8901234,678901,34567890123456,890123456789012345678,,,\r\n" ++
        "a,,012345678901234567890123456789012345678901234567890123456789\r\n" ++
        ",012345678901234567890123456789012345678901234567890123456789\r\n,";

    const fieldCount = 17;

    var parser = Parser.init(input, .{});
    var cnt: usize = 0;
    while (parser.next()) |_| {
        cnt += 1;
    }

    try testing.expectEqual(fieldCount, cnt);
}
