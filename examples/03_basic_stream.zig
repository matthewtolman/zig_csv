// This example will print the rows and fields from stdin

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

    var parser = zcsv.zero_allocs.stream.init(reader, @TypeOf(stderr), .{});
    std.log.info("Enter CSV to parse", .{});

    try stderr.print("> ", .{});
    // The writer is passed to each call to next
    // This allows us to use a different writer per field
    //
    // next does throw if it has an error.
    // next will return `false` when it hits the end of the input
    while (!parser.done()) {
        try parser.next(stderr);
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
