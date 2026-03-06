const std = @import("std");
const zigimg = @import("zigimg");
const pipeline_mod = @import("../pipeline.zig");
const PipelineResult = pipeline_mod.PipelineResult;
const tilemap_mod = @import("../tilemap.zig");

/// Write a full JSON dump of pipeline results.
///
/// Output format:
/// ```json
/// {
///   "tilemap_width": <u32>,
///   "tilemap_height": <u32>,
///   "palette_count": <u32>,
///   "tile_count": <u32>,
///   "tilemap": [{"tile_index":<u8>,"palette_index":<u8>,"transparent":<bool>,"x_flip":<bool>,"raw":<u16>}, ...],
///   "palettes": [[{"l":<f32>,"a":<f32>,"b":<f32>}, ...], ...],
///   "tileset": [[<u8>, ...], ...]   // pixel indices, one array per unique tile
/// }
/// ```
pub fn writeJsonDump(
    out: std.io.AnyWriter,
    result: *const PipelineResult,
) !void {
    try out.writeAll("{\n");

    // Scalar metadata
    try out.print("  \"tilemap_width\": {},\n", .{result.tilemap_width});
    try out.print("  \"tilemap_height\": {},\n", .{result.tilemap_height});
    try out.print("  \"palette_count\": {},\n", .{result.palettes.len});
    try out.print("  \"tile_count\": {},\n", .{result.unique_tiles.len});

    // Tilemap entries
    try out.writeAll("  \"tilemap\": [\n");
    for (result.tilemap, 0..) |entry, i| {
        const raw = entry.toU16();
        try out.print(
            "    {{\"tile_index\":{},\"palette_index\":{},\"transparent\":{},\"x_flip\":{},\"raw\":{}}}",
            .{ entry.tile_index, entry.palette_index, entry.transparent, entry.x_flip, raw },
        );
        if (i + 1 < result.tilemap.len) try out.writeByte(',');
        try out.writeByte('\n');
    }
    try out.writeAll("  ],\n");

    // Palettes: array of arrays of {l,a,b} objects, padded to colors_per_palette
    try out.writeAll("  \"palettes\": [\n");
    for (result.palettes, 0..) |palette, pi| {
        try out.writeAll("    [");
        const limit = palette.count;
        for (0..limit) |ci| {
            const c = palette.colors[ci];
            try out.print("{{\"l\":{d:.6},\"a\":{d:.6},\"b\":{d:.6}}}", .{ c.l, c.a, c.b });
            if (ci + 1 < limit) try out.writeByte(',');
        }
        try out.writeByte(']');
        if (pi + 1 < result.palettes.len) try out.writeByte(',');
        try out.writeByte('\n');
    }
    try out.writeAll("  ],\n");

    // Tileset: array of arrays of u8 pixel indices, one per unique tile
    try out.writeAll("  \"tileset\": [\n");
    for (result.unique_tiles, 0..) |tile, ti| {
        try out.writeByte('[');
        for (tile.data, 0..) |px, pi| {
            try out.print("{}", .{px});
            if (pi + 1 < tile.data.len) try out.writeByte(',');
        }
        try out.writeByte(']');
        if (ti + 1 < result.unique_tiles.len) try out.writeByte(',');
        try out.writeByte('\n');
    }
    try out.writeAll("  ]\n");

    try out.writeAll("}\n");
}
