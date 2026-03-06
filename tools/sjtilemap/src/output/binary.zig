const std = @import("std");
const zigimg = @import("zigimg");
const tilemap_mod = @import("../tilemap.zig");
const TilemapEntry = tilemap_mod.TilemapEntry;
const quantize_mod = @import("../quantize.zig");
const QuantizedTile = quantize_mod.QuantizedTile;
const palette_mod = @import("../palette.zig");
const Palette = palette_mod.Palette;

/// Write palettes as raw binary RGB bytes (3 bytes per color: R, G, B as u8).
/// One palette per group of colors_per_palette triplets. Padded with zeros.
pub fn writePaletteBinary(
    out: std.io.AnyWriter,
    palettes: []const Palette,
    colors_per_palette: usize,
) !void {
    for (palettes) |palette| {
        for (palette.colors) |oklab| {
            const srgb = zigimg.color.sRGB.fromOkLabAlpha(oklab, .clamp);
            const r8: u8 = @intFromFloat(@round(srgb.r * 255.0));
            const g8: u8 = @intFromFloat(@round(srgb.g * 255.0));
            const b8: u8 = @intFromFloat(@round(srgb.b * 255.0));
            try out.writeByte(r8);
            try out.writeByte(g8);
            try out.writeByte(b8);
        }
        // Pad to colors_per_palette
        for (palette.count..colors_per_palette) |_| {
            try out.writeByte(0);
            try out.writeByte(0);
            try out.writeByte(0);
        }
    }
}

/// Write tilemap as raw little-endian u16 bytes (no header).
pub fn writeTilemapBinary(out: std.io.AnyWriter, tilemap: []const TilemapEntry) !void {
    for (tilemap) |entry| {
        try out.writeInt(u16, entry.toU16(), .little);
    }
}

/// Pack a row of 8 pixel indices (u8, value 0-15) into 2 u16 chunks (4 bits per pixel).
fn packRow8(row_pixels: []const u8) [2]u16 {
    var chunks: [2]u16 = .{ 0, 0 };
    for (row_pixels, 0..) |px, i| {
        const chunk_idx = i / 4;
        const bit_pos: u4 = @intCast((i % 4) * 4);
        chunks[chunk_idx] |= @as(u16, px) << bit_pos;
    }
    return chunks;
}

/// Write tileset pixel data as raw little-endian u16 words, row-major order.
/// Outer loop: pixel row (0..tile_height); inner loop: tile.
/// Each tile row produces 2 u16 words (4 bits per pixel, 8 pixels per row).
/// Padded to max_unique_tiles tiles per row with zero words.
pub fn writeTilesetBinaryRowMajor(
    out: std.io.AnyWriter,
    tiles: []const QuantizedTile,
    tile_height: usize,
    tile_width: usize,
    max_unique_tiles: usize,
) !void {
    for (0..tile_height) |row| {
        for (tiles) |tile| {
            const row_start = row * tile_width;
            const row_pixels = tile.data[row_start .. row_start + tile_width];
            const chunks = packRow8(row_pixels);
            try out.writeInt(u16, chunks[0], .little);
            try out.writeInt(u16, chunks[1], .little);
        }
        // Pad to max_unique_tiles
        for (tiles.len..max_unique_tiles) |_| {
            try out.writeInt(u16, 0, .little);
            try out.writeInt(u16, 0, .little);
        }
    }
}

/// Write tileset pixel data as raw little-endian u16 words, sequential (tile-first) order.
pub fn writeTilesetBinarySequential(
    out: std.io.AnyWriter,
    tiles: []const QuantizedTile,
    tile_height: usize,
    tile_width: usize,
) !void {
    for (tiles) |tile| {
        for (0..tile_height) |row| {
            const row_start = row * tile_width;
            const row_pixels = tile.data[row_start .. row_start + tile_width];
            const chunks = packRow8(row_pixels);
            try out.writeInt(u16, chunks[0], .little);
            try out.writeInt(u16, chunks[1], .little);
        }
    }
}
