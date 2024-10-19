pub const raw = @import("raw.zig");
pub const stream = @import("stream.zig");
pub const column = @import("column.zig");
pub const writer = @import("writer.zig");
pub const map_sk = @import("map_sk.zig");
pub const map_ck = @import("map_ck.zig");
pub const CsvWriteError = @import("common.zig").CsvWriteError;
pub const CsvReadError = @import("common.zig").CsvReadError;

test "imports" {
    const std = @import("std");

    // buffer for writing stuff to
    // Not using stdout because that blocks when doing build test
    var buf: [1000]u8 = undefined;
    var buff = std.io.fixedBufferStream(&buf);
    _ = raw.Parser.init("");
    _ = stream.FieldStream(void, void);
    _ = column.Parser(void);
    _ = try writer.row(buff.writer(), .{ 1, "hello", false });
    _ = map_sk.Parser(void);
    _ = map_ck.Parser(void);
}
