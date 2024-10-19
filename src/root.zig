pub const raw = @import("raw.zig");
pub const stream = @import("stream.zig");
pub const parser = @import("parser.zig");
pub const writer = @import("writer.zig");
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
    _ = parser.Parser(void);
    _ = try writer.row(buff.writer(), .{ 1, "hello", false });
}
