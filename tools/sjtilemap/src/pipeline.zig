const std = @import("std");
const zigimg = @import("zigimg");
const config_mod = @import("config.zig");
const Config = config_mod.Config;
const PaletteStrategy = config_mod.PaletteStrategy;
const TilesetStrategy = config_mod.TilesetStrategy;
const TransparencyMode = config_mod.TransparencyMode;
const color_mod = @import("color.zig");
const OklabAlpha = color_mod.OklabAlpha;
const tile_mod = @import("tile.zig");
const Tile = tile_mod.Tile;
const palette_mod = @import("palette.zig");
const Palette = palette_mod.Palette;
const quantize_mod = @import("quantize.zig");
const QuantizedTile = quantize_mod.QuantizedTile;
const tileset_mod = @import("tileset.zig");
const TilesetResult = tileset_mod.TilesetResult;
const tilemap_mod = @import("tilemap.zig");
const TilemapEntry = tilemap_mod.TilemapEntry;
const input_mod = @import("input.zig");
const LoadedImage = input_mod.LoadedImage;
const dither_mod = @import("dither.zig");
const hex_out = @import("output/hex.zig");

pub const PipelineResult = struct {
    /// Unique quantized tiles
    unique_tiles: []QuantizedTile,
    /// Generated palettes
    palettes: []Palette,
    /// Tilemap: one entry per tile position
    tilemap: []TilemapEntry,
    /// tilemap_width in tiles
    tilemap_width: u32,
    /// tilemap_height in tiles
    tilemap_height: u32,
    /// Reconstructed pixel output (in sRGB Colorf32)
    /// Owned by the result arena; caller must free via deinit.
    output_pixels: []OklabAlpha,
    output_width: u32,
    output_height: u32,
};

/// Convert an sRGB [3]u8 color to OKLab using zigimg's conversion pipeline.
fn srgbToOklab(alloc: std.mem.Allocator, rgb: [3]u8) !OklabAlpha {
    var image = try zigimg.Image.create(alloc, 1, 1, .rgb24);
    defer image.deinit(alloc);
    image.pixels.rgb24[0] = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
    try image.convert(alloc, .float32);
    const oklab_pixels = try zigimg.color.sRGB.sliceToOklabAlphaCopy(alloc, image.pixels.float32);
    // oklab_pixels is arena-owned; return the single pixel value
    return oklab_pixels[0];
}

/// Preprocess pixels for .color transparency: pixels matching cfg.transparent_color get alpha=0.
/// Returns the original slice unchanged when no preprocessing is needed.
/// When preprocessing is needed, returns an arena-allocated modified copy.
fn applyColorTransparency(alloc: std.mem.Allocator, cfg: Config, pixels: []const OklabAlpha) ![]const OklabAlpha {
    if (cfg.transparency_mode != .color) return pixels;
    const tc = cfg.transparent_color orelse return pixels;
    const tc_oklab = try srgbToOklab(alloc, tc);
    const modified = try alloc.dupe(OklabAlpha, pixels);
    for (modified) |*px| {
        const dist = color_mod.deltaESquared(
            OklabAlpha{ .l = px.l, .a = px.a, .b = px.b, .alpha = 1.0 },
            OklabAlpha{ .l = tc_oklab.l, .a = tc_oklab.a, .b = tc_oklab.b, .alpha = 1.0 },
        );
        if (dist < 1e-5) px.alpha = 0.0;
    }
    return modified;
}

// TODO: this doesn't really belong here....
pub const ErrorMetrics = struct {
    // DeltaE stats
    mean_de: f32,
    min_de: f32,
    max_de: f32,
    median_de: f32,
    p75_de: f32,
    p90_de: f32,
    p95_de: f32,
    p99_de: f32,

    // PSNR stats
    psnr_r: f64,
    psnr_g: f64,
    psnr_b: f64,
    psnr_avg: f64,
};

pub fn computeErrorMetrics(
    allocator: std.mem.Allocator,
    orig_pixels: []const OklabAlpha,
    /// Original sRGB u8 bytes (3 per pixel: R, G, B), captured before OKLab conversion.
    /// When non-null, used directly for PSNR to avoid the OKLab→sRGB round-trip precision loss.
    /// When null, falls back to converting orig_pixels back to sRGB (less accurate).
    orig_srgb_bytes: ?[]const u8,
    out_pixels: []const OklabAlpha,
) !ErrorMetrics {
    var metrics: ErrorMetrics = undefined;

    const n = orig_pixels.len;
    const delta_e_values = try allocator.alloc(f32, n);
    defer allocator.free(delta_e_values);

    var sum_de: f64 = 0;
    for (orig_pixels, out_pixels, 0..) |orig, out, i| {
        const de = color_mod.deltaE(orig, out);
        delta_e_values[i] = de;
        sum_de += de;
    }
    std.sort.block(f32, delta_e_values, {}, struct {
        fn lt(_: void, a: f32, b: f32) bool { return a < b; }
    }.lt);

    metrics.mean_de = @floatCast(sum_de / @as(f64, @floatFromInt(n)));
    metrics.min_de = delta_e_values[0];
    metrics.max_de = delta_e_values[n - 1];
    metrics.median_de = delta_e_values[n / 2];
    metrics.p75_de = delta_e_values[@as(usize, @intFromFloat(@as(f32, @floatFromInt(n)) * 0.75))];
    metrics.p90_de = delta_e_values[@as(usize, @intFromFloat(@as(f32, @floatFromInt(n)) * 0.90))];
    metrics.p95_de = delta_e_values[@as(usize, @intFromFloat(@as(f32, @floatFromInt(n)) * 0.95))];
    metrics.p99_de = delta_e_values[@as(usize, @intFromFloat(@as(f32, @floatFromInt(n)) * 0.99))];

    // PSNR: compare in sRGB u8 space (MAX=255).
    // Use orig_srgb_bytes when available (no round-trip loss).
    // Fallback: convert OKLab → sRGB float32 (introduces small precision loss).
    const out_srgb = try zigimg.color.sRGB.sliceFromOkLabAlphaCopy(allocator, out_pixels, .clamp);
    defer allocator.free(out_srgb);

    var mse_r: f64 = 0;
    var mse_g: f64 = 0;
    var mse_b: f64 = 0;
    if (orig_srgb_bytes) |srgb_bytes| {
        // Use original u8 sRGB bytes directly — no round-trip loss.
        for (out_srgb, 0..) |out_f, i| {
            const or8: f64 = @floatFromInt(srgb_bytes[i * 3]);
            const og8: f64 = @floatFromInt(srgb_bytes[i * 3 + 1]);
            const ob8: f64 = @floatFromInt(srgb_bytes[i * 3 + 2]);
            const outr: f64 = std.math.clamp(@as(f64, out_f.r), 0, 1) * 255.0;
            const outg: f64 = std.math.clamp(@as(f64, out_f.g), 0, 1) * 255.0;
            const outb: f64 = std.math.clamp(@as(f64, out_f.b), 0, 1) * 255.0;
            mse_r += (or8 - outr) * (or8 - outr);
            mse_g += (og8 - outg) * (og8 - outg);
            mse_b += (ob8 - outb) * (ob8 - outb);
        }
    } else {
        // Fallback: convert orig OKLab → sRGB float32.
        const orig_srgb = try zigimg.color.sRGB.sliceFromOkLabAlphaCopy(allocator, orig_pixels, .clamp);
        defer allocator.free(orig_srgb);
        for (orig_srgb, out_srgb) |orig_f, out_f| {
            const or8: f64 = std.math.clamp(@as(f64, orig_f.r), 0, 1) * 255.0;
            const og8: f64 = std.math.clamp(@as(f64, orig_f.g), 0, 1) * 255.0;
            const ob8: f64 = std.math.clamp(@as(f64, orig_f.b), 0, 1) * 255.0;
            const outr: f64 = std.math.clamp(@as(f64, out_f.r), 0, 1) * 255.0;
            const outg: f64 = std.math.clamp(@as(f64, out_f.g), 0, 1) * 255.0;
            const outb: f64 = std.math.clamp(@as(f64, out_f.b), 0, 1) * 255.0;
            mse_r += (or8 - outr) * (or8 - outr);
            mse_g += (og8 - outg) * (og8 - outg);
            mse_b += (ob8 - outb) * (ob8 - outb);
        }
    }
    const nf: f64 = @floatFromInt(n);
    mse_r /= nf;
    mse_g /= nf;
    mse_b /= nf;
    const mse_avg = (mse_r + mse_g + mse_b) / 3.0;
    const max_val: f64 = 255.0;
    metrics.psnr_r = if (mse_r > 0) 20.0 * std.math.log10(max_val) - 10.0 * std.math.log10(mse_r) else std.math.inf(f64);
    metrics.psnr_g = if (mse_g > 0) 20.0 * std.math.log10(max_val) - 10.0 * std.math.log10(mse_g) else std.math.inf(f64);
    metrics.psnr_b = if (mse_b > 0) 20.0 * std.math.log10(max_val) - 10.0 * std.math.log10(mse_b) else std.math.inf(f64);
    metrics.psnr_avg = if (mse_avg > 0) 20.0 * std.math.log10(max_val) - 10.0 * std.math.log10(mse_avg) else std.math.inf(f64);

    return metrics;
}

/// Run the full conversion pipeline on a pre-loaded image.
/// Thin wrapper around runMulti for single-image use and test compatibility.
pub fn run(arena: std.mem.Allocator, cfg: Config, img: LoadedImage) !PipelineResult {
    const results = try runMulti(arena, cfg, &[_]LoadedImage{img});
    return results[0];
}

fn assignPalettes(
    arena: std.mem.Allocator,
    tiles: []const Tile,
    palettes: []const Palette,
) ![]u8 {
    const assignments = try arena.alloc(u8, tiles.len);

    for (tiles, 0..) |tile, ti| {
        var best_palette: u8 = 0;
        var best_err: f32 = std.math.floatMax(f32);

        for (palettes, 0..) |palette, pi| {
            var err: f32 = 0.0;
            const valid_colors = palette.colors[0..palette.count];
            for (tile.pixels) |px| {
                // Find min deltaE to any valid palette color
                var min_d = color_mod.deltaESquared(px, valid_colors[0]);
                for (valid_colors[1..]) |c| {
                    const d = color_mod.deltaESquared(px, c);
                    if (d < min_d) min_d = d;
                }
                err += min_d;
            }
            if (err < best_err) {
                best_err = err;
                best_palette = @intCast(pi);
            }
        }

        assignments[ti] = best_palette;
    }

    return assignments;
}

fn quantizeTiles(
    arena: std.mem.Allocator,
    tiles: []const Tile,
    palettes: []const Palette,
    palette_assignments: []const u8,
    cfg: Config,
) ![]QuantizedTile {
    const result = try arena.alloc(QuantizedTile, tiles.len);
    for (tiles, 0..) |tile, i| {
        const palette = palettes[palette_assignments[i]];
        const use_transparency = (cfg.transparency_mode == .alpha or cfg.transparency_mode == .color) and tile.has_transparent;
        if (use_transparency) {
            result[i] = try quantize_mod.quantizeTileWithTransparency(
                arena,
                tile.pixels,
                cfg.tile_width,
                cfg.tile_height,
                palette,
            );
        } else {
            result[i] = try quantize_mod.quantizeTile(
                arena,
                tile.pixels,
                cfg.tile_width,
                cfg.tile_height,
                palette,
            );
        }
    }
    return result;
}


/// Per-tile best (unique_tile, palette, x_flip) assignment found by exhaustive search.
const BestAssignments = struct {
    tile_indices: []u8,
    palette_indices: []u8,
    x_flip_flags: []bool,
};

/// Calculate the reconstruction error between an original tile and a (unique_tile, palette) pair.
/// For each pixel: error = deltaE(original_pixel, palette_color_at_quantized_index).
/// When x_flip=true the unique tile is read mirrored (left-right) to match VDP x_flip rendering.
/// Transparent pixels (alpha < 0.5) are skipped when transparency is enabled.
fn calculateReconstructionError(
    original: []const OklabAlpha,
    quantized: *const QuantizedTile,
    palette: *const Palette,
    x_flip: bool,
    tw: u32,
    transparency_mode: TransparencyMode,
) f32 {
    var total: f32 = 0;
    for (original, 0..) |px, idx| {
        if (transparency_mode != .none and px.alpha < 0.5) continue;
        const x: u32 = @intCast(idx % tw);
        const y: u32 = @intCast(idx / tw);
        const read_x = if (x_flip) (tw - 1 - x) else x;
        const color_idx = quantized.data[y * tw + read_x];
        total += color_mod.deltaE(px, palette.colors[color_idx]);
    }
    return total;
}

/// For each original tile, find the best (unique_tile_index, palette_index, x_flip) combination
/// by evaluating reconstruction error across all (unique_tile × palette × {normal, flipped}) triples.
/// Complexity: O(N_tiles × N_unique × N_palettes × 2) with N_pixels deltaE calls per evaluation.
fn findBestTileAssignments(
    arena: std.mem.Allocator,
    tiles: []const Tile,
    unique_tiles: []const QuantizedTile,
    palettes: []const Palette,
    cfg: Config,
) !BestAssignments {
    const n = tiles.len;
    const result_tile_indices = try arena.alloc(u8, n);
    const result_palette_indices = try arena.alloc(u8, n);
    const result_x_flip_flags = try arena.alloc(bool, n);

    for (tiles, 0..) |tile, i| {
        var best_error: f32 = std.math.floatMax(f32);
        var best_tile: u8 = 0;
        var best_palette: u8 = 0;
        var best_flip: bool = false;

        // For transparent tiles, x_flip would shift which pixel positions map to color index 0
        // (the transparency marker), producing incorrect alpha output. Skip flip evaluation.
        const allow_flip = !tile.has_transparent or cfg.transparency_mode == .none;

        for (unique_tiles, 0..) |*ut, ui| {
            for (palettes, 0..) |*pal, pi| {
                const err_normal = calculateReconstructionError(
                    tile.pixels, ut, pal, false, cfg.tile_width, cfg.transparency_mode,
                );
                if (err_normal < best_error) {
                    best_error = err_normal;
                    best_tile = @intCast(ui);
                    best_palette = @intCast(pi);
                    best_flip = false;
                }
                if (allow_flip) {
                    const err_flip = calculateReconstructionError(
                        tile.pixels, ut, pal, true, cfg.tile_width, cfg.transparency_mode,
                    );
                    if (err_flip < best_error) {
                        best_error = err_flip;
                        best_tile = @intCast(ui);
                        best_palette = @intCast(pi);
                        best_flip = true;
                    }
                }
            }
        }

        result_tile_indices[i] = best_tile;
        result_palette_indices[i] = best_palette;
        result_x_flip_flags[i] = best_flip;
    }

    return BestAssignments{
        .tile_indices = result_tile_indices,
        .palette_indices = result_palette_indices,
        .x_flip_flags = result_x_flip_flags,
    };
}

fn buildTilemap(
    arena: std.mem.Allocator,
    tile_indices: []const u8,
    x_flip_flags: []const bool,
    palette_assignments: []const u8,
    tilemap_width: u32,
    tilemap_height: u32,
    tiles: []const Tile,
    cfg: Config,
) ![]TilemapEntry {
    const n = tilemap_width * tilemap_height;
    const tilemap = try arena.alloc(TilemapEntry, n);
    for (0..n) |i| {
        const is_transparent = (cfg.transparency_mode == .alpha or cfg.transparency_mode == .color) and tiles[i].has_transparent;
        tilemap[i] = TilemapEntry{
            .tile_index = tile_indices[i],
            .palette_index = @intCast(palette_assignments[i]),
            .transparent = is_transparent,
            .x_flip = x_flip_flags[i],
        };
    }
    return tilemap;
}

fn reconstructPixels(
    arena: std.mem.Allocator,
    tilemap: []const TilemapEntry,
    unique_tiles: []const QuantizedTile,
    palettes: []const Palette,
    tilemap_width: u32,
    tilemap_height: u32,
    cfg: Config,
) ![]OklabAlpha {
    const tw = cfg.tile_width;
    const th = cfg.tile_height;
    const img_width = tilemap_width * tw;
    const img_height = tilemap_height * th;
    const pixels = try arena.alloc(OklabAlpha, img_width * img_height);

    for (tilemap, 0..) |entry, ti| {
        const tmap_x = ti % tilemap_width;
        const tmap_y = ti / tilemap_width;
        const tile = unique_tiles[entry.tile_index];
        const palette = palettes[entry.palette_index];

        for (0..th) |py| {
            for (0..tw) |px| {
                // Apply x_flip: when flipped, read from mirrored x position
                const src_px = if (entry.x_flip) (tw - 1 - px) else px;
                const color_idx = tile.data[py * tw + src_px];
                const dst_x = tmap_x * tw + px;
                const dst_y = tmap_y * th + py;
                // If tile is transparent and color_idx==0, output transparent pixel
                if (entry.transparent and color_idx == 0) {
                    pixels[dst_y * img_width + dst_x] = OklabAlpha{ .l = 0, .a = 0, .b = 0, .alpha = 0 };
                } else {
                    const color = palette.colors[color_idx];
                    pixels[dst_y * img_width + dst_x] = color;
                }
            }
        }
    }

    return pixels;
}

/// Run the pipeline on multiple images with shared/per-file palette/tileset strategies.
pub fn runMulti(
    arena: std.mem.Allocator,
    cfg: Config,
    images: []const LoadedImage,
) ![]PipelineResult {
    const n = images.len;

    // Step 1: Extract tiles from all images.
    const all_tiles = try arena.alloc([]Tile, n);
    for (images, 0..) |img, i| {
        try cfg.validateImageDimensions(img.width, img.height);
        const effective_pixels = try applyColorTransparency(arena, cfg, img.pixels);
        all_tiles[i] = try tile_mod.extractTiles(arena, effective_pixels, img.width, img.height, cfg);
    }

    // Step 2: Generate palettes (shared or per-file).
    const palettes_per_image = try arena.alloc([]Palette, n);
    switch (cfg.palette_strategy) {
        .shared => {
            // Collect all tiles from all images into one flat slice.
            var total_tiles: usize = 0;
            for (all_tiles) |tiles| total_tiles += tiles.len;
            const combined_tiles = try arena.alloc(Tile, total_tiles);
            var offset: usize = 0;
            for (all_tiles) |tiles| {
                @memcpy(combined_tiles[offset..][0..tiles.len], tiles);
                offset += tiles.len;
            }
            const shared_palettes = try palette_mod.generatePalettes(arena, combined_tiles, cfg);
            // All images share the same palette slice.
            for (0..n) |i| {
                palettes_per_image[i] = shared_palettes;
            }
        },
        .per_file => {
            for (all_tiles, 0..) |tiles, i| {
                palettes_per_image[i] = try palette_mod.generatePalettes(arena, tiles, cfg);
            }
        },
        .preloaded => {
            const path = cfg.preloaded_palette orelse return error.NoPreloadedPalettePath;
            const pal_data = try std.fs.cwd().readFileAlloc(arena, path, 16 * 1024 * 1024);
            const loaded_palettes = try hex_out.loadPaletteFromHex(arena, pal_data, cfg.colors_per_palette);
            if (loaded_palettes.len == 0) return error.EmptyPreloadedPalette;
            for (0..n) |i| palettes_per_image[i] = loaded_palettes;
        },
    }

    // Step 3: Assign palettes and quantize per image.
    const quantized_per_image = try arena.alloc([]QuantizedTile, n);
    const palette_assignments_per_image = try arena.alloc([]u8, n);
    for (0..n) |i| {
        palette_assignments_per_image[i] = try assignPalettes(arena, all_tiles[i], palettes_per_image[i]);
        const img = images[i];
        const tilemap_width = img.width / cfg.tile_width;
        const tilemap_height = img.height / cfg.tile_height;
        quantized_per_image[i] = switch (cfg.dither_algorithm) {
            .none => try quantizeTiles(arena, all_tiles[i], palettes_per_image[i], palette_assignments_per_image[i], cfg),
            .sierra => blk: {
                if (cfg.dither_factor == 0.0) {
                    break :blk try quantizeTiles(arena, all_tiles[i], palettes_per_image[i], palette_assignments_per_image[i], cfg);
                } else {
                    break :blk try dither_mod.quantizeTilesWithSierra(
                        arena,
                        all_tiles[i],
                        palettes_per_image[i],
                        palette_assignments_per_image[i],
                        cfg,
                        img.width,
                        img.height,
                        tilemap_width,
                        tilemap_height,
                    );
                }
            },
        };
    }

    // Step 4: Deduplicate tiles (shared or per-file).
    // We store unique_tiles and per-image tile_indices/x_flip_flags separately.
    const unique_tiles_per_image = try arena.alloc([]QuantizedTile, n);
    const tile_indices_per_image = try arena.alloc([]u8, n);
    const x_flip_flags_per_image = try arena.alloc([]bool, n);

    switch (cfg.tileset_strategy) {
        .shared => {
            // Combine all quantized tiles from all images.
            var total: usize = 0;
            for (quantized_per_image) |qts| total += qts.len;
            const combined = try arena.alloc(QuantizedTile, total);
            // Combine palette assignments and flatten palettes (offsetting indices per image).
            var total_palettes: usize = 0;
            for (palettes_per_image) |pals| total_palettes += pals.len;
            const combined_palettes = try arena.alloc(Palette, total_palettes);
            const combined_assignments = try arena.alloc(u8, total);
            var pal_off: usize = 0;
            var tile_off: usize = 0;
            for (0..n) |i| {
                const pals = palettes_per_image[i];
                @memcpy(combined_palettes[pal_off..][0..pals.len], pals);
                const img_tiles = quantized_per_image[i];
                @memcpy(combined[tile_off..][0..img_tiles.len], img_tiles);
                for (palette_assignments_per_image[i], 0..) |pa, j| {
                    combined_assignments[tile_off + j] = @intCast(pa + pal_off);
                }
                pal_off += pals.len;
                tile_off += img_tiles.len;
            }
            const shared_tileset = try tileset_mod.deduplicateExact(arena, combined, combined_assignments, combined_palettes, cfg.max_unique_tiles, cfg.tile_kmeans_max_iter, cfg.tile_reducer);
            // Split tile_indices and x_flip_flags back per image; unique_tiles is shared.
            var split_off: usize = 0;
            for (0..n) |i| {
                const len = quantized_per_image[i].len;
                unique_tiles_per_image[i] = shared_tileset.unique_tiles;
                tile_indices_per_image[i] = shared_tileset.tile_indices[split_off..][0..len];
                x_flip_flags_per_image[i] = shared_tileset.x_flip_flags[split_off..][0..len];
                split_off += len;
            }
        },
        .per_file => {
            for (0..n) |i| {
                const ts = try tileset_mod.deduplicateExact(arena, quantized_per_image[i], palette_assignments_per_image[i], palettes_per_image[i], cfg.max_unique_tiles, cfg.tile_kmeans_max_iter, cfg.tile_reducer);
                unique_tiles_per_image[i] = ts.unique_tiles;
                tile_indices_per_image[i] = ts.tile_indices;
                x_flip_flags_per_image[i] = ts.x_flip_flags;
            }
        },
        .preloaded => {
            const path = cfg.preloaded_tileset orelse return error.NoPreloadedTilesetPath;
            const ts_data = try std.fs.cwd().readFileAlloc(arena, path, 64 * 1024 * 1024);
            const num_tiles = if (cfg.num_preloaded_tiles > 0) cfg.num_preloaded_tiles else cfg.max_unique_tiles;
            const loaded_tiles = try hex_out.loadTilesetFromHex(
                arena, ts_data, cfg.tile_height, cfg.tile_width, num_tiles,
            );
            if (loaded_tiles.len == 0) return error.EmptyPreloadedTileset;
            // Build a TilesetResult-compatible structure: map each original tile to the
            // closest loaded tile using calculateReconstructionError.
            for (0..n) |i| {
                unique_tiles_per_image[i] = loaded_tiles;
                const img_qt = quantized_per_image[i];
                tile_indices_per_image[i] = try arena.alloc(u8, img_qt.len);
                x_flip_flags_per_image[i] = try arena.alloc(bool, img_qt.len);
                @memset(x_flip_flags_per_image[i], false);
                // Assign each original tile to closest loaded tile
                for (all_tiles[i], 0..) |tile, ti| {
                    var best_idx: u8 = 0;
                    var best_err: f32 = std.math.floatMax(f32);
                    for (loaded_tiles, 0..) |*lt, li| {
                        const pal = palettes_per_image[i][palette_assignments_per_image[i][ti]];
                        const err = calculateReconstructionError(
                            tile.pixels, lt, &pal, false, cfg.tile_width, cfg.transparency_mode,
                        );
                        if (err < best_err) {
                            best_err = err;
                            best_idx = @intCast(li);
                        }
                    }
                    tile_indices_per_image[i][ti] = best_idx;
                }
            }
        },
    }

    // Step 5: For each image, find best (unique_tile, palette, x_flip) assignments and build tilemap.
    const results = try arena.alloc(PipelineResult, n);
    for (0..n) |i| {
        const img = images[i];
        const tw = img.width / cfg.tile_width;
        const th = img.height / cfg.tile_height;

        const best = try findBestTileAssignments(
            arena,
            all_tiles[i],
            unique_tiles_per_image[i],
            palettes_per_image[i],
            cfg,
        );

        const tilemap = try buildTilemap(
            arena,
            best.tile_indices,
            best.x_flip_flags,
            best.palette_indices,
            tw,
            th,
            all_tiles[i],
            cfg,
        );

        const output_pixels = try reconstructPixels(
            arena,
            tilemap,
            unique_tiles_per_image[i],
            palettes_per_image[i],
            tw,
            th,
            cfg,
        );

        results[i] = PipelineResult{
            .unique_tiles = unique_tiles_per_image[i],
            .palettes = palettes_per_image[i],
            .tilemap = tilemap,
            .tilemap_width = @intCast(tw),
            .tilemap_height = @intCast(th),
            .output_pixels = output_pixels,
            .output_width = img.width,
            .output_height = img.height,
        };
    }

    return results;
}
