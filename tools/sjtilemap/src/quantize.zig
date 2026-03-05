const std = @import("std");
const color_mod = @import("color.zig");
const OklabAlpha = color_mod.OklabAlpha;
const Palette = @import("palette.zig").Palette;

/// Find the index of the nearest palette entry to the given color.
pub fn bestPaletteEntry(px: OklabAlpha, palette: Palette) u8 {
    var best_idx: u8 = 0;
    var best_dist = color_mod.deltaESquared(px, palette.colors[0]);
    for (palette.colors[1..], 1..) |c, i| {
        const d = color_mod.deltaESquared(px, c);
        if (d < best_dist) {
            best_dist = d;
            best_idx = @intCast(i);
        }
    }
    return best_idx;
}

/// Find the index of the nearest palette entry, searching from index 1 onward.
/// Index 0 is reserved for transparency.
pub fn bestPaletteEntrySkipFirst(px: OklabAlpha, palette: Palette) u8 {
    if (palette.colors.len <= 1) return 0;
    var best_idx: u8 = 1;
    var best_dist = color_mod.deltaESquared(px, palette.colors[1]);
    for (palette.colors[2..], 2..) |c, i| {
        const d = color_mod.deltaESquared(px, c);
        if (d < best_dist) {
            best_dist = d;
            best_idx = @intCast(i);
        }
    }
    return best_idx;
}

/// A tile with pixels quantized to palette indices.
pub const QuantizedTile = struct {
    /// One byte per pixel containing the 4-bit palette index (0-15).
    data: []u8,
    width: u32,
    height: u32,
};

/// Quantize a tile's pixels to palette indices (no dithering).
pub fn quantizeTile(
    arena: std.mem.Allocator,
    tile_pixels: []const OklabAlpha,
    width: u32,
    height: u32,
    palette: Palette,
) !QuantizedTile {
    const n = width * height;
    const data = try arena.alloc(u8, n);
    for (tile_pixels, 0..) |px, i| {
        data[i] = bestPaletteEntry(px, palette);
    }
    return QuantizedTile{ .data = data, .width = width, .height = height };
}

/// Quantize a tile's pixels with transparency: alpha < 0.5 -> index 0 (transparent),
/// other pixels search from index 1 onward.
pub fn quantizeTileWithTransparency(
    arena: std.mem.Allocator,
    tile_pixels: []const OklabAlpha,
    width: u32,
    height: u32,
    palette: Palette,
) !QuantizedTile {
    const n = width * height;
    const data = try arena.alloc(u8, n);
    for (tile_pixels, 0..) |px, i| {
        if (px.alpha < 0.5) {
            data[i] = 0; // Transparent color reserved at index 0
        } else {
            data[i] = bestPaletteEntrySkipFirst(px, palette);
        }
    }
    return QuantizedTile{ .data = data, .width = width, .height = height };
}
