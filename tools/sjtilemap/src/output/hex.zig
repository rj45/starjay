const std = @import("std");
const tilemap_mod = @import("../tilemap.zig");
const TilemapEntry = tilemap_mod.TilemapEntry;
const quantize_mod = @import("../quantize.zig");
const QuantizedTile = quantize_mod.QuantizedTile;
const palette_mod = @import("../palette.zig");
const Palette = palette_mod.Palette;
const zigimg = @import("zigimg");

/// Write tilemap as hex. Format: `{XXXX} ` per entry (lowercase), newline per row.
pub fn writeTilemapHex(
    out: std.io.AnyWriter,
    tilemap: []const TilemapEntry,
    tilemap_width: usize,
    logisim: bool,
) !void {
    if (logisim) try out.writeAll("v2.0 raw\n");
    for (tilemap, 0..) |entry, i| {
        try out.print("{x:0>4} ", .{entry.toU16()});
        if ((i + 1) % tilemap_width == 0) try out.writeByte('\n');
    }
}

/// Pack a row of 8 pixel indices (u8, value 0-15) into 2 u16 chunks.
/// chunk0 packs pixels 0..3: p[0] | (p[1]<<4) | (p[2]<<8) | (p[3]<<12)
/// chunk1 packs pixels 4..7: same pattern
fn packRow8(row_pixels: []const u8) [2]u16 {
    var chunks: [2]u16 = .{ 0, 0 };
    for (row_pixels, 0..) |px, i| {
        const chunk_idx = i / 4;
        const bit_pos: u4 = @intCast((i % 4) * 4);
        chunks[chunk_idx] |= @as(u16, px) << bit_pos;
    }
    return chunks;
}

/// Write tileset as hex in row-major order.
/// For each row r (0..tile_height):
///   for each unique tile: write 2 u16 chunks for row r
///   pad to max_unique_tiles with 0000 0000
///   newline
pub fn writeTilesetHexRowMajor(
    out: std.io.AnyWriter,
    tiles: []const QuantizedTile,
    tile_height: usize,
    tile_width: usize,
    max_unique_tiles: usize,
    logisim: bool,
) !void {
    if (logisim) try out.writeAll("v2.0 raw\n");
    for (0..tile_height) |row| {
        for (tiles) |tile| {
            const row_start = row * tile_width;
            const row_pixels = tile.data[row_start .. row_start + tile_width];
            const chunks = packRow8(row_pixels);
            try out.print("{x:0>4} {x:0>4} ", .{ chunks[0], chunks[1] });
        }
        // Pad to max_unique_tiles
        for (tiles.len..max_unique_tiles) |_| {
            try out.writeAll("0000 0000 ");
        }
        try out.writeByte('\n');
    }
}

/// Write palettes as hex:
/// One palette per line, `{RR}{GG}{BB} ` per color in sRGB u8, padded to colors_per_palette entries.
/// OKLab colors are converted to sRGB via zigimg.
pub fn writePaletteHex(
    out: std.io.AnyWriter,
    palettes: []const Palette,
    colors_per_palette: usize,
) !void {
    for (palettes) |palette| {
        for (palette.colors) |oklab| {
            // Convert OKLab to sRGB float32 via zigimg, then clamp and encode as u8
            const srgb = zigimg.color.sRGB.fromOkLabAlpha(oklab, .clamp);
            const r8: u8 = @intFromFloat(@round(srgb.r * 255.0));
            const g8: u8 = @intFromFloat(@round(srgb.g * 255.0));
            const b8: u8 = @intFromFloat(@round(srgb.b * 255.0));
            try out.print("{x:0>2}{x:0>2}{x:0>2} ", .{ r8, g8, b8 });
        }
        // Pad to colors_per_palette entries
        for (palette.count..colors_per_palette) |_| {
            try out.writeAll("000000 ");
        }
        try out.writeByte('\n');
    }
}

/// Load palettes from a palette hex file.
/// Format: one palette per line, `RRGGBB ` per color (case-insensitive hex), padded to
/// colors_per_palette entries with `000000`. Returns []Palette allocated with arena.
/// The number of palettes loaded equals the number of non-empty lines in `data`.
pub fn loadPaletteFromHex(
    arena: std.mem.Allocator,
    data: []const u8,
    colors_per_palette: usize,
) ![]Palette {
    var palettes = std.ArrayListUnmanaged(Palette){};
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const colors = try arena.alloc(zigimg.color.OklabAlpha, colors_per_palette);
        var color_idx: usize = 0;
        var tokens = std.mem.splitScalar(u8, trimmed, ' ');
        while (tokens.next()) |tok| {
            const t = std.mem.trim(u8, tok, " \t");
            if (t.len == 0) continue;
            if (color_idx >= colors_per_palette) break;
            if (t.len < 6) return error.InvalidPaletteHexFormat;
            const r8 = try std.fmt.parseInt(u8, t[0..2], 16);
            const g8 = try std.fmt.parseInt(u8, t[2..4], 16);
            const b8 = try std.fmt.parseInt(u8, t[4..6], 16);
            const srgb = zigimg.color.Colorf32{
                .r = @as(f32, @floatFromInt(r8)) / 255.0,
                .g = @as(f32, @floatFromInt(g8)) / 255.0,
                .b = @as(f32, @floatFromInt(b8)) / 255.0,
                .a = 1.0,
            };
            colors[color_idx] = zigimg.color.sRGB.toOklabAlpha(srgb);
            color_idx += 1;
        }
        const loaded_count: u32 = @intCast(color_idx);
        // Pad remaining slots with black
        while (color_idx < colors_per_palette) : (color_idx += 1) {
            colors[color_idx] = zigimg.color.OklabAlpha{ .l = 0, .a = 0, .b = 0, .alpha = 1.0 };
        }
        try palettes.append(arena, Palette{ .colors = colors, .count = loaded_count });
    }
    return palettes.toOwnedSlice(arena);
}

/// Unpack 2 u16 chunks (row-major 4bpp packing) into 8 pixel indices (0..15).
/// Inverse of packRow8: chunk0 carries pixels 0..3, chunk1 carries pixels 4..7.
fn unpackRow8(chunks: [2]u16, out: []u8) void {
    for (0..4) |i| {
        out[i]     = @truncate((chunks[0] >> @intCast(i * 4)) & 0xF);
        out[i + 4] = @truncate((chunks[1] >> @intCast(i * 4)) & 0xF);
    }
}

/// Load tileset from a row-major hex file.
/// Format: tile_height lines; each line contains `num_tiles` pairs of u16 hex chunks.
/// `num_tiles`: number of tiles to load (leading tiles; remainder is ignored padding).
/// `tile_width` must match what was used when writing (default 8 → 2 chunks per tile per row).
/// Tiles are allocated with arena and returned as []QuantizedTile.
pub fn loadTilesetFromHex(
    arena: std.mem.Allocator,
    data: []const u8,
    tile_height: usize,
    tile_width: usize,
    num_tiles: usize,
) ![]QuantizedTile {
    // Allocate tile storage: each tile has tile_height * tile_width pixels (u8 each)
    const tiles = try arena.alloc(QuantizedTile, num_tiles);
    for (tiles) |*t| {
        t.data = try arena.alloc(u8, tile_height * tile_width);
        t.width = @intCast(tile_width);
        t.height = @intCast(tile_height);
        @memset(t.data, 0);
    }

    const chunks_per_tile = tile_width / 4; // 8-wide tiles → 2 chunks per row
    var row: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (row >= tile_height) break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        var tokens = std.mem.splitScalar(u8, trimmed, ' ');
        for (0..num_tiles) |ti| {
            var row_pixels: [8]u8 = undefined;
            var chunks_read: usize = 0;
            var chunks: [2]u16 = .{ 0, 0 };
            while (chunks_read < chunks_per_tile) {
                const tok = tokens.next() orelse break;
                const t = std.mem.trim(u8, tok, " \t");
                if (t.len == 0) {
                    // try again
                    continue;
                }
                chunks[chunks_read] = try std.fmt.parseInt(u16, t, 16);
                chunks_read += 1;
            }
            unpackRow8(chunks, &row_pixels);
            const row_start = row * tile_width;
            @memcpy(tiles[ti].data[row_start .. row_start + tile_width], &row_pixels);
        }
        row += 1;
    }
    return tiles;
}

/// Write tileset as hex in sequential order (all rows of tile 0, then tile 1, ...).
pub fn writeTilesetHexSequential(
    out: std.io.AnyWriter,
    tiles: []const QuantizedTile,
    tile_height: usize,
    tile_width: usize,
    logisim: bool,
) !void {
    if (logisim) try out.writeAll("v2.0 raw\n");
    for (tiles) |tile| {
        for (0..tile_height) |row| {
            const row_start = row * tile_width;
            const row_pixels = tile.data[row_start .. row_start + tile_width];
            const chunks = packRow8(row_pixels);
            try out.print("{x:0>4} {x:0>4} ", .{ chunks[0], chunks[1] });
            try out.writeByte('\n');
        }
    }
}
