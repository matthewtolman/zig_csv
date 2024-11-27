const CsvReadError = @import("common.zig").CsvReadError;
const ParseBoolError = @import("common.zig").ParseBoolError;
const common = @import("common.zig");
const decode = @import("decode_writer.zig");
const std = @import("std");

// DO NOT CHANGE
const chunk_size = 64;
const ChunkMask = u64;
const quotes: @Vector(chunk_size, u8) = @splat(@as(u8, '"'));

const ChunkWriteRes = enum { FINISHED_FIELD, PARTIAL_FIELD, WROTE_NOTHING };
const ChunkFieldCover = enum(u8) { COMPLETE, INCOMPLETE, INVALID };

/// Creates match bit string
fn match(ch: u8, slice: []const u8) u64 {
    var res: u64 = 0;
    for (slice, 0..) |c, i| {
        res |= @as(u64, @intFromBool(c == ch)) << @truncate(i);
    }
    return res;
}

/// Calculates quoted region mask
fn quotedRegions(m: u64) u64 {
    var x: u64 = m;
    var res: u64 = x;
    while (x != 0) : (x = x & x - 1) {
        const x1: u64 = @bitCast(-%@as(i64, @bitCast(x)));
        res = res ^ (x1 ^ x);
    }
    return res;
}

const Chunk = struct {
    quoted: ChunkMask = 0,
    quotes: ChunkMask = 0,
    crs: ChunkMask = 0,
    next_delim_track: ChunkMask = 0,
    delims: ChunkMask = 0,
    bytes: [chunk_size]u8 = undefined,
    field_cover: ChunkFieldCover = .INCOMPLETE,
    len: u8 = 0,
    offset: u8 = 0,
    end_seps_passed: bool = false,
    opts: common.CsvOpts = .{},

    pub fn clear(self: *@This()) void {
        self.quoted = 0;
        self.quotes = 0;
        self.crs = 0;
        self.next_delim_track = 0;
        self.delims = 0;
        self.len = 0;
        self.offset = 0;
        self.field_cover = .INVALID;
    }

    fn populate(self: *@This(), prev: *const Chunk) CsvReadError!ChunkFieldCover {
        const chunk = self.bytes[0..self.len];
        const quote = self.opts.column_quote;
        const comma = self.opts.column_delim;
        const cr = self.opts.column_line_end_prefix;
        const lf = self.opts.column_line_end;

        self.quotes = match(quote, chunk);
        const commas = match(comma, chunk);
        self.crs = if (cr) |r| match(r, chunk) else 0;
        var lfs = match(lf, chunk);

        // Add a "terminator" chunk
        if (chunk.len < chunk_size) {
            lfs |= @as(u64, 1) << @truncate(chunk.len);
        }

        const carry: u64 = @bitCast(-%@as(
            i64,
            @bitCast(prev.quoted >> (chunk_size - 1)),
        ));
        self.quoted = quotedRegions(self.quotes) ^ carry;

        const unquoted = ~self.quoted;

        const delim_commas = commas & unquoted;
        const delim_crs = self.crs & unquoted;
        const delim_lfs = lfs & unquoted;
        self.next_delim_track = delim_commas | delim_crs | delim_lfs;
        self.delims = self.next_delim_track;

        const expected_lfs = (delim_crs << 1) | (prev.crs >> (chunk_size - 1));
        const mcheck_lfs = expected_lfs & delim_lfs;

        if (@popCount(expected_lfs) != @popCount(mcheck_lfs)) {
            return CsvReadError.InvalidLineEnding;
        }

        defer {
            // if we ended on a CR previously, make sure to clear it from the
            // field separators, otherwise we end up getting a bad start position
            // We don't remove it from field_seps since we need it for line
            // ending validation
            if (prev.crs & (1 << (chunk_size - 1)) != 0) {
                self.clearNextDelim();
            }
        }

        const expected_start_seps = (self.stringStarts() & ~(prev.stringEnds() >> (chunk_size - 1)));
        const expected_end_seps = ((self.stringEnds() << 1) | (prev.stringEnds() >> (chunk_size - 1))) & (~self.stringStarts());
        const delim_seps_start = (self.delims << 1) | (prev.delims >> (chunk_size - 1));

        const mcheck_delim_end = self.delims & expected_end_seps;
        const mcheck_delim_start = delim_seps_start & expected_start_seps;

        self.end_seps_passed = @popCount(expected_end_seps) == @popCount(mcheck_delim_end);
        const start_seps_passed = @popCount(expected_start_seps) == @popCount(mcheck_delim_start);

        if (!start_seps_passed) {
            return CsvReadError.UnexpectedQuote;
        }

        return .INCOMPLETE;
    }

    pub fn readFrom(self: *@This(), reader: anytype, prev: *const Chunk) !void {
        self.offset = 0;
        self.len = @truncate(try reader.readAll(&self.bytes));
        self.field_cover = try self.populate(prev);
    }

    fn strings(self: *const @This()) u64 {
        return self.quotes | self.quoted;
    }

    fn stringStarts(self: *const @This()) u64 {
        const str = self.strings();
        return str & ~(str << 1);
    }

    fn stringEnds(self: *const @This()) u64 {
        const str = self.strings();
        return str & ~(str >> 1);
    }

    fn nextDelim(self: *const @This()) u8 {
        return @intCast(@ctz(self.next_delim_track));
    }

    fn clearNextDelim(self: *@This()) void {
        self.next_delim_track = self.next_delim_track & ~(@as(u64, 1) << @truncate(self.nextDelim()));
    }

    fn atEnd(self: *const @This()) bool {
        return self.len < chunk_size;
    }

    fn consumed(self: *const @This()) bool {
        return self.offset >= self.len;
    }
};

const ParserState = struct {
    prev_chunk: Chunk = .{},
    cur_chunk: Chunk = .{},
    next_chunk: Chunk = .{},

    field_separators: u64 = 0,

    at_end: bool = false,
    need_init: bool = true,
    erred: bool = false,
    field_start: bool = true,
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
        _opts: common.CsvOpts = .{},
        _row_end: bool = false,

        /// Initializes a parser
        pub fn init(reader: Reader, opts: common.CsvOpts) @This() {
            std.debug.assert(opts.valid());
            return @This(){
                ._reader = reader,
                ._opts = opts,
                ._state = ParserState{
                    .prev_chunk = Chunk{
                        .opts = opts,
                    },
                    .next_chunk = Chunk{
                        .opts = opts,
                    },
                    .cur_chunk = Chunk{
                        .opts = opts,
                    },
                },
            };
        }

        pub fn atRowEnd(self: *const @This()) bool {
            return self.done() or self._row_end;
        }

        /// Returns if a parser is done
        pub fn done(self: *const @This()) bool {
            if (self._state.erred) {
                return true;
            }
            if (self._state.field_start) {
                return false;
            }
            if (self._state.need_init) {
                return false;
            }
            if (self._state.cur_chunk.consumed()) {
                if (self._state.cur_chunk.atEnd()) {
                    return true;
                }
                if (self._state.next_chunk.len == 0) {
                    return true;
                }
            }
            return false;
        }

        fn nextChunk(self: *@This()) Error!void {
            std.debug.assert(self._state.prev_chunk.len <= chunk_size);
            std.debug.assert(self._state.cur_chunk.len <= chunk_size);
            std.debug.assert(self._state.next_chunk.len <= chunk_size);

            defer self._state.need_init = false;
            const at_end = self._state.next_chunk.atEnd();

            const tmp = self._state.prev_chunk;
            self._state.prev_chunk = self._state.cur_chunk;
            self._state.cur_chunk = self._state.next_chunk;
            self._state.next_chunk = tmp;

            if (!self._state.need_init and at_end) {
                self._state.next_chunk.clear();
                return;
            }

            // Don't read from a reader when we're done
            std.debug.assert(!self.done());
            try self._state.next_chunk.readFrom(self._reader, &self._state.cur_chunk);
        }

        /// Gets the next CSV field
        pub fn next(self: *@This(), writer: Writer) Error!void {
            if (self.done()) {
                return;
            }
            var d = decode.init(writer, self._opts);
            self.nextImpl(d.writer()) catch |err| {
                self._state.erred = true;
                return err;
            };
        }

        /// Gets the next CSV field
        fn nextImpl(self: *@This(), writer: anytype) Error!void {
            std.debug.assert(!self.done());
            // lazy init our parser
            if (self._state.need_init) {
                self._state.next_chunk.delims = @as(ChunkMask, 1 << @truncate(chunk_size - 1));
                self._state.next_chunk.next_delim_track = @as(ChunkMask, 1 << @truncate(chunk_size - 1));
                try self.nextChunk();
                try self.nextChunk();
                std.debug.assert(!self._state.need_init);
                _ = try self.validateChunk();
            }

            self._state.field_start = false;
            self._row_end = false;

            const MAX_ITER = self._opts.max_iter;
            var index: usize = 0;
            while (index < MAX_ITER) : (index += 1) {
                const write_state = try self.writeChunk(writer);
                switch (write_state) {
                    .FINISHED_FIELD => return,
                    else => {},
                }

                try self.nextChunk();
                _ = try self.validateChunk();
            }

            return CsvReadError.InternalLimitReached;
        }

        fn writeChunk(self: *@This(), writer: anytype) Error!ChunkWriteRes {
            const cr = self._opts.column_line_end_prefix;
            const lf = self._opts.column_line_end;
            const comma = self._opts.column_delim;

            std.debug.assert(self._state.cur_chunk.len <= chunk_size);
            if (self._state.cur_chunk.len == 0) {
                return .FINISHED_FIELD;
            }

            if (self._state.cur_chunk.consumed()) {
                return .WROTE_NOTHING;
            }

            var offset = self._state.cur_chunk.offset;
            if (offset == 0) {
                if (self._state.prev_chunk.len > 0) {
                    if (self._state.prev_chunk.bytes[self._state.prev_chunk.len - 1] == cr) {
                        if (self._state.cur_chunk.bytes[offset] == lf) {
                            offset = 1;
                        }
                    }
                }
            }
            std.debug.assert(offset <= chunk_size);
            std.debug.assert(offset < self._state.cur_chunk.len);

            if (self._state.cur_chunk.next_delim_track == 0) {
                const field = self._state.cur_chunk.bytes[offset..self._state.cur_chunk.len];
                if (field[field.len - 1] == comma) {
                    self._state.field_start = true;
                }
                try writer.writeAll(field);
                self._state.cur_chunk.offset = chunk_size + 1;
                return .PARTIAL_FIELD;
            }

            const out_delim = self._state.cur_chunk.nextDelim();
            std.debug.assert(out_delim <= chunk_size);

            const end_index = @min(out_delim, self._state.cur_chunk.len - 1);
            std.debug.assert(end_index < chunk_size);
            std.debug.assert(end_index < self._state.cur_chunk.len);

            const field = self._state.cur_chunk.bytes[offset..out_delim];
            var row_end = false;

            if (self._state.cur_chunk.atEnd() or self._state.next_chunk.len == 0) {
                if (out_delim >= self._state.cur_chunk.len) {
                    row_end = true;
                }
            }
            if (self._state.cur_chunk.bytes[end_index] == cr) {
                row_end = true;
            } else if (self._state.cur_chunk.bytes[end_index] == lf) {
                row_end = true;
            }

            if (self._state.cur_chunk.bytes[end_index] == comma) {
                self._state.field_start = true;
                row_end = false;
            }

            try writer.writeAll(field);

            self._state.cur_chunk.offset = out_delim + 1;
            self._state.cur_chunk.clearNextDelim();

            if (self._state.cur_chunk.bytes[end_index] == cr) {
                self._state.cur_chunk.offset = out_delim + 2;
                self._state.cur_chunk.clearNextDelim();
                row_end = true;
            }
            self._row_end = row_end;
            return .FINISHED_FIELD;
        }

        fn validateChunk(self: *@This()) CsvReadError!ChunkFieldCover {
            const cr = self._opts.column_line_end_prefix;
            if (self._state.cur_chunk.atEnd() or self._state.next_chunk.len == 0) {
                const last_bit_quoted = (self._state.cur_chunk.quoted >> @truncate(chunk_size - 1)) & 1;
                const last_quote_end = (self._state.cur_chunk.stringEnds() >> @truncate(chunk_size - 1)) & 1;
                if (last_bit_quoted == 1 and last_quote_end != 0) {
                    return CsvReadError.UnexpectedEndOfFile;
                }

                if (self._state.cur_chunk.len > 0) {
                    if (self._state.cur_chunk.bytes[self._state.cur_chunk.len - 1] == cr) {
                        return CsvReadError.InvalidLineEnding;
                    }
                } else if (self._state.prev_chunk.len > 0) {
                    if (self._state.prev_chunk.bytes[self._state.prev_chunk.len - 1] == cr) {
                        return CsvReadError.InvalidLineEnding;
                    }
                }
            } else if (!self._state.cur_chunk.end_seps_passed) {
                return CsvReadError.QuotePrematurelyTerminated;
            }

            if (self._state.cur_chunk.next_delim_track != 0) {
                return .COMPLETE;
            }
            return .INCOMPLETE;
        }
    };
}

/// Initializes parser
pub fn init(reader: anytype, comptime Writer: type, opts: common.CsvOpts) Parser(@TypeOf(reader), Writer) {
    return Parser(@TypeOf(reader), Writer).init(reader, opts);
}

test "simd array custom delims" {
    const testing = @import("std").testing;
    var csv = std.io.fixedBufferStream(
        "c1;c2;c3;c4;c5\\\tr1;'ff1;ff2';;ff3;ff4\tr2;' ';' ';' ';' '\tr3;1  ;2  ;3  ;4\tr4;   ;   ;   ;\tr5;abc;def;geh;''''\tr6;'''';' '' ';hello;'b b b'\t",
    );
    const expected_fields: usize = 35;
    const expected_lines: usize = 7;
    var fields: usize = 0;
    var lines: usize = 0;

    const expected_decoded = [35][]const u8{
        "c1", "c2",      "c3",  "c4",    "c5",
        "r1", "ff1;ff2", "",    "ff3",   "ff4",
        "r2", " ",       " ",   " ",     " ",
        "r3", "1  ",     "2  ", "3  ",   "4",
        "r4", "   ",     "   ", "   ",   "",
        "r5", "abc",     "def", "geh",   "'",
        "r6", "'",       " ' ", "hello", "b b b",
    };

    var fb_buff: [64]u8 = undefined;
    var fb_stream = std.io.fixedBufferStream(&fb_buff);

    const parser_opts: common.CsvOpts = .{
        .column_quote = '\'',
        .column_delim = ';',
        .column_line_end = '\t',
        .column_line_end_prefix = '\\',
    };
    var parser = init(csv.reader(), @TypeOf(fb_stream.writer()), parser_opts);

    while (!parser.done()) {
        fb_stream.reset();
        try parser.next(fb_stream.writer());
        defer {
            fields += 1;
            if (parser.atRowEnd()) lines += 1;
        }
        try testing.expectEqualStrings(expected_decoded[fields], fb_stream.getWritten());
    }

    try testing.expectEqual(expected_lines, lines);
    try testing.expectEqual(expected_fields, fields);
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
        "r3", "1  ",     "2  ",  "3  ",   "4",
        "r4", "   ",     "   ",  "   ",   "",
        "r5", "abc",     "def",  "geh",   "\"",
        "r6", "\"",      " \" ", "hello", "b b b",
    };

    var fb_buff: [64]u8 = undefined;
    var fb_stream = std.io.fixedBufferStream(&fb_buff);

    var parser = init(csv.reader(), @TypeOf(fb_stream.writer()), .{});

    while (!parser.done()) {
        fb_stream.reset();
        try parser.next(fb_stream.writer());
        defer {
            fields += 1;
            if (parser.atRowEnd()) lines += 1;
        }
        try testing.expectEqualStrings(expected_decoded[fields], fb_stream.getWritten());
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
    var parser = init(input.reader(), @TypeOf(buff.writer()), .{});

    while (!parser.done()) {
        defer {
            buff.clearRetainingCapacity();
            ei += 1;
        }
        try parser.next(buff.writer());
        const atEnd = ei % 5 == 4;
        const field = buff.items;
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
    var parser = init(input.reader(), @TypeOf(buff.writer()), .{});

    while (!parser.done()) {
        defer {
            buff.clearRetainingCapacity();
            ei += 1;
        }
        try parser.next(buff.writer());
        const atEnd = ei % 5 == 4;
        try std.testing.expectEqualStrings(expected[ei], buff.items);
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
            .err = CsvReadError.UnexpectedQuote,
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
                if (testCase.err == null) {
                    try testing.expectFmt("", "Unexpected error: {}", .{err});
                } else {
                    try testing.expectEqual(testCase.err.?, err);
                }
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

    var b: [150]u8 = undefined;
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
        try std.testing.expectEqual(null, std.mem.indexOf(u8, buff.getWritten(), "\n"));
    }

    try std.testing.expectEqual(fieldCount, cnt);
}

test "crlfa, at 63" {
    const testing = @import("std").testing;

    var input = std.io.fixedBufferStream(
        ",012345,,8901234,678901,34567890123456,890123456789012345678,,,\r\n" ++
            "a,,012345678901234567890123456789012345678901234567890123456789\r\n" ++
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

test "End with quote" {
    const testing = @import("std").testing;
    var buff = std.ArrayList(u8).init(std.testing.allocator);
    defer buff.deinit();

    var input = std.io.fixedBufferStream("\"hello, world\"");

    const fieldCount = 1;

    const reader = input.reader();
    var stream = init(
        reader,
        @TypeOf(buff.writer()),
        .{},
    );

    var cnt: usize = 0;
    while (!stream.done()) {
        try stream.next(buff.writer());
        defer {
            buff.clearRetainingCapacity();
        }
        cnt += 1;
    }

    try testing.expectEqual(fieldCount, cnt);
}
