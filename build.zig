const std = @import("std");

pub fn build(b: *std.Build) void {
    const target_opt = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdl2 = b.option(bool, "sdl2", "Build for SDL2 instead of SDL3") orelse false;
    const sdl3 = !sdl2;

    const target = if (target_opt.result.os.tag == .emscripten)
        b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
            .cpu_features_add = std.Target.wasm.featureSet(&.{
                .atomics,
                .bulk_memory,
            }),
            .os_tag = .emscripten,
        })
    else
        target_opt;

    // For the SDK
    _ = b.addModule("starjay", .{
        .root_source_file = b.path("sdk/zig/src/starjay.zig"),
        .target = target,
        .optimize = optimize,
    });

    // For dvui and SDL, never use Debug mode; use ReleaseSafe instead.
    const fast_debug_build: @TypeOf(optimize) = if (optimize == .Debug) .ReleaseSafe else optimize;

    const dvui_dep = if (sdl3) b.dependency("dvui", .{
        .target = target,
        .optimize = fast_debug_build,
        .backend = .sdl3,
        .freetype = target.result.os.tag != .emscripten,
    }) else b.dependency("dvui", .{
        .target = target,
        .optimize = fast_debug_build,
        .backend = .sdl2,
    });

    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const spsc_queue = b.dependency("spsc_queue", .{
        .target = target,
        .optimize = fast_debug_build,
    });

    // const stack_check = if ((optimize == .Debug or optimize == .ReleaseSafe) and target.result.os.tag != .macos) true else false;

    const dvui_sdl_mod = if (sdl3) dvui_dep.module("sdl3") else dvui_dep.module("sdl2");
    const dvui_mod = if (sdl3) dvui_dep.module("dvui_sdl3") else dvui_dep.module("dvui_sdl2");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // .stack_check = stack_check,
        // .stack_protector = stack_check,
        .link_libc = target.result.os.tag == .emscripten,
        .imports = &.{
            .{ .name = "dvui", .module = dvui_mod },
            .{ .name = "backend", .module = dvui_sdl_mod },
            .{ .name = "clap", .module = clap.module("clap") },
            .{ .name = "spsc_queue", .module = spsc_queue.module("spsc_queue") },
        },
    });

    // if (b.systemIntegrationOption("sdl3", .{})) {
    //     exe_mod.linkSystemLibrary("SDL3", .{});
    // } else {
    //     if (dvui_dep.builder.lazyDependency("sdl3", .{
    //         .target = target,
    //         .optimize = optimize,
    //     })) |s| {
    //         exe_mod.linkLibrary(s.artifact("SDL3"));
    //     }
    // }

    const run_step = b.step("run", "Run the app");

    if (target.result.os.tag == .emscripten) {
        // Build for the Web.

        if (b.sysroot) |sysroot| {
            const path: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ sysroot, "include" }) };
            exe_mod.addSystemIncludePath(path);
            dvui_mod.addSystemIncludePath(path);
            dvui_sdl_mod.addSystemIncludePath(path);
        } else {
            std.log.err("'--sysroot' is required when building for Emscripten", .{});
            std.process.exit(1);
        }

        const app_lib = b.addLibrary(.{
            .linkage = .static,
            .name = "starjay",
            .root_module = exe_mod,
        });

        app_lib.rdynamic = true;
        app_lib.linkLibC();
        exe_mod.single_threaded = false;

        const run_emcc = b.addSystemCommand(&.{"emcc"});

        // Pass 'app_lib' and any static libraries it links with as input files.
        // 'app_lib.getCompileDependencies()' will always return 'app_lib' as the first element.
        for (app_lib.getCompileDependencies(false)) |lib| {
            if (lib.isStaticLibrary()) {
                run_emcc.addArtifactArg(lib);
            }
        }

        run_emcc.addArgs(&.{
            "-pthread",
            "-sPROXY_TO_PTHREAD",
            "-sEXPORTED_FUNCTIONS=_main",
            "-sPTHREAD_POOL_SIZE=4",
            "-sALLOW_MEMORY_GROWTH=1",
            "-sSTACK_SIZE=8mb",
            "-sENVIRONMENT=web",
            "--preload-file=sdk/zig/examples/vdp_demo/zig-out/bin",
            // fixes Aborted(Cannot use convertFrameToPC (needed by __builtin_return_address) without -sUSE_OFFSET_CONVERTER)
            // "-sUSE_OFFSET_CONVERTER=1",
            "-sMINIFY_HTML=0",
            // "-sSTB_IMAGE=1", // TODO: try to use this instaed of what dvui provides?
        });

        if (target.result.cpu.arch == .wasm64) {
            run_emcc.addArg("-sMEMORY64");
        }

        run_emcc.addArgs(switch (optimize) {
            .Debug => &.{
                "-O0",
                // Preserve DWARF debug information.
                "-g",
                // Use UBSan (full runtime).
                "-fsanitize=undefined",
            },
            .ReleaseSafe => &.{
                "-O3",
                // Use UBSan (minimal runtime).
                "-fsanitize=undefined",
                "-fsanitize-minimal-runtime",
                "-sSAFE_HEAP=2",
                "-sASSERTIONS=2",
                "-sSTACK_OVERFLOW_CHECK=2",
                "-sMALLOC=mimalloc",
                "-sABORTING_MALLOC=0",
            },
            .ReleaseFast => &.{
                "-O3",
                "-sMALLOC=mimalloc",
            },
            .ReleaseSmall => &.{
                "-Oz",
                "-sMALLOC=mimalloc",
            },
        });

        // if (optimize != .Debug) {
        //     run_emcc.addArg("-flto");
        //     // Fails with ERROR - [JSC_UNDEFINED_VARIABLE] variable _free is undeclared
        //     // https://qa.fmod.com/t/errors-optimizing-with-closure-compiler-emscripten/20366?
        //     // run_emcc.addArgs(&.{ "--closure", "1" });
        // }

        // Patch the default HTML shell.
        run_emcc.addArg("--pre-js");
        run_emcc.addFileArg(b.addWriteFiles().add("pre.js", (
            // Display messages printed to stderr.
            \\Module['printErr'] ??= Module['print'];
            \\
        )));

        run_emcc.addArg("-o");
        const app_html = run_emcc.addOutputFileArg("starjay.html");

        b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = app_html.dirname(),
            .install_dir = .{ .custom = "www" },
            .install_subdir = "",
        }).step);

        const run_emrun = b.addSystemCommand(&.{"emrun"});
        run_emrun.addArg(b.pathJoin(&.{ b.install_path, "www", "starjay.html" }));
        if (b.args) |args| run_emrun.addArgs(args);
        run_emrun.step.dependOn(b.getInstallStep());

        run_step.dependOn(&run_emrun.step);
    } else {
        const exe = b.addExecutable(.{
            .name = "starjay",
            .use_llvm = true, // Prevent using zig's built-in codegen, since the code it produces is too slow
            .root_module = exe_mod,
        });

        b.installArtifact(exe);



        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);

        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }

    const exe_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
