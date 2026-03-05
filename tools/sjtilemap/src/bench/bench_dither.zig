const std = @import("std");
const lib = @import("lib");

pub fn run(gpa: std.mem.Allocator) !void {
    std.debug.print("=== bench_dither: Sierra dithering on 64x64 gradient image ===\n", .{});

    const width: u32 = 64;
    const height: u32 = 64;
    const n_pixels = width * height;
    const n_runs: usize = 5;

    // Create a synthetic gradient image in OKLab space
    const pixels = try gpa.alloc(lib.color.OklabAlpha, n_pixels);
    defer gpa.free(pixels);

    for (0..height) |y| {
        for (0..width) |x| {
            const t: f32 = @as(f32, @floatFromInt(y * width + x)) / @as(f32, @floatFromInt(n_pixels - 1));
            pixels[y * width + x] = lib.color.OklabAlpha{
                .l = t,
                .a = (t - 0.5) * 0.4,
                .b = (0.5 - t) * 0.3,
                .alpha = 1.0,
            };
        }
    }

    const img = lib.input.LoadedImage{
        .pixels = pixels,
        .width = width,
        .height = height,
        .allocator = gpa,
    };

    const cfg = lib.config.Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = width / 8,
        .tilemap_height = height / 8,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .sierra,
        .dither_factor = 1.0,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.01,
        .palette_kmeans_max_iter = 50,
        .tile_kmeans_max_iter = 50,
    };

    // Warm-up
    {
        var result = try lib.pipeline.run(gpa, cfg, img);
        result.deinit();
    }

    const start = std.time.nanoTimestamp();
    for (0..n_runs) |_| {
        var result = try lib.pipeline.run(gpa, cfg, img);
        result.deinit();
    }
    const elapsed_ns = std.time.nanoTimestamp() - start;
    const ns_per_op = @divTrunc(elapsed_ns, n_runs);
    std.debug.print("  sierra_dither({}x{} image, 1 palette, 16 colors): {} ms/op\n", .{
        width, height, @divTrunc(ns_per_op, 1_000_000),
    });
}
