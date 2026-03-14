const std = @import("std");
const zigimg = @import("zigimg");
const tilemap_mod = @import("../tilemap.zig");
const TilemapEntry = tilemap_mod.TilemapEntry;
const quantize_mod = @import("../quantize.zig");
const QuantizedTile = quantize_mod.QuantizedTile;
const palette_mod = @import("../palette.zig");
const Palette = palette_mod.Palette;
const common = @import("common.zig");

/// Write palettes as a C array of packed color values (one uint32_t per color).
/// .rgb:  values are 0x00{RR}{GG}{BB} printed as 6 hex digits (0xRRGGBB).
/// .xrgb: values are 0x00{RR}{GG}{BB} printed as 8 hex digits (0x00RRGGBB). Default.
/// Padded to colors_per_palette entries per palette.
pub fn writePaletteCArray(
    out: std.io.AnyWriter,
    palettes: []const Palette,
    colors_per_palette: usize,
    palette_format: common.PaletteFormat,
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

    var cbuf: [common.max_palette_entry_bytes]u8 = undefined;
    for (palettes) |palette| {
        for (palette.colors) |oklab| {
            const rgb = common.oklabToSrgbU8(oklab);
            const bytes = common.paletteColorBytes(rgb, palette_format, &cbuf);

            if (entry_count % c_cfg.entries_per_line == 0) try out.writeAll("    ");
            try out.writeAll("0x");
            for (bytes) |b| try out.print("{X:0>2}", .{b});
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
        for (palette.count..colors_per_palette) |_| {
            if (entry_count % c_cfg.entries_per_line == 0) try out.writeAll("    ");
            try out.writeAll("0x");
            for (0..common.paletteEntryByteCount(palette_format)) |_| try out.writeAll("00");
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
    try out.print("#ifndef {s}\n", .{c_cfg.include_guard});
    try out.print("#define {s}\n", .{c_cfg.include_guard});
    if (c_cfg.add_stdint_include) {
        try out.writeAll("#include <stdint.h>\n");
    }
    try out.writeByte('\n');

    const const_kw: []const u8 = if (c_cfg.use_const) "const " else "";
    try out.print("{s}{s} {s}_data[] = {{\n", .{ const_kw, c_cfg.tilemap_entry_type, c_cfg.var_prefix });

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

/// Write tileset pixel data as a C array in row-major order.
/// Each u16 word holds (16 / bits_per_pixel) pixels. Padded to max_unique_tiles tiles per row.
pub fn writeTilesetCArrayRowMajor(
    out: std.io.AnyWriter,
    tiles: []const QuantizedTile,
    tile_height: usize,
    tile_width: usize,
    max_unique_tiles: usize,
    bits_per_pixel: u4,
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

    const n_chunks = common.chunksPerRow(tile_width, bits_per_pixel);
    var chunks_buf: [common.max_chunks_per_row]u16 = undefined;
    var word_count: usize = 0;
    for (0..tile_height) |row| {
        for (tiles) |tile| {
            const row_start = row * tile_width;
            const row_pixels = tile.data[row_start .. row_start + tile_width];
            common.packRow(row_pixels, bits_per_pixel, chunks_buf[0..n_chunks]);
            for (chunks_buf[0..n_chunks]) |chunk| {
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
            for (0..n_chunks) |_| {
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
    bits_per_pixel: u4,
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

    const n_chunks = common.chunksPerRow(tile_width, bits_per_pixel);
    var chunks_buf: [common.max_chunks_per_row]u16 = undefined;
    var word_count: usize = 0;
    for (tiles) |tile| {
        for (0..tile_height) |row| {
            const row_start = row * tile_width;
            const row_pixels = tile.data[row_start .. row_start + tile_width];
            common.packRow(row_pixels, bits_per_pixel, chunks_buf[0..n_chunks]);
            for (chunks_buf[0..n_chunks]) |chunk| {
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
