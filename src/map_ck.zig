const std = @import("std");
const p = @import("column.zig");

pub const Field = p.Field;
pub const Row = struct {
    _header_mem: std.ArrayList(std.ArrayList(u8)),
    _map: std.StringHashMap(Field),

    pub fn data(self: *const @This()) *const std.StringHashMap(Field) {
        return &self._map;
    }

    pub fn deinit(self: @This()) void {
        {
            var valIt = self._map.valueIterator();
            while (valIt.next()) |v| {
                v.deinit();
            }
            var shallowCopy = self._map;
            shallowCopy.deinit();
        }
        {
            for (self._header_mem.items) |elem| {
                elem.deinit();
            }
            self._header_mem.deinit();
        }
    }
};

/// A parser that parses a CSV file into a map with keys copied for each row
/// The lifetime of a row's keys are independent of each other
/// The parser does hold a copy of headers which needs to be freed when done
pub fn Parser(comptime Reader: type) type {
    return struct {
        pub const Error = p.Parser(Reader).Error || error{NoHeaderForColumn};
        _lineParser: p.Parser(Reader),
        _header: p.Row,
        _alloc: std.mem.Allocator,
        err: ?Error = null,

        /// Creates a new map-based parser
        pub fn init(allocator: std.mem.Allocator, reader: Reader) !@This() {
            var parser = p.init(allocator, reader);
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
                return error.NoHeaderRow;
            }
        }

        /// Frees the header-related memory
        /// Note: this will free the memory for all keys for any maps returned by next
        pub fn deinit(self: @This()) void {
            self._header.deinit();
        }

        /// Returns a map of the next row
        /// Both the map and the values of the map need to be cleaned by the caller
        pub fn next(self: *@This()) ?Row {
            if (self.err) |_| {
                return null;
            }

            var row: p.Row = self._lineParser.next() orelse {
                if (self._lineParser.err) |err| {
                    self.err = err;
                }
                return null;
            };
            defer row.deinit();

            if (self._lineParser.err) |err| {
                self.err = err;
                return null;
            }

            return nextImpl(self, &row) catch |e| {
                self.err = e;
                return null;
            };
        }

        fn nextImpl(self: *@This(), row: *p.Row) Error!?Row {
            var fields = row.fieldsMut();
            var res = Row{
                ._header_mem = std.ArrayList(std.ArrayList(u8)).init(self._alloc),
                ._map = std.StringHashMap(Field).init(self._alloc),
            };
            // Clean up our memory
            errdefer res.deinit();

            // Reserve capacity for our headers copy
            try res._header_mem.ensureTotalCapacity(self._header.fields().len);

            // copy header memory
            for (self._header.fields()) |h| {
                var h_mem = std.ArrayList(u8).init(self._alloc);
                errdefer h_mem.deinit();

                // Resize and then mem copy
                try h_mem.resize(h.data().len);
                std.mem.copyForwards(u8, h_mem.items, h.data());
                try res._header_mem.append(h_mem);
            }

            for (fields, 0..) |_, i| {
                if (i >= res._header_mem.items.len) {
                    return Error.NoHeaderForColumn;
                }

                // get a slice from our self-contained header data
                const header = res._header_mem.items[i].items;

                // Avoid memory leaks when headers are duplicated
                if (res._map.contains(header)) {
                    res._map.getPtr(header).?.deinit();
                }

                // Put our field in the memory and reattach memory scope
                try res._map.put(header, Field{ ._data = fields[i].detachMemory() });
            }

            return res;
        }
    };
}

/// Initializes a parser that parses a CSV file into a map with keys copied for
/// each row
/// The lifetime of a row's keys are independent of each other
/// The parser does hold a copy of headers which needs to be freed when done
pub fn init(allocator: std.mem.Allocator, reader: anytype) !Parser(@TypeOf(reader)) {
    return Parser(@TypeOf(reader)).init(allocator, reader);
}

test "csv parse into map ck" {
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
    var parser = try init(std.testing.allocator, input.reader());
    defer parser.deinit();

    const expected = [_]User{
        User{ .id = 1, .name = "John \"Johnny\" Doe", .age = 32, .active = true },
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
            .id = try (row.data().get("userid").?.asInt(i64, 10)) orelse 0,
            .name = row.data().get("name").?.asSlice(),
            .age = try (row.data().get("age").?.asInt(u32, 10)),
            .active = try (row.data().get("active").?.asBool()) orelse false,
        };

        try std.testing.expectEqualDeep(expected[ei], user);
    }
}
