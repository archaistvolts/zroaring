const std = @import("std");
const BenchTarget = @import("src/bench2.zig").BenchTarget;

pub fn build(b: *std.Build) !void {
    const options = b.addOptions();
    options.addOption(bool, "trace", b.option(bool, "trace", "show debug trace output. default false.") orelse false);
    options.addOption(bool, "fuzzprint", b.option(bool, "fuzzprint", "print fuzz.Ops which may be added to src/fuzz-crash-corpus.zon to reproduce crashes. default false.") orelse false);
    options.addOption(bool, "run_slow_tests", b.option(bool, "run-slow-tests", "perform long running tests such as checkAllocationFailures(). default false.") orelse false);
    const bench_target = b.option(BenchTarget, "bench-target", "bench2 target");
    options.addOption(BenchTarget, "bench_target", bench_target orelse .zr);
    const opt_bench_op = b.option([]const u8, "bench-op", "Benchmark a specific op.  A fuzz.Op tag name.  Results in zig-out/bin/bench-<bench-target>-<bench-op>, an executable which runs a single op on recorded crash corpus.");
    options.addOption(?[]const u8, "bench_op", opt_bench_op);

    const options_mod = options.createModule();
    const use_llvm = b.option(bool, "llvm", "use llvm. null by default. needed when fuzzing with zig.") orelse null;
    const avx512 = b.option(bool, "avx512", "enable croaring avx512.  default false.") orelse false;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zr_mod = b.addModule("zroaring", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build-options", .module = options_mod },
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
            .{ .name = "croaring", .module = translate_cr_mod },
        },
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
    libcroaring.root_module.addCSourceFile(.{
        .file = b.path("src/c/roaring.c"),
    });
    if (!avx512) libcroaring.root_module.addCMacro("CROARING_COMPILER_SUPPORTS_AVX512", "0");

    const tests = b.addTest(.{
        .root_module = test_mod,
        .filters = b.option([]const []const u8, "test-filter", "filter tests") orelse &.{},
        .use_llvm = use_llvm,
    });
    test_mod.linkLibrary(libcroaring);
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
    b.installArtifact(tests);

    const lib = b.addLibrary(.{ .root_module = zr_mod, .name = "zroaring" });
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .{ .prefix = {} },
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation to zig-out/docs.");
    docs_step.dependOn(&docs.step);

    // AFL++ fuzzing exe
    if (b.option(bool, "fuzz-exe", "Generate an instrumented executable for AFL++") orelse false) {
        const fuzz_mod = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
            .stack_check = false,
            .fuzz = true,
            .imports = &.{
                .{ .name = "zroaring", .module = zr_mod },
                .{ .name = "build-options", .module = options_mod },
                .{ .name = "croaring", .module = translate_cr_mod },
            },
        });
        fuzz_mod.linkLibrary(libcroaring);
        // an object file that contains the test function
        const afl_obj = b.addObject(.{
            .name = "fuzz_obj",
            .use_llvm = use_llvm,
            .root_module = fuzz_mod,
        });
        afl_obj.sanitize_coverage_trace_pc_guard = true;

        const afl_cc = b.findProgram(&.{"afl-clang-lto"}, &.{}) catch @panic("afl-clang-lto not found; is AFL++ installed?");
        const run_afl_cc = b.addSystemCommand(&.{
            afl_cc,
            "-O3",
            "-Wno-override-module",
            "-Wno-static-in-inline",
        });
        run_afl_cc.addArg("-o");
        const fuzz_exe = run_afl_cc.addOutputFileArg("fuzz-afl");
        run_afl_cc.addFileArg(b.path("src/fuzz-afl-main.c"));
        run_afl_cc.addFileArg(b.path("src/c/roaring.c"));
        run_afl_cc.addArg("-I");
        run_afl_cc.addDirectoryArg(b.path("src/c"));
        run_afl_cc.addFileArg(afl_obj.getEmittedLlvmBc());
        run_afl_cc.addArg("-lc");

        const install_afl = b.addInstallBinFile(fuzz_exe, "fuzz-afl");
        b.getInstallStep().dependOn(&install_afl.step);
    }

    const exe = b.addExecutable(.{
        .name = "main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zroaring", .module = zr_mod },
                .{ .name = "build-options", .module = options_mod },
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
                .{ .name = "build-options", .module = options_mod },
                .{ .name = "croaring", .module = translate_cr_mod },
            },
        }),
    });
    b.installArtifact(gen_corpus);
    b.step("gen-afl-corpus", "Generate afl/input/ corpus files.")
        .dependOn(&b.addRunArtifact(gen_corpus).step);
    gen_corpus.root_module.linkLibrary(libcroaring);

    const afl_main = b.addExecutable(.{
        .name = "afl-run",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz-afl-run.zig"),
            .target = target,
            .link_libc = true,
            .imports = &.{
                .{ .name = "build-options", .module = options_mod },
                .{ .name = "croaring", .module = translate_cr_mod },
            },
        }),
    });
    b.installArtifact(afl_main);
    b.step("afl-run", "fuzz a single afl/output/ file")
        .dependOn(&b.addRunArtifact(afl_main).step);
    afl_main.root_module.linkLibrary(libcroaring);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "build-options", .module = options_mod },
                .{ .name = "croaring", .module = translate_cr_mod },
            },
            // .strip = false,
        }),
    });
    bench_exe.root_module.linkLibrary(libcroaring);
    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    b.step("bench", "Run simple benchmark with CRoaring.").dependOn(&bench_run.step);
    b.installArtifact(bench_exe);

    const bench_exe2 = b.addExecutable(.{
        .name = if (opt_bench_op) |bo|
            b.fmt("bench-{t}-{s}", .{ bench_target orelse .zr, bo })
        else
            b.fmt("bench-{t}", .{bench_target orelse .zr}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench2.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "build-options", .module = options_mod },
                .{ .name = "croaring", .module = translate_cr_mod },
            },
        }),
    });
    bench_exe2.root_module.linkLibrary(libcroaring);
    b.installArtifact(bench_exe2);

    const exe_check = b.addExecutable(.{ .name = "check", .root_module = zr_mod });
    const check = b.step("check", "Check if everything compiles");
    check.dependOn(&exe_check.step);
    check.dependOn(&tests.step);
    check.dependOn(&bench_exe.step);
    check.dependOn(&bench_exe2.step);
    check.dependOn(&gen_corpus.step);

    if (opt_bench_op) |bench_op| {
        const gen_corpus_playback = b.addExecutable(.{
            .name = "gen-corpus-playback",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bench-gen-corpus-playback.zig"),
                .target = target,
                .optimize = .Debug,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "build-options", .module = options_mod },
                    .{ .name = "croaring", .module = translate_cr_mod },
                    .{ .name = "zroaring", .module = zr_mod },
                },
            }),
        });
        gen_corpus_playback.root_module.linkLibrary(libcroaring);
        const run_gen = b.addRunArtifact(gen_corpus_playback);
        run_gen.addArg(bench_op);
        const bench_options = b.addOptions();
        const bin_name = b.fmt("corpus_replay_{s}_bin", .{bench_op});
        bench_options.addOptionPath(bin_name, run_gen.addOutputFileArg(bin_name));
        bench_exe2.root_module.addImport("bench_options", bench_options.createModule());
        check.dependOn(&gen_corpus_playback.step);
    }
}
