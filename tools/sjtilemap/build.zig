const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fast_optimize: std.builtin.OptimizeMode =
        if (optimize == .Debug or optimize == .ReleaseSafe) .ReleaseSafe else .ReleaseFast;

    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const kmeans_mod = b.createModule(.{
        .root_source_file = b.path("src/kmeans.zig"),
        .target = target,
        .optimize = fast_optimize,
    });

    // Shared library module (used by exe, tests, bench)
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "kmeans", .module = kmeans_mod },
            .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
            .{ .name = "clap", .module = clap_dep.module("clap") },
        },
    });


    // Thin executable module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lib", .module = lib_mod },
            .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
            .{ .name = "clap", .module = clap_dep.module("clap") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "sjtilemap",
        .use_llvm = true,
        .root_module = exe_mod,
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Unit tests on lib module
    const lib_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "kmeans", .module = kmeans_mod },
            .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
            .{ .name = "clap", .module = clap_dep.module("clap") },
        },
    });
    const lib_tests = b.addTest(.{ .root_module = lib_test_mod });
    lib_tests.linkLibC();
    const run_lib_tests = b.addRunArtifact(lib_tests);

    // Integration tests, with slow tests split out so they can run in parallel
    const main_integ_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration/test_roundtrip.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lib", .module = lib_mod },
            .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
        },
    });
    const main_integ_tests = b.addTest(.{ .root_module = main_integ_mod });
    main_integ_tests.linkLibC();
    const run_main_integ_tests = b.addRunArtifact(main_integ_tests);

    // TODO: make this a configurable option to allow running these tests in debug mode?
    const slow_test_opt = fast_optimize;

    const finch_integ_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration/test_gouldian_finch.zig"),
        .target = target,
        .optimize = slow_test_opt,
        .imports = &.{
            .{ .name = "lib", .module = lib_mod },
            .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
        },
    });
    const finch_integ_tests = b.addTest(.{ .root_module = finch_integ_mod });
    finch_integ_tests.linkLibC();
    const run_finch_integ_tests = b.addRunArtifact(finch_integ_tests);


    const kodak_integ_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration/test_kodak_23.zig"),
        .target = target,
        .optimize = slow_test_opt,
        .imports = &.{
            .{ .name = "lib", .module = lib_mod },
            .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
        },
    });
    const kodak_integ_tests = b.addTest(.{ .root_module = kodak_integ_mod });
    kodak_integ_tests.linkLibC();
    const run_kodak_integ_tests = b.addRunArtifact(kodak_integ_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_main_integ_tests.step);
    test_step.dependOn(&run_finch_integ_tests.step);
    test_step.dependOn(&run_kodak_integ_tests.step);

    // Benchmarks (always ReleaseFast)
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench/bench_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "lib", .module = lib_mod },
        },
    });
    const bench_exe = b.addExecutable(.{
        .name = "sjtilemap-bench",
        .use_llvm = true,
        .root_module = bench_mod,
    });
    bench_exe.linkLibC();
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);
}
