const std = @import("std");
const zigimg = @import("zigimg");
const config_mod = @import("../config.zig");

pub const PaletteFormat = config_mod.PaletteFormat;

/// Stack buffer capacity: supports up to 128 pixels per row at 8bpp (64 u16 words).
/// Tile widths beyond this would require allocator-based packing.
pub const max_chunks_per_row: usize = 64;

/// sRGB u8 triplet produced by oklabToSrgbU8.
pub const SrgbU8 = struct { r: u8, g: u8, b: u8 };

/// Convert an OKLab color to clamped sRGB u8 components.
/// Single source of truth for the OKLab → sRGB → u8 encoding used by all output formats.
pub fn oklabToSrgbU8(oklab: zigimg.color.OklabAlpha) SrgbU8 {
    const srgb = zigimg.color.sRGB.fromOkLabAlpha(oklab, .clamp);
    return .{
        .r = @intFromFloat(@round(srgb.r * 255.0)),
        .g = @intFromFloat(@round(srgb.g * 255.0)),
        .b = @intFromFloat(@round(srgb.b * 255.0)),
    };
}

/// Maximum number of bytes a palette color entry can occupy across all formats.
/// Increase this if a future format needs more bytes.
pub const max_palette_entry_bytes: usize = 4;

/// Return the canonical byte representation of a palette color in the given format.
/// The slice is valid for the lifetime of `buf`. All output formats render these bytes
/// verbatim — hex writers emit 2 hex digits per byte, binary writers write bytes directly,
/// C array writers emit "0x" + 2 hex chars per byte. No format writer needs to know the
/// bit layout; changing the format here is the single change needed everywhere.
///
/// .rgb:  [B, G, R]        — 3 bytes; little-endian 24-bit color.
/// .xrgb: [B, G, R, 0x00]  — 4 bytes; little-endian u32, MSB = 0x00 (ignored).
///        Bit layout: (R<<16)|(G<<8)|B — matches Rust imgconv:
///        `let rgb: u32 = ((r as u32) << 16) | ((g as u32) << 8) | (b as u32);`
pub fn paletteColorBytes(rgb: SrgbU8, format: PaletteFormat, buf: *[max_palette_entry_bytes]u8) []const u8 {
    switch (format) {
        .rgb => {
            buf[0] = rgb.b; buf[1] = rgb.g; buf[2] = rgb.r;
            return buf[0..3];
        },
        .xrgb => {
            buf[0] = rgb.b; buf[1] = rgb.g; buf[2] = rgb.r; buf[3] = 0x00;
            return buf[0..4];
        },
    }
}

/// Number of bytes per palette color entry in the given format.
/// Single query site for zero-padding loops and size calculations.
pub fn paletteEntryByteCount(format: PaletteFormat) usize {
    return switch (format) { .rgb => 3, .xrgb => 4 };
}

/// Number of u16 words needed to pack tile_width pixels at bits_per_pixel bpp.
/// bits_per_pixel must evenly divide 16 (i.e. 1, 2, 4, or 8).
///
/// For 6bpp — which does not divide 16 evenly — use bitplanes: split the 6 bits per
/// pixel into three 2bpp planes and call packRow / unpackRow once per plane.
pub fn chunksPerRow(tile_width: usize, bits_per_pixel: u4) usize {
    return (tile_width * bits_per_pixel + 15) / 16;
}

/// Pack pixel indices into u16 words, LSB-first within each word.
/// bits_per_pixel must evenly divide 16 (1, 2, 4, or 8).
/// out_chunks.len must equal chunksPerRow(row_pixels.len, bits_per_pixel).
pub fn packRow(row_pixels: []const u8, bits_per_pixel: u4, out_chunks: []u16) void {
    std.debug.assert(out_chunks.len == chunksPerRow(row_pixels.len, bits_per_pixel));
    const pixels_per_chunk: usize = @as(usize, 16) / @as(usize, bits_per_pixel);
    const mask: u16 = (@as(u16, 1) << bits_per_pixel) - 1;
    for (out_chunks) |*c| c.* = 0;
    for (row_pixels, 0..) |px, i| {
        const chunk_idx = i / pixels_per_chunk;
        const bit_pos: u4 = @intCast((i % pixels_per_chunk) * bits_per_pixel);
        out_chunks[chunk_idx] |= (@as(u16, px) & mask) << bit_pos;
    }
}

/// Unpack u16 words into pixel indices. Inverse of packRow.
/// chunks.len must equal chunksPerRow(out_pixels.len, bits_per_pixel).
pub fn unpackRow(chunks: []const u16, bits_per_pixel: u4, out_pixels: []u8) void {
    std.debug.assert(chunks.len == chunksPerRow(out_pixels.len, bits_per_pixel));
    const pixels_per_chunk: usize = @as(usize, 16) / @as(usize, bits_per_pixel);
    const mask: u16 = (@as(u16, 1) << bits_per_pixel) - 1;
    for (out_pixels, 0..) |*px, i| {
        const chunk_idx = i / pixels_per_chunk;
        const bit_pos: u4 = @intCast((i % pixels_per_chunk) * bits_per_pixel);
        px.* = @truncate((chunks[chunk_idx] >> bit_pos) & mask);
    }
}
