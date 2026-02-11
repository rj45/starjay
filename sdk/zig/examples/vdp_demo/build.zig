const std = @import("std");

const Target = @import("std").Target;
const Feature = @import("std").Target.Cpu.Feature;

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
    // except multiply and atomic
    enabled_features.addFeature(@intFromEnum(features.m));

    const target = b.resolveTargetQuery(.{
        .cpu_arch = Target.Cpu.Arch.riscv32,
        .os_tag = Target.Os.Tag.freestanding,
        .abi = Target.Abi.none,
        .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32},
        .cpu_features_sub = disabled_features,
        .cpu_features_add = enabled_features
    });

    const starjay_dep = b.dependency("starjay", .{
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const exe = b.addExecutable(.{
        .name = "vdp_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "starjay", .module = starjay_dep.module("starjay") },
            },
        }),
    });


    exe.entry = .{ .symbol_name = "_start" };

    exe.addAssemblyFile(b.path("../../../common/start.s"));

    exe.setLinkerScript(b.path("../../../common/linker.ld"));

    b.installArtifact(exe);
}
