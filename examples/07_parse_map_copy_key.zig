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

/// Parses a CSV file into a list of users
pub fn parseFile(alloc: std.mem.Allocator, fileName: []const u8) !std.ArrayList(User) {
    // Open our file
    const file = try std.fs.cwd().openFile(fileName, .{});
    defer file.close();

    var res = std.ArrayList(User).init(alloc);
    errdefer res.deinit();

    // We can read directly from our file reader
    var parser = try zcsv.map_ck.init(alloc, file.reader(), .{});

    // We do need to deinitialize this parser to free it's copy of the header
    defer parser.deinit();

    while (parser.next()) |row| {
        // Clean up our memory
        // With map_ck our row memory can outlive our parser memory
        // This is because the row headers are copied for each row
        defer row.deinit();

        const id = row.data().get("userid") orelse return error.MissingUserId;
        const name = row.data().get("name") orelse return error.MissingName;
        const age = row.data().get("age") orelse return error.MissingAge;

        try res.append(User{
            .id = id.asInt(i64, 10) catch {
                return error.InvalidUserId;
            } orelse return error.MissingUserId,
            .name = try name.clone(),
            .age = age.asInt(u16, 10) catch return error.InvalidAge,
        });
    }

    if (parser.err) |err| {
        return err;
    }

    return res;
}
