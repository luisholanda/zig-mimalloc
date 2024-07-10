const std = @import("std");

const BuildOpts = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opts = BuildOpts{
        .target = target,
        .optimize = optimize,
    };

    // zig build check
    {
        const step = b.step("check", "check for semantic analysis errors");
        const lib = buildZigMimalloc(b, opts);
        const check = b.addTest(.{
            .name = ".mimalloc-check",
            .root_source_file = b.path("src/_check.zig"),
            .target = opts.target,
            .optimize = .Debug,
        });
        check.root_module.addImport("mimmaloc", lib);
        check.generated_bin = null;
        step.dependOn(&check.step);
    }

    // zig build test
    {
        const test_step = b.step("test", "run unit tests");
        const unit_tests = b.addTest(.{
            .name = "mimalloc-unit-tests",
            .root_source_file = b.path("src/root.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
}

fn buildZigMimalloc(b: *std.Build, opts: BuildOpts) *std.Build.Module {
    const lib = b.addModule("mimalloc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .omit_frame_pointer = true,
        .error_tracing = false,
    });

    return lib;
}
