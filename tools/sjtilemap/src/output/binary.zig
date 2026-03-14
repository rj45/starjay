const std = @import("std");
const zigimg = @import("zigimg");
const tilemap_mod = @import("../tilemap.zig");
const TilemapEntry = tilemap_mod.TilemapEntry;
const quantize_mod = @import("../quantize.zig");
const QuantizedTile = quantize_mod.QuantizedTile;
const palette_mod = @import("../palette.zig");
const Palette = palette_mod.Palette;
const common = @import("common.zig");

/// Write palettes as raw binary.
/// .rgb:  3 bytes per color (R, G, B). Padded with 3 zero bytes per empty slot.
/// .xrgb: 4-byte little-endian u32 per color, value = (R<<16)|(G<<8)|B, MSB=0. Padded with 4 zero bytes.
pub fn writePaletteBinary(
    out: std.io.AnyWriter,
    palettes: []const Palette,
    colors_per_palette: usize,
    palette_format: common.PaletteFormat,
) !void {
    var cbuf: [common.max_palette_entry_bytes]u8 = undefined;
    for (palettes) |palette| {
        for (palette.colors) |oklab| {
            const rgb = common.oklabToSrgbU8(oklab);
            try out.writeAll(common.paletteColorBytes(rgb, palette_format, &cbuf));
        }
        // Pad to colors_per_palette
        for (palette.count..colors_per_palette) |_| {
            for (0..common.paletteEntryByteCount(palette_format)) |_| try out.writeByte(0);
        }
    }
}

/// Write tilemap as raw little-endian u16 bytes (no header).
pub fn writeTilemapBinary(out: std.io.AnyWriter, tilemap: []const TilemapEntry) !void {
    for (tilemap) |entry| {
        try out.writeInt(u16, entry.toU16(), .little);
    }
}

/// Write tileset pixel data as raw little-endian u16 words, row-major order.
/// Outer loop: pixel row (0..tile_height); inner loop: tile.
/// Each tile row produces chunksPerRow(tile_width, bits_per_pixel) u16 words.
/// Padded to max_unique_tiles tiles per row with zero words.
pub fn writeTilesetBinaryRowMajor(
    out: std.io.AnyWriter,
    tiles: []const QuantizedTile,
    tile_height: usize,
    tile_width: usize,
    max_unique_tiles: usize,
    bits_per_pixel: u4,
) !void {
    const n_chunks = common.chunksPerRow(tile_width, bits_per_pixel);
    var chunks_buf: [common.max_chunks_per_row]u16 = undefined;
    for (0..tile_height) |row| {
        for (tiles) |tile| {
            const row_start = row * tile_width;
            const row_pixels = tile.data[row_start .. row_start + tile_width];
            common.packRow(row_pixels, bits_per_pixel, chunks_buf[0..n_chunks]);
            for (chunks_buf[0..n_chunks]) |chunk| {
                try out.writeInt(u16, chunk, .little);
            }
        }
        // Pad to max_unique_tiles
        for (tiles.len..max_unique_tiles) |_| {
            for (0..n_chunks) |_| try out.writeInt(u16, 0, .little);
        }
    }
}

/// Write tileset pixel data as raw little-endian u16 words, sequential (tile-first) order.
pub fn writeTilesetBinarySequential(
    out: std.io.AnyWriter,
    tiles: []const QuantizedTile,
    tile_height: usize,
    tile_width: usize,
    bits_per_pixel: u4,
) !void {
    const n_chunks = common.chunksPerRow(tile_width, bits_per_pixel);
    var chunks_buf: [common.max_chunks_per_row]u16 = undefined;
    for (tiles) |tile| {
        for (0..tile_height) |row| {
            const row_start = row * tile_width;
            const row_pixels = tile.data[row_start .. row_start + tile_width];
            common.packRow(row_pixels, bits_per_pixel, chunks_buf[0..n_chunks]);
            for (chunks_buf[0..n_chunks]) |chunk| {
                try out.writeInt(u16, chunk, .little);
            }
        }
    }
}
