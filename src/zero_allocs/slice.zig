const common = @import("../common.zig");
const CsvReadError = common.CsvReadError;
const ParseBoolError = common.ParseBoolError;
const CsvOpts = common.CsvOpts;
const std = @import("std");
const assert = std.debug.assert;

/// Represents a field in the CSV file
pub const Field = struct {
    _data: []const u8,
    _opts: common.CsvOpts,

    /// Decodes the array CSV data into a writer
    /// This will remove surrounding quotes and unescape escaped quotes
    pub fn decode(self: *const Field, writer: anytype) !void {
        try common.decode(self._data, writer, self._opts);
    }

    /// Returns the encoded data for the field
    /// Note: Unique to allocating fields
    pub fn raw(self: *const Field) []const u8 {
        return self._data;
    }

    pub fn opts(self: *const Field) common.CsvOpts {
        return self._opts;
    }

    /// Clones memory using a specific allocator
    /// Useful when wanting to keep a field's memory past the lifetime of the
    /// row or field
    pub fn clone(
        self: *const Field,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!std.ArrayList(u8) {
        var copy = std.ArrayList(u8).init(allocator);
        errdefer copy.deinit();
        try common.decode(self._data, copy.writer(), self._opts);
        return copy;
    }
};

/// Represents a field inside a row
pub const RowField = struct {
    field: Field,
    row_end: bool,
};

/// Iterates over fields in a CSV row
pub const RowIter = struct {
    _field_parser: FieldParser,

    pub fn next(self: *RowIter) ?Field {
        if (self._field_parser.next()) |f| {
            return f.field;
        }
        return null;
    }
};

/// A CSV row
pub const Row = struct {
    const OutOfBoundsError = error{IndexOutOfBounds};
    _data: []const u8,
    _opts: CsvOpts,
    _len: usize,

    /// Get a row iterator
    pub fn iter(self: Row) RowIter {
        return RowIter{
            ._field_parser = fieldsInit(self._data, self._opts),
        };
    }

    /// Returns the number of fields/columns in a row
    pub fn len(self: *const Row) usize {
        return self._len;
    }

    /// Gets the field/column at an index
    /// If the index is out of bounds will return an error
    /// O(n)
    pub fn field(self: *const Row, index: usize) OutOfBoundsError!Field {
        if (index >= self.len()) {
            return OutOfBoundsError.IndexOutOfBounds;
        }
        var it = self.iter();
        var i: usize = 0;
        while (it.next()) |f| {
            if (i == index) {
                return f;
            }
            i += 1;
        }
        return OutOfBoundsError.IndexOutOfBounds;
    }

    /// Gets the field/column at an index
    /// If the index is out of bounds will return null
    /// O(n)
    pub fn fieldOrNull(self: *const Row, index: usize) ?Field {
        if (index >= self.len()) {
            return null;
        }
        return self.field(index) catch null;
    }
};

/// Initializes a new parser
pub fn init(text: []const u8, opts: common.CsvOpts) Parser {
    return Parser.init(text, opts);
}

/// A CSV row parser
/// Will parse a row twice, once for identifying the row end
/// and once for iterating over fields in a row
pub const Parser = struct {
    pub const Rows = Row;
    _text: []const u8,
    _field_parser: FieldParser,
    _opts: CsvOpts,
    err: ?CsvReadError = null,

    /// Gets the next row in a row
    pub fn next(self: *Parser) ?Row {
        if (self._field_parser.done()) {
            return null;
        }

        const start = self._field_parser.startPos();
        var end = start;

        const MAX_ITER = self._opts.max_iter;
        var index: usize = 0;
        while (self._field_parser.next()) |f| {
            if (index >= MAX_ITER) {
                self.err = CsvReadError.InternalLimitReached;
                return null;
            }
            defer index += 1;

            self.err = self._field_parser.err;
            if (self.err) |_| {
                return null;
            }

            end += f.field._data.len + 1;
            end = @min(end, self._text.len);

            if (f.row_end) {
                break;
            }
        }
        self.err = self._field_parser.err;

        assert(start < self._text.len);
        assert(end <= self._text.len);
        assert(end >= start);

        var data = self._text[start..end];
        if (data.len > 0 and data[data.len - 1] == self._opts.column_line_end_prefix) {
            data = data[0..(data.len - 1)];
        }

        if (self._field_parser.done()) {
            if (data.len == 0) {
                return null;
            }
            if (self._opts.column_line_end_prefix) |cr| {
                if (data.len == 2 and data[0] == cr and data[1] == self._opts.column_line_end) {
                    return null;
                }
            }
            if (data.len == 1 and data[0] == self._opts.column_line_end) {
                return null;
            }
        }

        return Row{
            ._data = data,
            ._opts = self._opts,
            ._len = index,
        };
    }

    /// Initializes a parser
    pub fn init(text: []const u8, opts: CsvOpts) Parser {
        std.debug.assert(opts.valid());
        return Parser{
            ._text = text,
            ._opts = opts,
            ._field_parser = fieldsInit(text, opts),
        };
    }
};

// DO NOT CHANGE
const chunk_size = 64;

const FieldParserState = struct {
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
pub const FieldParser = struct {
    _text: []const u8,
    err: ?CsvReadError = null,
    _opts: common.CsvOpts,
    _state: FieldParserState = .{},

    /// Initializes a parser
    pub fn init(text: []const u8, opts: common.CsvOpts) FieldParser {
        std.debug.assert(opts.valid());
        return FieldParser{
            ._text = text,
            ._opts = opts,
            .err = null,
        };
    }

    /// Gets the current start position
    pub fn startPos(self: *const FieldParser) u64 {
        const base = self._state.start_chunk * chunk_size + self._state.start_chunk_pos;
        if (self._state.skip) {
            return base + 1;
        }
        return base;
    }

    /// Returns if a parser is done
    pub fn done(self: *const FieldParser) bool {
        return self.startPos() >= self._text.len or self.err != null;
    }

    /// Returns whether has next chunk
    fn hasNextChunk(self: *const FieldParser) bool {
        return self._state.next_chunk * chunk_size < self._text.len;
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
    pub fn next(self: *FieldParser) ?RowField {
        if (self.done()) {
            if (self._state.field_start) {
                self._state.field_start = false;
                return RowField{
                    .field = Field{
                        ._data = self._text[self._text.len..],
                        ._opts = self._opts,
                    },
                    .row_end = true,
                };
            }
            return null;
        }
        self._state.field_start = false;
        assert(self.startPos() < self._text.len);
        assert(self.err == null);

        const quote = self._opts.column_quote;
        const cr = self._opts.column_line_end_prefix;
        const lf = self._opts.column_line_end;
        const comma = self._opts.column_delim;

        // This means we need to find our next field ending
        const MAX_CHUNK_LEN = self._opts.max_iter;
        var index: usize = 0;
        while (self._state.field_separators == 0 and self.hasNextChunk() and index < MAX_CHUNK_LEN) {
            defer {
                index += 1;
                self._state.end_chunk = self._state.next_chunk;
                self._state.next_chunk += 1;
            }

            const next_chunk_start = self._state.next_chunk * chunk_size;
            assert(next_chunk_start < self._text.len);

            const sub_text = self._text[next_chunk_start..];
            const extract = @min(chunk_size, sub_text.len);
            assert(extract <= sub_text.len);

            const chunk = sub_text[0..extract];

            const match_quotes: u64 = match(quote, chunk);

            const match_commas = match(comma, chunk);

            const match_crs = if (cr) |r| match(r, chunk) else @as(u64, 0);
            defer self._state.prev_cr = match_crs;

            var match_lfs = match(lf, chunk);

            const len: u8 = extract;

            if (len < chunk_size) {
                match_lfs |= @as(u64, 1) << @truncate(len);
            }

            const carry: u64 = @bitCast(-%@as(
                i64,
                @bitCast(self._state.prev_quote >> (chunk_size - 1)),
            ));
            const quoted = FieldParser.quotedRegions(match_quotes) ^ carry;
            defer self._state.prev_quote = quoted;

            const unquoted = ~quoted;

            const field_commas = match_commas & unquoted;
            const field_crs = match_crs & unquoted;
            const field_lfs = match_lfs & unquoted;

            const expected_lfs = (match_crs << 1) | (self._state.prev_cr >> (chunk_size - 1));
            const masked_lfs = expected_lfs & field_lfs;

            if (expected_lfs != masked_lfs) {
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
            // This code helps detect and correct those errors
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

                if (self._text[self._text.len - 1] == cr) {
                    self.err = CsvReadError.InvalidLineEnding;
                    return null;
                }
            }

            const expected_end_seps = ((quote_ends << 1) | (self._state.prev_quote_ends >> (chunk_size - 1))) & (~quote_starts);
            const field_seps_start = (self._state.field_separators << 1) | (self._state.prev_field_seps >> (chunk_size - 1));

            const masked_end_seps = self._state.field_separators & expected_end_seps;
            const masked_sep_start = field_seps_start & expected_starts;

            if (!at_end and expected_end_seps != masked_end_seps) {
                self.err = CsvReadError.QuotePrematurelyTerminated;
                return null;
            }

            if (masked_sep_start != expected_starts) {
                self.err = CsvReadError.UnexpectedQuote;
                return null;
            }
        }

        if (index >= MAX_CHUNK_LEN) {
            self.err = CsvReadError.InternalLimitReached;
            return null;
        }

        const chunk_end = @ctz(self._state.field_separators);
        const t_end = (self._state.end_chunk * chunk_size) + chunk_end;
        const end_pos = @min(self._text.len - 1, t_end);
        assert(self._state.end_chunk >= self._state.start_chunk);

        const field_end = @min(self._text.len, t_end);
        assert(self.startPos() < self._text.len);
        assert(field_end <= self._text.len);

        const field = self._text[self.startPos()..field_end];
        const row_end = if (t_end >= self._text.len) true else self._text[end_pos] == cr or self._text[end_pos] == lf;

        self._state.skip = false;
        self._state.start_chunk = self._state.end_chunk;
        self._state.start_chunk_pos = chunk_end + 1;
        self._state.field_separators ^= @as(u64, 1) << @truncate(chunk_end);

        if (end_pos < self._text.len and self._text[end_pos] == cr) {
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

        if (self.done() and self._text[self._text.len - 1] == comma) {
            self._state.field_start = true;
            return RowField{
                .field = Field{
                    ._data = field,
                    ._opts = self._opts,
                },
                .row_end = false,
            };
        }

        return RowField{
            .field = Field{
                ._data = field,
                ._opts = self._opts,
            },
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

/// Initializes fields parser
/// Only use when you want more complexity in exchange for better performance
pub fn fieldsInit(text: []const u8, opts: common.CsvOpts) FieldParser {
    return FieldParser.init(text, opts);
}

test "simd array custom chars" {
    const testing = @import("std").testing;
    const csv = "c1;c2;c3;c4;c5\\\tr1;'ff1;ff2';;ff3;ff4\tr2;' ';' ';' ';' '\tr3;1  ;2  ;3  ;4  \tr4;   ;   ;   ;   \tr5;abc;def;geh;''''\tr6;'''';' '' ';hello;'b b b'\t";
    var parser = fieldsInit(csv, .{
        .column_delim = ';',
        .column_line_end_prefix = '\\',
        .column_line_end = '\t',
        .column_quote = '\'',
    });

    const expected_fields: usize = 35;
    const expected_lines: usize = 7;
    var fields: usize = 0;
    var lines: usize = 0;

    const expected_decoded = [35][]const u8{
        "c1", "c2",      "c3",  "c4",    "c5",
        "r1", "ff1;ff2", "",    "ff3",   "ff4",
        "r2", " ",       " ",   " ",     " ",
        "r3", "1  ",     "2  ", "3  ",   "4  ",
        "r4", "   ",     "   ", "   ",   "   ",
        "r5", "abc",     "def", "geh",   "'",
        "r6", "'",       " ' ", "hello", "b b b",
    };

    var decode_buff: [64]u8 = undefined;
    var fb_stream = std.io.fixedBufferStream(&decode_buff);

    while (parser.next()) |f| {
        fb_stream.reset();
        defer {
            fields += 1;
            if (f.row_end) lines += 1;
        }
        try f.field.decode(fb_stream.writer());
        try testing.expectEqualStrings(expected_decoded[fields], fb_stream.getWritten());
    }

    if (parser.err) |err| {
        try testing.expectFmt("", "Unexpected error {any}\n", .{err});
    }

    try testing.expectEqual(expected_lines, lines);
    try testing.expectEqual(expected_fields, fields);
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
    var parser = fieldsInit(csv, .{});

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
        try f.field.decode(fb_stream.writer());
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
    var parser = fieldsInit(input, .{});

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
        try f.field.decode(buff.writer());
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

    var parser = fieldsInit(input, .{});
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
        try f.field.decode(buff.writer());
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
        var iterator = FieldParser.init(testCase.input, .{});
        var cnt: usize = 0;
        while (iterator.next()) |_| {
            cnt += 1;
        }

        try testing.expectEqual(testCase.err, iterator.err);
        try testing.expectEqual(testCase.count, cnt);
    }
}

test "row and field iterator 2" {
    const testing = @import("std").testing;

    const input =
        \\userid,name,age
        \\1,"Jonny",23
        \\2,Jack,32
    ;

    const fieldCount = 9;

    var parser = FieldParser.init(input, .{});
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

    var parser = FieldParser.init(input, .{});
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

    var parser = FieldParser.init(input, .{});
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

    var parser = FieldParser.init(input, .{});
    var cnt: usize = 0;
    while (parser.next()) |_| {
        cnt += 1;
    }

    try testing.expectEqual(fieldCount, cnt);
}

test "row iterator" {
    const testing = @import("std").testing;

    const tests = [_]struct {
        input: []const u8,
        count: usize,
        err: ?CsvReadError = null,
    }{
        .{
            .input = "c1,c2,c3\r\nv1,v2,v3\na,b,c",
            .count = 3,
        },
        .{
            .input = "c1,c2,c3\r\nv1,v2,v3\na,b,c\r\n",
            .count = 3,
        },
        .{
            .input = "c1,c2,c3\r\nv1,v2,v3\na,b,c\n",
            .count = 3,
        },
        .{
            .input = "\",,\",",
            .count = 1,
        },
        .{
            .input =
            \\abc,"def",
            \\"def""geh",
            ,
            .count = 2,
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
    while (parser.next()) |row| {
        var iter = row.iter();
        while (iter.next()) |_| {
            cnt += 1;
        }
    }

    try testing.expectEqual(fieldCount, cnt);
}

test "row end empty row" {
    const repeat = 9441;
    const testing = @import("std").testing;
    const input = "2321234423412345678902322\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n9\r\n1\r\n2\r\n3124,\r\n" ** repeat;
    const rows = 11 * repeat;

    var parser = Parser.init(input, .{});
    var cnt : usize = 0;
    while (parser.next()) |_| {
        cnt += 1;
    }

    try testing.expectEqual(rows, cnt);
}

// For my own testing. I don't have the ability to distribute trips.csv at this time
// I uncomment this for testing locally against a 13MB test file

// test "csv" {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();
//     var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
//     const path = try std.fs.realpathZ("trips.csv", &path_buffer);
//
//     const file = try std.fs.openFileAbsolute(path, .{});
//     defer file.close();
//
//     const mb = (1 << 10) << 10;
//     const csv = try file.readToEndAlloc(allocator, 500 * mb);
//     var parser = Parser.init(csv, .{});
//     var count: usize = 0;
//     var lines: usize = 0;
//     while (parser.next()) |row| {
//         var iter = row.iter();
//         lines += 1;
//         while (iter.next()) |_| {
//             count += 1;
//         }
//     }
//
//     try std.testing.expectEqual(114393, lines);
//     try std.testing.expectEqual(915144, count);
// }

