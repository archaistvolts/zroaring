const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const options = b.addOptions();
    options.addOption(bool, "trace", b.option(bool, "trace", "show debug trace output") orelse false);

    const mod = b.addModule("RoaringRegex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "build-options", .module = options.createModule() }},
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = if (b.option([]const []const u8, "test-filter", "filter tests")) |o| o else &.{},
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "roaring_regex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "RoaringRegex", .module = mod }},
        }),
    });
    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);

    const lib = b.addLibrary(.{ .root_module = mod, .name = "roaring_regex" });
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .{ .prefix = {} },
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation to zig-out/docs.");
    docs_step.dependOn(&docs.step);
}
