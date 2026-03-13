const std = @import("std");
const lib = @import("lib");
const pipeline = lib.pipeline;
const config_mod = lib.config;
const Config = config_mod.Config;
const input_mod = lib.input;


// =============================================================================
// Kodak 23 Real image integration test
// =============================================================================


test "Kodak 23 256x256 integration test" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    var img = try input_mod.loadImage(gpa, "test_assets/kodak_23_256x256.png");
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 256), img.width);
    try std.testing.expectEqual(@as(u32, 256), img.height);

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
    defer arena.deinit();
    const result = try pipeline.run(arena.allocator(), cfg, img);

    try std.testing.expect(result.unique_tiles.len <= 256);
    try std.testing.expectEqual(@as(usize, 1024), result.tilemap.len);
    try std.testing.expectEqual(@as(u32, 32), result.tilemap_width);
    try std.testing.expectEqual(@as(u32, 32), result.tilemap_height);

    // Rust baseline (cargo run --release, default config):
    //   Mean delta-E (×100 display): 2.176  → actual avg deltaE = 0.02176
    // Threshold = 0.025 (15% above Rust baseline).
    const metrics = try lib.pipeline.computeErrorMetrics(gpa, img.pixels, img.srgb_bytes, result.output_pixels);

    std.debug.print("Kodak 23: avg deltaE = {d:.5}\n", .{metrics.mean_de});
    std.debug.print("Kodak 23: pSNR = {d:.5}\n", .{metrics.psnr_avg});

    // Rust baseline (cargo run --release, dither_factor=1.0, 32 palettes, 16 colors, sierra):
    //   Mean delta-E (×100 display): 2.218  → actual avg deltaE = 0.02218
    //   Average PSNR: 27.841 dB
    // Zig achieves better perceptual quality (deltaE) because the optimizer works in OKLab space.
    // PSNR is measured in sRGB space; Zig achieves ~27.2 dB (0.6 dB below Rust).
    // deltaE threshold: 0.025 (15% above Rust baseline).
    // PSNR threshold: 26.5 dB provides regression protection (Zig achieves ~27.2 dB).
    if (metrics.mean_de > 0.025) {
        std.debug.print("Kodak23: avg deltaE {d:.5} too high (Rust baseline 0.022, threshold 0.025)\n", .{metrics.mean_de});
        return error.QualityTooLow;
    }
    if (metrics.psnr_avg < 26.5) {
        std.debug.print("Kodak 23: avg PSNR {d:.3} dB too low (Zig baseline ~27.2 dB, threshold 26.5 dB)\n", .{metrics.psnr_avg});
        return error.PsnrTooLow;
    }
}
