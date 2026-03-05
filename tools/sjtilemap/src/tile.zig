const std = @import("std");
const color_mod = @import("color.zig");
const OklabAlpha = color_mod.OklabAlpha;
const Config = @import("config.zig").Config;

/// A single tile's pixels in OKLab color space.
pub const Tile = struct {
    pixels: []OklabAlpha,
    width: u32,
    height: u32,
    /// True if any pixel in this tile has alpha < 0.5
    has_transparent: bool = false,
};

/// Extract tiles from an image's pixel buffer.
/// The image is addressed row-major: pixel[y * image_width + x].
/// Returns a slice of Tiles backed by the arena allocator.
pub fn extractTiles(
    arena: std.mem.Allocator,
    pixels: []const OklabAlpha,
    image_width: u32,
    image_height: u32,
    cfg: Config,
) ![]Tile {
    const tw = cfg.tile_width;
    const th = cfg.tile_height;
    const num_x = image_width / tw;
    const num_y = image_height / th;
    const num_tiles = num_x * num_y;

    const tiles = try arena.alloc(Tile, num_tiles);

    for (0..num_y) |ty| {
        for (0..num_x) |tx| {
            const tile_idx = ty * num_x + tx;
            const tile_pixels = try arena.alloc(OklabAlpha, tw * th);
            for (0..th) |py| {
                for (0..tw) |px| {
                    const src_x = tx * tw + px;
                    const src_y = ty * th + py;
                    const src_idx = src_y * image_width + src_x;
                    tile_pixels[py * tw + px] = pixels[src_idx];
                }
            }
            var has_transparent = false;
            for (tile_pixels) |px| {
                if (px.alpha < 0.5) {
                    has_transparent = true;
                    break;
                }
            }
            tiles[tile_idx] = .{
                .pixels = tile_pixels,
                .width = tw,
                .height = th,
                .has_transparent = has_transparent,
            };
        }
    }

    return tiles;
}
