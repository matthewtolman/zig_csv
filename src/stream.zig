const std = @import("std");
const CsvReadError = @import("common.zig").CsvReadError;
const ParserLimitOpts = @import("common.zig").ParserLimitOpts;

/// Packed flags and tiny state pieces for field streams
const FSFlags = packed struct {
    _in_quote: bool = false,
    _row_end: bool = false,
    _started: bool = false,
    // We always start with a field
    // This also means that an empty file will become one "null" field
    _field_start: bool = true,
};

/// Initializes a CSV field parser with the given reader and options.
/// The parser will read fields one at a time from the reader, writing them
/// to an output writer. Fields are parsed based on the configured `ParserLimitOpts`.
pub fn init(comptime Reader: type, comptime Writer: type, reader: Reader, opts: ParserLimitOpts, flags: FSFlags) Parser(Reader, Writer) {
    return Parser(Reader, Writer){
        ._reader = reader,
        ._cur = null,
        ._next = null,
        ._opts = opts,
        ._flags = flags,
    };
}

/// A CSV field stream will write fields to an output writer one field at a time
/// To know the row of the last read field, use the "row" property (starts at 0)
/// The next function may error (e.g. parse error or stream error)
/// Fields will be truncated at a configurable length (default 4,294,967,296 bytes)
/// Partial writes will be made to the writer, even if there is a parse error
/// later on
/// This is since the streamer will parse one character at a time with no
/// lookahead
pub fn Parser(
    comptime Reader: type,
    comptime Writer: type,
) type {
    return struct {
        pub const ReadError = Reader.Error || CsvReadError || error{EndOfStream};
        pub const WriteError = Writer.Error;
        pub const Error = ReadError || WriteError;

        _reader: Reader,
        _cur: ?u8 = null,
        _next: ?u8 = null,
        _opts: ParserLimitOpts = .{},
        _flags: FSFlags = .{},

        /// Creates a new CSV Field Stream
        pub fn init(reader: Reader, opts: ParserLimitOpts) @This() {
            return .{
                ._reader = reader,
                ._opts = opts,
            };
        }

        /// Returns whether the field just parsed was at the end of a row
        pub fn atRowEnd(self: @This()) bool {
            return self.done() or self._flags._row_end;
        }

        /// Returns we're at the end of the input
        pub fn done(self: @This()) bool {
            // If we haven't started then we can't be at the end yet
            if (!self._flags._started) {
                return false;
            }

            // If we're starting a new feild we aren't done yet
            if (self._flags._field_start) {
                return false;
            }

            // We're at the end if our current character is null
            return self.current() == null;
        }

        /// Consume a character and move forward our reader
        fn consume(self: *@This()) ReadError!void {
            // While we should behave properly, we shouldn't be consuming
            // when we're done
            std.debug.assert(!self.done());
            self._cur = self._next;

            // This checks to see if we already hit the end of the stream
            // If so, don't try calling our reader again since we know it's
            // already empty
            if (self._next == null and self._flags._started) {
                return;
            }
            self._flags._started = true;

            // Try to get the next byte from our reader
            self._next = self._reader.readByte() catch |err| blk: {
                // Handle the end of an input stream
                if (err == ReadError.EndOfStream) {
                    break :blk null;
                }
                return err;
            };
        }

        /// Peak at the next character
        fn peek(self: @This()) ?u8 {
            return self._next;
        }

        /// Get the current character
        fn current(self: @This()) ?u8 {
            return self._cur;
        }

        /// Parse the next field
        pub fn next(self: *@This(), writer: Writer) Error!void {
            // lazy-initialize our parser
            if (!self._flags._started) {
                // Consume twice to populate our cur and next registers
                try self.consume();
                try self.consume();
            }

            if (self.current() == null) {
                // If we end on a comma, we will output a "null" field
                // However, we need to make sure we don't output an infinte
                // number of null fields. To do that, we always set our
                // field_start flag to false, that way we output at most
                // one null field
                self._flags._field_start = false;
                return;
            }

            // When we start next we always are at the start or middle of a row
            self._flags._row_end = false;

            // We won't technically hit an infinite loop,
            // but we practically will since this is a lot
            const MAX_ITER = self._opts.max_iter;
            var index: usize = 0;
            while (index < MAX_ITER) : (index += 1) {
                if (self._flags._in_quote) {
                    // Handle quoted strings
                    if (self.current()) |cur| {
                        switch (cur) {
                            '"' => {
                                if (self.peek()) |p| {
                                    switch (p) {
                                        ',', '\r', '\n' => {
                                            self._flags._in_quote = false;
                                            try self.consume();
                                            continue;
                                        },
                                        '"' => {
                                            try self.consume();
                                            try self.consume();
                                            try writer.writeByte('"');
                                        },
                                        else => {
                                            return CsvReadError.QuotePrematurelyTerminated;
                                        },
                                    }
                                } else {
                                    self._flags._in_quote = false;
                                    try self.consume();
                                    continue;
                                }
                            },
                            else => |c| {
                                try writer.writeByte(c);
                                try self.consume();
                            },
                        }
                    } else {
                        return CsvReadError.UnexpectedEndOfFile;
                    }
                } else if (self.current()) |cur| {
                    // Handle unquoted strings
                    switch (cur) {
                        '"' => {
                            if (!self._flags._field_start) {
                                return CsvReadError.UnexpectedQuote;
                            }
                            self._flags._in_quote = true;
                            self._flags._field_start = false;
                            try self.consume();
                        },
                        ',',
                        => {
                            self._flags._field_start = true;
                            self._flags._row_end = false;
                            try self.consume();
                            return;
                        },
                        '\n',
                        => {
                            self._flags._field_start = self.peek() != null;
                            self._flags._row_end = true;
                            try self.consume();
                            return;
                        },
                        '\r' => {
                            if (self.peek() != '\n') {
                                return CsvReadError.InvalidLineEnding;
                            }
                            try self.consume();
                            try self.consume();
                            self._flags._field_start = self.peek() != null;
                            self._flags._row_end = true;
                            return;
                        },
                        else => |c| {
                            self._flags._field_start = false;
                            try writer.writeByte(c);
                            try self.consume();
                        },
                    }
                } else {
                    return;
                }
            }

            if (index >= MAX_ITER) {
                return CsvReadError.InternalLimitReached;
            }

            if (self._flags._in_quote) {
                return CsvReadError.UnexpectedEndOfFile;
            }
            return;
        }
    };
}

test "csv field streamer partial" {
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
    const reader = input.reader();

    var stream = init(
        @TypeOf(reader),
        @TypeOf(buff.writer()),
        reader,
        .{},
        .{},
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

    while (!stream.done()) {
        try stream.next(buff.writer());
        defer {
            buff.clearRetainingCapacity();
            ei += 1;
        }
        const atEnd = ei % 5 == 4;
        const field = buff.items;
        try std.testing.expectEqualStrings(expected[ei], field);
        try std.testing.expectEqual(atEnd, stream.atRowEnd());
    }

    try std.testing.expectEqual(expected.len, ei);
}

test "csv field streamer" {
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
    const reader = input.reader();
    var stream = Parser(
        @TypeOf(reader),
        @TypeOf(buff.writer()),
    ).init(reader, .{});

    const expected = [_][]const u8{
        "userid", "name",                    "age", "active", "",
        "1",      "John Doe",                "23",  "no",     "",
        "12",     "Robert \"Bobby\" Junior", "98",  "yes",    "",
        "21",     "Bob",                     "24",  "yes",    "",
        "31",     "New\nYork",               "43",  "no",     "",
        "4",      "",                        "",    "no",     "",
    };

    var ei: usize = 0;

    while (!stream.done()) {
        try stream.next(buff.writer());
        defer {
            buff.clearRetainingCapacity();
            ei += 1;
        }
        const atEnd = ei % 5 == 4;
        const field = buff.items;
        try std.testing.expectEqualStrings(expected[ei], field);
        try std.testing.expectEqual(atEnd, stream.atRowEnd());
    }

    try std.testing.expectEqual(expected.len, ei);
}

test "crlf, at 63" {
    const testing = @import("std").testing;
    var buff = std.ArrayList(u8).init(std.testing.allocator);
    defer buff.deinit();

    var input = std.io.fixedBufferStream(
        ",012345,,8901234,678901,34567890123456,890123456789012345678,,,\r\n" ++
            ",,012345678901234567890123456789012345678901234567890123456789\r\n" ++
            ",012345678901234567890123456789012345678901234567890123456789\r\n,",
    );

    const fieldCount = 17;

    const reader = input.reader();
    var stream = Parser(@TypeOf(reader), @TypeOf(buff.writer())).init(reader, .{});
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

test "crlf,\" at 63" {
    const testing = @import("std").testing;
    var buff = std.ArrayList(u8).init(std.testing.allocator);
    defer buff.deinit();

    var input = std.io.fixedBufferStream(
        ",012345,,8901234,678901,34567890123456,890123456789012345678,,,\r\n" ++
            "\"\",,012345678901234567890123456789012345678901234567890123456789\r\n" ++
            ",012345678901234567890123456789012345678901234567890123456789\r\n,",
    );

    const fieldCount = 17;

    const reader = input.reader();
    var stream = init(
        @TypeOf(reader),
        @TypeOf(buff.writer()),
        reader,
        .{},
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

test "End with quote" {
    const testing = @import("std").testing;
    var buff = std.ArrayList(u8).init(std.testing.allocator);
    defer buff.deinit();

    var input = std.io.fixedBufferStream("\"hello, world\"");

    const fieldCount = 1;

    const reader = input.reader();
    var stream = init(
        @TypeOf(reader),
        @TypeOf(buff.writer()),
        reader,
        .{},
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
