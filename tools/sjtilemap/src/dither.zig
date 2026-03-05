const std = @import("std");
const color_mod = @import("color.zig");
const OklabAlpha = color_mod.OklabAlpha;
const Palette = @import("palette.zig").Palette;
const quantize_mod = @import("quantize.zig");
const QuantizedTile = quantize_mod.QuantizedTile;
const tile_mod = @import("tile.zig");
const Tile = tile_mod.Tile;
const Config = @import("config.zig").Config;

pub const DitherAlgorithm = @import("config.zig").DitherAlgorithm;

/// Sierra dithering kernel coefficients.
/// Each entry offsets from the current pixel (dx, dy) and carries weight `num`.
/// The error divisor is derived at comptime by summing all weights.
pub const SierraCoeff = struct { dx: i32, dy: i32, num: f32 };
pub const sierra_pattern = [_]SierraCoeff{
    .{ .dx = 1, .dy = 0, .num = 5 },
    .{ .dx = 2, .dy = 0, .num = 3 },
    .{ .dx = -2, .dy = 1, .num = 2 },
    .{ .dx = -1, .dy = 1, .num = 4 },
    .{ .dx = 0, .dy = 1, .num = 5 },
    .{ .dx = 1, .dy = 1, .num = 4 },
    .{ .dx = 2, .dy = 1, .num = 2 },
    .{ .dx = -1, .dy = 2, .num = 2 },
    .{ .dx = 0, .dy = 2, .num = 3 },
    .{ .dx = 1, .dy = 2, .num = 2 },
};

/// The error divisor for Sierra dithering: the sum of all kernel coefficients.
/// This is the single source of truth — computed from `sierra_pattern`, not hardcoded.
/// Matches Rust `DITHER_ERROR_DIVISOR = 32.0` in `imgconv.rs:30`.
pub const sierra_error_divisor: f32 = blk: {
    var sum: f32 = 0;
    for (sierra_pattern) |c| sum += c.num;
    break :blk sum;
};

/// Propagate Sierra dithering error from one pixel into the error buffer.
/// `error_buf` covers the whole image (width × height).
pub fn applySierraDither(
    error_buf: []OklabAlpha,
    original: OklabAlpha,
    quantized: OklabAlpha,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    factor: f32,
) void {
    const dl = (original.l - quantized.l) * factor / sierra_error_divisor;
    const da = (original.a - quantized.a) * factor / sierra_error_divisor;
    const db = (original.b - quantized.b) * factor / sierra_error_divisor;

    for (sierra_pattern) |coeff| {
        const nx = @as(i64, @intCast(x)) + coeff.dx;
        const ny = @as(i64, @intCast(y)) + coeff.dy;
        if (nx >= 0 and ny >= 0 and
            nx < @as(i64, @intCast(width)) and
            ny < @as(i64, @intCast(height)))
        {
            const ni: usize = @intCast(ny * @as(i64, @intCast(width)) + nx);
            error_buf[ni].l += dl * coeff.num;
            error_buf[ni].a += da * coeff.num;
            error_buf[ni].b += db * coeff.num;
        }
    }
}

/// Quantize tiles with Sierra dithering applied across tile boundaries in scan-line order.
/// This is the primary entry point for dithered quantization.
/// Error propagates globally across the entire image for maximum quality.
pub fn quantizeTilesWithSierra(
    arena: std.mem.Allocator,
    tiles: []const Tile,
    palettes: []const Palette,
    palette_assignments: []const u8,
    cfg: Config,
    img_width: u32,
    img_height: u32,
    tilemap_width: u32,
    tilemap_height: u32,
) ![]QuantizedTile {
    const tile_w = cfg.tile_width;
    const tile_h = cfg.tile_height;

    // Allocate dither error buffer (one entry per image pixel)
    const total_pixels = img_width * img_height;
    const dither_error = try arena.alloc(OklabAlpha, total_pixels);
    @memset(dither_error, OklabAlpha{ .l = 0, .a = 0, .b = 0, .alpha = 0 });

    // Allocate result tiles
    const result = try arena.alloc(QuantizedTile, tiles.len);
    for (result) |*qt| {
        const data = try arena.alloc(u8, tile_w * tile_h);
        @memset(data, 0);
        qt.* = .{ .data = data, .width = tile_w, .height = tile_h };
    }

    // Process in scan-line order: row by row, left to right within each row
    for (0..tilemap_height) |ty| {
        for (0..tile_h) |py| {
            for (0..tilemap_width) |tx| {
                const tile_idx = ty * tilemap_width + tx;
                const palette = palettes[palette_assignments[tile_idx]];
                const use_transparency = (cfg.transparency_mode == .alpha or cfg.transparency_mode == .color) and
                    tiles[tile_idx].has_transparent;

                for (0..tile_w) |px| {
                    const global_x = tx * tile_w + px;
                    const global_y = ty * tile_h + py;
                    const local_i = py * tile_w + px;
                    const err_i = global_y * img_width + global_x;

                    const orig = tiles[tile_idx].pixels[local_i];

                    // Transparent pixels: always assign index 0, no dithering
                    if (use_transparency and orig.alpha < 0.5) {
                        result[tile_idx].data[local_i] = 0;
                        continue;
                    }

                    // Original color + accumulated dither error
                    const accumulated_err = dither_error[err_i];
                    const color = OklabAlpha{
                        .l = orig.l + accumulated_err.l,
                        .a = orig.a + accumulated_err.a,
                        .b = orig.b + accumulated_err.b,
                        .alpha = orig.alpha,
                    };

                    // Quantize to nearest palette color
                    const color_idx = if (use_transparency)
                        quantize_mod.bestPaletteEntrySkipFirst(color, palette)
                    else
                        quantize_mod.bestPaletteEntry(color, palette);
                    result[tile_idx].data[local_i] = color_idx;

                    // Propagate Sierra dither error
                    const quantized_color = palette.colors[color_idx];
                    applySierraDither(
                        dither_error,
                        color,
                        quantized_color,
                        global_x,
                        global_y,
                        img_width,
                        img_height,
                        cfg.dither_factor,
                    );
                }
            }
        }
    }

    return result;
}
