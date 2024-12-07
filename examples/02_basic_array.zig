// This example parses an in-memory buffer and then prints the parsed fields
// Fields are printed as-is (no escaping or unescaping)

const zcsv = @import("zcsv");
const std = @import("std");

pub fn main() !void {
    std.log.info("Enter CSV text to parse", .{});

    const buf =
        \\"hello""world""",123,yes
        \\"John","doe",no
    ;

    var parser = zcsv.zero_allocs.slice.init(buf, .{});
    while (parser.next()) |row| {
        std.log.info("New row", .{});
        var iter = row.iter();
        while (iter.next()) |field| {
            std.log.info("Found: {s}", .{field.raw()});
        }
    }
    std.log.info("DONE!", .{});
}
