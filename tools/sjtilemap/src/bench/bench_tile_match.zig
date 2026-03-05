const std = @import("std");
const lib = @import("lib");

pub fn run(gpa: std.mem.Allocator) !void {
    std.debug.print("=== bench_tile_match: bestPaletteEntry() lookups ===\n", .{});

    const n_queries: usize = 100_000;
    const palette_size: usize = 16;

    // Build a test palette with 16 evenly-spaced OKLab colors
    const palette_colors = try gpa.alloc(lib.color.OklabAlpha, palette_size);
    defer gpa.free(palette_colors);
    for (0..palette_size) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(palette_size - 1));
        palette_colors[i] = lib.color.OklabAlpha{
            .l = t,
            .a = (t - 0.5) * 0.3,
            .b = (0.5 - t) * 0.2,
            .alpha = 1.0,
        };
    }
    const palette = lib.palette.Palette{ .colors = palette_colors };

    // Build query colors (slightly varied)
    const queries = try gpa.alloc(lib.color.OklabAlpha, n_queries);
    defer gpa.free(queries);
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    for (queries) |*q| {
        q.* = lib.color.OklabAlpha{
            .l = rand.float(f32),
            .a = (rand.float(f32) - 0.5) * 0.3,
            .b = (rand.float(f32) - 0.5) * 0.3,
            .alpha = 1.0,
        };
    }

    // Benchmark bestPaletteEntry
    var result_sum: u32 = 0; // prevent optimization
    const start = std.time.nanoTimestamp();
    for (queries) |q| {
        result_sum += lib.quantize.bestPaletteEntry(q, palette);
    }
    const elapsed_ns = std.time.nanoTimestamp() - start;
    const ns_per_op = @divTrunc(elapsed_ns, n_queries);

    std.debug.print("  bestPaletteEntry({} colors): {} ns/op (sum={})\n", .{
        palette_size, ns_per_op, result_sum,
    });
}
