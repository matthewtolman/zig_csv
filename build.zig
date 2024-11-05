const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "csv",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const mod = b.addModule("zcsv", .{
        .root_source_file = b.path("src/root.zig"),
    });

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_unit_step = b.step("test-unit", "Run unit tests");
    test_unit_step.dependOn(&run_lib_unit_tests.step);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const examples = [_]struct {
        file: []const u8,
        name: []const u8,
        libc: bool = false,
    }{
        .{ .file = "examples/01_basic.zig", .name = "example_1" },
        .{ .file = "examples/02_basic_array.zig", .name = "example_2" },
        .{ .file = "examples/03_basic_field_stream.zig", .name = "example_3" },
        .{ .file = "examples/04_read_file.zig", .name = "example_4" },
        .{ .file = "examples/05_clone_memory.zig", .name = "example_5" },
        .{ .file = "examples/06_parse_map.zig", .name = "example_6" },
        .{ .file = "examples/07_parse_map_copy_key.zig", .name = "example_7" },
        .{ .file = "examples/08_write_csv.zig", .name = "example_8" },
        .{ .file = "examples/09_fast_field_stream.zig", .name = "example_9" },
        .{ .file = "examples/10_fast_array.zig", .name = "example_10" },
        .{ .file = "examples/11_fast_array_fields.zig", .name = "example_11" },
    };
    {
        for (examples) |example| {
            const exe = b.addExecutable(.{
                .name = example.name,
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path(example.file),
            });
            exe.root_module.addImport("zcsv", mod);
            if (example.libc) {
                exe.linkLibC();
            }
            b.installArtifact(exe);

            const run_cmd = b.addRunArtifact(exe);
            run_cmd.step.dependOn(b.getInstallStep());
            if (b.args) |args| {
                run_cmd.addArgs(args);
            }

            const run_step = b.step(example.name, example.file);
            run_step.dependOn(&run_cmd.step);

            test_step.dependOn(&run_cmd.step);
        }
    }
}
