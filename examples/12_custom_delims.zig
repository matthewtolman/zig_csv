// This example will parse Tab delimited with single quotes from memory and
// then print the data as CSV rows

const zcsv = @import("zcsv");
const std = @import("std");

pub fn main() !void {
    // Get our allocator since we'll use an allocating parser
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const state = gpa.deinit();
        if (state == .leak) {
            std.log.err("MEMORY LEAK DETECTED!\n", .{});
            unreachable;
        }
    }
    const allocator = gpa.allocator();

    const stderr = std.io.getStdErr().writer();

    const csv =
        "productid\tproductname\tproductsales\n\\1238943\t'''Juice'' Box'\t9238\n\\3892392\t'I can''t believe it''s not chicken!'\t480\n\\5934810\t'Win The Fish'\t-";

    var buff = std.io.fixedBufferStream(csv);

    // Get our parser
    var parser = zcsv.column.init(allocator, buff.reader(), .{
        .column_delim = '\t',
        .column_quote = '\'',
    });

    // Parse a new row
    while (parser.next()) |row| {
        defer {
            // Clean up memory
            row.deinit();
            // Write a newline
            stderr.writeAll("\r\n") catch unreachable;
        }

        // Iterate over our row fields
        var fieldIter = row.iter();
        var first = true;
        while (fieldIter.next()) |field| {
            // Print a comma if we aren't the first row
            defer first = false;
            if (!first) try stderr.writeByte(',');

            // Write the value as a valid CSV string
            try zcsv.writer.value(stderr, field.data(), .{});
        }
    }

    // Error handling
    if (parser.err) |err| {
        std.log.err("Error: {}", .{err});
    }
}
