const std = @import("std");
const lib = @import("lib");
const bench_kmeans = @import("bench_kmeans.zig");
const bench_dither = @import("bench_dither.zig");
const bench_tile_match = @import("bench_tile_match.zig");
const bench_delta_e = @import("bench_delta_e.zig");

pub fn main() !void {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    std.debug.print("sjtilemap benchmarks\n", .{});
    bench_delta_e.run();
    try bench_kmeans.run(gpa);
    try bench_dither.run(gpa);
    try bench_tile_match.run(gpa);
}
