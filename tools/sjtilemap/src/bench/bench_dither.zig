const std = @import("std");
const lib = @import("lib");

pub fn run(gpa: std.mem.Allocator) !void {
    std.debug.print("=== bench_dither: Sierra dithering kernel throughput ===\n", .{});

    const tile_w: u32 = 8;
    const tile_h: u32 = 8;
    const tile_pixels = tile_w * tile_h;
    const n_tiles: u32 = 1024; // 1K tiles = 256x256 image equivalent
    const n_runs: usize = 20;

    // Build a 16-color gradient palette
    const palette_colors = try gpa.alloc(lib.color.OklabAlpha, 16);
    defer gpa.free(palette_colors);
    for (0..16) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 15.0;
        palette_colors[i] = lib.color.OklabAlpha{
            .l = t,
            .a = (t - 0.5) * 0.3,
            .b = (0.5 - t) * 0.2,
            .alpha = 1.0,
        };
    }
    const palette = lib.palette.Palette{ .colors = palette_colors, .count = 16 };
    const palettes = try gpa.alloc(lib.palette.Palette, 1);
    defer gpa.free(palettes);
    palettes[0] = palette;

    // Build gradient tiles
    const tile_pixel_data = try gpa.alloc(lib.color.OklabAlpha, n_tiles * tile_pixels);
    defer gpa.free(tile_pixel_data);
    const tiles = try gpa.alloc(lib.tile.Tile, n_tiles);
    defer gpa.free(tiles);
    for (0..n_tiles) |ti| {
        const base = ti * tile_pixels;
        for (0..tile_pixels) |pi| {
            const t: f32 = @as(f32, @floatFromInt(ti * tile_pixels + pi)) /
                @as(f32, @floatFromInt(n_tiles * tile_pixels - 1));
            tile_pixel_data[base + pi] = lib.color.OklabAlpha{
                .l = t,
                .a = (t - 0.5) * 0.3,
                .b = (0.5 - t) * 0.2,
                .alpha = 1.0,
            };
        }
        tiles[ti] = lib.tile.Tile{
            .pixels = tile_pixel_data[base .. base + tile_pixels],
            .width = tile_w,
            .height = tile_h,
            .has_transparent = false,
        };
    }

    const palette_assignments = try gpa.alloc(u8, n_tiles);
    defer gpa.free(palette_assignments);
    @memset(palette_assignments, 0);

    const tilemap_w = 32;
    const tilemap_h = n_tiles / tilemap_w;
    const cfg = lib.config.Config{
        .tile_width = tile_w,
        .tile_height = tile_h,
        .tilemap_width = tilemap_w,
        .tilemap_height = tilemap_h,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .sierra,
        .dither_factor = 0.75,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
    };

    // Warm-up
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        _ = try lib.dither.quantizeTilesWithSierra(
            arena.allocator(), tiles, palettes, palette_assignments, cfg,
            tilemap_w * tile_w, tilemap_h * tile_h, tilemap_w, tilemap_h,
        );
    }

    const start = std.time.nanoTimestamp();
    for (0..n_runs) |_| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        _ = try lib.dither.quantizeTilesWithSierra(
            arena.allocator(), tiles, palettes, palette_assignments, cfg,
            tilemap_w * tile_w, tilemap_h * tile_h, tilemap_w, tilemap_h,
        );
    }
    const elapsed_ns = std.time.nanoTimestamp() - start;
    const ns_per_op = @divTrunc(elapsed_ns, n_runs);
    const ns_per_tile = @divTrunc(ns_per_op, n_tiles);

    std.debug.print("  quantizeTilesWithSierra({} tiles, {}x{}, 16 colors): {} ns/tile ({} ms/op)\n", .{
        n_tiles, tile_w, tile_h, ns_per_tile, @divTrunc(ns_per_op, 1_000_000),
    });
}
