/// Fast-ish CSV parser which iterates over rows
pub const rows = @import("slice/rows.zig");
/// Fast CSV parser which iterates over CSV fields
pub const fields = @import("slice/fields.zig");

test "import" {
    _ = rows.init("", .{});
    _ = fields.init("", .{});
}
