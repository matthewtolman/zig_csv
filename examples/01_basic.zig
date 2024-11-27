// This example will parse CSV from memory and then print CSV rows

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
        \\productid,productname,productsales
        \\1238943,"""Juice"" Box",9238
        \\3892392,"I can't believe it's not chicken!",480
        \\5934810,"Win The Fish",-
    ;

    var buff = std.io.fixedBufferStream(csv);

    // Get our parser
    var parser = zcsv.column.init(allocator, buff.reader(), .{});

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
