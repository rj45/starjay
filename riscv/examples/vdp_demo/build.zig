const std = @import("std");
const ObjCopyExternal = @import("ObjCopyExternal.zig").ObjCopyExternal;

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

    const exe = b.addExecutable(.{
        .name = "vdp_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
        }),
    });


    exe.entry = .{ .symbol_name = "_start" };

    exe.addAssemblyFile(b.path("src/start.s"));

    exe.setLinkerScript(b.path("src/linker.ld"));

    b.installArtifact(exe);

    // Use external objcopy due to bug in zig's 0.15.x objcopy
    const bin = ObjCopyExternal.create(b, exe.getEmittedBin(), .{
        .format = .bin,
    });
    // const bin = b.addObjCopy(exe.getEmittedBin(), .{
    //     .format = .bin,
    // });
    bin.step.dependOn(&exe.step);

    const copy_bin = b.addInstallBinFile(bin.getOutput(), "vdp_demo.bin");
    b.default_step.dependOn(&copy_bin.step);
}
