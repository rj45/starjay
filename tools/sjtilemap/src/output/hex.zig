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

/// Write palettes as hex. Format matches Rust imgconv.rs:924-942:
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
        for (palette.colors.len..colors_per_palette) |_| {
            try out.writeAll("000000 ");
        }
        try out.writeByte('\n');
    }
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
