const std = @import("std");

const BuildOpts = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    secure: bool,
    debug_full: bool,
    padding: bool,
    valgrind: bool,
};

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const secure = b.option(bool, "secure", "Use full security mitigations, see mimalloc source for details") orelse false;
    const debug_full = b.option(bool, "debug-full", "Use full internal heap invariant checking in Debug mode (expensive)") orelse false;
    const padding = b.option(bool, "padding", "Enable padding to detect heap block overflows") orelse secure;
    const valgrind = b.option(bool, "valgrind", "Compile with valgrind support") orelse false;

    const opts: BuildOpts = .{
        .target = target,
        .optimize = optimize,
        .secure = secure,
        .debug_full = debug_full,
        .padding = padding,
        .valgrind = valgrind,
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
        check.root_module.addImport("mimalloc", lib);
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

    const mimalloc = buildMimalloc(b, opts);

    lib.linkLibrary(mimalloc);
    lib.addIncludePath(b.path("mimalloc/include"));

    return lib;
}

fn buildMimalloc(b: *std.Build, opts: BuildOpts) *std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "mimmaloc",
        .target = opts.target,
        .optimize = opts.optimize,
        .version = std.SemanticVersion.parse("2.1.7") catch unreachable,
        .use_llvm = true,
    });
    lib.linkLibC();

    b.installArtifact(lib);

    lib.addCSourceFile(.{ .file = b.path("mimalloc/src/static.c") });
    lib.addIncludePath(b.path("mimalloc/include"));

    if (opts.secure) {
        lib.defineCMacro("MI_SECURE", "4");
    }

    if (opts.padding) {
        lib.defineCMacro("MI_PADDING", "1");
    }

    switch (opts.optimize) {
        .Debug => lib.defineCMacro("MI_DEBUG", if (opts.debug_full) "3" else "1"),
        .ReleaseSafe => lib.defineCMacro("MI_DEBUG", "1"),
        else => lib.defineCMacro("NDEBUG", ""),
    }

    if (opts.valgrind) {
        lib.root_module.valgrind = true;
    }

    return lib;
}
