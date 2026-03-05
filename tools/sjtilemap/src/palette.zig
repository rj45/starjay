const std = @import("std");
const color_mod = @import("color.zig");
const OklabAlpha = color_mod.OklabAlpha;
const Config = @import("config.zig").Config;
const Tile = @import("tile.zig").Tile;
const kmeans = @import("kmeans");

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
    colors: []OklabAlpha,
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
        // Reduce to max_colors via k-means
        const n = unique_colors.items.len;
        // Build input data: each color is a 3-float feature vector [L, a, b]
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
        const centers = try km.getCenters();

        colors = try arena.alloc(OklabAlpha, centers.len);
        for (centers, 0..) |center, i| {
            colors[i] = .{ .l = center[0], .a = center[1], .b = center[2], .alpha = 1.0 };
        }
    }

    // Sort by luminance (ascending)
    std.sort.block(OklabAlpha, colors, {}, struct {
        pub fn lessThan(_: void, a: OklabAlpha, b: OklabAlpha) bool {
            return a.l < b.l;
        }
    }.lessThan);

    // Force palette[0] = black if configured
    if (cfg.palette_0_color_0_is_black and colors.len > 0) {
        // Shift everything up, insert black at index 0
        const black = OklabAlpha{ .l = 0.0, .a = 0.0, .b = 0.0, .alpha = 1.0 };
        // Only insert if first color is not already black
        const first = colors[0];
        if (color_mod.deltaESquared(first, black) > 1e-8) {
            // Drop the last color to make room
            if (colors.len > 0) {
                var i: usize = colors.len - 1;
                while (i > 0) : (i -= 1) {
                    colors[i] = colors[i - 1];
                }
                colors[0] = black;
            }
        }
    }

    return Palette{ .colors = colors };
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

    return palettes;
}
