const std = @import("std");
const zigimg = @import("zigimg");
const lib = @import("lib");
const pipeline = lib.pipeline;
const config_mod = lib.config;
const Config = config_mod.Config;
const color_mod = lib.color;
const OklabAlpha = color_mod.OklabAlpha;
const input_mod = lib.input;
const LoadedImage = input_mod.LoadedImage;
const tilemap_mod = lib.tilemap;
const TilemapEntry = tilemap_mod.TilemapEntry;
const quantize_mod = lib.quantize;
const QuantizedTile = quantize_mod.QuantizedTile;
const palette_mod = lib.palette;
const Palette = palette_mod.Palette;
const hex_out = lib.output.hex;
const binary_out = lib.output.binary;
const c_array_out = lib.output.c_array;

/// 16 distinct RGB colors for the test image.
const test_colors_rgb = [16][3]u8{
    .{ 255, 0, 0 },   .{ 0, 255, 0 },   .{ 0, 0, 255 },   .{ 255, 255, 0 },
    .{ 255, 0, 255 }, .{ 0, 255, 255 },  .{ 128, 0, 0 },   .{ 0, 128, 0 },
    .{ 0, 0, 128 },   .{ 128, 128, 0 },  .{ 128, 0, 128 }, .{ 0, 128, 128 },
    .{ 255, 128, 0 }, .{ 0, 255, 128 },  .{ 128, 0, 255 }, .{ 64, 64, 64 },
};

/// Build a synthetic 8x8 LoadedImage with exactly 16 distinct colors.
/// pixel[i] uses color test_colors_rgb[i / 4] where i = y*8+x.
fn buildTestImage(allocator: std.mem.Allocator) !LoadedImage {
    const width: u32 = 8;
    const height: u32 = 8;

    // Create a zigimg rgb24 image
    var image = try zigimg.Image.create(allocator, width, height, .rgb24);
    defer image.deinit(allocator);

    for (image.pixels.rgb24, 0..) |*px, i| {
        const color_idx = i / 4;
        const rgb = test_colors_rgb[color_idx];
        px.* = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
    }

    // Convert to float32, then to OKLab
    try image.convert(allocator, .float32);
    const oklab_pixels = try zigimg.color.sRGB.sliceToOklabAlphaCopy(
        allocator,
        image.pixels.float32,
    );

    return LoadedImage{
        .pixels = oklab_pixels,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

/// Build a synthetic 16x16 LoadedImage with 4 identical 8x8 quadrants.
/// Each quadrant is the same 8x8 pattern as Phase 2.
fn buildTestImage16x16(allocator: std.mem.Allocator) !LoadedImage {
    const width: u32 = 16;
    const height: u32 = 16;

    var image = try zigimg.Image.create(allocator, width, height, .rgb24);
    defer image.deinit(allocator);

    for (0..height) |y| {
        for (0..width) |x| {
            // Map to local 8x8 coordinates within each quadrant
            const local_x = x % 8;
            const local_y = y % 8;
            const i = local_y * 8 + local_x;
            const color_idx = i / 4;
            const rgb = test_colors_rgb[color_idx];
            image.pixels.rgb24[y * width + x] = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
        }
    }

    try image.convert(allocator, .float32);
    const oklab_pixels = try zigimg.color.sRGB.sliceToOklabAlphaCopy(
        allocator,
        image.pixels.float32,
    );

    return LoadedImage{
        .pixels = oklab_pixels,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

test "Phase 4: 16x16 with 4 identical tiles deduplicates to 1 unique tile" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    var img = try buildTestImage16x16(gpa);
    defer img.deinit();

    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 2,
        .tilemap_height = 2,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = try pipeline.run(arena.allocator(), cfg, img);
    defer arena.deinit();

    // Assert 1: Pixel-perfect reconstruction
    const output_pixels = result.output_pixels;
    try std.testing.expectEqual(img.pixels.len, output_pixels.len);
    for (img.pixels, output_pixels, 0..) |in_px, out_px, i| {
        const err = color_mod.deltaE(in_px, out_px);
        if (err > 1e-4) {
            std.debug.print("Phase4 pixel {} mismatch: deltaE={d:.6}\n", .{ i, err });
            return error.PixelMismatch;
        }
    }

    // Assert 2: Tileset has exactly 1 unique tile
    try std.testing.expectEqual(@as(usize, 1), result.unique_tiles.len);

    // Assert 3: Tilemap is 2x2 (4 entries)
    try std.testing.expectEqual(@as(usize, 4), result.tilemap.len);

    // Assert 4: All entries point to tile_index=0, palette_index=0
    for (result.tilemap, 0..) |entry, i| {
        if (entry.tile_index != 0) {
            std.debug.print("Phase4 tilemap[{}] tile_index={} expected 0\n", .{ i, entry.tile_index });
            return error.WrongTileIndex;
        }
        if (entry.palette_index != 0) {
            std.debug.print("Phase4 tilemap[{}] palette_index={} expected 0\n", .{ i, entry.palette_index });
            return error.WrongPaletteIndex;
        }
    }
}

/// Build 16x16 image with 4 distinct 8x8 tiles but all using the same 16 colors.
/// Quadrant 0: colors in order (i/4)
/// Quadrant 1: colors in reverse order (15 - i/4)
/// Quadrant 2: colors by column-major (i%4 * 4 + i/16) - a different permutation
/// Quadrant 3: colors in a shifted order ((i/4 + 8) % 16)
fn buildTestImage16x16FourDistinct(allocator: std.mem.Allocator) !LoadedImage {
    const width: u32 = 16;
    const height: u32 = 16;

    var image = try zigimg.Image.create(allocator, width, height, .rgb24);
    defer image.deinit(allocator);

    for (0..height) |y| {
        for (0..width) |x| {
            const local_x = x % 8;
            const local_y = y % 8;
            const quadrant = (y / 8) * 2 + (x / 8);
            const i = local_y * 8 + local_x; // 0..63
            const color_idx: usize = switch (quadrant) {
                0 => i / 4, // forward
                1 => 15 - i / 4, // reverse
                2 => (i % 4) * 4 + i / 16, // column-major-ish
                3 => (i / 4 + 8) % 16, // shifted
                else => 0,
            };
            const rgb = test_colors_rgb[color_idx];
            image.pixels.rgb24[y * width + x] = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
        }
    }

    try image.convert(allocator, .float32);
    const oklab_pixels = try zigimg.color.sRGB.sliceToOklabAlphaCopy(
        allocator,
        image.pixels.float32,
    );

    return LoadedImage{
        .pixels = oklab_pixels,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

test "Phase 5: 4 distinct tiles with 1 shared palette, pixel-perfect reconstruction" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    var img = try buildTestImage16x16FourDistinct(gpa);
    defer img.deinit();

    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 2,
        .tilemap_height = 2,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = try pipeline.run(arena.allocator(), cfg, img);
    defer arena.deinit();

    // Assert 1: Pixel-perfect reconstruction
    const output_pixels = result.output_pixels;
    try std.testing.expectEqual(img.pixels.len, output_pixels.len);
    for (img.pixels, output_pixels, 0..) |in_px, out_px, i| {
        const err = color_mod.deltaE(in_px, out_px);
        if (err > 1e-4) {
            std.debug.print("Phase5 pixel {} mismatch: deltaE={d:.6}\n", .{ i, err });
            return error.PixelMismatch;
        }
    }

    // Assert 2: Tileset has exactly 4 unique tiles
    try std.testing.expectEqual(@as(usize, 4), result.unique_tiles.len);

    // Assert 3: Tilemap is 2x2 with each of 0,1,2,3 appearing exactly once
    try std.testing.expectEqual(@as(usize, 4), result.tilemap.len);
    var tile_seen = [4]bool{ false, false, false, false };
    for (result.tilemap) |entry| {
        if (entry.tile_index >= 4) {
            std.debug.print("Phase5: unexpected tile_index={}\n", .{entry.tile_index});
            return error.UnexpectedTileIndex;
        }
        tile_seen[entry.tile_index] = true;
    }
    for (tile_seen, 0..) |seen, idx| {
        if (!seen) {
            std.debug.print("Phase5: tile_index {} never appeared in tilemap\n", .{idx});
            return error.MissingTileIndex;
        }
    }

    // Assert 4: All tilemap entries have palette_index=0
    for (result.tilemap, 0..) |entry, i| {
        if (entry.palette_index != 0) {
            std.debug.print("Phase5 tilemap[{}] palette_index={} expected 0\n", .{ i, entry.palette_index });
            return error.WrongPaletteIndex;
        }
    }

    // Assert 5: The palette contains all 16 test colors (order-independent).
    // We check by using the same image pipeline: each test color should be recoverable.
    // Approach: the pixel-perfect check (Assert 1) already guarantees each input color
    // maps to an output color within deltaE < 1e-4. Since the input uses exactly the 16
    // test colors, and each input pixel reconstructs correctly, we know the palette
    // is suitable. The per-color palette check would require sRGB->OKLab conversion
    // which is already validated by the zigimg pipeline used in buildTestImage.
    // We just verify the palette has exactly 16 colors.
    const palette = result.palettes[0];
    try std.testing.expectEqual(@as(usize, 16), palette.colors.len);
}

/// 4 groups of 16 colors, one per quadrant of the 16x16 image
const phase6_color_groups = [4][16][3]u8{
    // Group 0: reds
    .{ .{ 255, 0, 0 }, .{ 230, 0, 0 }, .{ 200, 0, 0 }, .{ 180, 0, 0 }, .{ 160, 0, 0 }, .{ 140, 0, 0 }, .{ 120, 0, 0 }, .{ 100, 0, 0 }, .{ 80, 0, 0 }, .{ 60, 0, 0 }, .{ 40, 0, 0 }, .{ 255, 20, 20 }, .{ 255, 40, 40 }, .{ 255, 60, 60 }, .{ 255, 80, 80 }, .{ 255, 100, 100 } },
    // Group 1: greens
    .{ .{ 0, 255, 0 }, .{ 0, 230, 0 }, .{ 0, 200, 0 }, .{ 0, 180, 0 }, .{ 0, 160, 0 }, .{ 0, 140, 0 }, .{ 0, 120, 0 }, .{ 0, 100, 0 }, .{ 0, 80, 0 }, .{ 0, 60, 0 }, .{ 0, 40, 0 }, .{ 20, 255, 20 }, .{ 40, 255, 40 }, .{ 60, 255, 60 }, .{ 80, 255, 80 }, .{ 100, 255, 100 } },
    // Group 2: blues
    .{ .{ 0, 0, 255 }, .{ 0, 0, 230 }, .{ 0, 0, 200 }, .{ 0, 0, 180 }, .{ 0, 0, 160 }, .{ 0, 0, 140 }, .{ 0, 0, 120 }, .{ 0, 0, 100 }, .{ 0, 0, 80 }, .{ 0, 0, 60 }, .{ 0, 0, 40 }, .{ 20, 20, 255 }, .{ 40, 40, 255 }, .{ 60, 60, 255 }, .{ 80, 80, 255 }, .{ 100, 100, 255 } },
    // Group 3: yellows
    .{ .{ 255, 255, 0 }, .{ 230, 230, 0 }, .{ 200, 200, 0 }, .{ 180, 180, 0 }, .{ 160, 160, 0 }, .{ 140, 140, 0 }, .{ 120, 120, 0 }, .{ 100, 100, 0 }, .{ 80, 80, 0 }, .{ 60, 60, 0 }, .{ 40, 40, 0 }, .{ 255, 255, 20 }, .{ 255, 255, 40 }, .{ 255, 255, 60 }, .{ 255, 255, 80 }, .{ 255, 255, 100 } },
};

/// Build a 16x16 image with 4 copies of the same spatial pattern but each quadrant
/// using a completely different set of 16 colors (64 distinct colors total).
fn buildTestImage16x16MultiPalette(allocator: std.mem.Allocator) !LoadedImage {
    const width: u32 = 16;
    const height: u32 = 16;

    var image = try zigimg.Image.create(allocator, width, height, .rgb24);
    defer image.deinit(allocator);

    for (0..height) |y| {
        for (0..width) |x| {
            const local_x = x % 8;
            const local_y = y % 8;
            const quadrant = (y / 8) * 2 + (x / 8);
            const i = local_y * 8 + local_x; // 0..63
            // Same spatial pattern for all quadrants: pixel i uses color[i/4]
            const color_idx = i / 4;
            const rgb = phase6_color_groups[quadrant][color_idx];
            image.pixels.rgb24[y * width + x] = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
        }
    }

    try image.convert(allocator, .float32);
    const oklab_pixels = try zigimg.color.sRGB.sliceToOklabAlphaCopy(
        allocator,
        image.pixels.float32,
    );

    return LoadedImage{
        .pixels = oklab_pixels,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

test "Phase 6: 4 identical tile shapes, 4 different color sets -> 4 palettes, 1 unique tile" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    var img = try buildTestImage16x16MultiPalette(gpa);
    defer img.deinit();

    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 2,
        .tilemap_height = 2,
        .num_palettes = 4,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = try pipeline.run(arena.allocator(), cfg, img);
    defer arena.deinit();

    // Assert 1: Pixel-perfect reconstruction (deltaE < 1e-4 per pixel)
    const output_pixels = result.output_pixels;
    try std.testing.expectEqual(img.pixels.len, output_pixels.len);
    for (img.pixels, output_pixels, 0..) |in_px, out_px, i| {
        const err = color_mod.deltaE(in_px, out_px);
        if (err > 1e-4) {
            std.debug.print("Phase6 pixel {} mismatch: deltaE={d:.6}\n", .{ i, err });
            return error.PixelMismatch;
        }
    }

    // Assert 2: Tileset has exactly 1 unique tile
    if (result.unique_tiles.len != 1) {
        std.debug.print("Phase6: expected 1 unique tile, got {}\n", .{result.unique_tiles.len});
        return error.WrongUniqueTileCount;
    }

    // Assert 3: Tilemap is 2x2, tile_index=0 for all 4 entries
    try std.testing.expectEqual(@as(usize, 4), result.tilemap.len);
    for (result.tilemap, 0..) |entry, i| {
        if (entry.tile_index != 0) {
            std.debug.print("Phase6 tilemap[{}] tile_index={} expected 0\n", .{ i, entry.tile_index });
            return error.WrongTileIndex;
        }
    }

    // Assert 4: 4 distinct palette_index values appear in the tilemap
    var palette_seen = [4]bool{ false, false, false, false };
    for (result.tilemap) |entry| {
        if (entry.palette_index >= 4) {
            std.debug.print("Phase6: unexpected palette_index={}\n", .{entry.palette_index});
            return error.UnexpectedPaletteIndex;
        }
        palette_seen[entry.palette_index] = true;
    }
    for (palette_seen, 0..) |seen, idx| {
        if (!seen) {
            std.debug.print("Phase6: palette_index {} never appeared in tilemap\n", .{idx});
            return error.MissingPaletteIndex;
        }
    }
}

test "Palette reduce_colors: frequency-weighted centroids for skewed distributions" {
    // Tests that when there are more unique colors than colors_per_palette,
    // the reduction produces palette entries that faithfully represent the
    // dominant color (the one appearing in most pixels).
    //
    // Scenario: 64 pixels — 60 pixels use a dominant color A (L=0.50, a=0.0, b=0.0),
    // and 4 pixels use rare colors B/C/D/E that are far from A in OKLab.
    // With colors_per_palette=4, there are 5 unique colors → reduction needed.
    //
    // K-means on 5 equal-weight colors with k=4: A and B (the two closest colors,
    // since B=0.55 is closest to A=0.50) get grouped together. Their unweighted
    // centroid is 0.525 — noticeably far from A.
    //
    // With frequency-weighted centroids: (60*0.50 + 1*0.55)/61 = 0.5008 — very
    // close to A. Any pixel of color A reconstructed via the palette should have
    // deltaE < 0.005 (instead of ~0.025 without frequency weighting).
    const tile_mod = lib.tile;
    const palette_gen_mod = lib.palette;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Color A: dominant (60 pixels), L=0.50, neutral (a=b=0)
    // Color B: rare (1 pixel), L=0.55, very close to A → will cluster with A in k-means
    // Colors C,D,E: rare (1 pixel each), L=0.10, 0.20, 0.30 → far from A
    const color_a = OklabAlpha{ .l = 0.50, .a = 0.0, .b = 0.0, .alpha = 1.0 };
    const color_b = OklabAlpha{ .l = 0.55, .a = 0.0, .b = 0.0, .alpha = 1.0 };
    const color_c = OklabAlpha{ .l = 0.10, .a = 0.0, .b = 0.0, .alpha = 1.0 };
    const color_d = OklabAlpha{ .l = 0.20, .a = 0.0, .b = 0.0, .alpha = 1.0 };
    const color_e = OklabAlpha{ .l = 0.30, .a = 0.0, .b = 0.0, .alpha = 1.0 };

    // Build one tile: 60 pixels of A, then 1 each of B, C, D, E (total 64)
    const tile_pixels = try alloc.alloc(OklabAlpha, 64);
    @memset(tile_pixels, color_a);
    tile_pixels[60] = color_b;
    tile_pixels[61] = color_c;
    tile_pixels[62] = color_d;
    tile_pixels[63] = color_e;

    const tiles = [_]tile_mod.Tile{.{
        .pixels = tile_pixels,
        .width = 8,
        .height = 8,
        .has_transparent = false,
    }};

    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .colors_per_palette = 4,     // Only 4 slots → 5 unique colors triggers reduction
        .color_similarity_threshold = 0.001, // Tight: no color merging
        .palette_0_color_0_is_black = false,
        .palette_kmeans_max_iter = 10_000,
    };

    const palette = try palette_gen_mod.generatePaletteFromTiles(alloc, &tiles, cfg);

    // The palette must have a representative close to color_a.
    // With frequency-weighted centroids, the representative for A's cluster
    // should be within deltaE < 0.005 of A (actual ≈ 0.0008).
    // Without frequency weighting, the representative would be the midpoint
    // of {A, B} = L=0.525, giving deltaE(A, 0.525) ≈ 0.025 — failing this check.
    var min_de_from_a: f32 = std.math.floatMax(f32);
    for (palette.colors[0..palette.count]) |c| {
        const de = color_mod.deltaE(color_a, c);
        if (de < min_de_from_a) min_de_from_a = de;
    }

    if (min_de_from_a > 0.005) {
        std.debug.print(
            "reduce_colors: nearest palette entry to dominant color A has deltaE={d:.4} > 0.005\n" ++
                "(without frequency weighting, k-means center of {{A,B}} ≈ 0.525, deltaE ≈ 0.025)\n",
            .{min_de_from_a},
        );
        return error.DominantColorNotWellRepresented;
    }
}

test "Phase 6 extended: palettes are sorted by average luminance (ascending)" {
    // Verifies that after palette generation, palettes are ordered by their average
    // OKLab luminance (palette[0] is darkest, palette[n-1] is brightest).
    // The Phase 6 image has reds, greens, blues, yellows — yellows are much brighter
    // in OKLab (L≈0.88-0.97) than reds/blues (L≈0.28-0.63), so yellows must be last.
    // Without luminance sorting, palette order depends on random k-means initialization.
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    var img = try buildTestImage16x16MultiPalette(gpa);
    defer img.deinit();

    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 2,
        .tilemap_height = 2,
        .num_palettes = 4,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = try pipeline.run(arena.allocator(), cfg, img);
    defer arena.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.palettes.len);

    // Compute average luminance of each palette (over valid colors only)
    var avg_l: [4]f32 = undefined;
    for (result.palettes, 0..) |pal, pi| {
        var sum_l: f32 = 0;
        const valid_count: u32 = @min(pal.count, @as(u32, @intCast(pal.colors.len)));
        for (pal.colors[0..valid_count]) |c| sum_l += c.l;
        avg_l[pi] = if (valid_count > 0) sum_l / @as(f32, @floatFromInt(valid_count)) else 0;
    }

    // Assert ascending sort: palette[i].avg_L <= palette[i+1].avg_L
    for (0..3) |i| {
        if (avg_l[i] > avg_l[i + 1] + 1e-4) {
            std.debug.print(
                "Palette luminance sort violated: avg_L[{}]={d:.4} > avg_L[{}]={d:.4}\n",
                .{ i, avg_l[i], i + 1, avg_l[i + 1] },
            );
            return error.PalettesNotSortedByLuminance;
        }
    }

    // The brightest palette (yellows, L≈0.9) must be palette[3] and much brighter than palette[0]
    if (avg_l[3] - avg_l[0] < 0.2) {
        std.debug.print(
            "Expected large luminance spread between palette[0]={d:.4} and palette[3]={d:.4}\n",
            .{ avg_l[0], avg_l[3] },
        );
        return error.PaletteLuminanceRangeTooSmall;
    }
}

test "Phase 2: 8x8 single tile, 16 exact colors, pixel-perfect reconstruction" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    var img = try buildTestImage(gpa);
    defer img.deinit();

    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 1,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = try pipeline.run(arena.allocator(), cfg, img);
    defer arena.deinit();

    // Assert 1: Tileset has exactly 1 unique tile
    try std.testing.expectEqual(@as(usize, 1), result.unique_tiles.len);

    // Assert 2: Tilemap has exactly 1 entry
    try std.testing.expectEqual(@as(usize, 1), result.tilemap.len);

    // Assert 3: The tilemap entry points to tile 0, palette 0
    const entry = result.tilemap[0];
    try std.testing.expectEqual(@as(u8, 0), entry.tile_index);
    try std.testing.expectEqual(@as(u6, 0), entry.palette_index);

    // Assert 4: Pixel-perfect reconstruction
    // Every output pixel must match the input pixel exactly.
    // Since no dithering and 16 exact colors in palette, quantization is lossless.
    const output_pixels = result.output_pixels;
    try std.testing.expectEqual(img.pixels.len, output_pixels.len);

    for (img.pixels, output_pixels, 0..) |in_px, out_px, i| {
        const err = color_mod.deltaE(in_px, out_px);
        if (err > 1e-4) {
            std.debug.print(
                "Pixel {} mismatch: in=({d:.4},{d:.4},{d:.4}) out=({d:.4},{d:.4},{d:.4}) deltaE={d:.6}\n",
                .{ i, in_px.l, in_px.a, in_px.b, out_px.l, out_px.a, out_px.b, err },
            );
            return error.PixelMismatch;
        }
    }
}

/// Build an 8x8 image with a smooth gradient (64 distinct colors, limited to 16-color palette).
fn buildGradientImage8x8(allocator: std.mem.Allocator) !LoadedImage {
    const width: u32 = 8;
    const height: u32 = 8;

    var image = try zigimg.Image.create(allocator, width, height, .rgb24);
    defer image.deinit(allocator);

    // Create a gradient from red to blue across 64 pixels
    for (0..64) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 63.0;
        const r: u8 = @intFromFloat(255.0 * (1.0 - t));
        const g: u8 = @intFromFloat(255.0 * @abs(0.5 - t) * 2.0);
        const b: u8 = @intFromFloat(255.0 * t);
        image.pixels.rgb24[i] = .{ .r = r, .g = g, .b = b };
    }

    try image.convert(allocator, .float32);
    const oklab_pixels = try zigimg.color.sRGB.sliceToOklabAlphaCopy(
        allocator,
        image.pixels.float32,
    );

    return LoadedImage{
        .pixels = oklab_pixels,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

test "Phase 7: Sierra dithering changes output compared to no dithering" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    // Use the gradient image. The 16-color palette is generated by k-means but
    // for the dithering comparison test we'll use the SAME palette for both runs.
    // Strategy: run no-dither first, capture the palette, then run both no-dither
    // and sierra-dither using quantization only (not re-generating palettes).
    //
    // For simplicity, just verify that Sierra dithering produces a DIFFERENT output
    // than no-dithering on the gradient image. We don't need it to be better - just
    // that the dithering code is actually doing something.
    var img = try buildGradientImage8x8(gpa);
    defer img.deinit();

    const base_cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 1,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 4, // Only 4 colors so quantization error is large
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    var cfg_none = base_cfg;
    cfg_none.dither_algorithm = .none;
    var arena = std.heap.ArenaAllocator.init(gpa);
    const result_none = try pipeline.run(arena.allocator(), cfg_none, img);
    defer arena.deinit();

    var cfg_sierra = base_cfg;
    cfg_sierra.dither_algorithm = .sierra;
    cfg_sierra.dither_factor = 1.0;

    const result_sierra = try pipeline.run(arena.allocator(), cfg_sierra, img);

    // Sierra should produce different output than no-dither (pixels should differ)
    var diff_count: usize = 0;
    for (result_none.output_pixels, result_sierra.output_pixels) |pn, ps| {
        if (color_mod.deltaE(pn, ps) > 0.001) {
            diff_count += 1;
        }
    }
    std.debug.print("Phase7: Sierra changed {}/{} pixels vs no-dither\n", .{ diff_count, result_none.output_pixels.len });

    // Sierra dithering must change at least some pixels
    if (diff_count == 0) {
        return error.DitherProducedNoChange;
    }

    // Test that dither_factor=0.0 gives same result as dither=none
    // Use the exact-16-color image so palette is deterministic (no k-means needed).
    var img2 = try buildTestImage(gpa);
    defer img2.deinit();

    const exact_cfg_none = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 1,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    const result_exact_none = try pipeline.run(arena.allocator(), exact_cfg_none, img2);

    const exact_cfg_zero = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 1,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .sierra,
        .dither_factor = 0.0,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    const result_exact_zero = try pipeline.run(arena.allocator(), exact_cfg_zero, img2);

    for (result_exact_none.output_pixels, result_exact_zero.output_pixels, 0..) |pn, pz, i| {
        const err = color_mod.deltaE(pn, pz);
        if (err > 1e-5) {
            std.debug.print("Phase7 dither_factor=0 pixel {} differs from no-dither: deltaE={d:.8}\n", .{ i, err });
            return error.ZeroStrengthNotIdentical;
        }
    }
}

/// Build an 8x8 image with a mix of opaque and transparent pixels.
/// Top-left 4x4 quadrant: opaque with 8 distinct colors
/// Bottom-right 4x4 quadrant: transparent (alpha=0)
/// Other quadrants: opaque with remaining 8 colors
fn buildTransparentTestImage(allocator: std.mem.Allocator) !LoadedImage {
    const width: u32 = 8;
    const height: u32 = 8;
    const n = width * height;

    const pixels = try allocator.alloc(OklabAlpha, n);

    // Convert test_colors_rgb to OKLab via zigimg
    var image = try zigimg.Image.create(allocator, width, height, .rgba32);
    defer image.deinit(allocator);

    for (0..height) |y| {
        for (0..width) |x| {
            const i = y * width + x;
            // Bottom-right quadrant (y>=4 and x>=4): transparent
            const is_transparent = (y >= 4 and x >= 4);
            const color_idx = i / 4;
            const rgb = test_colors_rgb[color_idx];
            if (is_transparent) {
                image.pixels.rgba32[i] = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            } else {
                image.pixels.rgba32[i] = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
            }
        }
    }

    try image.convert(allocator, .float32);
    const oklab_pixels_tmp = try zigimg.color.sRGB.sliceToOklabAlphaCopy(
        allocator,
        image.pixels.float32,
    );
    defer allocator.free(oklab_pixels_tmp);

    // Copy into our pixel buffer
    @memcpy(pixels, oklab_pixels_tmp);

    return LoadedImage{
        .pixels = pixels,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

test "Phase 8A: transparency_mode=alpha preserves transparent pixels" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    var img = try buildTransparentTestImage(gpa);
    defer img.deinit();

    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 1,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .alpha,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = try pipeline.run(arena.allocator(), cfg, img);
    defer arena.deinit();

    // Assert: tilemap entry has transparent=true
    const entry = result.tilemap[0];
    if (!entry.transparent) {
        std.debug.print("Phase8A: expected transparent=true for tile with transparent pixels\n", .{});
        return error.ExpectedTransparent;
    }

    // Assert: transparent pixels in output have alpha close to 0
    const output_pixels = result.output_pixels;
    for (img.pixels, output_pixels, 0..) |in_px, out_px, i| {
        const y = i / 8;
        const x = i % 8;
        const is_transparent = (y >= 4 and x >= 4);
        if (is_transparent) {
            if (out_px.alpha > 0.1) {
                std.debug.print("Phase8A: transparent pixel {} has alpha={d:.4} expected 0\n", .{ i, out_px.alpha });
                return error.TransparentPixelNotTransparent;
            }
        } else {
            // Opaque pixels should match input
            const err = color_mod.deltaE(in_px, out_px);
            if (err > 1e-4) {
                std.debug.print("Phase8A: opaque pixel {} mismatch: deltaE={d:.6}\n", .{ i, err });
                return error.OpaquePixelMismatch;
            }
        }
    }
}

test "Phase 8B: transparency_mode=alpha, all opaque -> transparent=false" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    var img = try buildTestImage(gpa);
    defer img.deinit();

    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 1,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .alpha,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = try pipeline.run(arena.allocator(), cfg, img);
    defer arena.deinit();

    // All-opaque image: tilemap entry should have transparent=false
    const entry = result.tilemap[0];
    if (entry.transparent) {
        std.debug.print("Phase8B: expected transparent=false for all-opaque tile\n", .{});
        return error.UnexpectedTransparent;
    }
}

test "Phase 8C: transparency_mode=none ignores alpha channel" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    var img = try buildTransparentTestImage(gpa);
    defer img.deinit();

    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 1,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = try pipeline.run(arena.allocator(), cfg, img);
    defer arena.deinit();

    // transparency_mode=none: all tilemap entries should have transparent=false
    for (result.tilemap, 0..) |entry, i| {
        if (entry.transparent) {
            std.debug.print("Phase8C: tilemap[{}] transparent=true but mode=none\n", .{i});
            return error.UnexpectedTransparent;
        }
    }
}

/// Build a 16x8 image where the right 8x8 half is the horizontal mirror of the left 8x8 half.
fn buildMirroredTestImage(allocator: std.mem.Allocator) !LoadedImage {
    const width: u32 = 16;
    const height: u32 = 8;

    var image = try zigimg.Image.create(allocator, width, height, .rgb24);
    defer image.deinit(allocator);

    for (0..height) |y| {
        for (0..8) |x| {
            const i = y * 8 + x;
            const color_idx = i / 4;
            const rgb = test_colors_rgb[color_idx];
            // Left tile: normal
            image.pixels.rgb24[y * width + x] = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
            // Right tile: horizontally mirrored (flip x)
            image.pixels.rgb24[y * width + (15 - x)] = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
        }
    }

    try image.convert(allocator, .float32);
    const oklab_pixels = try zigimg.color.sRGB.sliceToOklabAlphaCopy(
        allocator,
        image.pixels.float32,
    );

    return LoadedImage{
        .pixels = oklab_pixels,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

test "Phase 9: x_flip deduplication - mirrored tile deduplicates to 1 unique tile" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    var img = try buildMirroredTestImage(gpa);
    defer img.deinit();

    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 2,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = try pipeline.run(arena.allocator(), cfg, img);
    defer arena.deinit();

    // Assert 1: Pixel-perfect reconstruction
    const output_pixels = result.output_pixels;
    try std.testing.expectEqual(img.pixels.len, output_pixels.len);
    for (img.pixels, output_pixels, 0..) |in_px, out_px, i| {
        const err = color_mod.deltaE(in_px, out_px);
        if (err > 1e-4) {
            std.debug.print("Phase9 pixel {} mismatch: deltaE={d:.6}\n", .{ i, err });
            return error.PixelMismatch;
        }
    }

    // Assert 2: Tileset has exactly 1 unique tile
    if (result.unique_tiles.len != 1) {
        std.debug.print("Phase9: expected 1 unique tile, got {}\n", .{result.unique_tiles.len});
        return error.WrongUniqueTileCount;
    }

    // Assert 3: Tilemap is 2 entries (2x1)
    try std.testing.expectEqual(@as(usize, 2), result.tilemap.len);

    // Assert 4: One entry has x_flip=false and one has x_flip=true
    const entry0 = result.tilemap[0];
    const entry1 = result.tilemap[1];

    if (entry0.tile_index != 0 or entry1.tile_index != 0) {
        std.debug.print("Phase9: both entries should reference tile 0, got {} and {}\n", .{ entry0.tile_index, entry1.tile_index });
        return error.WrongTileIndex;
    }

    // Exactly one should have x_flip=true, the other x_flip=false
    if (entry0.x_flip == entry1.x_flip) {
        std.debug.print("Phase9: expected one x_flip=false and one x_flip=true, got {} and {}\n", .{ entry0.x_flip, entry1.x_flip });
        return error.WrongXFlip;
    }
}

// =============================================================================
// Phase 10: Output format tests
// =============================================================================

test "Phase 10: hex tilemap format - basic entries" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    const tilemap = [_]TilemapEntry{
        TilemapEntry{ .tile_index = 1, .palette_index = 0, .transparent = false, .x_flip = false },
        TilemapEntry{ .tile_index = 2, .palette_index = 1, .transparent = false, .x_flip = false },
    };
    // tile_index=1 -> 0x0001, tile_index=2 palette_index=1 -> 0x0102
    try hex_out.writeTilemapHex(buf.writer(std.testing.allocator).any(), &tilemap, 2, false);
    try std.testing.expectEqualStrings("0001 0102 \n", buf.items);
}

test "Phase 10: hex tilemap format - logisim header" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    const tilemap = [_]TilemapEntry{
        TilemapEntry{ .tile_index = 1, .palette_index = 0, .transparent = false, .x_flip = false },
    };
    try hex_out.writeTilemapHex(buf.writer(std.testing.allocator).any(), &tilemap, 1, true);
    try std.testing.expectEqualStrings("v2.0 raw\n0001 \n", buf.items);
}

test "Phase 10: binary tilemap format" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    const tilemap = [_]TilemapEntry{
        TilemapEntry{ .tile_index = 1, .palette_index = 0, .transparent = false, .x_flip = false },
        TilemapEntry{ .tile_index = 2, .palette_index = 1, .transparent = false, .x_flip = false },
    };
    // 0x0001 little-endian: [0x01, 0x00], 0x0102 little-endian: [0x02, 0x01]
    try binary_out.writeTilemapBinary(buf.writer(std.testing.allocator).any(), &tilemap);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00, 0x02, 0x01 }, buf.items);
}

test "Phase 10: C array tilemap format - include guard and entries" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    const tilemap = [_]TilemapEntry{
        TilemapEntry{ .tile_index = 1, .palette_index = 0, .transparent = false, .x_flip = false },
        TilemapEntry{ .tile_index = 0xFF, .palette_index = 0x3F, .transparent = true, .x_flip = true },
    };
    const c_cfg = c_array_out.CArrayConfig{
        .var_prefix = "tilemap",
        .include_guard = "MY_TILEMAP_H",
        .entries_per_line = 8,
    };
    try c_array_out.writeTilemapCArray(buf.writer(std.testing.allocator).any(), &tilemap, c_cfg);
    // Should contain include guard
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "#ifndef MY_TILEMAP_H") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "#define MY_TILEMAP_H") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "#endif") != null);
    // Should contain the entry 0x0001
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "0x0001") != null);
    // Should contain 0xFFFF
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "0xFFFF") != null);
}

test "Phase 10: tileset row-major storage" {
    // 2 tiles:
    // tile0: row 0 = [1,2,3,4,1,2,3,4], all other rows = 0
    // tile1: row 0 = [5,6,7,8,5,6,7,8], all other rows = 0
    const tile_w: usize = 8;
    const tile_h: usize = 8;
    const n = tile_w * tile_h;

    var data0 = [_]u8{0} ** n;
    data0[0] = 1; data0[1] = 2; data0[2] = 3; data0[3] = 4;
    data0[4] = 1; data0[5] = 2; data0[6] = 3; data0[7] = 4;

    var data1 = [_]u8{0} ** n;
    data1[0] = 5; data1[1] = 6; data1[2] = 7; data1[3] = 8;
    data1[4] = 5; data1[5] = 6; data1[6] = 7; data1[7] = 8;

    const tiles = [_]QuantizedTile{
        QuantizedTile{ .data = &data0, .width = 8, .height = 8 },
        QuantizedTile{ .data = &data1, .width = 8, .height = 8 },
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try hex_out.writeTilesetHexRowMajor(buf.writer(std.testing.allocator).any(), &tiles, tile_h, tile_w, 2, false);

    // Row 0: tile0 chunk0 = 1|(2<<4)|(3<<8)|(4<<12) = 0x4321, chunk1 = 0x4321
    // tile1 chunk0 = 5|(6<<4)|(7<<8)|(8<<12) = 0x8765, chunk1 = 0x8765
    // First line: "4321 4321 8765 8765 \n"
    const lines = buf.items;
    const first_newline = std.mem.indexOfScalar(u8, lines, '\n') orelse return error.NoNewline;
    const first_line = lines[0..first_newline + 1];
    try std.testing.expectEqualStrings("4321 4321 8765 8765 \n", first_line);
}

test "Phase 10: tileset sequential storage" {
    const tile_w: usize = 8;
    const tile_h: usize = 8;
    const n = tile_w * tile_h;

    var data0 = [_]u8{0} ** n;
    data0[0] = 1; data0[1] = 2; data0[2] = 3; data0[3] = 4;
    data0[4] = 1; data0[5] = 2; data0[6] = 3; data0[7] = 4;

    var data1 = [_]u8{0} ** n;
    data1[0] = 5; data1[1] = 6; data1[2] = 7; data1[3] = 8;
    data1[4] = 5; data1[5] = 6; data1[6] = 7; data1[7] = 8;

    const tiles = [_]QuantizedTile{
        QuantizedTile{ .data = &data0, .width = 8, .height = 8 },
        QuantizedTile{ .data = &data1, .width = 8, .height = 8 },
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try hex_out.writeTilesetHexSequential(buf.writer(std.testing.allocator).any(), &tiles, tile_h, tile_w, false);

    // Sequential: tile0 row0, tile0 row1..7, then tile1 row0, tile1 row1..7
    // All 8-tile-row lines: each line is "XXXX XXXX \n"
    // Total lines: 2 tiles * 8 rows = 16 lines
    var line_count: usize = 0;
    var it = std.mem.splitScalar(u8, buf.items, '\n');
    while (it.next()) |_| : (line_count += 1) {}
    // 16 lines + 1 empty after final newline = 17 elements from split
    try std.testing.expectEqual(@as(usize, 17), line_count);

    // First line should be tile0 row0: "4321 4321 \n"
    const first_newline = std.mem.indexOfScalar(u8, buf.items, '\n') orelse return error.NoNewline;
    const first_line = buf.items[0..first_newline + 1];
    try std.testing.expectEqualStrings("4321 4321 \n", first_line);
}

// =============================================================================
// Phase 11: Config validation and ZON serialization tests
// =============================================================================

test "Phase 11: Config validate passes for default config" {
    const cfg = Config{};
    try cfg.validate();
}

test "Phase 11: Config validate catches colors_per_palette=0" {
    const cfg = Config{ .colors_per_palette = 0 };
    try std.testing.expectError(error.ColorsPerPaletteNotPowerOfTwo, cfg.validate());
}

test "Phase 11: Config validate catches colors_per_palette not power of two" {
    const cfg = Config{ .colors_per_palette = 3 };
    try std.testing.expectError(error.ColorsPerPaletteNotPowerOfTwo, cfg.validate());
}

test "Phase 11: Config validate catches colors_per_palette > 16" {
    const cfg = Config{ .colors_per_palette = 32 };
    try std.testing.expectError(error.ColorsPerPaletteTooLarge, cfg.validate());
}

test "Phase 11: Config generateDefault produces parseable ZON" {
    var writer = std.io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    try Config.generateDefault(&writer.writer);

    // Parse back with ZON
    const source = try writer.toOwnedSliceSentinel(0);
    defer std.testing.allocator.free(source);

    // Config has many enum fields; increase comptime branch quota for ZON parsing.
    @setEvalBranchQuota(10000);
    const parsed = try std.zon.parse.fromSlice(Config, std.testing.allocator, source, null, .{});
    defer std.zon.parse.free(std.testing.allocator, parsed);

    // Verify defaults match
    const defaults = Config{};
    try std.testing.expectEqual(defaults.tile_width, parsed.tile_width);
    try std.testing.expectEqual(defaults.tile_height, parsed.tile_height);
    try std.testing.expectEqual(defaults.num_palettes, parsed.num_palettes);
    try std.testing.expectEqual(defaults.colors_per_palette, parsed.colors_per_palette);
}

test "Phase 10: hex tilemap multi-row wrapping" {
    // tilemap_width=2, so every 2 entries gets a newline
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    const tilemap = [_]TilemapEntry{
        TilemapEntry{ .tile_index = 0, .palette_index = 0, .transparent = false, .x_flip = false },
        TilemapEntry{ .tile_index = 1, .palette_index = 0, .transparent = false, .x_flip = false },
        TilemapEntry{ .tile_index = 2, .palette_index = 0, .transparent = false, .x_flip = false },
        TilemapEntry{ .tile_index = 3, .palette_index = 0, .transparent = false, .x_flip = false },
    };
    try hex_out.writeTilemapHex(buf.writer(std.testing.allocator).any(), &tilemap, 2, false);
    try std.testing.expectEqualStrings("0000 0001 \n0002 0003 \n", buf.items);
}

// =============================================================================
// Phase 12: Multi-file processing tests
// =============================================================================

/// Build a pixel pattern for multi-file tests.
/// pattern_idx 0 = P1 (sequential), 1 = P2 (reversed), 2 = P3 (permuted)
fn buildPattern(pattern_idx: u8, pixel_i: usize) [3]u8 {
    const color_i: usize = switch (pattern_idx) {
        0 => pixel_i / 4, // P1: sequential
        1 => (63 - pixel_i) / 4, // P2: reversed
        2 => (pixel_i * 3) % 16, // P3: permuted
        else => 0,
    };
    return test_colors_rgb[color_i];
}

/// Build a 16x8 image (2 tiles wide, 1 tile tall).
/// Left tile (x < 8) uses pattern_a, right tile (x >= 8) uses pattern_b.
fn buildTestImageMultiFile(
    allocator: std.mem.Allocator,
    pattern_a: u8,
    pattern_b: u8,
) !LoadedImage {
    const width: u32 = 16;
    const height: u32 = 8;

    var image = try zigimg.Image.create(allocator, width, height, .rgb24);
    defer image.deinit(allocator);

    for (0..height) |y| {
        for (0..width) |x| {
            const tile_x = x / 8; // 0 or 1
            const local_x = x % 8;
            const local_i = y * 8 + local_x; // pixel within tile (0..63)
            const pattern = if (tile_x == 0) pattern_a else pattern_b;
            const rgb = buildPattern(pattern, local_i);
            image.pixels.rgb24[y * width + x] = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
        }
    }

    try image.convert(allocator, .float32);
    const oklab_pixels = try zigimg.color.sRGB.sliceToOklabAlphaCopy(
        allocator,
        image.pixels.float32,
    );

    return LoadedImage{
        .pixels = oklab_pixels,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

test "Phase 12: shared palette, shared tileset - common tiles appear once" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    // Image A: tile0=P1, tile1=P2
    var img_a = try buildTestImageMultiFile(gpa, 0, 1);
    defer img_a.deinit();

    // Image B: tile0=P1 (same as A's tile0), tile1=P3
    var img_b = try buildTestImageMultiFile(gpa, 0, 2);
    defer img_b.deinit();

    const cfg = config_mod.Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 2,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
        .palette_strategy = .shared,
        .tileset_strategy = .shared,
    };

    const images = [_]LoadedImage{ img_a, img_b };
    var arena = std.heap.ArenaAllocator.init(gpa);
    const mresults = try lib.pipeline.runMulti(arena.allocator(), cfg, &images);
    defer arena.deinit();

    // Assert 1: shared tileset -> results[0] and results[1] have same unique_tiles pointer
    try std.testing.expectEqual(
        mresults[0].unique_tiles.ptr,
        mresults[1].unique_tiles.ptr,
    );

    // Assert 2: shared tileset has exactly 3 unique tiles (P1, P2, P3)
    try std.testing.expectEqual(@as(usize, 3), mresults[0].unique_tiles.len);

    // Assert 3: Image A tilemap[0] and Image B tilemap[0] point to the same tile index (P1)
    try std.testing.expectEqual(
        mresults[0].tilemap[0].tile_index,
        mresults[1].tilemap[0].tile_index,
    );

    // Assert 4: shared palette -> same palette pointer for both results
    try std.testing.expectEqual(
        mresults[0].palettes.ptr,
        mresults[1].palettes.ptr,
    );

    // Assert 5: pixel-perfect reconstruction for both images
    for (mresults, [_]LoadedImage{ img_a, img_b }, 0..) |res, orig_img, img_idx| {
        const output_pixels = res.output_pixels;
        try std.testing.expectEqual(orig_img.pixels.len, output_pixels.len);
        for (orig_img.pixels, output_pixels, 0..) |in_px, out_px, i| {
            const err = color_mod.deltaE(in_px, out_px);
            if (err > 1e-4) {
                std.debug.print("Phase12A img{} pixel {} mismatch: deltaE={d:.6}\n", .{ img_idx, i, err });
                return error.PixelMismatch;
            }
        }
    }
}

test "Phase 12: per-file palette, shared tileset - common tiles with separate palettes" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    var img_a = try buildTestImageMultiFile(gpa, 0, 1);
    defer img_a.deinit();

    var img_b = try buildTestImageMultiFile(gpa, 0, 2);
    defer img_b.deinit();

    const cfg = config_mod.Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 2,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
        .palette_strategy = .per_file,
        .tileset_strategy = .shared,
    };

    const images = [_]LoadedImage{ img_a, img_b };
    var arena = std.heap.ArenaAllocator.init(gpa);
    const mresults = try lib.pipeline.runMulti(arena.allocator(), cfg, &images);
    defer arena.deinit();

    // Assert 1: per-file palette -> different palette pointers
    try std.testing.expect(
        mresults[0].palettes.ptr != mresults[1].palettes.ptr,
    );

    // Assert 2: shared tileset -> same unique_tiles pointer
    try std.testing.expectEqual(
        mresults[0].unique_tiles.ptr,
        mresults[1].unique_tiles.ptr,
    );

    // Assert 3: tileset has exactly 3 unique tiles (P1, P2, P3)
    try std.testing.expectEqual(@as(usize, 3), mresults[0].unique_tiles.len);

    // Assert 4: pixel-perfect reconstruction
    for (mresults, [_]LoadedImage{ img_a, img_b }, 0..) |res, orig_img, img_idx| {
        for (orig_img.pixels, res.output_pixels, 0..) |in_px, out_px, i| {
            const err = color_mod.deltaE(in_px, out_px);
            if (err > 1e-4) {
                std.debug.print("Phase12B img{} pixel {} mismatch: deltaE={d:.6}\n", .{ img_idx, i, err });
                return error.PixelMismatch;
            }
        }
    }
}

test "Phase 12: shared palette, per-file tileset - each image has own tileset" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    var img_a = try buildTestImageMultiFile(gpa, 0, 1);
    defer img_a.deinit();

    var img_b = try buildTestImageMultiFile(gpa, 0, 2);
    defer img_b.deinit();

    const cfg = config_mod.Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 2,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
        .palette_strategy = .shared,
        .tileset_strategy = .per_file,
    };

    const images = [_]LoadedImage{ img_a, img_b };
    var arena = std.heap.ArenaAllocator.init(gpa);
    const mresults = try lib.pipeline.runMulti(arena.allocator(), cfg, &images);
    defer arena.deinit();

    // Assert 1: per-file tileset -> different unique_tiles pointers
    try std.testing.expect(
        mresults[0].unique_tiles.ptr != mresults[1].unique_tiles.ptr,
    );

    // Assert 2: each image has 2 unique tiles (P1+P2 for A, P1+P3 for B)
    try std.testing.expectEqual(@as(usize, 2), mresults[0].unique_tiles.len);
    try std.testing.expectEqual(@as(usize, 2), mresults[1].unique_tiles.len);

    // Assert 3: shared palette -> same palette pointer
    try std.testing.expectEqual(
        mresults[0].palettes.ptr,
        mresults[1].palettes.ptr,
    );

    // Assert 4: pixel-perfect reconstruction
    for (mresults, [_]LoadedImage{ img_a, img_b }, 0..) |res, orig_img, img_idx| {
        for (orig_img.pixels, res.output_pixels, 0..) |in_px, out_px, i| {
            const err = color_mod.deltaE(in_px, out_px);
            if (err > 1e-4) {
                std.debug.print("Phase12C img{} pixel {} mismatch: deltaE={d:.6}\n", .{ img_idx, i, err });
                return error.PixelMismatch;
            }
        }
    }
}

// =============================================================================
// Phase 10: Tileset binary and C-array output
// =============================================================================

test "Phase 10: tileset binary - row-major produces same u16 words as hex" {
    // Same 2-tile setup as the row-major hex test
    const tile_w: usize = 8;
    const tile_h: usize = 8;
    const n = tile_w * tile_h;

    var data0 = [_]u8{0} ** n;
    data0[0] = 1; data0[1] = 2; data0[2] = 3; data0[3] = 4;
    data0[4] = 1; data0[5] = 2; data0[6] = 3; data0[7] = 4;

    var data1 = [_]u8{0} ** n;
    data1[0] = 5; data1[1] = 6; data1[2] = 7; data1[3] = 8;
    data1[4] = 5; data1[5] = 6; data1[6] = 7; data1[7] = 8;

    const tiles = [_]QuantizedTile{
        QuantizedTile{ .data = &data0, .width = 8, .height = 8 },
        QuantizedTile{ .data = &data1, .width = 8, .height = 8 },
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    // Row-major binary: tile0-row0 chunk0+chunk1, tile1-row0 chunk0+chunk1, tile0-row1 ...
    // chunk for row0 of tile0: pixels [1,2,3,4,1,2,3,4] → chunk0=0x4321, chunk1=0x4321
    // chunk for row0 of tile1: pixels [5,6,7,8,5,6,7,8] → chunk0=0x8765, chunk1=0x8765
    try binary_out.writeTilesetBinaryRowMajor(buf.writer(std.testing.allocator).any(), &tiles, tile_h, tile_w, 2);

    // First 8 bytes: row0 tile0 chunk0 (LE), chunk1 (LE), tile1 chunk0, chunk1
    // 0x4321 LE = [0x21, 0x43]
    // 0x8765 LE = [0x65, 0x87]
    try std.testing.expectEqual(@as(u8, 0x21), buf.items[0]);
    try std.testing.expectEqual(@as(u8, 0x43), buf.items[1]);
    try std.testing.expectEqual(@as(u8, 0x21), buf.items[2]);
    try std.testing.expectEqual(@as(u8, 0x43), buf.items[3]);
    try std.testing.expectEqual(@as(u8, 0x65), buf.items[4]);
    try std.testing.expectEqual(@as(u8, 0x87), buf.items[5]);
    try std.testing.expectEqual(@as(u8, 0x65), buf.items[6]);
    try std.testing.expectEqual(@as(u8, 0x87), buf.items[7]);
}

test "Phase 10: tileset C-array - row-major includes include guard and tile data" {
    const tile_w: usize = 8;
    const tile_h: usize = 8;
    const n = tile_w * tile_h;

    var data0 = [_]u8{0} ** n;
    data0[0] = 1; data0[1] = 2; data0[2] = 3; data0[3] = 4;
    data0[4] = 1; data0[5] = 2; data0[6] = 3; data0[7] = 4;

    const tiles = [_]QuantizedTile{
        QuantizedTile{ .data = &data0, .width = 8, .height = 8 },
    };

    const c_cfg = c_array_out.CArrayConfig{
        .var_prefix = "tiles",
        .include_guard = "TILES_H",
        .entries_per_line = 4,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try c_array_out.writeTilesetCArrayRowMajor(buf.writer(std.testing.allocator).any(), &tiles, tile_h, tile_w, 1, c_cfg);

    // Should contain include guard
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "#ifndef TILES_H") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "#define TILES_H") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "#endif") != null);
    // Should contain the first row's chunk0 value: 0x4321
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "0x4321") != null);
}

// =============================================================================
// Phase 11: Additional Config tests
// =============================================================================

test "Phase 11: validate rejects num_palettes + palette_start_offset > 64" {
    const cfg = Config{
        .num_palettes = 60,
        .palette_start_offset = 10, // 60 + 10 = 70 > 64
    };
    try std.testing.expectError(error.PaletteRangeExceedsMax, cfg.validate());
}

test "Phase 11: validate accepts num_palettes + palette_start_offset = 64" {
    const cfg = Config{
        .num_palettes = 56,
        .palette_start_offset = 8, // 56 + 8 = 64 = max
    };
    try cfg.validate();
}

test "Phase 11: validate rejects max_unique_tiles + tileset_start_offset > 256" {
    const cfg = Config{
        .max_unique_tiles = 250,
        .tileset_start_offset = 10, // 250 + 10 = 260 > 256
    };
    try std.testing.expectError(error.TileRangeExceedsMax, cfg.validate());
}

test "Phase 11: validate accepts max_unique_tiles + tileset_start_offset = 256" {
    const cfg = Config{
        .max_unique_tiles = 248,
        .tileset_start_offset = 8, // 248 + 8 = 256 = max
    };
    try cfg.validate();
}

test "Phase 11: validateImageDimensions rejects non-multiple image size" {
    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 4,
        .tilemap_height = 4,
    };
    // 33x32 is not a multiple of 8 in width
    try std.testing.expectError(error.ImageDimensionsNotMultipleOfTileSize, cfg.validateImageDimensions(33, 32));
}

test "Phase 11: validateImageDimensions rejects mismatched tilemap size" {
    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 4,
        .tilemap_height = 4,
    };
    // 32x32 is valid multiples, but tilemap_width=4 means expected width=32 ✓
    // Let's use 16x32 which is a multiple but doesn't match 4*8=32 for width
    try std.testing.expectError(error.ImageWidthMismatch, cfg.validateImageDimensions(16, 32));
}

test "Phase 11: validateImageDimensions accepts valid dimensions" {
    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 4,
        .tilemap_height = 4,
    };
    try cfg.validateImageDimensions(32, 32);
}

test "Phase 11: ZON round-trip includes palette_strategy and tileset_strategy" {
    var writer = std.io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    try Config.generateDefault(&writer.writer);

    // Parse back with ZON
    const source = try writer.toOwnedSliceSentinel(0);
    defer std.testing.allocator.free(source);

    // Config has many enum fields; increase comptime branch quota for ZON parsing.
    @setEvalBranchQuota(10000);
    const parsed = try std.zon.parse.fromSlice(Config, std.testing.allocator, source, null, .{});
    defer std.zon.parse.free(std.testing.allocator, parsed);

    const defaults = Config{};
    try std.testing.expectEqual(defaults.palette_strategy, parsed.palette_strategy);
    try std.testing.expectEqual(defaults.tileset_strategy, parsed.tileset_strategy);
    try std.testing.expectEqual(defaults.transparency_mode, parsed.transparency_mode);
    try std.testing.expectEqual(defaults.palette_0_color_0_is_black, parsed.palette_0_color_0_is_black);
    try std.testing.expectEqual(defaults.dither_factor, parsed.dither_factor);
}

test "Phase 11: palette_0_color_0_is_black=true forces black at palettes[0].colors[0]" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    var img = try buildTestImage(gpa);
    defer img.deinit();

    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 1,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = true,
        .color_similarity_threshold = 0.001,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = try pipeline.run(arena.allocator(), cfg, img);
    defer arena.deinit();

    const first_color = result.palettes[0].colors[0];
    // Black in OKLab: L=0, a=0, b=0
    const eps: f32 = 1e-4;
    try std.testing.expect(@abs(first_color.l) < eps);
    try std.testing.expect(@abs(first_color.a) < eps);
    try std.testing.expect(@abs(first_color.b) < eps);
}

// =============================================================================
// Phase 10: Palette hex output
// =============================================================================

test "Phase 10: palette hex output - known palette" {
    // Build a simple palette: 2 colors, black and white in OKLab
    // Black: L=0, a=0, b=0 → sRGB (0, 0, 0) → hex "000000"
    // White: L≈1, a≈0, b≈0 → sRGB (255, 255, 255) → hex "ffffff"
    // The palette hex format (matching Rust imgconv.rs:924-942):
    //   one palette per line, {RR}{GG}{BB} per color, padded to colors_per_palette entries
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Convert sRGB to OKLab via zigimg for accurate values
    var image = try zigimg.Image.create(alloc, 2, 1, .rgb24);
    defer image.deinit(alloc);
    image.pixels.rgb24[0] = .{ .r = 0, .g = 0, .b = 0 }; // black
    image.pixels.rgb24[1] = .{ .r = 255, .g = 255, .b = 255 }; // white

    try image.convert(alloc, .float32);
    const oklab = try zigimg.color.sRGB.sliceToOklabAlphaCopy(alloc, image.pixels.float32);

    const palette = Palette{ .colors = oklab, .count = @intCast(oklab.len) };
    const palettes = [_]Palette{palette};

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try hex_out.writePaletteHex(buf.writer(std.testing.allocator).any(), &palettes, 2);

    // Expect one line: "000000 ffffff \n"
    try std.testing.expectEqualStrings("000000 ffffff \n", buf.items);
}

// =============================================================================
// Phase 11: bitsPerColorIndex, Config.load()
// =============================================================================

test "Phase 11: bitsPerColorIndex returns correct bit widths" {
    try std.testing.expectEqual(@as(u4, 4), (Config{ .colors_per_palette = 16 }).bitsPerColorIndex());
    try std.testing.expectEqual(@as(u4, 2), (Config{ .colors_per_palette = 4 }).bitsPerColorIndex());
    try std.testing.expectEqual(@as(u4, 1), (Config{ .colors_per_palette = 2 }).bitsPerColorIndex());
}

test "Phase 11: Config.load() parses ZON file with tile_width=16 and runs pipeline" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    // Write a minimal ZON config to a temp file
    const tmp_path = "/tmp/sjtilemap_test_config_phase11.zon";
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        defer f.close();
        try f.writeAll(".{ .tile_width = 16, .tile_height = 16, .tilemap_width = 1, .tilemap_height = 1, .num_palettes = 1, .colors_per_palette = 16, .dither_algorithm = .none, .transparency_mode = .none, .palette_0_color_0_is_black = false, .palette_strategy = .shared, .tileset_strategy = .shared, .tileset_storage_order = .row_major }");
    }

    const cfg = try config_mod.Config.load(gpa, tmp_path);
    try std.testing.expectEqual(@as(u32, 16), cfg.tile_width);
    try std.testing.expectEqual(@as(u32, 16), cfg.tile_height);
    try std.testing.expectEqual(@as(u32, 1), cfg.tilemap_width);
    // Other fields use ZON values (not defaults, since we wrote them explicitly)
    try std.testing.expectEqual(@as(u32, 1), cfg.num_palettes);

    // Build a 16x16 test image (single tile) with 16 unique colors
    var img = try zigimg.Image.create(gpa, 16, 16, .rgb24);
    defer img.deinit(gpa);
    for (img.pixels.rgb24, 0..) |*px, i| {
        const rgb = test_colors_rgb[i / 16];
        px.* = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
    }
    try img.convert(gpa, .float32);
    const oklab_pixels = try zigimg.color.sRGB.sliceToOklabAlphaCopy(gpa, img.pixels.float32);
    var loaded_img = LoadedImage{ .pixels = oklab_pixels, .width = 16, .height = 16, .allocator = gpa };
    defer loaded_img.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = try pipeline.run(arena.allocator(), cfg, loaded_img);
    defer arena.deinit();

    // 1 unique tile, 1x1 tilemap
    try std.testing.expectEqual(@as(usize, 1), result.unique_tiles.len);
    try std.testing.expectEqual(@as(usize, 1), result.tilemap.len);

    // The tile should have 16*16 = 256 pixel entries
    try std.testing.expectEqual(@as(usize, 256), result.unique_tiles[0].data.len);
}

// =============================================================================
// Phase 8D: transparency_mode=.color (color-key transparency)
// =============================================================================

test "Phase 8D: transparency_mode=color treats matching pixels as transparent" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    // 8x8 image: most pixels are red, a checkerboard of magenta (255, 0, 255) pixels
    // We'll mark magenta as the transparent color
    const width: u32 = 8;
    const height: u32 = 8;

    var image = try zigimg.Image.create(gpa, width, height, .rgba32);
    defer image.deinit(gpa);

    // Fill with red; checkerboard positions (even row, even col) use magenta
    for (0..height) |y| {
        for (0..width) |x| {
            const i = y * width + x;
            const is_magenta = ((y + x) % 2 == 0); // checkerboard
            if (is_magenta) {
                image.pixels.rgba32[i] = .{ .r = 255, .g = 0, .b = 255, .a = 255 };
            } else {
                image.pixels.rgba32[i] = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
            }
        }
    }

    try image.convert(gpa, .float32);
    const oklab_pixels = try zigimg.color.sRGB.sliceToOklabAlphaCopy(gpa, image.pixels.float32);
    var img = LoadedImage{ .pixels = oklab_pixels, .width = width, .height = height, .allocator = gpa };
    defer img.deinit();

    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 1,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .color,
        .transparent_color = .{ 255, 0, 255 }, // magenta is transparent
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = try pipeline.run(arena.allocator(), cfg, img);
    defer arena.deinit();

    // Assert 1: tilemap entry has transparent=true (tile contains transparent pixels)
    try std.testing.expect(result.tilemap[0].transparent);

    // Assert 2: reconstructed magenta pixels have alpha=0 (transparent)
    const output_pixels = result.output_pixels;
    for (0..height) |y| {
        for (0..width) |x| {
            const i = y * width + x;
            const is_magenta = ((y + x) % 2 == 0);
            if (is_magenta) {
                if (output_pixels[i].alpha > 0.1) {
                    std.debug.print("Phase8D: magenta pixel ({},{}) has alpha={d:.4} expected 0\n", .{ x, y, output_pixels[i].alpha });
                    return error.TransparentPixelNotTransparent;
                }
            } else {
                // Non-transparent (red) pixels should have alpha > 0
                if (output_pixels[i].alpha < 0.5) {
                    std.debug.print("Phase8D: red pixel ({},{}) has alpha={d:.4} expected 1\n", .{ x, y, output_pixels[i].alpha });
                    return error.OpaquePixelTransparent;
                }
            }
        }
    }
}

// =============================================================================
// Phase 10: writeTilesetCArraySequential
// =============================================================================

test "Phase 10: tileset C-array sequential - tile 0 complete before tile 1" {
    const tile_w: usize = 8;
    const tile_h: usize = 8;
    const n = tile_w * tile_h;

    var data0 = [_]u8{0} ** n;
    data0[0] = 1; data0[1] = 2; data0[2] = 3; data0[3] = 4;
    data0[4] = 1; data0[5] = 2; data0[6] = 3; data0[7] = 4;

    var data1 = [_]u8{0} ** n;
    data1[0] = 5; data1[1] = 6; data1[2] = 7; data1[3] = 8;
    data1[4] = 5; data1[5] = 6; data1[6] = 7; data1[7] = 8;

    const tiles = [_]QuantizedTile{
        QuantizedTile{ .data = &data0, .width = 8, .height = 8 },
        QuantizedTile{ .data = &data1, .width = 8, .height = 8 },
    };

    const c_cfg = c_array_out.CArrayConfig{
        .var_prefix = "tiles",
        .include_guard = "TILES_SEQ_H",
        .entries_per_line = 4,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try c_array_out.writeTilesetCArraySequential(buf.writer(std.testing.allocator).any(), &tiles, tile_h, tile_w, c_cfg);

    // Should contain include guard
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "#ifndef TILES_SEQ_H") != null);

    // Sequential: tile 0's row 0 data (0x4321) must appear BEFORE tile 1's row 0 data (0x8765)
    const pos0 = std.mem.indexOf(u8, buf.items, "0x4321") orelse return error.Tile0NotFound;
    const pos1 = std.mem.indexOf(u8, buf.items, "0x8765") orelse return error.Tile1NotFound;
    if (pos0 >= pos1) {
        std.debug.print("Phase10 C-array sequential: tile0 data at {} must come before tile1 data at {}\n", .{ pos0, pos1 });
        return error.WrongOrder;
    }

    // Sequential must differ from row-major
    var buf_rm: std.ArrayList(u8) = .empty;
    defer buf_rm.deinit(std.testing.allocator);
    const c_cfg_rm = c_array_out.CArrayConfig{
        .var_prefix = "tiles",
        .include_guard = "TILES_RM_H",
        .entries_per_line = 4,
    };
    try c_array_out.writeTilesetCArrayRowMajor(buf_rm.writer(std.testing.allocator).any(), &tiles, tile_h, tile_w, 2, c_cfg_rm);
    // Strip headers to compare just the data portion
    // For 2 distinct tiles the data arrays will differ in some positions
    try std.testing.expect(!std.mem.eql(u8, buf.items, buf_rm.items));
}

// =============================================================================
// Phase 10: Palette binary and C-array output
// =============================================================================

test "Phase 10: palette binary output - known black and white palette" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Convert sRGB black and white to OKLab
    var image = try zigimg.Image.create(alloc, 2, 1, .rgb24);
    defer image.deinit(alloc);
    image.pixels.rgb24[0] = .{ .r = 0, .g = 0, .b = 0 };
    image.pixels.rgb24[1] = .{ .r = 255, .g = 255, .b = 255 };
    try image.convert(alloc, .float32);
    const oklab = try zigimg.color.sRGB.sliceToOklabAlphaCopy(alloc, image.pixels.float32);

    const palette = Palette{ .colors = oklab, .count = @intCast(oklab.len) };
    const palettes = [_]Palette{palette};

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try binary_out.writePaletteBinary(buf.writer(std.testing.allocator).any(), &palettes, 2);

    // 2 colors, 3 bytes each = 6 bytes total
    // black: 0x00, 0x00, 0x00
    // white: 0xFF, 0xFF, 0xFF
    try std.testing.expectEqual(@as(usize, 6), buf.items.len);
    try std.testing.expectEqual(@as(u8, 0x00), buf.items[0]);
    try std.testing.expectEqual(@as(u8, 0x00), buf.items[1]);
    try std.testing.expectEqual(@as(u8, 0x00), buf.items[2]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf.items[3]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf.items[4]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf.items[5]);
}

test "Phase 10: palette C-array output - include guard and RGB entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var image = try zigimg.Image.create(alloc, 2, 1, .rgb24);
    defer image.deinit(alloc);
    image.pixels.rgb24[0] = .{ .r = 0, .g = 0, .b = 0 };
    image.pixels.rgb24[1] = .{ .r = 255, .g = 0, .b = 0 }; // red
    try image.convert(alloc, .float32);
    const oklab = try zigimg.color.sRGB.sliceToOklabAlphaCopy(alloc, image.pixels.float32);

    const palette = Palette{ .colors = oklab, .count = @intCast(oklab.len) };
    const palettes = [_]Palette{palette};

    const c_cfg = c_array_out.CArrayConfig{
        .var_prefix = "palette",
        .include_guard = "PALETTE_H",
        .entries_per_line = 8,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try c_array_out.writePaletteCArray(buf.writer(std.testing.allocator).any(), &palettes, 2, c_cfg);

    // Should contain include guard
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "#ifndef PALETTE_H") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "#define PALETTE_H") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "#endif") != null);
    // Should contain black (0x000000) and red (0xFF0000)
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "0x000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "0xFF0000") != null);
}

test "Phase 12: per-file palette, per-file tileset - fully independent" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    var img_a = try buildTestImageMultiFile(gpa, 0, 1);
    defer img_a.deinit();

    var img_b = try buildTestImageMultiFile(gpa, 0, 2);
    defer img_b.deinit();

    const cfg = config_mod.Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 2,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
        .palette_strategy = .per_file,
        .tileset_strategy = .per_file,
    };

    const images = [_]LoadedImage{ img_a, img_b };
    var arena = std.heap.ArenaAllocator.init(gpa);
    const mresults = try lib.pipeline.runMulti(arena.allocator(), cfg, &images);
    defer arena.deinit();

    // Assert 1: per-file palette -> different palette pointers
    try std.testing.expect(
        mresults[0].palettes.ptr != mresults[1].palettes.ptr,
    );

    // Assert 2: per-file tileset -> different unique_tiles pointers
    try std.testing.expect(
        mresults[0].unique_tiles.ptr != mresults[1].unique_tiles.ptr,
    );

    // Assert 3: each image has 2 unique tiles
    try std.testing.expectEqual(@as(usize, 2), mresults[0].unique_tiles.len);
    try std.testing.expectEqual(@as(usize, 2), mresults[1].unique_tiles.len);

    // Assert 4: pixel-perfect reconstruction for both images
    for (mresults, [_]LoadedImage{ img_a, img_b }, 0..) |res, orig_img, img_idx| {
        for (orig_img.pixels, res.output_pixels, 0..) |in_px, out_px, i| {
            const err = color_mod.deltaE(in_px, out_px);
            if (err > 1e-4) {
                std.debug.print("Phase12D img{} pixel {} mismatch: deltaE={d:.6}\n", .{ img_idx, i, err });
                return error.PixelMismatch;
            }
        }
    }
}

/// Build a 24x24 image with 9 distinct 8x8 tiles, each filled with a solid color.
/// Tile (col, row) uses color group col + row*3.
/// Colors are chosen to cluster naturally: 3 reds, 3 blues, 2 greens, 1 yellow.
fn buildSolidTileImage24x24(allocator: std.mem.Allocator) !LoadedImage {
    const tile_colors = [9][3]u8{
        .{ 200, 20, 20 },  // red-0
        .{ 220, 30, 30 },  // red-1
        .{ 240, 10, 10 },  // red-2
        .{ 20, 20, 200 },  // blue-0
        .{ 30, 30, 220 },  // blue-1
        .{ 10, 10, 240 },  // blue-2
        .{ 20, 180, 20 },  // green-0
        .{ 10, 200, 10 },  // green-1
        .{ 220, 220, 20 }, // yellow
    };

    const width: u32 = 24;
    const height: u32 = 24;

    var image = try zigimg.Image.create(allocator, width, height, .rgb24);
    defer image.deinit(allocator);

    for (0..height) |y| {
        for (0..width) |x| {
            const tile_col = x / 8;
            const tile_row = y / 8;
            const tile_idx = tile_row * 3 + tile_col;
            const rgb = tile_colors[tile_idx];
            image.pixels.rgb24[y * width + x] = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
        }
    }

    try image.convert(allocator, .float32);
    const oklab_pixels = try zigimg.color.sRGB.sliceToOklabAlphaCopy(
        allocator,
        image.pixels.float32,
    );

    return LoadedImage{
        .pixels = oklab_pixels,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

test "Tileset k-means: correctly handles > 256 unique tiles without capping" {
    // Regression test for a bug where tiles beyond the 256th unique tile were silently
    // assigned tile_index=0 due to the HashMap value type being u8 (max 255 entries).
    // Bug symptoms: in preview images, the bottom 4/5 renders as solid-color blocks
    // because all overflow tiles map to the same cluster representative as tile 0.
    //
    // This test creates 300 truly unique tiles (> 256 threshold), calls deduplicateExact
    // with max_unique_tiles=64, and verifies that tiles 256-299 (the "overflow" tiles with
    // the bug) end up with varied tile_indices rather than all being the same value.
    const tileset_mod = lib.tileset;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n_tiles = 300; // > 256 triggers the overflow bug
    const tile_pixels = 8 * 8;

    // Create 300 truly unique tiles. Each tile encodes its index in the first 3 nibbles
    // (data[0..2]) so tiles 0-255 and 256-299 all have different data. The remaining
    // pixels use a pseudo-random fill based on `i` so k-means has meaningful distances.
    const tiles = try alloc.alloc(QuantizedTile, n_tiles);
    for (0..n_tiles) |i| {
        const data = try alloc.alloc(u8, tile_pixels);
        data[0] = @intCast(i % 16);        // low nibble
        data[1] = @intCast((i / 16) % 16); // mid nibble (0..18 for i<300)
        data[2] = @intCast((i / 256) % 16); // high nibble: 0 for i<256, 1 for i=256..299
        for (3..tile_pixels) |j| {
            // Pseudo-random fill unique per tile: mix i and j multiplicatively
            const mix: u32 = @truncate((@as(u64, i) *% 2654435761) ^
                (@as(u64, j) *% 2246822519));
            data[j] = @intCast((mix >> 28) % 16);
        }
        tiles[i] = QuantizedTile{ .data = data, .width = 8, .height = 8 };
    }

    // Single palette: 16 evenly-spaced grayscale OKLab values.
    const palette_colors = try alloc.alloc(OklabAlpha, 16);
    for (0..16) |ci| {
        palette_colors[ci] = OklabAlpha{
            .l = @as(f32, @floatFromInt(ci)) / 15.0,
            .a = 0.0,
            .b = 0.0,
            .alpha = 1.0,
        };
    }
    const palettes = try alloc.alloc(Palette, 1);
    palettes[0] = Palette{ .colors = palette_colors, .count = @intCast(palette_colors.len) };

    // All tiles assigned to palette 0
    const palette_assignments = try alloc.alloc(u8, n_tiles);
    @memset(palette_assignments, 0);

    const max_unique: u32 = 64;
    const result = try tileset_mod.deduplicateExact(
        alloc, tiles, palette_assignments, palettes, max_unique, 1000, .auto,
    );

    // All tile_indices must be valid
    for (result.tile_indices, 0..) |idx, i| {
        if (idx >= result.unique_tiles.len) {
            std.debug.print("tile {} has invalid index {} >= unique_tiles.len={}\n", .{
                i, idx, result.unique_tiles.len,
            });
            return error.InvalidTileIndex;
        }
    }

    // Tiles 256-299 (the "overflow" tiles that triggered the bug) must have
    // diverse tile_indices — not all collapsed to the same value.
    // With the bug: all 44 overflow tiles get index 0 → labels[0] → 1 distinct value.
    // With the fix: they are properly clustered → many distinct values.
    var overflow_indices = std.AutoHashMap(u8, void).init(std.testing.allocator);
    defer overflow_indices.deinit();
    for (result.tile_indices[256..300]) |idx| {
        try overflow_indices.put(idx, {});
    }
    if (overflow_indices.count() < 3) {
        std.debug.print(
            "Tiles 256-299 only have {} distinct tile_indices — expected >= 3 " ++
                "(bug: all overflow tiles collapsed to same cluster)\n",
            .{overflow_indices.count()},
        );
        return error.OverflowTilesCollapsedToSameIndex;
    }
}

test "Tileset k-means reducer: max_unique_tiles is respected when exceeded" {
    // This test verifies the KmeansColorReducer fallback:
    // when an image has more unique tiles than max_unique_tiles,
    // k-means is used to reduce them to the allowed maximum.
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    // 24x24 image = 9 distinct solid-color 8x8 tiles
    var img = try buildSolidTileImage24x24(gpa);
    defer img.deinit();

    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 3,
        .tilemap_height = 3,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .max_unique_tiles = 4, // Force k-means fallback (9 unique tiles > 4)
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = try pipeline.run(arena.allocator(), cfg, img);
    defer arena.deinit();

    // Assert 1: unique tile count respects max_unique_tiles
    if (result.unique_tiles.len > cfg.max_unique_tiles) {
        std.debug.print("KmeansReducer: unique_tiles={} > max_unique_tiles={}\n", .{
            result.unique_tiles.len, cfg.max_unique_tiles,
        });
        return error.TooManyUniqueTiles;
    }

    // Assert 2: all tilemap entries reference valid tile indices
    for (result.tilemap, 0..) |entry, i| {
        if (entry.tile_index >= result.unique_tiles.len) {
            std.debug.print("KmeansReducer: tilemap[{}].tile_index={} >= unique_tiles.len={}\n", .{
                i, entry.tile_index, result.unique_tiles.len,
            });
            return error.InvalidTileIndex;
        }
    }

    // Assert 3: at least 2 distinct tile indices appear (k-means actually assigns different tiles)
    var tile_index_seen = std.AutoHashMap(u8, void).init(gpa);
    defer tile_index_seen.deinit();
    for (result.tilemap) |entry| {
        try tile_index_seen.put(entry.tile_index, {});
    }
    if (tile_index_seen.count() < 2) {
        std.debug.print("KmeansReducer: only {} distinct tile indices in tilemap, expected >= 2\n", .{
            tile_index_seen.count(),
        });
        return error.TooFewDistinctTileIndices;
    }

    // Assert 4: reconstruction quality — each tile should map to a perceptually similar
    // representative. With 9 solid-color tiles reduced to 4, correct OKLab-based clustering
    // groups reds/blues/greens by hue. Each tile's reconstructed color should stay within
    // deltaE 0.25 of the original (within-hue error is ~0.05-0.15). If clustering is
    // index-based (wrong), cross-hue mappings produce deltaE ~0.5-0.8, failing this check.
    const output_pixels = result.output_pixels;
    const tw = cfg.tile_width;
    const th = cfg.tile_height;
    for (result.tilemap, 0..) |_, tile_pos| {
        const tile_col = tile_pos % cfg.tilemap_width;
        const tile_row = tile_pos / cfg.tilemap_width;
        var tile_err: f32 = 0;
        for (0..th) |py| {
            for (0..tw) |px| {
                const gx = tile_col * tw + px;
                const gy = tile_row * th + py;
                const idx = gy * cfg.tilemap_width * tw + gx;
                tile_err += color_mod.deltaE(img.pixels[idx], output_pixels[idx]);
            }
        }
        tile_err /= @floatFromInt(tw * th);
        if (tile_err > 0.25) {
            std.debug.print(
                "KmeansReducer: tile {} avg deltaE={d:.4} > 0.25 — wrong representative assigned\n",
                .{ tile_pos, tile_err },
            );
            return error.KmeansRepresentativeTooDistant;
        }
    }
}

// =============================================================================
// JSON dump output
// =============================================================================

test "JSON dump: tilemap, palette, and tileset data are correctly serialized" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    // Use the Phase 2 scenario: 8x8 image, 16 exact colors, 1 unique tile
    var img = try buildTestImage(gpa);
    defer img.deinit();

    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 1,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = try pipeline.run(arena.allocator(), cfg, img);
    defer arena.deinit();

    // Write JSON dump to a buffer
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try lib.output.json.writeJsonDump(buf.writer(gpa).any(), &result);

    // Parse back to verify structure
    const JsonTop = struct {
        tilemap_width: u32,
        tilemap_height: u32,
        palette_count: u32,
        tile_count: u32,
    };
    const parsed = try std.json.parseFromSlice(JsonTop, gpa, buf.items, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 1), parsed.value.tilemap_width);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.tilemap_height);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.palette_count);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.tile_count);

    // Verify the JSON contains required keys
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"tilemap\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"palettes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"tileset\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"tile_index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"palette_index\"") != null);
}

// =============================================================================
// Phase 12: preloaded palette / tileset strategies + Sierra multi-file
// =============================================================================

test "Phase 12: preloaded palette strategy uses loaded palettes without regenerating" {
    // Tests that palette_strategy=.preloaded loads palettes from a hex file and
    // uses them as-is, rather than generating new palettes from the image.
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    // Step 1: generate a reference palette from a known 8x8 image (16 distinct colors).
    var img_ref = try buildTestImage(gpa);
    defer img_ref.deinit();

    const base_cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 1,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const ref_result = try pipeline.run(arena.allocator(), base_cfg, img_ref);
    defer arena.deinit();

    // Step 2: write the reference palette to a temp file.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    {
        var pal_buf: std.ArrayList(u8) = .empty;
        defer pal_buf.deinit(gpa);
        try hex_out.writePaletteHex(pal_buf.writer(gpa).any(), ref_result.palettes, 16);
        try tmp_dir.dir.writeFile(.{ .sub_path = "palette.hex", .data = pal_buf.items });
    }

    // Get real path for the pipeline to load.
    var pal_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pal_path = try tmp_dir.dir.realpath("palette.hex", &pal_path_buf);

    // Step 3: run a second image with the preloaded palette — same 16 colors.
    var img_b = try buildTestImage(gpa);
    defer img_b.deinit();

    var preloaded_cfg = base_cfg;
    preloaded_cfg.palette_strategy = .preloaded;
    preloaded_cfg.preloaded_palette = pal_path;

    const images = [_]LoadedImage{img_b};
    const mresults = try pipeline.runMulti(arena.allocator(), preloaded_cfg, &images);

    // Assert 1: exactly 1 palette was loaded (from the file).
    try std.testing.expectEqual(@as(usize, 1), mresults[0].palettes.len);

    // Assert 2: every tilemap entry uses a valid palette index.
    for (mresults[0].tilemap) |entry| {
        try std.testing.expect(entry.palette_index < mresults[0].palettes.len);
    }

    // Assert 3: reconstruction quality — same 16 colors → pixel-perfect match.
    for (img_b.pixels, mresults[0].output_pixels, 0..) |in_px, out_px, i| {
        const err = color_mod.deltaE(in_px, out_px);
        if (err > 1e-3) {
            std.debug.print("Preloaded palette: pixel {} deltaE={d:.6}\n", .{ i, err });
            return error.PixelMismatch;
        }
    }
}

test "Phase 12: preloaded tileset strategy uses loaded tiles without regenerating" {
    // Tests that tileset_strategy=.preloaded loads tiles from a hex file and maps
    // each input tile to the closest loaded tile (no new tile generation).
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    // Step 1: generate a reference tileset from a 16x16 image with 2 unique tiles.
    var img_ref = try buildTestImage16x16(gpa);
    defer img_ref.deinit();

    const base_cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 2,
        .tilemap_height = 2,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .max_unique_tiles = 256,
        .dither_algorithm = .none,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const ref_result = try pipeline.run(arena.allocator(), base_cfg, img_ref);
    defer arena.deinit();

    const n_tiles = ref_result.unique_tiles.len;
    std.debug.print("Preloaded tileset: reference has {} unique tile(s)\n", .{n_tiles});

    // Step 2: write the reference tileset to a temp file (row-major).
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    {
        var ts_buf: std.ArrayList(u8) = .empty;
        defer ts_buf.deinit(gpa);
        try hex_out.writeTilesetHexRowMajor(
            ts_buf.writer(gpa).any(),
            ref_result.unique_tiles,
            8, 8, 256, false,
        );
        try tmp_dir.dir.writeFile(.{ .sub_path = "tileset.hex", .data = ts_buf.items });
    }

    var ts_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ts_path = try tmp_dir.dir.realpath("tileset.hex", &ts_path_buf);

    // Step 3: run the same image with preloaded tileset.
    var img_b = try buildTestImage16x16(gpa);
    defer img_b.deinit();

    var preloaded_cfg = base_cfg;
    preloaded_cfg.tileset_strategy = .preloaded;
    preloaded_cfg.preloaded_tileset = ts_path;
    preloaded_cfg.num_preloaded_tiles = @intCast(n_tiles);

    const images = [_]LoadedImage{img_b};
    const mresults = try pipeline.runMulti(arena.allocator(), preloaded_cfg, &images);

    // Assert 1: the loaded tileset has exactly n_tiles tiles.
    try std.testing.expectEqual(n_tiles, mresults[0].unique_tiles.len);

    // Assert 2: all tilemap entries reference valid tile indices.
    for (mresults[0].tilemap) |entry| {
        try std.testing.expect(entry.tile_index < n_tiles);
    }

    // Assert 3: reconstruction quality — same tile pattern → pixel-perfect.
    for (img_b.pixels, mresults[0].output_pixels, 0..) |in_px, out_px, i| {
        const err = color_mod.deltaE(in_px, out_px);
        if (err > 1e-3) {
            std.debug.print("Preloaded tileset: pixel {} deltaE={d:.6}\n", .{ i, err });
            return error.PixelMismatch;
        }
    }
}

test "Phase 12: multi-file shared pipeline with Sierra dithering produces acceptable quality" {
    // Verifies that runMulti works with sierra dithering (not just .none).
    // Uses two identical images; checks quality metrics rather than pixel-perfect match.
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    var img_a = try buildTestImageMultiFile(gpa, 0, 1);
    defer img_a.deinit();
    var img_b = try buildTestImageMultiFile(gpa, 0, 2);
    defer img_b.deinit();

    const cfg = Config{
        .tile_width = 8,
        .tile_height = 8,
        .tilemap_width = 2,
        .tilemap_height = 1,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .dither_algorithm = .sierra,
        .dither_factor = 0.75,
        .transparency_mode = .none,
        .palette_0_color_0_is_black = false,
        .color_similarity_threshold = 0.001,
        .palette_strategy = .shared,
        .tileset_strategy = .shared,
    };

    const images = [_]LoadedImage{ img_a, img_b };
    var arena = std.heap.ArenaAllocator.init(gpa);
    const mresults = try lib.pipeline.runMulti(arena.allocator(), cfg, &images);
    defer arena.deinit();

    // Assert 1: tilemap dimensions correct for both images.
    try std.testing.expectEqual(@as(usize, 2), mresults.len);
    try std.testing.expectEqual(@as(usize, 2), mresults[0].tilemap.len);
    try std.testing.expectEqual(@as(usize, 2), mresults[1].tilemap.len);

    // Assert 2: quality — these images have 16 exact colors so even with dithering,
    // reconstruction should be near-perfect (dithering shouldn't hurt exact-color tiles).
    for (mresults, [_]LoadedImage{ img_a, img_b }, 0..) |res, orig_img, img_idx| {
        const metrics = try lib.pipeline.computeErrorMetrics(gpa, orig_img.pixels, null, res.output_pixels);
        std.debug.print("Phase12 Sierra img{}: avg deltaE={d:.5}\n", .{ img_idx, metrics.mean_de });
        // With exact 16 colors, sierra dithering should keep quality very high.
        try std.testing.expect(metrics.mean_de < 0.05);
    }
}

// =============================================================================
// Phase 11 extension: tile_reducer config field
// =============================================================================

test "tile_reducer=exact_hash succeeds when unique tile count is within limit" {
    const gpa = std.testing.allocator;

    // 4-tile image with 4 distinct patterns, limit = 4 → exact_hash should succeed
    var img = try buildTestImage16x16FourDistinct(gpa);
    defer img.deinit();

    const cfg = Config{
        .tile_width = 8, .tile_height = 8,
        .tilemap_width = 2, .tilemap_height = 2,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .max_unique_tiles = 4,
        .dither_algorithm = .none,
        .palette_0_color_0_is_black = false,
        .tile_reducer = .exact_hash,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = try pipeline.run(arena.allocator(), cfg, img);
    defer arena.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.unique_tiles.len);
}

test "tile_reducer=exact_hash fails when unique tile count exceeds limit" {
    const gpa = std.testing.allocator;

    // 4-tile image with 4 distinct patterns, limit = 2 → exact_hash should fail
    var img = try buildTestImage16x16FourDistinct(gpa);
    defer img.deinit();

    const cfg = Config{
        .tile_width = 8, .tile_height = 8,
        .tilemap_width = 2, .tilemap_height = 2,
        .num_palettes = 1,
        .colors_per_palette = 16,
        .max_unique_tiles = 2,
        .dither_algorithm = .none,
        .palette_0_color_0_is_black = false,
        .tile_reducer = .exact_hash,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const result = pipeline.run(arena.allocator(), cfg, img);
    defer arena.deinit();

    try std.testing.expectError(error.TooManyUniqueTiles, result);
}
