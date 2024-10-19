// This file will take a CLI argument for a file and then parse that CSV file
// It will then put everything into an array of structs and detach the memory
// from the row of memory

const zcsv = @import("zcsv");
const std = @import("std");

const User = struct {
    id: i64,
    name: std.ArrayList(u8),
    age: ?u16,

    pub fn deinit(self: User) void {
        self.name.deinit();
    }

    pub fn format(
        self: User,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("User {{ id: {d}, name: {s}, age: {any} }}", .{
            self.id, self.name.items, self.age,
        });
    }
};

pub fn main() !void {
    // Get our allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Figure out which file to load
    var args = std.process.args();
    _ = args.skip();

    const file = args.next() orelse "test.csv";
    // Parse our file
    const users = try parseFile(alloc, file);

    // Make sure we cleanup our users
    defer {
        for (users.items) |*u| {
            // Comment out this line to see a memory leak
            defer u.deinit();
        }
        users.deinit();
    }

    // Print out users
    for (users.items) |*u| {
        std.log.info("User: {any}", .{u});
    }
}

const Errors = error{ BadHeader, MissingFields };

pub fn parseFile(alloc: std.mem.Allocator, fileName: []const u8) !std.ArrayList(User) {
    // Open our file
    const file = try std.fs.cwd().openFile(fileName, .{});
    defer file.close();

    var res = std.ArrayList(User).init(alloc);
    errdefer res.deinit();

    // We can read directly from our file reader
    var parser = zcsv.column.init(alloc, file.reader());

    var columns = std.StringHashMap(usize).init(alloc);
    defer columns.deinit();

    var maxIndex: usize = 0;

    // Parse all of our rows
    // We need it mutable for detachMemory to work
    var row: zcsv.column.Row = undefined;
    while (true) {
        row = parser.next() orelse break;
        // Clean up our memory
        defer row.deinit();

        // Process our header row and make a map of column => value mappings
        if (columns.count() == 0) {
            var fieldIter = row.iter();

            var index: usize = 0;
            while (fieldIter.next()) |field| {
                defer index += 1;

                // Put our columns into the map
                if (std.mem.eql(u8, field.data(), "userid")) {
                    try columns.put("id", index);
                    maxIndex = index;
                }
                if (std.mem.eql(u8, field.data(), "name")) {
                    try columns.put("name", index);
                    maxIndex = index;
                }
                if (std.mem.eql(u8, field.data(), "age")) {
                    try columns.put("age", index);
                    maxIndex = index;
                }
            }

            if (columns.count() != 3) {
                return Errors.BadHeader;
            }
            continue;
        }

        // For eachfield
        const fields = row.fieldsMut();
        if (maxIndex >= fields.len) {
            return Errors.MissingFields;
        }

        try res.append(User{
            .id = (try fields[columns.get("id").?].asInt(i64, 10)).?,
            .name = fields[columns.get("name").?].detachMemory(),
            .age = try fields[columns.get("age").?].asInt(u16, 10),
        });
    }

    if (parser.err) |err| {
        return err;
    }

    return res;
}
