// This file will take a CLI argument for a file and then parse that CSV file

const zcsv = @import("zcsv");
const std = @import("std");

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();

    const file = args.next() orelse "test.csv";
    try parseFile(file);
}

pub fn parseFile(fileName: []const u8) !void {
    // Get our allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Open our file
    const file = try std.fs.cwd().openFile(fileName, .{});
    defer file.close();

    // We can read directly from our file reader
    var parser = zcsv.column.init(alloc, file.reader());
    while (parser.next()) |row| {
        // Clean up our memory
        defer row.deinit();

        try std.io.getStdErr().writeAll("\nROW:");

        // Iterate over our fields
        var fieldIter = row.iter();
        while (fieldIter.next()) |field| {
            try std.io.getStdErr().writeAll(" Field: ");
            try std.io.getStdErr().writeAll(field.data());
        }
    }
}
