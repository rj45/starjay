const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const starjay_mod = b.addModule("starjay", .{
        .root_source_file = b.path("src/starjay.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "starjay",
        .root_module = starjay_mod,
    });

    b.installArtifact(lib);
}
