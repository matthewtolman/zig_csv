pub const slice = @import("simd/slice.zig");
pub const slice_2 = @import("simd/slice_no_simd.zig");
pub const slice_3 = @import("simd/slice_no_simd_32.zig");

test "import" {
    _ = slice.init("");
    _ = slice_2.init("");
    _ = slice_3.init("");
}
