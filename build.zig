const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdl2 = b.option(bool, "sdl2", "Build for SDL2 instead of SDL3") orelse false;
    const sdl3 = !sdl2;

    // For dvui and SDL, never use Debug mode; use ReleaseSafe instead.
    const ui_opt_mode: @TypeOf(optimize) = if (optimize == .Debug) .ReleaseSafe else optimize;

    const dvui_dep = if (sdl3) b.dependency("dvui", .{
        .target = target,
        .optimize = ui_opt_mode,
        .backend = .sdl3,
    }) else b.dependency("dvui", .{
        .target = target,
        .optimize = ui_opt_mode,
        .backend = .sdl2,
    });

    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const spsc_queue = b.dependency("spsc_queue", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "starjay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dvui", .module = if (sdl3) dvui_dep.module("dvui_sdl3") else dvui_dep.module("dvui_sdl2") },
                .{ .name = "backend", .module = if (sdl3) dvui_dep.module("sdl3") else dvui_dep.module("sdl2") },
                .{ .name = "clap", .module = clap.module("clap") },
                .{ .name = "spsc_queue", .module = spsc_queue.module("spsc_queue") },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
