const std = @import("std");

const BuildOpts = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    secure: bool,
    debug_full: bool,
    no_debug: bool,
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
    const no_debug = b.option(bool, "no-debug", "Disable all internal heap invariant checking") orelse (optimize == .ReleaseFast);
    const padding = b.option(bool, "padding", "Enable padding to detect heap block overflows") orelse secure;
    const valgrind = b.option(bool, "valgrind", "Compile with valgrind support") orelse false;

    const opts: BuildOpts = .{
        .target = target,
        .optimize = optimize,
        .secure = secure,
        .debug_full = debug_full,
        .no_debug = no_debug,
        .padding = padding,
        .valgrind = valgrind,
    };

    const lib = buildZigMimalloc(b, opts);

    // zig build check
    {
        const step = b.step("check", "check for semantic analysis errors");
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
            .root_source_file = b.path("src/tests.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        unit_tests.root_module.addImport("mimalloc", lib);
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
}

fn buildZigMimalloc(b: *std.Build, opts: BuildOpts) *std.Build.Module {
    const lib = b.addModule("mimalloc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });

    lib.addCSourceFile(.{ .file = b.path("mimalloc/src/static.c") });
    lib.addIncludePath(b.path("mimalloc/include"));
    lib.link_libc = true;

    if (opts.secure) {
        lib.addCMacro("MI_SECURE", "4");
    }

    if (opts.padding) {
        lib.addCMacro("MI_PADDING", "1");
    }

    if (opts.valgrind) {
        lib.valgrind = true;
        lib.addCMacro("MI_TRACK_VALGRIND", "1");
        lib.linkSystemLibrary("valgrind", .{
            .use_pkg_config = .force,
            .preferred_link_mode = .static,
        });
    }

    if (opts.no_debug) {
        lib.addCMacro("NDEBUG", "");
    } else {
        switch (opts.optimize) {
            .Debug => lib.addCMacro("MI_DEBUG", if (opts.debug_full) "3" else "1"),
            else => lib.addCMacro("MI_DEBUG", "1"),
        }
    }

    return lib;
}
