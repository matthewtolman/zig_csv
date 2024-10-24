const std = @import("std");
const CsvReadError = @import("common.zig").CsvReadError;
// the volume of memory allocations we do overshadows any performance gains from
// stream_fast by a vast margin
// Using stream since it is better tested, simpler, and easier to verify that it
// is indeed correct
const stream = @import("stream.zig");

/// Represents a CSV field copied to the heap
pub const Field = struct {
    const ParseBoolError = error{
        InvalidBoolInput,
    };
    _data: std.ArrayList(u8),

    /// Returns the string data tied to the field
    pub fn data(self: *const Field) []const u8 {
        return self._data.items;
    }

    /// Frees memory tied to the field
    /// Generally not needed since Row.deinit() will also clear the field memory
    pub fn deinit(self: *Field) void {
        self._data.clearAndFree();
    }

    /// Detaches memory from the field and returns an ArrayList with the memory
    /// Useful when wanting to keep a field's memory past the lifetime of the
    /// row or field
    /// Note: This will set the Field to contain an empty string!
    pub fn detachMemory(self: *Field) std.ArrayList(u8) {
        defer {
            self._data = std.ArrayList(u8).init(self._data.allocator);
        }
        return self._data;
    }

    /// Clones memory using the same allocator that was used to make the field
    /// Useful when wanting to keep a field's memory past the lifetime of the
    /// row or field but wanting to keep the original row memory in-tact
    pub fn clone(self: Field) std.mem.Allocator.Error!std.ArrayList(u8) {
        return self._data.clone();
    }

    /// Clones memory using a specific allocator
    /// Useful when wanting to keep a field's memory past the lifetime of the
    /// row or field but wanting to keep the original row memory in-tact
    pub fn cloneAlloc(
        self: Field,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!std.ArrayList(u8) {
        var copy = std.ArrayList(u8).init(allocator);
        errdefer copy.deinit();
        try copy.resize(self._data.items.len);
        std.mem.copyForwards(u8, copy.items, self._data.items);
        return copy;
    }

    /// Returns a slice string of the data
    /// If the data is empty or equal to "-", will return null instead of an
    /// empty string
    /// If you don't want null, use ".data()"
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
        if (self._pos >= self._row._data.items.len) {
            return null;
        }
        defer self._pos += 1;
        return self._row._data.items[self._pos];
    }
};

/// Represents a CSV row with memory on the heap
/// Make sure to call Row.denit()
/// Row.denit() will clean all memory owned by the Row (including field memory)
pub const Row = struct {
    _data: std.ArrayList(Field),

    /// Cleans up all memory owned by the row (including field memory)
    pub fn deinit(self: Row) void {
        defer self._data.deinit();

        for (self._data.items) |*e| e.deinit();
    }

    /// Returns a slice of all field elements
    pub fn fieldsMut(self: *Row) []Field {
        return self._data.items;
    }

    /// Returns a slice of all field elements
    pub fn fields(self: Row) []const Field {
        return self._data.items;
    }

    /// Returns an iterator over the row
    pub fn iter(self: *const Row) RowIter {
        return .{ ._row = self };
    }
};

/// Options for using FieldStream as underlying parser
pub const FullStreamOpts = struct {
    /// size of the internal buffer
    buff_size: usize = 1_024,
};

/// Options for using FieldStreamPartial as underlying parser
pub const PartialStreamOpts = struct {
    /// Infinite loop safeguard for maximum field size
    max_len: usize = 65_536,
    /// Initial guess for reserving capacity (null = no reserving done)
    capacity: ?usize = null,
};

/// Options union for parser options
pub const ParserOptsUnion = union(enum) {
    heap: PartialStreamOpts,
    stack: FullStreamOpts,
};

/// Parser options
pub const ParserOpts = struct {
    /// Field stream parser options
    buffer: ParserOptsUnion = .{ .heap = .{} },
};

/// Creates a CSV parser over a reader that stores parsed data on the heap
/// Will parse the reader line-by-line instead of all at once
/// Memory is owned by returned rows, so call Row.deinit()
pub fn Parser(comptime Reader: type, comptime opts: ParserOpts) type {
    const Writer = std.ArrayList(u8).Writer;
    const Fs = comptime switch (opts.buffer) {
        .stack => |o| stream.FieldStream(Reader, Writer, o.buff_size),
        .heap => |_| stream.FieldStreamPartial(Reader, Writer),
    };
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

        /// Initializes a CSV parser with an allocator and a reader
        pub fn init(allocator: std.mem.Allocator, reader: Reader) @This() {
            switch (comptime opts.buffer) {
                .stack => |_| return .{
                    ._allocator = allocator,
                    ._buffer = Fs.init(reader),
                },
                .heap => |o| return .{
                    ._allocator = allocator,
                    ._buffer = Fs.init(reader, .{ .max_len = o.max_len }),
                },
            }
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

            var row = Row{ ._data = std.ArrayList(Field).init(self._allocator) };
            // Cleanup our memory on an error
            errdefer row.deinit();

            var at_row_end = false;

            switch (comptime opts.buffer) {
                .heap => |p| {
                    // Internal buffer for receiving fields
                    // This should minimize the number of allocations when using
                    // the partial buffer
                    var buffer = std.ArrayList(u8).init(self._allocator);
                    defer buffer.deinit();

                    if (comptime p.capacity) |capacity| {
                        try buffer.ensureTotalCapacity(capacity);
                    }

                    // We're only getting the next row, so only iterate over fields
                    // until we reach the end of the row
                    while (!at_row_end) {
                        defer buffer.clearRetainingCapacity();

                        try self._buffer.next(buffer.writer());

                        var field = Field{
                            ._data = std.ArrayList(u8).init(self._allocator),
                        };

                        // Clean up our field memory if we have an error
                        errdefer field.deinit();

                        // Copy over just what's needed
                        try field._data.appendSlice(buffer.items);

                        // try adding our field to our row
                        try row._data.append(field);
                        at_row_end = self._buffer.atRowEnd();
                    }
                },
                else => {
                    while (!at_row_end) {
                        // Clean up our field memory if we have an error
                        var field = Field{
                            ._data = std.ArrayList(u8).init(self._allocator),
                        };

                        errdefer field.deinit();

                        try self._buffer.next(field._data.writer());

                        // try adding our field to our row
                        try row._data.append(field);
                        at_row_end = self._buffer.atRowEnd();
                    }
                },
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
    comptime opts: ParserOpts,
) Parser(@TypeOf(reader), opts) {
    return Parser(@TypeOf(reader), opts).init(allocator, reader);
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
        .{ .buffer = .{ .heap = .{} } },
    ).init(std.testing.allocator, input.reader());

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
        .{ .buffer = .{ .heap = .{ .capacity = 35 } } },
    ).init(std.testing.allocator, input.reader());

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
        .{ .buffer = .{ .stack = .{ .buff_size = 256 } } },
    ).init(std.testing.allocator, input.reader());

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
            .id = try row.fields()[0].asInt(i64, 10) orelse 0,
            .name = row.fields()[1].asSlice(),
            .age = try row.fields()[2].asInt(u32, 10),
            .active = try row.fields()[3].asBool() orelse false,
        };

        try std.testing.expectEqualDeep(expected[ei - 1], user);
    }
}

test "csv detach memory" {
    const UserMem = struct {
        id: i64,
        name: std.ArrayList(u8),
        age: ?u32,
        active: bool,
    };

    const User = struct {
        id: i64,
        name: []const u8,
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
        User{ .id = 4, .name = "", .age = null, .active = false },
    };

    var actual_mem: [expected.len]UserMem = undefined;
    var actual: [expected.len]User = undefined;

    var ei: usize = 0;
    var row: Row = undefined;
    while (true) {
        row = parser.next() orelse break;
        defer {
            row.deinit();
            ei += 1;
        }
        if (ei == 0) {
            continue;
        }

        actual_mem[ei - 1] = UserMem{
            .id = try row.fieldsMut()[0].asInt(i64, 10) orelse 0,
            .name = row.fieldsMut()[1].detachMemory(),
            .age = try row.fieldsMut()[2].asInt(u32, 10),
            .active = try row.fieldsMut()[3].asBool() orelse false,
        };
        actual[ei - 1] = User{
            .id = actual_mem[ei - 1].id,
            .name = actual_mem[ei - 1].name.items,
            .age = actual_mem[ei - 1].age,
            .active = actual_mem[ei - 1].active,
        };
    }

    try std.testing.expectEqualDeep(expected, actual);

    for (actual_mem) |m| {
        m.name.deinit();
    }
}
