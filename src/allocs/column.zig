const std = @import("std");
const CsvReadError = @import("../common.zig").CsvReadError;
const ParseBoolError = @import("../common.zig").ParseBoolError;
pub const CsvOpts = @import("../common.zig").CsvOpts;
const streamFast = @import("../zero_allocs/stream.zig");

/// Internal representation of a field in a row
pub const RowField = struct {
    _pos: usize,
    _len: usize,

    /// Converts a RowField to a field for a given row
    pub fn toField(self: RowField, row: *const Row) Field {
        std.debug.assert(self._pos <= row._bytes.items.len);
        std.debug.assert(self._pos + self._len <= row._bytes.items.len);
        return Field{ ._data = row._bytes.items[self._pos..][0..self._len] };
    }
};

/// Represents a CSV field copied to the heap
pub const Field = struct {
    // This references an internal buffer in the row
    _data: []const u8,

    /// Writes the string data tied to the field
    pub fn decode(self: *const Field, writer: anytype) !void {
        try writer.writeAll(self._data);
    }

    /// Returns the decoded data for the field
    /// Note: Unique to allocating fields
    pub fn data(self: *const Field) []const u8 {
        return self._data;
    }

    /// Clones memory using a specific allocator
    /// Useful when wanting to keep a field's memory past the lifetime of the
    /// row or field
    pub fn clone(
        self: Field,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!std.ArrayList(u8) {
        var copy = std.ArrayList(u8).init(allocator);
        errdefer copy.deinit();
        try copy.resize(self.data().len);
        std.mem.copyForwards(u8, copy.items, self.data());
        return copy;
    }
};

/// Iterates over a CSV row
pub const RowIter = struct {
    _row: *const Row,
    _pos: usize = 0,

    /// Gets the next field from the row
    pub fn next(self: *RowIter) ?Field {
        if (self._pos >= self._row._fields.items.len) {
            return null;
        }
        defer self._pos += 1;
        return self._row.field(self._pos) catch unreachable;
    }
};

/// Represents a CSV row with memory on the heap
/// Make sure to call Row.denit()
/// Row.denit() will clean all memory owned by the Row (including field memory)
pub const Row = struct {
    const OutOfBoundsError = error{IndexOutOfBounds};
    _fields: std.ArrayList(RowField),
    /// Holds the byte data for all of the fields
    _bytes: std.ArrayList(u8),

    /// Cleans up all memory owned by the row (including field memory)
    pub fn deinit(self: Row) void {
        defer self._fields.deinit();
        defer self._bytes.deinit();
    }

    /// Returns the number of fields/columns in a row
    pub fn len(self: *const Row) usize {
        return self._fields.items.len;
    }

    /// Gets the field/column at an index
    /// If the index is out of bounds will return an error
    /// O(1)
    pub fn field(self: *const Row, index: usize) OutOfBoundsError!Field {
        if (index >= self.len()) {
            return OutOfBoundsError.IndexOutOfBounds;
        }
        return self._fields.items[index].toField(self);
    }

    /// Gets the field/column at an index
    /// If the index is out of bounds will return null
    /// O(1)
    pub fn fieldOrNull(self: *const Row, index: usize) ?Field {
        if (index >= self.len()) {
            return null;
        }
        return self.field(index) catch unreachable;
    }

    /// Returns an iterator over the row
    pub fn iter(self: *const Row) RowIter {
        return .{ ._row = self };
    }
};

/// Creates a CSV parser over a reader that stores parsed data on the heap
/// Will parse the reader line-by-line instead of all at once
/// Memory is owned by returned rows, so call Row.deinit()
pub fn Parser(comptime Reader: type) type {
    const Writer = std.ArrayList(u8).Writer;
    const Fs = streamFast.Parser(Reader, Writer);
    return struct {
        pub const Error = Fs.Error || std.mem.Allocator.Error || error{
            EndOfInput,
            EndOfStream,
            ReadError,
        };

        _allocator: std.mem.Allocator,
        err: ?Error = null,
        _done: bool = false,
        _buffer: Fs,
        _row_field_count: usize = 1,
        _row_byte_count: usize = 1,

        /// Initializes a CSV parser with an allocator and a reader
        pub fn init(
            allocator: std.mem.Allocator,
            reader: Reader,
            opts: CsvOpts,
        ) @This() {
            std.debug.assert(opts.valid());
            return .{
                ._allocator = allocator,
                ._buffer = Fs.init(reader, opts),
            };
        }

        /// Returns the next row in the CSV file
        /// Heap memory is owend by the Row, so call Row.deinit()
        pub fn next(self: *@This()) ?Row {
            if (self._done) {
                return null;
            }
            return self.nextImpl() catch |err| {
                switch (err) {
                    Error.EndOfInput => {
                        self._done = true;
                        return null;
                    },
                    else => {
                        self.err = err;
                        return null;
                    },
                }
            };
        }

        /// Internal implementation, we use errors to indicate end of input
        /// so that we can use errdefer to clean up memory if needed
        fn nextImpl(self: *@This()) Error!?Row {
            if (self.err) |err| {
                return err;
            }

            if (self._buffer.done()) {
                return Error.EndOfInput;
            }

            std.debug.assert(!self._done);

            var row = Row{
                ._fields = std.ArrayList(RowField).init(self._allocator),
                ._bytes = std.ArrayList(u8).init(self._allocator),
            };

            // Doing this defer since so we can track our max field for
            // fewer allocation in the future
            // Not worried about excess memory as much since rows should be
            // short-lived
            // Rows that are long-lived should have a `clone()` called which
            // will trim excess memory on copy
            defer {
                self._row_field_count = @max(self._row_field_count, row._fields.items.len);
                self._row_byte_count = @max(self._row_byte_count, row._bytes.items.len);
            }

            // Cleanup our memory on an error
            errdefer row.deinit();

            try row._fields.ensureTotalCapacity(self._row_field_count);
            try row._bytes.ensureTotalCapacity(self._row_byte_count);
            const row_writer = row._bytes.writer();

            var at_row_end = false;

            // We're only getting the next row, so only iterate over fields
            // until we reach the end of the row
            while (!at_row_end) {
                const start = row._bytes.items.len;

                try self._buffer.next(row_writer);

                const field = RowField{
                    ._pos = start,
                    ._len = row._bytes.items[start..].len,
                };

                // try adding our field to our row
                try row._fields.append(field);
                at_row_end = self._buffer.atRowEnd();
            }
            // Return our row
            return row;
        }
    };
}

/// Initializes a new parser
pub fn init(
    allocator: std.mem.Allocator,
    reader: anytype,
    opts: CsvOpts,
) Parser(@TypeOf(reader)) {
    return Parser(@TypeOf(reader)).init(allocator, reader, opts);
}

test "csv parser empty fields only" {
    const buffer = ",,,,,,";
    var input = std.io.fixedBufferStream(buffer);
    var parser = Parser(
        @TypeOf(input.reader()),
    ).init(std.testing.allocator, input.reader(), .{});

    const expected = [_][7][]const u8{
        [_][]const u8{ "", "", "", "", "", "", "" },
    };

    var er: usize = 0;
    while (parser.next()) |row| {
        defer {
            row.deinit();
            er += 1;
        }
        const e_row = expected[er];

        var ef: usize = 0;
        var iter = row.iter();
        while (iter.next()) |field| {
            defer {
                ef += 1;
            }
            try std.testing.expectEqualStrings(e_row[ef], field.data());
        }
    }
}

test "csv parser empty file" {
    const buffer = "";
    var input = std.io.fixedBufferStream(buffer);
    var parser = Parser(
        @TypeOf(input.reader()),
    ).init(std.testing.allocator, input.reader(), .{});

    const expected = [_][1][]const u8{
        [_][]const u8{""},
    };

    var er: usize = 0;
    while (parser.next()) |row| {
        defer {
            row.deinit();
            er += 1;
        }
        const e_row = expected[er];

        var ef: usize = 0;
        var iter = row.iter();
        while (iter.next()) |field| {
            defer {
                ef += 1;
            }
            try std.testing.expectEqualStrings(e_row[ef], field.data());
        }
    }
}

test "csv parser heap no buffer" {
    const buffer =
        \\userid,name,age,active
        \\1,"John ""Johnny"" Doe",32,yes
        \\2,"Smith, Jack",53,no
        \\3,Peter,18,yes
    ;
    var input = std.io.fixedBufferStream(buffer);
    var parser = Parser(
        @TypeOf(input.reader()),
    ).init(std.testing.allocator, input.reader(), .{});

    const expected = [_][4][]const u8{
        [_][]const u8{ "userid", "name", "age", "active" },
        [_][]const u8{ "1", "John \"Johnny\" Doe", "32", "yes" },
        [_][]const u8{ "2", "Smith, Jack", "53", "no" },
        [_][]const u8{ "3", "Peter", "18", "yes" },
    };

    var er: usize = 0;
    while (parser.next()) |row| {
        defer {
            row.deinit();
            er += 1;
        }
        const e_row = expected[er];

        var ef: usize = 0;
        var iter = row.iter();
        while (iter.next()) |field| {
            defer {
                ef += 1;
            }
            try std.testing.expectEqualStrings(e_row[ef], field.data());
        }
    }
}

test "csv parser stack buffer" {
    const buffer =
        \\userid,name,age,active
        \\1,"John ""Johnny"" Doe",32,yes
        \\2,"Smith, Jack",53,no
        \\3,Peter,18,yes
    ;
    var input = std.io.fixedBufferStream(buffer);
    var parser = Parser(
        @TypeOf(input.reader()),
    ).init(std.testing.allocator, input.reader(), .{});

    const expected = [_][4][]const u8{
        [_][]const u8{ "userid", "name", "age", "active" },
        [_][]const u8{ "1", "John \"Johnny\" Doe", "32", "yes" },
        [_][]const u8{ "2", "Smith, Jack", "53", "no" },
        [_][]const u8{ "3", "Peter", "18", "yes" },
    };

    var er: usize = 0;
    while (parser.next()) |row| {
        defer {
            row.deinit();
            er += 1;
        }
        const e_row = expected[er];

        var ef: usize = 0;
        var iter = row.iter();
        while (iter.next()) |field| {
            defer {
                ef += 1;
            }
            try std.testing.expectEqualStrings(e_row[ef], field.data());
        }
    }
}

test "csv parser stack" {
    const buffer =
        \\userid,name,age,active
        \\1,"John ""Johnny"" Doe",32,yes
        \\2,"Smith, Jack",53,no
        \\3,Peter,18,yes
    ;
    var input = std.io.fixedBufferStream(buffer);
    var parser = Parser(
        @TypeOf(input.reader()),
    ).init(std.testing.allocator, input.reader(), .{});

    const expected = [_][4][]const u8{
        [_][]const u8{ "userid", "name", "age", "active" },
        [_][]const u8{ "1", "John \"Johnny\" Doe", "32", "yes" },
        [_][]const u8{ "2", "Smith, Jack", "53", "no" },
        [_][]const u8{ "3", "Peter", "18", "yes" },
    };

    var er: usize = 0;
    while (parser.next()) |row| {
        defer {
            row.deinit();
            er += 1;
        }
        const e_row = expected[er];

        var ef: usize = 0;
        var iter = row.iter();
        while (iter.next()) |field| {
            defer {
                ef += 1;
            }
            try std.testing.expectEqualStrings(e_row[ef], field.data());
        }
    }
}

test "csv parse into value custom chars" {
    const decode = @import("../decode.zig");
    const User = struct {
        id: i64,
        name: ?[]const u8,
        age: ?u32,
        active: bool,
    };

    const buffer = "userid;name;age;active\\\t1;'John ''Johnny'' Doe';32;yes\t2;'Smith; Jack';53;no\t3;Peter;18;yes\t4;;;no\t";

    var input = std.io.fixedBufferStream(buffer);
    var parser = init(
        std.testing.allocator,
        input.reader(),
        .{
            .column_quote = '\'',
            .column_line_end_prefix = '\\',
            .column_line_end = '\t',
            .column_delim = ';',
        },
    );

    const expected = [_]User{
        User{
            .id = 1,
            .name = "John 'Johnny' Doe",
            .age = 32,
            .active = true,
        },
        User{ .id = 2, .name = "Smith; Jack", .age = 53, .active = false },
        User{ .id = 3, .name = "Peter", .age = 18, .active = true },
        User{ .id = 4, .name = null, .age = null, .active = false },
    };

    var ei: usize = 0;
    while (parser.next()) |row| {
        defer {
            row.deinit();
            ei += 1;
        }
        if (ei == 0) {
            continue;
        }

        const user = User{
            .id = try decode.fieldToInt(i64, try row.field(0), 10) orelse 0,
            .name = decode.fieldToDecodedStr(try row.field(1)),
            .age = try decode.fieldToInt(u32, try row.field(2), 10),
            .active = try decode.fieldToBool(try row.field(3)) orelse false,
        };

        try std.testing.expectEqualDeep(expected[ei - 1], user);
    }
    try std.testing.expectEqual(expected.len + 1, ei);
}

test "csv parse into value" {
    const decode = @import("../decode.zig");
    const User = struct {
        id: i64,
        name: ?[]const u8,
        age: ?u32,
        active: bool,
    };

    const buffer =
        \\userid,name,age,active
        \\1,"John ""Johnny"" Doe",32,yes
        \\2,"Smith, Jack",53,no
        \\3,Peter,18,yes
        \\4,,,no
    ;

    var input = std.io.fixedBufferStream(buffer);
    var parser = init(
        std.testing.allocator,
        input.reader(),
        .{},
    );

    const expected = [_]User{
        User{
            .id = 1,
            .name = "John \"Johnny\" Doe",
            .age = 32,
            .active = true,
        },
        User{ .id = 2, .name = "Smith, Jack", .age = 53, .active = false },
        User{ .id = 3, .name = "Peter", .age = 18, .active = true },
        User{ .id = 4, .name = null, .age = null, .active = false },
    };

    var ei: usize = 0;
    while (parser.next()) |row| {
        defer {
            row.deinit();
            ei += 1;
        }
        if (ei == 0) {
            continue;
        }

        const user = User{
            .id = try decode.fieldToInt(i64, try row.field(0), 10) orelse 0,
            .name = decode.fieldToDecodedStr(try row.field(1)),
            .age = try decode.fieldToInt(u32, try row.field(2), 10),
            .active = try decode.fieldToBool(try row.field(3)) orelse false,
        };

        try std.testing.expectEqualDeep(expected[ei - 1], user);
    }
    try std.testing.expectEqual(expected.len + 1, ei);
}
