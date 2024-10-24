const std = @import("std");
const CsvReadError = @import("common.zig").CsvReadError;
const ParserLimitOpts = @import("common.zig").ParserLimitOpts;

// the volume of memory allocations we do overshadows any performance gains from
// stream_fast by a vast margin
// Using stream since it is better tested, simpler, and easier to verify that it
// is indeed correct
const stream = @import("stream.zig");

/// Internal representation of a field in a row
pub const RowField = struct {
    _pos: usize,
    _len: usize,

    pub fn toField(self: RowField, row: *const Row) Field {
        std.debug.assert(self._pos <= row._bytes.items.len);
        std.debug.assert(self._pos + self._len <= row._bytes.items.len);
        return Field{ ._data = row._bytes.items[self._pos..][0..self._len] };
    }
};

/// Represents a CSV field copied to the heap
pub const Field = struct {
    const ParseBoolError = error{
        InvalidBoolInput,
    };
    // This references an internal buffer in the row
    _data: []const u8,

    /// Returns the string data tied to the field
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

    /// Returns a slice string of the data
    /// If the data is empty or equal to "-", will return null instead of an
    /// empty string
    /// If you don't want null, use ".data()"
    /// Note: the data lifetime is tied to the CSV row lifetime
    pub fn asSlice(self: *const Field) ?[]const u8 {
        if (self.isNull()) {
            return null;
        }
        return self.data();
    }

    /// Checks if a value is "null"-like
    /// Null is either the empty string or "-"
    pub fn isNull(self: *const Field) bool {
        if (self.data().len == 0 or std.mem.eql(u8, "-", self.data())) {
            return true;
        }
        return false;
    }

    /// Parses a field into a nullable integer ("" and "-" == null)
    pub fn asInt(
        self: Field,
        comptime T: type,
        base: u8,
    ) std.fmt.ParseIntError!?T {
        if (self.isNull()) {
            return null;
        }
        const ti = @typeInfo(T);
        // Zig 0.13.0 uses SnakeCase
        // Zig 0.14.0-dev uses lower_case
        if (@hasField(@TypeOf(ti), "Int")) {
            if (comptime ti.Int.signedness == .unsigned) {
                const v: T = try std.fmt.parseUnsigned(T, self.data(), base);
                return v;
            } else {
                const v: T = try std.fmt.parseInt(T, self.data(), base);
                return v;
            }
        } else {
            if (comptime ti.int.signedness == .unsigned) {
                const v: T = try std.fmt.parseUnsigned(T, self.data(), base);
                return v;
            } else {
                const v: T = try std.fmt.parseInt(T, self.data(), base);
                return v;
            }
        }
    }

    /// Parses a field into a nullable float ("" and "-" == null)
    pub fn asFloat(self: Field, comptime T: type) std.fmt.ParseFloatError!?T {
        if (self.isNull()) {
            return null;
        }
        return std.fmt.parseFloat(T, self.data());
    }

    /// Parses a field into a nullable bool ("" and "-" == null)
    /// Truthy values (case insensitive):
    ///     yes, y, true, t, 1
    /// Falsey values (case insensitive):
    ///     no, n, false, f, 0
    pub fn asBool(self: Field) ParseBoolError!?bool {
        if (self.isNull()) {
            return null;
        }
        if (std.mem.eql(u8, "1", self.data())) {
            return true;
        }
        if (std.mem.eql(u8, "0", self.data())) {
            return false;
        }

        var lower: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
        var end: usize = 0;
        for (0..lower.len) |i| {
            end = i;
            if (i >= self.data().len) {
                break;
            }
            lower[i] = self.data()[i] | 0b0100000;
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
    _fields: std.ArrayList(RowField),
    /// Holds the byte data for all of the fields
    _bytes: std.ArrayList(u8),

    /// Cleans up all memory owned by the row (including field memory)
    pub fn deinit(self: Row) void {
        defer self._fields.deinit();
        defer self._bytes.deinit();
    }

    pub fn len(self: *const Row) usize {
        return self._fields.items.len;
    }

    pub fn field(self: *const Row, index: usize) !Field {
        if (index >= self.len()) {
            return error.IndexOutOfBounds;
        }
        return self._fields.items[index].toField(self);
    }

    pub fn clone(self: *const Row, alloc: std.mem.Allocator) !Row {
        var new = Row{
            ._fields = std.ArrayList(RowField).init(alloc),
            ._bytes = std.ArrayList(u8).init(alloc),
        };

        errdefer new.deinit();

        try new._fields.resize(self._fields.items.len);
        try new._bytes.resize(self._bytes.items.len);

        std.mem.copyForwards(RowField, new._fields.items, self._fields.items);
        std.mem.copyForwards(u8, new._bytes.items, self._bytes.items);

        return new;
    }

    /// Returns an iterator over the row
    pub fn iter(self: *const Row) RowIter {
        return .{ ._row = self };
    }
};

/// Parser options
pub const ParserOpts = struct {
    limits: ParserLimitOpts = .{},
};

/// Creates a CSV parser over a reader that stores parsed data on the heap
/// Will parse the reader line-by-line instead of all at once
/// Memory is owned by returned rows, so call Row.deinit()
pub fn Parser(comptime Reader: type) type {
    const Writer = std.ArrayList(u8).Writer;
    const Fs = stream.FieldStreamPartial(Reader, Writer);
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
            opts: ParserOpts,
        ) @This() {
            return .{
                ._allocator = allocator,
                ._buffer = Fs.init(reader, opts.limits),
            };
        }

        /// Returns the next row in the CSV file
        /// Heap memory is owend by the Row, so call Row.deinit()
        pub fn next(self: *@This()) ?Row {
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
                return null;
            }

            var row = Row{
                ._fields = std.ArrayList(RowField).init(self._allocator),
                ._bytes = std.ArrayList(u8).init(self._allocator),
            };

            // Doing this defer since we don't want to access a deinitialized
            // row when there's an error
            defer {
                self._row_field_count = @max(self._row_field_count, row._fields.items.len);
                self._row_byte_count = @max(self._row_byte_count, row._bytes.items.len);
            }

            // Cleanup our memory on an error
            errdefer row.deinit();

            try row._fields.ensureTotalCapacity(self._row_field_count);
            try row._bytes.ensureTotalCapacity(self._row_byte_count);

            var at_row_end = false;

            // We're only getting the next row, so only iterate over fields
            // until we reach the end of the row
            while (!at_row_end) {
                const start = row._bytes.items.len;

                try self._buffer.next(row._bytes.writer());

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
    opts: ParserOpts,
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

test "csv parse into value" {
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
            .id = try (try row.field(0)).asInt(i64, 10) orelse 0,
            .name = (try row.field(1)).asSlice(),
            .age = try (try row.field(2)).asInt(u32, 10),
            .active = try (try row.field(3)).asBool() orelse false,
        };

        try std.testing.expectEqualDeep(expected[ei - 1], user);
    }
}
