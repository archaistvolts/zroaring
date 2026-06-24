const std = @import("std");
const afl = @import("afl_kit");

pub fn build(b: *std.Build) !void {
    const options = b.addOptions();
    options.addOption(bool, "trace", b.option(bool, "trace", "show debug trace output. default false.") orelse false);
    options.addOption(bool, "fuzzprint", b.option(bool, "fuzzprint", "print fuzzer FuzzOps which may be added to src/fuzz-crash-corpus.zon to reproduce crashes. default false.") orelse false);
    options.addOption(bool, "run_slow_tests", b.option(bool, "run-slow-tests", "perform long running tests such as checkAllocationFailures(). default false.") orelse false);
    const options_mod = options.createModule();
    const use_llvm = b.option(bool, "llvm", "use llvm. null by default. needed when fuzzing with zig.") orelse null;
    const avx512 = b.option(bool, "avx512", "enable croaring avx512.  default false.") orelse false;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const flexible = b.dependency("flexible_struct", .{ .target = target, .optimize = optimize });

    const zrmod = b.addModule("zroaring", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build-options", .module = options_mod },
            .{ .name = "flexible_struct", .module = flexible.module("flexible_struct") },
        },
    });

    const translate_cr = b.addTranslateC(.{
        .root_source_file = b.path("src/c/roaring-subset.h"),
        .target = target,
        .optimize = optimize,
    });
    const translate_cr_mod = translate_cr.createModule();
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "build-options", .module = options.createModule() },
            .{ .name = "flexible_struct", .module = flexible.module("flexible_struct") },
            .{ .name = "croaring", .module = translate_cr_mod },
        },
    });
    const tests = b.addTest(.{
        .root_module = test_mod,
        .filters = if (b.option([]const []const u8, "test-filter", "filter tests")) |o| o else &.{},
        .use_llvm = use_llvm,
    });

    const libcroaring = b.addLibrary(.{
        .name = "croaring",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    libcroaring.root_module.addIncludePath(b.path("src/c"));
    libcroaring.root_module.addCSourceFile(.{ .file = b.path("src/c/roaring.c") });
    libcroaring.root_module.addCMacro(if (avx512) "" else "CROARING_COMPILER_SUPPORTS_AVX512", "0");
    test_mod.linkLibrary(libcroaring);

    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
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
            .use_llvm = use_llvm,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/fuzz.zig"),
                .target = target,
                .optimize = .ReleaseSafe,
                .link_libc = true,
                .stack_check = false,
                .fuzz = true,
                .imports = &.{
                    .{ .name = "zroaring", .module = zrmod },
                    .{ .name = "build-options", .module = options_mod },
                    .{ .name = "flexible_struct", .module = flexible.module("flexible_struct") },
                    .{ .name = "croaring", .module = translate_cr_mod },
                },
            }),
        });
        afl_obj.root_module.linkLibrary(libcroaring); // https://github.com/kristoff-it/zig-afl-kit/issues/14
        afl_obj.sanitize_coverage_trace_pc_guard = true;

        // Generate an instrumented executable and install.  but only when afl-cc is present.
        const afl_fuzz = afl.addInstrumentedExe(b, target, optimize, null, true, afl_obj, &.{
            // "-Lzig-out/lib/",
            // "-lcroaring",
        }).?;

        const install_afl_fuzz = b.addInstallBinFile(afl_fuzz, "fuzz-afl");
        b.getInstallStep().dependOn(&install_afl_fuzz.step);
    }

    const exe = b.addExecutable(.{
        .name = "main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zroaring", .module = zrmod },
                .{ .name = "build-options", .module = options_mod },
                .{ .name = "flexible_struct", .module = flexible.module("flexible_struct") },
                .{ .name = "croaring", .module = translate_cr_mod },
            },
        }),
    });
    b.installArtifact(exe);
    const exe_run = b.step("run", "run main exe");
    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    exe_run.dependOn(&run_exe.step);

    const gen_corpus = b.addExecutable(.{
        .name = "gen-afl-corpus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz-gen.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "flexible_struct", .module = flexible.module("flexible_struct") },
                .{ .name = "build-options", .module = options_mod },
                .{ .name = "croaring", .module = translate_cr_mod },
            },
        }),
    });
    b.installArtifact(gen_corpus);
    b.step("gen-afl-corpus", "Generate afl/input/ corpus files.")
        .dependOn(&b.addRunArtifact(gen_corpus).step);

    const afl_main = b.addExecutable(.{
        .name = "afl-main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz-main.zig"),
            .target = target,
            .link_libc = true,
            .imports = &.{
                .{ .name = "flexible_struct", .module = flexible.module("flexible_struct") },
                .{ .name = "build-options", .module = options_mod },
                .{ .name = "croaring", .module = translate_cr_mod },
            },
        }),
    });
    b.installArtifact(afl_main);
    b.step("afl-main", "fuzz a single afl/output file")
        .dependOn(&b.addRunArtifact(afl_main).step);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "flexible_struct", .module = flexible.module("flexible_struct") },
                .{ .name = "build-options", .module = options_mod },
                .{ .name = "croaring", .module = translate_cr_mod },
            },
        }),
    });
    bench_exe.root_module.linkLibrary(libcroaring);
    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    b.step("bench", "Run the zroaring benchmark").dependOn(&bench_run.step);
    b.installArtifact(bench_exe);
}
