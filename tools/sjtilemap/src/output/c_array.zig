const std = @import("std");
const zigimg = @import("zigimg");
const tilemap_mod = @import("../tilemap.zig");
const TilemapEntry = tilemap_mod.TilemapEntry;
const quantize_mod = @import("../quantize.zig");
const QuantizedTile = quantize_mod.QuantizedTile;
const palette_mod = @import("../palette.zig");
const Palette = palette_mod.Palette;

/// Write palettes as a C array of packed 0x{RR}{GG}{BB} values (one u32 per color).
/// Padded to colors_per_palette entries per palette.
pub fn writePaletteCArray(
    out: std.io.AnyWriter,
    palettes: []const Palette,
    colors_per_palette: usize,
    c_cfg: CArrayConfig,
) !void {
    try out.print("#ifndef {s}\n", .{c_cfg.include_guard});
    try out.print("#define {s}\n", .{c_cfg.include_guard});
    if (c_cfg.add_stdint_include) {
        try out.writeAll("#include <stdint.h>\n");
    }
    try out.writeByte('\n');

    const const_kw: []const u8 = if (c_cfg.use_const) "const " else "";
    try out.print("{s}uint32_t {s}_data[] = {{\n", .{ const_kw, c_cfg.var_prefix });

    var entry_count: usize = 0;
    const total = palettes.len * colors_per_palette;

    for (palettes) |palette| {
        for (palette.colors) |oklab| {
            const srgb = zigimg.color.sRGB.fromOkLabAlpha(oklab, .clamp);
            const r8: u32 = @intFromFloat(@round(srgb.r * 255.0));
            const g8: u32 = @intFromFloat(@round(srgb.g * 255.0));
            const b8: u32 = @intFromFloat(@round(srgb.b * 255.0));
            const packed_rgb: u32 = (r8 << 16) | (g8 << 8) | b8;

            if (entry_count % c_cfg.entries_per_line == 0) try out.writeAll("    ");
            try out.print("0x{X:0>6}", .{packed_rgb});
            entry_count += 1;
            if (entry_count < total) {
                if (entry_count % c_cfg.entries_per_line == 0) {
                    try out.writeAll(",\n");
                } else {
                    try out.writeAll(", ");
                }
            }
        }
        // Pad to colors_per_palette
        for (palette.colors.len..colors_per_palette) |_| {
            if (entry_count % c_cfg.entries_per_line == 0) try out.writeAll("    ");
            try out.writeAll("0x000000");
            entry_count += 1;
            if (entry_count < total) {
                if (entry_count % c_cfg.entries_per_line == 0) {
                    try out.writeAll(",\n");
                } else {
                    try out.writeAll(", ");
                }
            }
        }
    }
    if (entry_count > 0 and entry_count % c_cfg.entries_per_line != 0) {
        try out.writeByte('\n');
    }

    try out.writeAll("};\n");
    try out.writeByte('\n');
    try out.print("#endif /* {s} */\n", .{c_cfg.include_guard});
}

pub const CArrayConfig = struct {
    var_prefix: []const u8 = "tilemap",
    tilemap_entry_type: []const u8 = "uint16_t",
    /// C type for each tileset row word (2 u16 chunks packed into one u32).
    tile_row_type: []const u8 = "uint32_t",
    include_guard: []const u8 = "TILEMAP_H",
    add_stdint_include: bool = true,
    use_const: bool = true,
    entries_per_line: u32 = 16,
    /// Use uppercase hex literals (0xABCD vs 0xabcd).
    hex_uppercase: bool = true,
};

pub fn writeTilemapCArray(
    out: std.io.AnyWriter,
    tilemap: []const TilemapEntry,
    c_cfg: CArrayConfig,
) !void {
    // Include guard header
    try out.print("#ifndef {s}\n", .{c_cfg.include_guard});
    try out.print("#define {s}\n", .{c_cfg.include_guard});
    if (c_cfg.add_stdint_include) {
        try out.writeAll("#include <stdint.h>\n");
    }
    try out.writeByte('\n');

    // Array declaration
    const const_kw: []const u8 = if (c_cfg.use_const) "const " else "";
    try out.print("{s}{s} {s}_data[] = {{\n", .{ const_kw, c_cfg.tilemap_entry_type, c_cfg.var_prefix });

    // Entries
    for (tilemap, 0..) |entry, i| {
        if (i % c_cfg.entries_per_line == 0) {
            try out.writeAll("    ");
        }
        try out.print("0x{X:0>4}", .{entry.toU16()});
        if (i + 1 < tilemap.len) {
            try out.writeAll(", ");
        }
        if ((i + 1) % c_cfg.entries_per_line == 0 or i + 1 == tilemap.len) {
            try out.writeByte('\n');
        }
    }

    try out.writeAll("};\n");
    try out.writeByte('\n');
    try out.print("#endif /* {s} */\n", .{c_cfg.include_guard});
}

/// Pack a row of 8 pixel indices (u8, 0-15) into 2 u16 chunks (4 bits per pixel).
fn packRow8(row_pixels: []const u8) [2]u16 {
    var chunks: [2]u16 = .{ 0, 0 };
    for (row_pixels, 0..) |px, i| {
        const chunk_idx = i / 4;
        const bit_pos: u4 = @intCast((i % 4) * 4);
        chunks[chunk_idx] |= @as(u16, px) << bit_pos;
    }
    return chunks;
}

/// Write tileset pixel data as a C array in row-major order.
/// Each u16 word holds 4 pixels (4 bits each). Padded to max_unique_tiles tiles per row.
pub fn writeTilesetCArrayRowMajor(
    out: std.io.AnyWriter,
    tiles: []const QuantizedTile,
    tile_height: usize,
    tile_width: usize,
    max_unique_tiles: usize,
    c_cfg: CArrayConfig,
) !void {
    try out.print("#ifndef {s}\n", .{c_cfg.include_guard});
    try out.print("#define {s}\n", .{c_cfg.include_guard});
    if (c_cfg.add_stdint_include) {
        try out.writeAll("#include <stdint.h>\n");
    }
    try out.writeByte('\n');

    const tile_row_type = "uint32_t"; // 2 u16 chunks = 1 u32 per tile row; use u32 for display
    const const_kw: []const u8 = if (c_cfg.use_const) "const " else "";
    // Total entries: tile_height rows × max_unique_tiles tiles × 2 u16 words each
    // Store as an array of u16 words (tile_height * max_unique_tiles * 2 words).
    // Alternatively, store as array of u32 (one u32 per tile per row).
    _ = tile_row_type;
    try out.print("{s}uint16_t {s}_data[] = {{\n", .{ const_kw, c_cfg.var_prefix });

    // Row-major: for each row, emit all tile chunks, padded to max_unique_tiles
    var word_count: usize = 0;
    const total_words = tile_height * max_unique_tiles * 2;
    _ = total_words;
    for (0..tile_height) |row| {
        for (tiles) |tile| {
            const row_start = row * tile_width;
            const row_pixels = tile.data[row_start .. row_start + tile_width];
            const chunks = packRow8(row_pixels);
            for (chunks) |chunk| {
                if (word_count % c_cfg.entries_per_line == 0) try out.writeAll("    ");
                try out.print("0x{X:0>4}", .{chunk});
                word_count += 1;
                if (word_count % c_cfg.entries_per_line == 0) {
                    try out.writeAll(",\n");
                } else {
                    try out.writeAll(", ");
                }
            }
        }
        // Pad to max_unique_tiles
        for (tiles.len..max_unique_tiles) |_| {
            for (0..2) |_| {
                if (word_count % c_cfg.entries_per_line == 0) try out.writeAll("    ");
                try out.writeAll("0x0000");
                word_count += 1;
                if (word_count % c_cfg.entries_per_line == 0) {
                    try out.writeAll(",\n");
                } else {
                    try out.writeAll(", ");
                }
            }
        }
    }
    // Handle trailing comma/newline
    if (word_count > 0 and word_count % c_cfg.entries_per_line != 0) {
        try out.writeByte('\n');
    }

    try out.writeAll("};\n");
    try out.writeByte('\n');
    try out.print("#endif /* {s} */\n", .{c_cfg.include_guard});
}

/// Write tileset pixel data as a C array in sequential order (tile-first).
/// Each tile's rows appear consecutively before the next tile begins.
pub fn writeTilesetCArraySequential(
    out: std.io.AnyWriter,
    tiles: []const QuantizedTile,
    tile_height: usize,
    tile_width: usize,
    c_cfg: CArrayConfig,
) !void {
    try out.print("#ifndef {s}\n", .{c_cfg.include_guard});
    try out.print("#define {s}\n", .{c_cfg.include_guard});
    if (c_cfg.add_stdint_include) {
        try out.writeAll("#include <stdint.h>\n");
    }
    try out.writeByte('\n');

    const const_kw: []const u8 = if (c_cfg.use_const) "const " else "";
    try out.print("{s}uint16_t {s}_data[] = {{\n", .{ const_kw, c_cfg.var_prefix });

    var word_count: usize = 0;
    for (tiles) |tile| {
        for (0..tile_height) |row| {
            const row_start = row * tile_width;
            const row_pixels = tile.data[row_start .. row_start + tile_width];
            const chunks = packRow8(row_pixels);
            for (chunks) |chunk| {
                if (word_count % c_cfg.entries_per_line == 0) try out.writeAll("    ");
                try out.print("0x{X:0>4}", .{chunk});
                word_count += 1;
                if (word_count % c_cfg.entries_per_line == 0) {
                    try out.writeAll(",\n");
                } else {
                    try out.writeAll(", ");
                }
            }
        }
    }
    if (word_count > 0 and word_count % c_cfg.entries_per_line != 0) {
        try out.writeByte('\n');
    }

    try out.writeAll("};\n");
    try out.writeByte('\n');
    try out.print("#endif /* {s} */\n", .{c_cfg.include_guard});
}
