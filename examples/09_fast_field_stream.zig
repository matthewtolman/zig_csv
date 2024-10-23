// This example shows how to use the fast CSV field parser
// Note: the fast parser does NOT do CSV decoding by default

const zcsv = @import("zcsv");
const std = @import("std");

pub fn main() !void {
    // Get reader and writer
    const csv =
        \\productid,productname,productsales
        \\1238943,"""Juice"" Box",9238
        \\3892392,"I can't believe it's not chicken!",480
        \\5934810,"Win The Fish",-
    ;
    const stderr = std.io.getStdErr().writer();
    var buff = std.io.fixedBufferStream(csv);
    const reader = buff.reader();

    var tmp_bytes: [1024]u8 = undefined;
    var tmp_buff = std.io.fixedBufferStream(&tmp_bytes);
    var parser = zcsv.stream_fast.init(reader, @TypeOf(tmp_buff).Writer, .{});
    std.log.info("Enter CSV to parse", .{});

    try stderr.print("> ", .{});
    // The writer is passed to each call to next
    // This allows us to use a different writer per field
    while (!parser.done()) {
        // We have to manually decode the field
        try parser.next(tmp_buff.writer());
        try zcsv.core.decode(tmp_buff.getWritten(), stderr);
        // Do whatever you need to here for the field

        // This is how you can tell if you're about to move to the next row
        // Note that we aren't at the next row, just that we're about to move
        if (parser.atRowEnd()) {
            if (!parser.done()) {
                try stderr.print("\n> ", .{});
            } else {
                try stderr.print("\nClosing...\n", .{});
            }
        } else {
            try stderr.print("\t", .{});
        }
    }
}
