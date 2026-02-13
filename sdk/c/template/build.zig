//! This build.zig file is *optional*. It just makes cross-compilation simpler if
//! you are comfortable installing Zig. If you are not, no problem, delete this file.
//!
//! It also generates the `compile_commands.json` file for `clangd` LSP support,
//! which is a nice little bonus. You can do that with the `make` version using `bear`.
//!
//! There are comments below where you'd want to change things, otherwise you don't
//! really need to know Zig in order to use this file to build your C code.
//!
//! To use it, do a `zig build` in the same folder as the `build.zig`.

const std = @import("std");
const zcc = @import("compile_commands");

const Target = std.Target;
const Feature = std.Target.Cpu.Feature;

// TODO: change this to where the starjay C SDK is
const STARJAY_SDK_PATH = "..";

pub fn build(b: *std.Build) void {
    const features = Target.riscv.Feature;
    var disabled_features = Feature.Set.empty;
    var enabled_features = Feature.Set.empty;

    // disable all CPU extensions
    disabled_features.addFeature(@intFromEnum(features.c));
    disabled_features.addFeature(@intFromEnum(features.d));
    disabled_features.addFeature(@intFromEnum(features.e));
    disabled_features.addFeature(@intFromEnum(features.f));
    disabled_features.addFeature(@intFromEnum(features.a));
    // except multiply
    enabled_features.addFeature(@intFromEnum(features.m));

    const target = b.resolveTargetQuery(.{
        .cpu_arch = Target.Cpu.Arch.riscv32,
        .os_tag = Target.Os.Tag.freestanding,
        .abi = Target.Abi.none,
        .cpu_model = .{ .explicit = &Target.riscv.cpu.generic_rv32 },
        .cpu_features_sub = disabled_features,
        .cpu_features_add = enabled_features,
    });

    const exe = b.addExecutable(.{
        // TODO: change the name of the binary produced here
        .name = "starjay_template",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseSmall,
        }),
    });

    exe.root_module.addCSourceFiles(.{
        .root = b.path("src/"),
        .files = &.{
            // Add C or C++ files here
            "main.c",
        },
        .flags = &.{ "-ffreestanding", "-nostdlib" },
    });

    exe.addAssemblyFile(b.path("src/start.s"));
    exe.setLinkerScript(b.path("src/linker.ld"));

    // You can add more include paths here if you need them
    exe.root_module.addIncludePath(b.path(STARJAY_SDK_PATH ++ "/libs"));

    var targets = std.ArrayListUnmanaged(*std.Build.Step.Compile){};
    targets.append(b.allocator, exe) catch @panic("OOM");

    // Create the compile_commands.json required for clangd LSP support
    const cdb = zcc.createStep(b, "cdb", targets.toOwnedSlice(b.allocator) catch @panic("OOM"));

    exe.step.dependOn(cdb);

    b.installArtifact(exe);
}
