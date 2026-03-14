const std = @import("std");
const tilemap_mod = @import("../tilemap.zig");
const TilemapEntry = tilemap_mod.TilemapEntry;
const quantize_mod = @import("../quantize.zig");
const QuantizedTile = quantize_mod.QuantizedTile;
const palette_mod = @import("../palette.zig");
const Palette = palette_mod.Palette;
const zigimg = @import("zigimg");
const common = @import("common.zig");

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

/// Write tileset as hex in row-major order.
/// For each row r (0..tile_height):
///   for each unique tile: write chunksPerRow u16 chunks for row r
///   pad to max_unique_tiles with zero chunks
///   newline
pub fn writeTilesetHexRowMajor(
    out: std.io.AnyWriter,
    tiles: []const QuantizedTile,
    tile_height: usize,
    tile_width: usize,
    max_unique_tiles: usize,
    bits_per_pixel: u4,
    logisim: bool,
) !void {
    if (logisim) try out.writeAll("v2.0 raw\n");
    const n_chunks = common.chunksPerRow(tile_width, bits_per_pixel);
    var chunks_buf: [common.max_chunks_per_row]u16 = undefined;
    for (0..tile_height) |row| {
        for (tiles) |tile| {
            const row_start = row * tile_width;
            const row_pixels = tile.data[row_start .. row_start + tile_width];
            common.packRow(row_pixels, bits_per_pixel, chunks_buf[0..n_chunks]);
            for (chunks_buf[0..n_chunks]) |chunk| {
                try out.print("{x:0>4} ", .{chunk});
            }
        }
        // Pad to max_unique_tiles
        for (tiles.len..max_unique_tiles) |_| {
            for (0..n_chunks) |_| try out.writeAll("0000 ");
        }
        try out.writeByte('\n');
    }
}

/// Write palettes as hex.
/// .rgb:  one palette per line, `{RRGGBB} ` per color (6 hex digits), padded to colors_per_palette entries.
/// .xrgb: one palette per line, `{00RRGGBB} ` per color (8 hex digits), MSB = 0x00 (ignored).
/// OKLab colors are converted to sRGB via zigimg.
pub fn writePaletteHex(
    out: std.io.AnyWriter,
    palettes: []const Palette,
    colors_per_palette: usize,
    palette_format: common.PaletteFormat,
) !void {
    var cbuf: [common.max_palette_entry_bytes]u8 = undefined;
    for (palettes) |palette| {
        for (palette.colors) |oklab| {
            const rgb = common.oklabToSrgbU8(oklab);
            for (common.paletteColorBytes(rgb, palette_format, &cbuf)) |b|
                try out.print("{x:0>2}", .{b});
            try out.writeByte(' ');
        }
        // Pad to colors_per_palette entries
        for (palette.count..colors_per_palette) |_| {
            for (0..common.paletteEntryByteCount(palette_format)) |_| try out.writeAll("00");
            try out.writeByte(' ');
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
            // Bytes are stored little-endian: [B, G, R] for .rgb, [B, G, R, 0x00] for .xrgb.
            // Parse the first 6 hex chars as B, G, R; any trailing X byte is ignored.
            const b8 = try std.fmt.parseInt(u8, t[0..2], 16);
            const g8 = try std.fmt.parseInt(u8, t[2..4], 16);
            const r8 = try std.fmt.parseInt(u8, t[4..6], 16);
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

/// Load tileset from a row-major hex file.
/// Format: tile_height lines; each line contains `num_tiles` groups of chunksPerRow u16 hex words.
/// `num_tiles`: number of tiles to load (leading tiles; remainder is ignored padding).
/// Tiles are allocated with arena and returned as []QuantizedTile.
pub fn loadTilesetFromHex(
    arena: std.mem.Allocator,
    data: []const u8,
    tile_height: usize,
    tile_width: usize,
    num_tiles: usize,
    bits_per_pixel: u4,
) ![]QuantizedTile {
    const tiles = try arena.alloc(QuantizedTile, num_tiles);
    for (tiles) |*t| {
        t.data = try arena.alloc(u8, tile_height * tile_width);
        t.width = @intCast(tile_width);
        t.height = @intCast(tile_height);
        @memset(t.data, 0);
    }

    const chunks_per_tile = common.chunksPerRow(tile_width, bits_per_pixel);
    // Allocate row buffers once; reused across all tiles and rows.
    const row_pixels = try arena.alloc(u8, tile_width);
    const chunks = try arena.alloc(u16, chunks_per_tile);

    var row: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (row >= tile_height) break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        var tokens = std.mem.splitScalar(u8, trimmed, ' ');
        for (0..num_tiles) |ti| {
            @memset(chunks, 0);
            var chunks_read: usize = 0;
            while (chunks_read < chunks_per_tile) {
                const tok = tokens.next() orelse break;
                const t = std.mem.trim(u8, tok, " \t");
                if (t.len == 0) continue;
                chunks[chunks_read] = try std.fmt.parseInt(u16, t, 16);
                chunks_read += 1;
            }
            common.unpackRow(chunks, bits_per_pixel, row_pixels);
            const row_start = row * tile_width;
            @memcpy(tiles[ti].data[row_start .. row_start + tile_width], row_pixels);
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
    bits_per_pixel: u4,
    logisim: bool,
) !void {
    if (logisim) try out.writeAll("v2.0 raw\n");
    const n_chunks = common.chunksPerRow(tile_width, bits_per_pixel);
    var chunks_buf: [common.max_chunks_per_row]u16 = undefined;
    for (tiles) |tile| {
        for (0..tile_height) |row| {
            const row_start = row * tile_width;
            const row_pixels = tile.data[row_start .. row_start + tile_width];
            common.packRow(row_pixels, bits_per_pixel, chunks_buf[0..n_chunks]);
            for (chunks_buf[0..n_chunks]) |chunk| {
                try out.print("{x:0>4} ", .{chunk});
            }
            try out.writeByte('\n');
        }
    }
}
