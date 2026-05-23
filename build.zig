const std = @import("std");
const afl = @import("afl_kit");

pub fn build(b: *std.Build) !void {
    const options = b.addOptions();
    const with_croaring = b.option(bool, "with-croaring", "include src/c/roaring.c in test exe.  default true.  use when fuzzing with zig to prevent undefined symbols (#31412).") orelse true;
    options.addOption(bool, "trace", b.option(bool, "trace", "show debug trace output") orelse false);
    options.addOption(bool, "with_croaring", with_croaring);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const flexible = b.dependency("flexible_struct", .{ .target = target, .optimize = optimize });

    // TODO // const translate_c = b.addTranslateC(.{ .root_source_file = b.path("c/roaring.h"), .target = target, .optimize = optimize });
    // https://codeberg.org/ziglang/translate-c/issues/330
    const zrmod = b.addModule("zroaring", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build-options", .module = options.createModule() },
            .{ .name = "flexible_struct", .module = flexible.module("flexible_struct") },
        },
    });

    const use_llvm = b.option(bool, "llvm", "use llvm. false by default. needed when fuzzing by zig 0.15.2.") orelse false;
    const tests = b.addTest(.{
        .root_module = zrmod,
        .filters = if (b.option([]const []const u8, "test-filter", "filter tests")) |o| o else &.{},
        .use_llvm = use_llvm,
    });

    const avx512 = b.option(bool, "avx512", "enable croaring avx512.  default false.") orelse false;

    if (with_croaring) {
        tests.root_module.addIncludePath(b.path("src"));
        tests.root_module.addCSourceFile(.{ .file = b.path("src/c/roaring.c") });
        tests.root_module.addCMacro(if (avx512) "" else "CROARING_COMPILER_SUPPORTS_AVX512", "0");
        tests.root_module.link_libc = true;
    }
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    b.installArtifact(tests);

    const lib = b.addLibrary(.{ .root_module = zrmod, .name = "zroaring" });
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .{ .prefix = {} },
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation to zig-out/docs.");
    docs_step.dependOn(&docs.step);

    const exe_check = b.addExecutable(.{ .name = "check", .root_module = zrmod });
    const check = b.step("check", "Check if everything compiles");
    check.dependOn(&exe_check.step);
    check.dependOn(&tests.step);

    // AFL++ fuzzing exe
    if (b.option(bool, "fuzz-exe", "Generate an instrumented executable for AFL++") orelse false) {
        // a step for generating fuzzing tooling
        // an oblect file that contains the test function
        const afl_obj = b.addObject(.{
            .name = "fuzz_obj",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/fuzz.zig"),
                .target = target,
                .optimize = .Debug,
                .link_libc = true,
                .stack_check = false,
                .fuzz = true,
                .imports = &.{
                    .{ .name = "zroaring", .module = zrmod },
                    .{ .name = "build-options", .module = options.createModule() },
                    .{ .name = "flexible_struct", .module = flexible.module("flexible_struct") },
                },
            }),
        });

        // Generate an instrumented executable and install.  but only when afl-cc is present.
        const afl_fuzz = afl.addInstrumentedExe(b, target, optimize, null, true, afl_obj, &.{}).?;
        b.getInstallStep().dependOn(&b.addInstallBinFile(afl_fuzz, "fuzz-afl").step);
    }
}
