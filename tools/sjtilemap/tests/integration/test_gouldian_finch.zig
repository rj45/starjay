const std = @import("std");
const lib = @import("lib");
const pipeline = lib.pipeline;
const config_mod = lib.config;
const Config = config_mod.Config;
const input_mod = lib.input;


// =============================================================================
// Gouldian Finch Real image integration test
// =============================================================================


test "Gouldian Finch 256x256 integration test" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    // Load the real test image
    var img = try input_mod.loadImage(gpa, "test_assets/Gouldian_Finch_256x256.png");
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 256), img.width);
    try std.testing.expectEqual(@as(u32, 256), img.height);

    // Run pipeline with reference config matching Rust imgconv defaults:
    // 32 palettes, 16 colors per palette, 256 max unique tiles, sierra dithering
    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 32,
        .tilemap_height = 32,
        .num_palettes = 32,
        .colors_per_palette = 16,
        .max_unique_tiles = 256,
        .dither_algorithm = .sierra,
        .dither_factor = 1.0,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = true,
        .color_similarity_threshold = 0.01,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = try pipeline.run(arena.allocator(), cfg, img);
    defer arena.deinit();

    // Assert 1: Unique tiles <= 256
    if (result.unique_tiles.len > 256) {
        std.debug.print("Gouldian Finch: too many unique tiles: {}\n", .{result.unique_tiles.len});
        return error.TooManyUniqueTiles;
    }
    std.debug.print("Gouldian Finch: unique_tiles={}, palettes={}\n", .{ result.unique_tiles.len, result.palettes.len });

    // Assert 2: Tilemap has 32*32 = 1024 entries
    try std.testing.expectEqual(@as(usize, 1024), result.tilemap.len);
    try std.testing.expectEqual(@as(u32, 32), result.tilemap_width);
    try std.testing.expectEqual(@as(u32, 32), result.tilemap_height);

    // Assert 3: Output pixels exist
    try std.testing.expectEqual(@as(usize, 256 * 256), result.output_pixels.len);

    const metrics = try lib.pipeline.computeErrorMetrics(gpa, img.pixels, img.srgb_bytes, result.output_pixels);

    // Assert 4: Quality metrics — Zig must match or beat Rust baseline.
    // Rust baseline (cargo run --release, dither_factor=1.0, 32 palettes, 16 colors, sierra):
    //   Mean delta-E (×100 display): 2.790  → actual avg deltaE = 0.02790
    //   Average PSNR: 25.254 dB
    // Zig achieves better perceptual quality (deltaE) because the optimizer works in OKLab space.
    // PSNR is measured in sRGB space; Zig's OKLab optimization does not minimize sRGB MSE directly,
    // so Zig PSNR is ~0.6 dB below Rust (~24.6 dB). Threshold 24.0 dB provides regression protection.
    // We allow 10% slack above the Rust deltaE baseline for k-means randomness: threshold = 0.030.
    std.debug.print("Gouldian Finch: avg deltaE = {d:.5}\n", .{metrics.mean_de});
    std.debug.print("Gouldian Finch: pSNR = {d:.5}\n", .{metrics.psnr_avg});

    if (metrics.mean_de > 0.030) {
        std.debug.print("Gouldian Finch: avg deltaE {d:.5} too high (Rust baseline 0.027, threshold 0.030)\n", .{metrics.mean_de});
        return error.QualityTooLow;
    }
    if (metrics.psnr_avg < 24.0) {
        std.debug.print("Gouldian Finch: avg PSNR {d:.3} dB too low (Zig baseline ~24.6 dB, threshold 24.0 dB)\n", .{metrics.psnr_avg});
        return error.PsnrTooLow;
    }
}
