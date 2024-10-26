/// Slow but simple CSV parser which iterates over rows and fields
/// Does not decode any fields, requires CSV file to be in memory
/// #zeroallocation
pub const raw = @import("raw.zig");
/// Collection of fast CSV parsers which operate on a CSV file in memory
/// #zeroallocation
pub const slice = @import("slice.zig");
/// Slow but simple CSV parser which operates on readers/writers
/// #zeroallocation
pub const stream = @import("stream.zig");
/// Fast CSV parser which operates on readers/writers
/// #zeroallocation
pub const stream_fast = @import("stream_fast.zig");
/// CSV writer which writes to a writer
/// It is able to handle many different raw zig fields such as ints, bools,
/// floats, and []u8
pub const writer = @import("writer.zig");
/// Columnar CSV parser which automatically decodes fields
/// Does perform memory allocations, very slow
pub const column = @import("column.zig");
/// Map-based CSV parser which puts rows into a map of fields
/// Does performa memory allocations, very slow
/// Does try to minimize allocations by sharing header memory across rows
pub const map_sk = @import("map_sk.zig");
/// Map-based CSV parser which puts rows into a map of fields
/// Does performa memory allocations, very slow
/// Copies header memory for every row
pub const map_ck = @import("map_ck.zig");
/// Core methods to use for decoding raw values
pub const core = @import("common.zig");
pub const CsvWriteError = @import("common.zig").CsvWriteError;
pub const CsvReadError = @import("common.zig").CsvReadError;
pub const ParseBoolError = @import("common.zig").ParseBoolError;

// since zig is lazy, we want to actually trigger compiling all of our files
// this allows us to run tests, and it allows us to catch syntax errors
test "imports" {
    const std = @import("std");

    // buffer for writing stuff to
    // Not using stdout because that blocks when doing build test
    var buf: [1000]u8 = undefined;
    var buff = std.io.fixedBufferStream(&buf);
    const Reader = @TypeOf(buff.reader());
    const Writer = @TypeOf(buff.writer());
    _ = raw.init("", .{});
    _ = slice.fields.init("", .{});
    _ = stream.Parser(Reader, Writer);
    _ = stream_fast.Parser(Reader, Writer);
    _ = column.Parser(Reader);
    _ = try writer.row(buff.writer(), .{ 1, "hello", false });
    _ = map_sk.Parser(Reader);
    _ = map_ck.Parser(Reader);
}
