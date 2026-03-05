const std = @import("std");
const quantize = @import("quantize.zig");
const QuantizedTile = quantize.QuantizedTile;
const kmeans = @import("kmeans");
const palette_mod = @import("palette.zig");
const Palette = palette_mod.Palette;

pub const TilesetResult = struct {
    /// The unique (deduplicated) tiles.
    unique_tiles: []QuantizedTile,
    /// For each original tile, the index into unique_tiles.
    tile_indices: []u8,
    /// For each original tile, whether it is stored as an x-flipped version.
    x_flip_flags: []bool,
};

/// Flip a tile horizontally (mirror left-right).
fn flipTileHorizontal(tile: QuantizedTile, arena: std.mem.Allocator) !QuantizedTile {
    const flipped_data = try arena.alloc(u8, tile.data.len);
    for (0..tile.height) |row| {
        for (0..tile.width) |col| {
            flipped_data[row * tile.width + col] = tile.data[row * tile.width + (tile.width - 1 - col)];
        }
    }
    return QuantizedTile{ .data = flipped_data, .width = tile.width, .height = tile.height };
}

/// Deduplicate quantized tiles using exact hash matching with optional k-means fallback.
///
/// Fast path (ExactHashReducer): each tile is hashed for O(1) lookup. Horizontal flips are
/// also detected — a flipped tile reuses the canonical tile with x_flip=true.
///
/// Fallback (KmeansColorReducer): when unique tile count exceeds max_unique_tiles, k-means
/// clusters the unique tiles into max_unique_tiles groups. Each cluster's closest-to-center
/// tile becomes the representative, giving max_unique_tiles unique tiles in the output.
pub fn deduplicateExact(
    arena: std.mem.Allocator,
    tiles: []const QuantizedTile,
    palette_assignments: []const u8,
    palettes: []const Palette,
    max_unique_tiles: u32,
    tile_kmeans_max_iter: u64,
) !TilesetResult {
    // Phase 1: collect all unique tiles via exact hash.
    // Use u32 values in the map so there is no 256-tile cap on unique tile collection.
    // The final u8 tile_indices are produced only after k-means reduces the set.
    var map = std.HashMap(u64, u32, HashContext, std.hash_map.default_max_load_percentage).init(arena);

    var unique_list: std.ArrayListUnmanaged(QuantizedTile) = .empty;
    var unique_pal_indices: std.ArrayListUnmanaged(u8) = .empty;
    // Intermediate tile_indices use u32 to accommodate any number of unique tiles.
    const tile_indices_u32 = try arena.alloc(u32, tiles.len);
    const x_flip_flags = try arena.alloc(bool, tiles.len);

    for (tiles, 0..) |tile, orig_idx| {
        // 1. Check exact match via hash
        const h = hashTileData(tile.data);
        if (map.get(h)) |candidate_idx| {
            if (candidate_idx < unique_list.items.len and
                std.mem.eql(u8, unique_list.items[candidate_idx].data, tile.data))
            {
                tile_indices_u32[orig_idx] = candidate_idx;
                x_flip_flags[orig_idx] = false;
                continue;
            }
        }

        // 2. Check flipped match
        const flipped = try flipTileHorizontal(tile, arena);
        const hf = hashTileData(flipped.data);
        found_flip: {
            if (map.get(hf)) |candidate_idx| {
                if (candidate_idx < unique_list.items.len and
                    std.mem.eql(u8, unique_list.items[candidate_idx].data, flipped.data))
                {
                    tile_indices_u32[orig_idx] = candidate_idx;
                    x_flip_flags[orig_idx] = true;
                    break :found_flip;
                }
            }

            // 3. New unique tile — collect without any cap; k-means handles reduction below.
            const new_idx: u32 = @intCast(unique_list.items.len);
            try map.put(h, new_idx);
            try unique_list.append(arena, tile);
            try unique_pal_indices.append(arena, palette_assignments[orig_idx]);
            tile_indices_u32[orig_idx] = new_idx;
            x_flip_flags[orig_idx] = false;
        }
    }

    // Phase 2: if too many unique tiles, reduce via k-means
    if (unique_list.items.len > max_unique_tiles) {
        return kmeansReduceTiles(
            arena,
            unique_list.items,
            unique_pal_indices.items,
            palettes,
            tile_indices_u32,
            x_flip_flags,
            max_unique_tiles,
            tile_kmeans_max_iter,
        );
    }

    // No reduction needed: convert u32 indices to u8 (safe: all values < unique_list.items.len <= max_unique_tiles <= 256)
    const tile_indices = try arena.alloc(u8, tiles.len);
    for (tile_indices_u32, 0..) |idx, i| tile_indices[i] = @intCast(idx);
    return TilesetResult{
        .unique_tiles = unique_list.items,
        .tile_indices = tile_indices,
        .x_flip_flags = x_flip_flags,
    };
}

/// Reduce N unique tiles to k representative tiles using k-means on OKLab color feature vectors.
/// Each pixel's palette color is looked up and its (L, a, b) components form the feature vector,
/// giving perceptually meaningful distances between tiles across different hues and luminances.
/// For each cluster, the unique tile closest to the cluster center is chosen as representative.
fn kmeansReduceTiles(
    arena: std.mem.Allocator,
    unique_tiles: []const QuantizedTile,
    unique_pal_indices: []const u8,
    palettes: []const Palette,
    tile_indices_u32: []u32,
    x_flip_flags: []bool,
    max_unique_tiles: u32,
    tile_kmeans_max_iter: u64,
) !TilesetResult {
    const n = unique_tiles.len;
    const k = @min(max_unique_tiles, n);

    // Build feature vectors: each pixel mapped to (L, a, b) from its palette color.
    // This gives perceptually meaningful distances — index-based distances are meaningless.
    const feature_vecs = try arena.alloc([]f32, n);
    for (unique_tiles, 0..) |tile, i| {
        const palette = palettes[unique_pal_indices[i]];
        const vec = try arena.alloc(f32, tile.data.len * 3);
        for (tile.data, 0..) |color_idx, j| {
            const color = palette.colors[color_idx];
            vec[j * 3 + 0] = color.l;
            vec[j * 3 + 1] = color.a;
            vec[j * 3 + 2] = color.b;
        }
        feature_vecs[i] = vec;
    }

    var km = kmeans.KMeans(f32, null, null, null, null){
        .allocator = arena,
        .n_clusters = k,
        .max_it = tile_kmeans_max_iter,
    };
    try km.fit(feature_vecs);

    // Get cluster assignment for each unique tile
    const const_vecs = try arena.alloc([]const f32, n);
    for (feature_vecs, 0..) |v, i| const_vecs[i] = v;
    const labels = try km.predict(const_vecs);

    const centers = try km.getCenters();

    // For each cluster, find the unique tile closest to the cluster center
    const representative = try arena.alloc(usize, k);
    for (0..k) |c| {
        var best_dist: f32 = std.math.floatMax(f32);
        var best_idx: usize = 0;
        for (0..n) |u| {
            if (labels[u] != c) continue;
            var dist: f32 = 0;
            for (feature_vecs[u], centers[c]) |fv, cv| {
                const diff = fv - cv;
                dist += diff * diff;
            }
            if (dist < best_dist) {
                best_dist = dist;
                best_idx = u;
            }
        }
        representative[c] = best_idx;
    }

    // Build new unique tile list from representatives (one per cluster)
    const new_unique = try arena.alloc(QuantizedTile, k);
    for (0..k) |c| {
        new_unique[c] = unique_tiles[representative[c]];
    }

    // Remap: each original tile_index points to its old unique tile (u32 index);
    // the new index is the cluster label of that old unique tile.
    // Convert from u32 intermediate to final u8 (safe: labels are in [0, k-1] <= 255).
    const tile_indices = try arena.alloc(u8, tile_indices_u32.len);
    for (tile_indices_u32, 0..) |old_idx, i| {
        tile_indices[i] = @intCast(labels[old_idx]);
    }

    return TilesetResult{
        .unique_tiles = new_unique,
        .tile_indices = tile_indices,
        .x_flip_flags = x_flip_flags,
    };
}

fn hashTileData(data: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(data);
    return hasher.final();
}

const HashContext = struct {
    pub fn hash(_: HashContext, key: u64) u64 {
        return key;
    }
    pub fn eql(_: HashContext, a: u64, b: u64) bool {
        return a == b;
    }
};
