// This will take an array of users and print them to stderr as a CSV file
const zcsv = @import("zcsv");
const std = @import("std");

const User = struct {
    id: i64,
    name: []const u8,
    age: ?u16,

    pub fn format(
        self: User,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("User {{ id: {d}, name: {s}, age: {any} }}", .{
            self.id, self.name, self.age,
        });
    }
};

pub fn main() !void {
    const users = [_]User{
        User{ .id = 1, .name = "John Doe", .age = null },
        User{ .id = 2, .name = "Robert \"Bob\" Duncan", .age = 54 },
        User{ .id = 3, .name = "Alfredo \"Sauce\" Jr.", .age = 3 },
    };

    // get our writer
    const writer = std.io.getStdErr().writer();

    // write our header
    try zcsv.writer.row(writer, .{ "userid", "name", "age" });

    // Write our data
    for (users) |u| {
        try zcsv.writer.row(writer, .{ u.id, u.name, u.age });
    }
}
