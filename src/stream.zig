const std = @import("std");
const CsvReadError = @import("common.zig").CsvReadError;

/// Packed flags and tiny state pieces for field streams
const FSFlags = packed struct {
    _prev: u8 = ',',
    _in_quote: bool = false,
    _endStr: bool = false,
    _cr: bool = false,
    _done: bool = false,
    _inc_row: bool = false,
};

/// Options for Partial Field Stream
pub const PartialOpts = struct {
    max_len: usize = 4_294_967_296,
};

/// A CSV field stream will write fields to an output writer one field at a time
/// To know the row of the last read field, use the "row" property (starts at 0)
/// The next function may error (e.g. parse error or stream error)
/// Fields will be truncated at a configurable length (default 4,294,967,296 bytes)
/// Partial writes will be made to the writer, even if there is a parse error
/// later on
/// This is since the streamer will parse one character at a time with no
/// lookahead
pub fn FieldStreamPartial(
    comptime Reader: type,
    comptime Writer: type,
) type {
    return struct {
        pub const ReadError = Reader.Error || CsvReadError;
        pub const WriteError = Writer.Error || error{EndOfStream};
        pub const Error = ReadError || WriteError;

        _reader: Reader,
        _row: usize = 0,
        _opts: PartialOpts = .{},
        _flags: FSFlags = .{},

        /// Creates a new CSV Field Stream
        pub fn init(reader: Reader, opts: PartialOpts) @This() {
            return .{
                ._reader = reader,
                ._opts = opts,
            };
        }

        /// Returns the current row number
        pub fn row(self: @This()) usize {
            return self._row;
        }

        /// Returns whether the field just parsed was at the end of a row
        pub fn atRowEnd(self: @This()) bool {
            return self._flags._done or self._flags._inc_row;
        }

        /// Returns we're at the end of the input
        pub fn atEnd(self: @This()) bool {
            return self._flags._done;
        }

        /// Parse the next field
        pub fn next(self: *@This(), writer: Writer) Error!bool {
            if (self._flags._done) {
                return false;
            }

            if (self._flags._inc_row) {
                self._row += 1;
                self._flags._inc_row = false;
            }

            // We won't technically hit an infinite loop,
            // but we practically will since this is a lot
            const MAX_FIELD_LEN = self._opts.max_len;
            var index: usize = 0;
            for (0..(MAX_FIELD_LEN + 1)) |i| {
                index = i;
                const cur = self._reader.readByte() catch |err| {
                    if (err == WriteError.EndOfStream) {
                        break;
                    }
                    self._flags._done = true;
                    return err;
                };

                defer {
                    self._flags._prev = cur;
                }

                const was_comma = self._flags._prev == ',' or self._flags._prev == '\r' or self._flags._prev == '\n';

                if (!self._flags._in_quote and was_comma and cur == '"') {
                    self._flags._in_quote = true;
                } else if (cur == ',' or cur == '\r' or cur == '\n') {
                    if (self._flags._in_quote) {
                        try writer.writeByte(cur);
                        continue;
                    }
                    self._flags._endStr = false;

                    defer {
                        self._flags._cr = cur == '\r';
                    }
                    if (self._flags._cr and cur != '\n') {
                        self._flags._done = true;
                        return CsvReadError.InvalidLineEnding;
                    }

                    if (cur == '\n') {
                        self._flags._inc_row = true;
                    }
                    if (cur != '\r') {
                        return true;
                    }
                } else if (self._flags._cr) {
                    self._flags._done = true;
                    return CsvReadError.InvalidLineEnding;
                } else if (cur == '"') {
                    if (self._flags._prev == '"' and self._flags._endStr) {
                        self._flags._endStr = false;
                        self._flags._in_quote = true;
                        try writer.writeByte('"');
                    } else if (self._flags._endStr) {
                        self._flags._done = true;
                        return CsvReadError.QuotePrematurelyTerminated;
                    } else if (self._flags._in_quote) {
                        self._flags._in_quote = false;
                        self._flags._endStr = true;
                    } else {
                        self._flags._done = true;
                        return CsvReadError.UnexpectedQuote;
                    }
                } else if (self._flags._endStr) {
                    self._flags._done = true;
                    return CsvReadError.QuotePrematurelyTerminated;
                } else {
                    try writer.writeByte(cur);
                }
            }

            if (index >= MAX_FIELD_LEN) {
                return CsvReadError.InternalLimitReached;
            }

            self._flags._done = true;
            if (self._flags._in_quote) {
                return CsvReadError.UnexpectedEndOfFile;
            }
            if (self._flags._cr) {
                return CsvReadError.InvalidLineEnding;
            }
            return true;
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

    var stream = FieldStreamPartial(
        @TypeOf(reader),
        @TypeOf(buff.writer()),
    ).init(reader, .{});

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
    var row: usize = 0;

    while (try stream.next(buff.writer())) {
        defer {
            buff.clearRetainingCapacity();
            row += if (expected[ei].len == 0) 1 else 0;
            ei += 1;
        }
        const field = buff.items;
        try std.testing.expectEqualStrings(expected[ei], field);
        try std.testing.expectEqual(row, stream._row);
    }
}

/// A CSV field stream will write fields to an output writer one field at a time
/// To know the row of the last read field, use the "row" property (starts at 0)
/// The next function may error (e.g. parse error or stream error)
/// Uses a 1,024 character buffer to avoid partial field writes on parse errors
pub fn FieldStream(
    comptime Reader: type,
    comptime Writer: type,
) type {
    const Fs = FieldStreamPartial(
        Reader,
        std.io.FixedBufferStream([]u8).Writer,
    );
    return struct {
        pub const ReadError = Fs.ReadError;
        pub const WriteError = Fs.WriteError;
        pub const Error = Fs.Error;
        _partial: Fs,

        /// Creates a new CSV Field Stream
        pub fn init(reader: Reader) @This() {
            return .{
                ._partial = Fs.init(reader, .{ .max_len = 1_024 }),
            };
        }

        /// Returns the current row number
        pub fn row(self: @This()) usize {
            return self._partial._row;
        }

        /// Returns whether the field just parsed was at the end of a row
        pub fn atRowEnd(self: @This()) bool {
            return self._partial.atRowEnd();
        }

        /// Returns we're at the end of the input
        pub fn atEnd(self: @This()) bool {
            return self._partial.atEnd();
        }

        /// Parse the next field
        pub fn next(self: *@This(), writer: Writer) !bool {
            var b: [1024]u8 = undefined;
            var buff = std.io.fixedBufferStream(&b);
            const _writer = buff.writer();

            const hasNext = try self._partial.next(_writer);
            try writer.writeAll(buff.getWritten());
            return hasNext;
        }
    };
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
    );
    const reader = input.reader();
    var stream = FieldStream(
        @TypeOf(reader),
        @TypeOf(buff.writer()),
    ).init(reader);

    const expected = [_][]const u8{
        "userid", "name",                    "age", "active", "",
        "1",      "John Doe",                "23",  "no",     "",
        "12",     "Robert \"Bobby\" Junior", "98",  "yes",    "",
        "21",     "Bob",                     "24",  "yes",    "",
        "31",     "New\nYork",               "43",  "no",     "",
    };

    var ei: usize = 0;
    var row: usize = 0;

    while (try stream.next(buff.writer())) {
        defer {
            buff.clearRetainingCapacity();
            row += if (expected[ei].len == 0) 1 else 0;
            ei += 1;
        }
        const field = buff.items;
        try std.testing.expectEqualStrings(expected[ei], field);
        try std.testing.expectEqual(row, stream.row());
    }
}
