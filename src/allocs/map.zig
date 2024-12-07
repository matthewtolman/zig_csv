const std = @import("std");
const column = @import("column.zig");

pub const Field = column.Field;

pub const CsvOpts = column.CsvOpts;

/// Represents a CSV row
pub const Row = struct {
    _header_row: ?column.Row,
    _map: std.StringHashMap(Field),
    _orig_row: column.Row,

    /// Length of the row
    pub fn len(self: *const @This()) usize {
        return self._orig_row.len();
    }

    /// Returns a const pointer to the underlying map
    pub fn data(self: *const @This()) *const std.StringHashMap(Field) {
        return &self._map;
    }

    /// Returns the field at a column or null if not present
    pub fn at(self: *const @This(), column_name: []const u8) ?Field {
        return self._map.get(column_name);
    }

    /// Cleans up the data held by the row (including the copy of keys)
    pub fn deinit(self: @This()) void {
        if (self._header_row) |header| {
            header.deinit();
        }
        var shallowCopy = self._map;
        shallowCopy.deinit();
        self._orig_row.deinit();
    }
};

/// Clones a row and its memory
fn cloneRow(self: column.Row, alloc: std.mem.Allocator) !column.Row {
    var new = column.Row{
        ._fields = std.ArrayList(column.RowField).init(alloc),
        ._bytes = std.ArrayList(u8).init(alloc),
    };

    errdefer new.deinit();

    try new._fields.resize(self._fields.items.len);
    try new._bytes.resize(self._bytes.items.len);

    std.mem.copyForwards(column.RowField, new._fields.items, self._fields.items);
    std.mem.copyForwards(u8, new._bytes.items, self._bytes.items);

    return new;
}

/// A parser that parses a CSV file into a map with keys copied for each row
/// The lifetime of a row's keys are independent of each other
/// The parser does hold a copy of headers which needs to be freed when done
pub fn Parser(comptime Reader: type) type {
    const ColParser = column.Parser(Reader);
    return struct {
        pub const Rows = Row;
        pub const Error = ColParser.Error || error{NoHeaderForColumn};
        pub const InitError = Error || error{NoHeaderRow};
        _lineParser: ColParser,
        _header: column.Row,
        _alloc: std.mem.Allocator,
        err: ?Error = null,

        /// Creates a new map-based parser
        pub fn init(
            allocator: std.mem.Allocator,
            reader: Reader,
            opts: column.CsvOpts,
        ) InitError!@This() {
            var parser = column.init(allocator, reader, opts);
            const row = parser.next();
            if (parser.err) |err| {
                return err;
            }

            if (row) |r| {
                return .{
                    ._lineParser = parser,
                    ._header = r,
                    ._alloc = allocator,
                };
            } else {
                return InitError.NoHeaderRow;
            }
        }

        /// Frees the parser-related memory
        pub fn deinit(self: @This()) void {
            self._header.deinit();
        }

        /// Returns a map of the next row
        /// Both the map and the values of the map need to be cleaned by the
        /// caller
        pub fn next(self: *@This()) ?Row {
            if (self.err) |_| {
                return null;
            }

            var row: column.Row = self._lineParser.next() orelse {
                if (self._lineParser.err) |err| {
                    self.err = err;
                }
                return null;
            };
            defer row.deinit();

            if (self._lineParser.err) |err| {
                defer row.deinit();
                self.err = err;
                return null;
            }

            // row deinit handled by nextImpl
            return nextImpl(self, row) catch |e| {
                self.err = e;
                return null;
            };
        }

        fn nextImpl(self: *@This(), row: column.Row) Error!?Row {
            var res = Row{
                ._header_row = try cloneRow(self._header, self._alloc),
                ._map = std.StringHashMap(Field).init(self._alloc),
                ._orig_row = try cloneRow(row, self._alloc),
            };
            // Clean up our memory
            errdefer res.deinit();

            try res._map.ensureTotalCapacity(@truncate(self._header.len()));

            for (0..res._orig_row.len()) |i| {
                if (i >= res._header_row.?.len()) {
                    return Error.NoHeaderForColumn;
                }

                // Put our field in the memory and reattach memory scope
                try res._map.put(
                    (res._header_row.?.field(i) catch unreachable).data(),
                    (res._orig_row.field(i) catch unreachable),
                );
            }

            return res;
        }
    };
}

/// Initializes a parser that parses a CSV file into a map with keys copied for
/// each row
/// The lifetime of a row's keys are independent of each other
/// The parser does hold a copy of headers which needs to be freed when done
pub fn init(
    allocator: std.mem.Allocator,
    reader: anytype,
    opts: column.CsvOpts,
) !Parser(@TypeOf(reader)) {
    return Parser(@TypeOf(reader)).init(allocator, reader, opts);
}

test "csv parse into map ck" {
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
    var parser = try init(std.testing.allocator, input.reader(), .{});
    defer parser.deinit();

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

        const user = User{
            .id = try decode.fieldToInt(
                i64,
                row.data().get("userid").?,
                10,
            ) orelse 0,
            .name = decode.fieldToDecodedStr(row.data().get("name").?),
            .age = try decode.fieldToInt(
                u32,
                row.data().get("age").?,
                10,
            ),
            .active = try decode.fieldToBool(
                row.data().get("active").?,
            ) orelse false,
        };

        try std.testing.expectEqualDeep(expected[ei], user);
    }
    try std.testing.expectEqual(expected.len, ei);
}

test "csv parse into map ck larger" {
    const decode = @import("../decode.zig");
    const User = struct {
        id: i64,
        name: ?[]const u8,
        age: ?u32,
        active: bool,
    };

    const growth = 125;

    const buffer =
        \\userid,name,age,active
        \\1,"John ""Johnny"" Doe",32,yes
        \\2,"Smith, Jack",53,no
        \\3,Peter,18,yes
        \\4,,,no
    ++ ("\r\n5,\"\"\"Jack\"\"\",99,no" ** growth);

    var input = std.io.fixedBufferStream(buffer);
    var parser = try init(std.testing.allocator, input.reader(), .{});
    defer parser.deinit();

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
    } ++ ([_]User{User{ .id = 5, .name = "\"Jack\"", .age = 99, .active = false }} ** growth);

    var ei: usize = 0;
    while (parser.next()) |row| {
        defer {
            row.deinit();
            ei += 1;
        }

        const user = User{
            .id = try decode.fieldToInt(
                i64,
                row.data().get("userid").?,
                10,
            ) orelse 0,
            .name = decode.fieldToDecodedStr(row.data().get("name").?),
            .age = try decode.fieldToInt(
                u32,
                row.data().get("age").?,
                10,
            ),
            .active = try decode.fieldToBool(
                row.data().get("active").?,
            ) orelse false,
        };

        try std.testing.expectEqualDeep(expected[ei], user);
    }

    try std.testing.expectEqual(expected.len, ei);
}
