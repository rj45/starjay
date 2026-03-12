const std = @import("std");
const color_mod = @import("color.zig");
const OklabAlpha = color_mod.OklabAlpha;
const Config = @import("config.zig").Config;
const Tile = @import("tile.zig").Tile;
const kmeans = @import("kmeans");

const black = OklabAlpha{ .l = 0.0, .a = 0.0, .b = 0.0, .alpha = 1.0 };

/// Build a per-tile feature vector for palette clustering.
/// Pixels are sorted by OKLab hue angle (atan2(b, a) in [0, 2π)), then flattened
/// as [L, a, b, L, a, b, ...]. Sorting by hue makes the feature vector
/// rotation-invariant: two tiles with the same color set but different spatial
/// arrangements map to the same (or similar) cluster centroid.
fn buildTileFeatureVector(arena: std.mem.Allocator, tile: *const Tile) ![]f32 {
    const n = tile.pixels.len;
    // Copy pixels for sorting (don't modify the tile)
    const sorted = try arena.dupe(OklabAlpha, tile.pixels);
    // Sort by hue angle ascending
    std.sort.block(OklabAlpha, sorted, {}, struct {
        pub fn lessThan(_: void, a: OklabAlpha, b: OklabAlpha) bool {
            return color_mod.hueAngle(a) < color_mod.hueAngle(b);
        }
    }.lessThan);
    // Flatten to [L, a, b] per pixel
    const vec = try arena.alloc(f32, n * 3);
    for (sorted, 0..) |px, i| {
        vec[i * 3 + 0] = px.l;
        vec[i * 3 + 1] = px.a;
        vec[i * 3 + 2] = px.b;
    }
    return vec;
}

pub const Palette = struct {
    /// Always colors_per_palette entries; unused slots are padded with OKLab black.
    colors: []OklabAlpha,
    /// Number of valid (non-padding) colors. May be < colors.len when the image
    /// has fewer unique colors than colors_per_palette.
    count: u32,
};

/// Generate a single palette from a set of tiles using k-means color quantization.
/// All pixels from all tiles are collected, deduplicated by similarity threshold,
/// then reduced to colors_per_palette entries via k-means if needed.
pub fn generatePaletteFromTiles(
    arena: std.mem.Allocator,
    tiles: []const Tile,
    cfg: Config,
) !Palette {
    const threshold_sq = cfg.color_similarity_threshold * cfg.color_similarity_threshold;
    const max_colors = cfg.colors_per_palette;

    // Collect all unique-ish colors from all tiles
    var unique_colors = std.ArrayList(OklabAlpha){};

    for (tiles) |tile| {
        for (tile.pixels) |px| {
            var found = false;
            for (unique_colors.items) |uc| {
                if (color_mod.deltaESquared(px, uc) < threshold_sq) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                // Store with alpha=1.0: palette colors are always opaque.
                // Transparency is handled by palette index 0 reservation, not alpha channel.
                const opaque_px = OklabAlpha{ .l = px.l, .a = px.a, .b = px.b, .alpha = 1.0 };
                try unique_colors.append(arena, opaque_px);
            }
        }
    }

    var colors: []OklabAlpha = undefined;

    if (unique_colors.items.len <= max_colors) {
        colors = unique_colors.items;
    } else {
        // More unique colors than the palette can hold — reduce via k-means then
        // compute frequency-weighted centroids (reduce_colors equivalent from Rust
        // imgconv.rs:525-568). Frequency-weighted centroids pull the representative
        // toward the dominant color in each cluster, matching the Rust approach.
        const n = unique_colors.items.len;

        // Build input data: each unique color is a 3-float feature vector [L, a, b]
        const data = try arena.alloc([]f32, n);
        for (0..n) |i| {
            const row = try arena.alloc(f32, 3);
            row[0] = unique_colors.items[i].l;
            row[1] = unique_colors.items[i].a;
            row[2] = unique_colors.items[i].b;
            data[i] = row;
        }

        var km = kmeans.KMeans(f32, null, null, null, null){
            .allocator = arena,
            .n_clusters = max_colors,
            .max_it = cfg.palette_kmeans_max_iter,
        };
        try km.fit(data);

        // Get cluster assignment for each unique color
        const const_data = try arena.alloc([]const f32, n);
        for (data, 0..) |row, i| const_data[i] = row;
        const assignments = try km.predict(const_data);

        // Compute frequency-weighted centroids: each unique color's weight is how many
        // pixels in the original image matched that unique color (i.e., its frequency).
        // This is the reduce_colors() algorithm from Rust imgconv.rs:548-565.
        // We reconstruct frequencies from the pixel data by counting how many pixels
        // matched each unique color entry.
        const freq = try arena.alloc(u32, n);
        @memset(freq, 0);
        for (tiles) |tile| {
            for (tile.pixels) |px| {
                // Find which unique color this pixel matched
                var best_uc: usize = 0;
                var best_d = color_mod.deltaESquared(px, unique_colors.items[0]);
                for (unique_colors.items[1..], 1..) |uc, ui| {
                    const d = color_mod.deltaESquared(px, uc);
                    if (d < best_d) { best_d = d; best_uc = ui; }
                }
                freq[best_uc] += 1;
            }
        }

        // Accumulate frequency-weighted sums per cluster
        const wsum_l = try arena.alloc(f64, max_colors);
        const wsum_a = try arena.alloc(f64, max_colors);
        const wsum_b = try arena.alloc(f64, max_colors);
        const wcount = try arena.alloc(u64, max_colors);
        @memset(wsum_l, 0);
        @memset(wsum_a, 0);
        @memset(wsum_b, 0);
        @memset(wcount, 0);
        for (0..n) |i| {
            const c = assignments[i];
            const w: f64 = @floatFromInt(if (freq[i] > 0) freq[i] else 1);
            wsum_l[c] += w * unique_colors.items[i].l;
            wsum_a[c] += w * unique_colors.items[i].a;
            wsum_b[c] += w * unique_colors.items[i].b;
            wcount[c] += if (freq[i] > 0) freq[i] else 1;
        }

        colors = try arena.alloc(OklabAlpha, max_colors);
        for (0..max_colors) |c| {
            if (wcount[c] > 0) {
                const inv: f32 = 1.0 / @as(f32, @floatFromInt(wcount[c]));
                colors[c] = .{
                    .l = @as(f32, @floatCast(wsum_l[c])) * inv,
                    .a = @as(f32, @floatCast(wsum_a[c])) * inv,
                    .b = @as(f32, @floatCast(wsum_b[c])) * inv,
                    .alpha = 1.0,
                };
            } else {
                // Empty cluster: use k-means center as fallback
                const center = (try km.getCenters())[c];
                colors[c] = .{ .l = center[0], .a = center[1], .b = center[2], .alpha = 1.0 };
            }
        }
    }

    // Sort by luminance (ascending)
    std.sort.block(OklabAlpha, colors, {}, struct {
        pub fn lessThan(_: void, a: OklabAlpha, b: OklabAlpha) bool {
            return a.l < b.l;
        }
    }.lessThan);

    const actual_count: u32 = @intCast(colors.len);

    // Always pad to colors_per_palette so palette.colors.len is always colors_per_palette.
    // Unused slots are set to black; callers that need to distinguish real vs padding use `count`.
    const padded = try arena.alloc(OklabAlpha, max_colors);
    @memcpy(padded[0..colors.len], colors);
    for (padded[colors.len..]) |*slot| slot.* = black;

    return Palette{ .colors = padded, .count = actual_count };
}

/// Generate multiple palettes by clustering tiles and generating one palette per cluster.
/// For num_palettes=1, trivially assigns all tiles to cluster 0.
///
/// For num_palettes>1: tiles are clustered using k-means on hue-sorted feature vectors
/// (rotation-invariant — tiles with the same color set in different spatial arrangements
/// are grouped together). Each cluster then generates its own palette via color k-means.
pub fn generatePalettes(
    arena: std.mem.Allocator,
    tiles: []const Tile,
    cfg: Config,
) ![]Palette {
    const palettes = try arena.alloc(Palette, cfg.num_palettes);

    if (cfg.num_palettes == 1 or tiles.len == 0) {
        palettes[0] = try generatePaletteFromTiles(arena, tiles, cfg);
        for (palettes[1..]) |*p| p.* = palettes[0];
        forceFirstColorToBlack(&palettes[0], cfg);
        return palettes;
    }

    // Phase 6: cluster tiles by hue-sorted feature vectors, then generate one palette
    // per cluster. Feature vector: pixels sorted by hue angle, flattened as [L, a, b, ...].
    // This is rotation-invariant: tiles with the same color set cluster together.
    const n = tiles.len;
    const feature_vecs = try arena.alloc([]f32, n);
    for (tiles, 0..) |*tile, i| {
        feature_vecs[i] = try buildTileFeatureVector(arena, tile);
    }

    const k = @min(cfg.num_palettes, n);
    var km = kmeans.KMeans(f32, null, null, null, null){
        .allocator = arena,
        .n_clusters = k,
        .max_it = cfg.palette_kmeans_max_iter,
    };
    try km.fit(feature_vecs);

    // Build []const []const f32 for predict (const coercion)
    const const_vecs = try arena.alloc([]const f32, n);
    for (feature_vecs, 0..) |v, i| const_vecs[i] = v;
    const labels = try km.predict(const_vecs);

    // Collect tiles per cluster
    const cluster_tiles = try arena.alloc(std.ArrayListUnmanaged(Tile), cfg.num_palettes);
    for (cluster_tiles) |*ct| ct.* = .{};
    for (tiles, 0..) |tile, i| {
        const cluster_idx = labels[i];
        try cluster_tiles[cluster_idx].append(arena, tile);
    }

    // Generate one palette per cluster; empty clusters get a palette from all tiles
    for (0..cfg.num_palettes) |pi| {
        if (cluster_tiles[pi].items.len > 0) {
            palettes[pi] = try generatePaletteFromTiles(arena, cluster_tiles[pi].items, cfg);
        } else {
            palettes[pi] = try generatePaletteFromTiles(arena, tiles, cfg);
        }
    }

    // Sort palettes by average luminance (ascending) for better visual organization.
    // Matches Rust imgconv.rs:404-409. This ensures palette[0] is darkest, palette[n-1]
    // is brightest. Required so that palette index 0 (often reserved for transparency or
    // color[0]=black) naturally contains the darkest color group.
    std.sort.block(Palette, palettes, {}, struct {
        pub fn lessThan(_: void, a: Palette, b: Palette) bool {
            var sum_a: f32 = 0;
            var sum_b: f32 = 0;
            for (a.colors[0..a.count]) |c| sum_a += c.l;
            for (b.colors[0..b.count]) |c| sum_b += c.l;
            const avg_a = if (a.count > 0) sum_a / @as(f32, @floatFromInt(a.count)) else 0;
            const avg_b = if (b.count > 0) sum_b / @as(f32, @floatFromInt(b.count)) else 0;
            return avg_a < avg_b;
        }
    }.lessThan);

    forceFirstColorToBlack(&palettes[0], cfg);

    return palettes;
}

fn forceFirstColorToBlack(palette: *Palette, cfg: Config) void {
    // Force palette[0] = black if configured
    if (cfg.palette_0_color_0_is_black) {
        // if there is room in the palette, add black but only if the first color isn't close to black
        // otherwise: always replace the darkest color (which should be the first one) with black
        const first = palette.colors[0];
        if (
            color_mod.deltaESquared(first, black) > cfg.color_similarity_threshold and
            palette.count < cfg.colors_per_palette
        ) {
            const count = palette.count;
            @memmove(palette.colors[1..count+1], palette.colors[0..count]);
            palette.count += 1;
        }
        palette.colors[0] = black;
    }
}
