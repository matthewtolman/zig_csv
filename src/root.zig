/// Slow but simple CSV parser which iterates over rows and fields
/// Does not decode any fields, requires CSV file to be in memory
/// #zeroallocation
pub const zero_allocs = @import("zero_allocs.zig");
/// Collection of fast CSV parsers which operate on a CSV file in memory
/// #zeroallocation
pub const allocs = @import("allocs.zig");
/// CSV writer which writes to a writer
/// It is able to handle many different raw zig fields such as ints, bools,
/// floats, and []u8
pub const writer = @import("writer.zig");

/// CSV to Zig value decoding methods
/// These are opinionated, but the source can be useful for making your own
pub const decode = @import("decode.zig");
pub const CsvWriteError = @import("common.zig").CsvWriteError;
pub const CsvReadError = @import("common.zig").CsvReadError;
pub const ParseBoolError = @import("common.zig").ParseBoolError;

// since zig is lazy, we want to actually trigger compiling all of our files
// this allows us to run tests, and it allows us to catch syntax errors
test "parse imports" {
    const std = @import("std");

    // buffer for reading stuff from
    var buf: [3]u8 = undefined;
    buf[0] = 'a';
    buf[1] = '\n';
    buf[2] = 'n';
    var buff = std.io.fixedBufferStream(&buf);
    const Writer = @TypeOf(buff).Writer;
    _ = zero_allocs.slice.init("", .{});
    _ = zero_allocs.stream.init(buff.reader(), Writer, .{});
    _ = allocs.column.init(std.testing.allocator, buff.reader(), .{});

    const m = try allocs.map.init(std.testing.allocator, buff.reader(), .{});
    defer m.deinit();

    const mt = try allocs.map_temporary.init(std.testing.allocator, buff.reader(), .{});
    defer mt.deinit();
}

test "write imports" {
    const std = @import("std");

    // buffer for writing stuff to
    // Not using stdout because that blocks when doing build test
    var buf: [500]u8 = undefined;
    var buff = std.io.fixedBufferStream(&buf);
    _ = try writer.row(buff.writer(), .{ 1, "hello", false }, .{});
}
