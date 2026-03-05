pub const color = @import("color.zig");
pub const kmeans = @import("kmeans");
pub const tile = @import("tile.zig");
pub const palette = @import("palette.zig");
pub const tileset = @import("tileset.zig");
pub const dither = @import("dither.zig");
pub const quantize = @import("quantize.zig");
pub const tilemap = @import("tilemap.zig");
pub const input = @import("input.zig");
pub const config = @import("config.zig");
pub const pipeline = @import("pipeline.zig");
pub const output = struct {
    pub const writer = @import("output/writer.zig");
    pub const hex = @import("output/hex.zig");
    pub const binary = @import("output/binary.zig");
    pub const c_array = @import("output/c_array.zig");
    pub const image = @import("output/image.zig");
    pub const json = @import("output/json.zig");
};

test {
    _ = color;
    _ = kmeans;
    _ = tile;
    _ = palette;
    _ = tileset;
    _ = dither;
    _ = quantize;
    _ = tilemap;
    _ = input;
    _ = config;
    _ = pipeline;
    _ = output.writer;
    _ = output.hex;
    _ = output.binary;
    _ = output.c_array;
    _ = output.image;
    _ = output.json;
}
