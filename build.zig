const std = @import("std");

pub fn build(b: *std.Build) void {
    const options = b.addOptions();
    options.addOption(bool, "trace", b.option(bool, "trace", "show debug trace output") orelse false);
    const target = b.standardTargetOptions(.{});
    const mod = b.addModule("zroaring", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "build-options", .module = options.createModule() }},
    });

    const tests_mod = b.addTest(.{
        .root_module = mod,
        .filters = if (b.option([]const []const u8, "test-filter", "filter tests")) |o| o else &.{},
    });
    const run_tests_mod = b.addRunArtifact(tests_mod);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests_mod.step);

    const lib = b.addLibrary(.{ .root_module = mod, .name = "roaring_regex" });
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .{ .prefix = {} },
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation to zig-out/docs.");
    docs_step.dependOn(&docs.step);

    const exe_check = b.addExecutable(.{ .name = "check", .root_module = mod });
    const check = b.step("check", "Check if everything compiles");
    check.dependOn(&exe_check.step);
    check.dependOn(&tests_mod.step);

    const avx512 = b.option(bool, "avx512", "enable croaring avx512 support") orelse false;
    tests_mod.root_module.addIncludePath(b.path("src"));
    tests_mod.addCSourceFile(.{ .file = b.path("src/c/roaring.c") });
    tests_mod.root_module.addCMacro(if (avx512) "" else "CROARING_COMPILER_SUPPORTS_AVX512", "0");
    tests_mod.linkLibC();
}
