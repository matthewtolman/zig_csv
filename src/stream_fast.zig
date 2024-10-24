const CsvReadError = @import("common.zig").CsvReadError;
const ParseBoolError = @import("common.zig").ParseBoolError;
const common = @import("common.zig");
const std = @import("std");

// DO NOT CHANGE
const chunk_size = 64;
const quotes: @Vector(chunk_size, u8) = @splat(@as(u8, '"'));

const ParserState = struct {
    prev_quote: u64 = 0,
    prev_cr: u64 = 0,
    prev_quote_ends: u64 = 0,
    prev_field_seps: u64 = 1 << (chunk_size - 1),
    field_separators: u64 = 0,
    next_bytes: [64]u8 = undefined,
    next_bytes_len: usize = 0,
    cur_bytes: [64]u8 = undefined,
    cur_bytes_len: usize = 0,
    cur_bytes_pos: u32 = 0,
    field_start: bool = true,
    at_end: bool = false,
    _need_init: bool = true,
    _erred: bool = false,
};

/// Fast fields parser
/// Parses individual fields and marks fields at the end of a row
pub fn Parser(comptime Reader: type, comptime Writer: type) type {
    return struct {
        pub const ReadError = Reader.Error || CsvReadError || error{EndOfStream};
        pub const WriteError = Writer.Error;
        pub const Error = ReadError || WriteError;
        _reader: Reader,
        _state: ParserState = .{},
        _opts: common.ParserLimitOpts = .{},
        _row_end: bool = false,

        /// Initializes a parser
        pub fn init(reader: Reader, opts: common.ParserLimitOpts) @This() {
            return @This(){
                ._reader = reader,
                ._opts = opts,
            };
        }

        pub fn atRowEnd(self: *const @This()) bool {
            const res = self.done() or self._row_end;
            return res;
        }

        /// Returns if a parser is done
        pub fn done(self: *const @This()) bool {
            if (self._state._erred) {
                return true;
            }
            if (self._state._need_init) {
                return false;
            }
            if (self._state.field_start) {
                return false;
            }
            if (self._state.cur_bytes_len == 0) {
                return true;
            }
            if (self._state.cur_bytes_pos >= self._state.cur_bytes_len and self._state.next_bytes_len == 0) {
                return true;
            }
            return false;
        }

        /// reates match bit string
        fn match(ch: u8, slice: []const u8) u64 {
            var res: u64 = 0;
            for (slice, 0..) |c, i| {
                res |= @as(u64, @intFromBool(c == ch)) << @truncate(i);
            }
            return res;
        }

        fn nextChunk(self: *@This()) !void {
            defer self._state._need_init = false;
            self._state.cur_bytes_len = self._state.next_bytes_len;
            self._state.cur_bytes_pos = 0;
            std.debug.assert(self._state.cur_bytes_len <= chunk_size);
            std.mem.copyForwards(u8, &self._state.cur_bytes, &self._state.next_bytes);

            if (!self._state._need_init and self._state.next_bytes_len < 64) {
                self._state.next_bytes_len = 0;
                return;
            }

            const amt = try self._reader.readAll(&self._state.next_bytes);
            self._state.next_bytes_len = amt;
        }

        /// Gets the next CSV field
        pub fn next(self: *@This(), writer: Writer) Error!void {
            self.nextImpl(writer) catch |err| {
                self._state._erred = true;
                return err;
            };
        }

        /// Gets the next CSV field
        fn nextImpl(self: *@This(), writer: Writer) !void {
            self._state.field_start = false;
            // lazy init our parser
            if (self._state._need_init) {
                // Consume twice to populate our cur and next registers
                try self.nextChunk();
                self._state.cur_bytes_pos = 64;
                std.debug.assert(!self._state._need_init);
            } else if (self.done()) {
                return;
            }

            self._row_end = false;

            const MAX_ITER = self._opts.max_iter;
            var index: usize = 0;
            for (0..(MAX_ITER + 1)) |i| {
                index = i;

                // If we have a field to print, print it
                if (self._state.field_separators != 0) {
                    const chunk_end = @ctz(self._state.field_separators);
                    std.debug.assert(chunk_end <= self._state.cur_bytes_len);
                    std.debug.assert(self._state.cur_bytes_pos < chunk_size);
                    std.debug.assert(chunk_end <= chunk_size);

                    const end_pos = @min(self._state.cur_bytes_len, chunk_end);
                    const out = self._state.cur_bytes[self._state.cur_bytes_pos..chunk_end];
                    std.debug.assert(out.len <= chunk_size);
                    try writer.writeAll(out);

                    self._row_end = self._state.cur_bytes[end_pos] == '\r' or self._state.cur_bytes[end_pos] == '\n';

                    self._state.field_separators ^= @as(u64, 1) << @truncate(chunk_end);
                    self._state.cur_bytes_pos = chunk_end + 1;

                    if (end_pos < self._state.cur_bytes_len and self._state.cur_bytes[end_pos] == '\r') {
                        if (chunk_end + 1 < chunk_size - 1) {
                            self._state.field_separators ^= @as(u64, 1) << @truncate(chunk_end + 1);
                            self._state.cur_bytes_pos = chunk_end + 2;
                        } else {
                            // Handle the edge case we end a chunk on a CR
                            // In this case, we need to go through the loop again to
                            // hit the LF
                            // Additionally, we need to not output an empty field on the LF
                            self._state.field_separators = 0;
                        }
                    }

                    if (end_pos < self._state.cur_bytes_len and self._state.cur_bytes[end_pos] == ',') {
                        self._state.field_start = true;
                    }
                    return;
                }
                self._state.field_start = false;

                // print the remainder of our current chunk
                if (self._state.cur_bytes_pos < self._state.cur_bytes_len) {
                    const out = self._state.cur_bytes[self._state.cur_bytes_pos..];
                    std.debug.assert(out.len <= chunk_size);
                    try writer.writeAll(out);
                }
                self._state.cur_bytes_pos = 0;

                // grab our next chunk
                try self.nextChunk();

                if (self._state.cur_bytes_len == 0) {
                    return;
                }

                const chunk = self._state.cur_bytes[0..self._state.cur_bytes_len];
                std.debug.assert(chunk.len <= chunk_size);

                const match_quotes = match('"', chunk);
                const match_commas = match(',', chunk);
                const match_crs = match('\r', chunk);
                var match_lfs = match('\n', chunk);

                defer self._state.prev_cr = match_crs;

                if (self._state.cur_bytes_len < chunk_size) {
                    match_lfs |= @as(u64, 1) << @truncate(self._state.cur_bytes_len);
                }

                const carry: u64 = @bitCast(-%@as(
                    i64,
                    @bitCast(self._state.prev_quote >> (chunk_size - 1)),
                ));
                const quoted = @This().quotedRegions(match_quotes) ^ carry;
                defer self._state.prev_quote = quoted;

                const unquoted = ~quoted;

                const field_commas = match_commas & unquoted;
                const field_crs = match_crs & unquoted;
                const field_lfs = match_lfs & unquoted;

                const expected_lfs = (match_crs << 1) | (self._state.prev_cr >> (chunk_size - 1));
                const masked_lfs = expected_lfs & field_lfs;

                if (@popCount(expected_lfs) != @popCount(masked_lfs)) {
                    return CsvReadError.InvalidLineEnding;
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

                const quote_starts = quote_strings & ~(quote_strings << 1);
                const quote_ends = quote_strings & ~(quote_strings >> 1);
                const expected_starts = quote_starts & ~(self._state.prev_quote_ends >> (chunk_size - 1));
                defer self._state.prev_quote_ends = quote_ends;

                const at_end = self._state.next_bytes_len == 0;
                if (at_end) {
                    const last_bit_quoted = (quoted >> @truncate(chunk_size - 1)) & 1;
                    const last_quote_end = (quote_ends >> @truncate(chunk_size - 1)) & 1;
                    if (last_bit_quoted == 1 and last_quote_end != 0) {
                        return CsvReadError.UnexpectedEndOfFile;
                    }

                    if (self._state.cur_bytes[self._state.cur_bytes_len - 1] == '\r') {
                        return CsvReadError.InvalidLineEnding;
                    }

                    if (self._state.cur_bytes[self._state.cur_bytes_len - 1] == ',') {
                        self._state.field_start = true;
                    }
                }

                const expected_end_seps = ((quote_ends << 1) | (self._state.prev_quote_ends >> (chunk_size - 1))) & (~quote_starts);
                const field_seps_start = (self._state.field_separators << 1) | (self._state.prev_field_seps >> (chunk_size - 1));

                const masked_end_seps = self._state.field_separators & expected_end_seps;
                const masked_sep_start = field_seps_start & expected_starts;

                if (!at_end and @popCount(expected_end_seps) != @popCount(masked_end_seps)) {
                    return CsvReadError.QuotePrematurelyTerminated;
                }

                if (@popCount(masked_sep_start) != @popCount(expected_starts)) {
                    return CsvReadError.UnexpectedQuote;
                }
            }

            return CsvReadError.InternalLimitReached;
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
}

/// Initializes parser
pub fn init(reader: anytype, comptime Writer: type, opts: common.ParserLimitOpts) Parser(@TypeOf(reader), Writer) {
    return Parser(@TypeOf(reader), Writer).init(reader, opts);
}

test "simd array" {
    const testing = @import("std").testing;
    var csv = std.io.fixedBufferStream(
        \\c1,c2,c3,c4,c5
        \\r1,"ff1,ff2",,ff3,ff4
        \\r2," "," "," "," "
        \\r3,1  ,2  ,3  ,4  
        \\r4,   ,   ,   ,   
        \\r5,abc,def,geh,""""
        \\r6,""""," "" ",hello,"b b b"
    );
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

    var fb_buff: [64]u8 = undefined;
    var fb_stream = std.io.fixedBufferStream(&fb_buff);

    var decode_buff: [64]u8 = undefined;
    var decode_stream = std.io.fixedBufferStream(&decode_buff);
    var parser = init(csv.reader(), @TypeOf(fb_stream.writer()), .{});

    while (!parser.done()) {
        fb_stream.reset();
        decode_stream.reset();
        try parser.next(fb_stream.writer());
        try common.decode(fb_stream.getWritten(), decode_stream.writer());
        defer {
            fields += 1;
            if (parser.atRowEnd()) lines += 1;
        }
        try testing.expectEqualStrings(expected_decoded[fields], decode_stream.getWritten());
    }

    try testing.expectEqual(expected_lines, lines);
    try testing.expectEqual(expected_fields, fields);
}

test "array field streamer" {
    // get our writer
    var buff = std.ArrayList(u8).init(std.testing.allocator);
    defer buff.deinit();

    var input = std.io.fixedBufferStream(
        \\userid,name,"age",active,
        \\1,"John Doe",23,no,
        \\12,"Robert ""Bobby"" Junior",98,yes,
        \\21,"Bob",24,yes,
        \\31,"New
        \\York",43,no,
        \\4,,,no,
    );

    const expected = [_][]const u8{
        "userid", "name",                    "age", "active", "",
        "1",      "John Doe",                "23",  "no",     "",
        "12",     "Robert \"Bobby\" Junior", "98",  "yes",    "",
        "21",     "Bob",                     "24",  "yes",    "",
        "31",     "New\nYork",               "43",  "no",     "",
        "4",      "",                        "",    "no",     "",
    };

    var ei: usize = 0;
    var decode_buff: [64]u8 = undefined;
    var decode_stream = std.io.fixedBufferStream(&decode_buff);
    var parser = init(input.reader(), @TypeOf(buff.writer()), .{});

    while (!parser.done()) {
        defer {
            decode_stream.reset();
            buff.clearRetainingCapacity();
            ei += 1;
        }
        try parser.next(buff.writer());
        try common.decode(buff.items, decode_stream.writer());
        const atEnd = ei % 5 == 4;
        const field = decode_stream.getWritten();
        try std.testing.expectEqualStrings(expected[ei], field);
        try std.testing.expectEqual(atEnd, parser.atRowEnd());
    }

    try std.testing.expectEqual(expected.len, ei);
}

test "slice streamer" {
    // get our writer
    var buff = std.ArrayList(u8).init(std.testing.allocator);
    defer buff.deinit();

    var input = std.io.fixedBufferStream(
        \\userid,name,"age",active,
        \\1,"John Doe",23,no,
        \\12,"Robert ""Bobby"" Junior",98,yes,
        \\21,"Bob",24,yes,
        \\31,"New
        \\York",43,no,
        \\33,"hello""world""",400,yes,
        \\34,"""world""",2,yes,
        \\35,"""""""""",1,no,
    );

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
    var decode_buff: [64]u8 = undefined;
    var decode_stream = std.io.fixedBufferStream(&decode_buff);
    var parser = init(input.reader(), @TypeOf(buff.writer()), .{});

    while (!parser.done()) {
        defer {
            buff.clearRetainingCapacity();
            decode_stream.reset();
            ei += 1;
        }
        try parser.next(buff.writer());
        try common.decode(buff.items, decode_stream.writer());
        const atEnd = ei % 5 == 4;
        const field = decode_stream.getWritten();
        try std.testing.expectEqualStrings(expected[ei], field);
        try std.testing.expectEqual(atEnd, parser.atRowEnd());
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
        var b: [100]u8 = undefined;
        var buff = std.io.fixedBufferStream(&b);

        var b_r: [100]u8 = undefined;
        std.mem.copyForwards(u8, &b_r, testCase.input);
        var i_b = std.io.fixedBufferStream(b_r[0..testCase.input.len]);

        var iterator = init(i_b.reader(), @TypeOf(buff.writer()), .{});
        var cnt: usize = 0;
        while (!iterator.done()) {
            buff.reset();
            iterator.next(buff.writer()) catch |err| {
                try testing.expectEqual(testCase.err.?, err);
                continue;
            };

            cnt += 1;
        }

        try testing.expectEqual(testCase.count, cnt);
    }
}

test "row and field iterator" {
    const testing = @import("std").testing;

    var input = std.io.fixedBufferStream(
        \\userid,name,age
        \\1,"Jonny",23
        \\2,Jack,32
    );

    const fieldCount = 9;

    var b: [100]u8 = undefined;
    var buff = std.io.fixedBufferStream(&b);
    var parser = init(input.reader(), @TypeOf(buff.writer()), .{});
    var cnt: usize = 0;
    while (!parser.done()) {
        buff.reset();
        try parser.next(buff.writer());
        cnt += 1;
    }

    try testing.expectEqual(fieldCount, cnt);
}

test "crlf, at 63" {
    const testing = @import("std").testing;

    var input = std.io.fixedBufferStream(
        ",012345,,8901234,678901,34567890123456,890123456789012345678,,,\r\n" ++
            ",,012345678901234567890123456789012345678901234567890123456789\r\n" ++
            ",012345678901234567890123456789012345678901234567890123456789\r\n,",
    );

    const fieldCount = 17;

    var b: [100]u8 = undefined;
    var buff = std.io.fixedBufferStream(&b);
    var parser = init(input.reader(), @TypeOf(buff.writer()), .{});
    var cnt: usize = 0;
    while (!parser.done()) {
        buff.reset();
        try parser.next(buff.writer());
        cnt += 1;
    }

    try testing.expectEqual(fieldCount, cnt);
}

test "crlf\", at 63" {
    const testing = @import("std").testing;

    var input = std.io.fixedBufferStream(
        ",012345,,8901234,678901,34567890123456,890123456789012345678,,,\r\n" ++
            "\"\",,012345678901234567890123456789012345678901234567890123456789\r\n" ++
            ",012345678901234567890123456789012345678901234567890123456789\r\n,",
    );

    const fieldCount = 17;

    var b: [100]u8 = undefined;
    var buff = std.io.fixedBufferStream(&b);
    var parser = init(input.reader(), @TypeOf(buff.writer()), .{});
    var cnt: usize = 0;
    while (!parser.done()) {
        buff.reset();
        try parser.next(buff.writer());
        cnt += 1;
    }

    try testing.expectEqual(fieldCount, cnt);
}
