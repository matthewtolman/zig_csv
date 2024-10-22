pub const rows = @import("slice/rows.zig");
pub const fields = @import("slice/fields.zig");

test "import" {
    _ = rows.init("");
    _ = fields.init("");
}
