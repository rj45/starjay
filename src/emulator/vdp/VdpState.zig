// (C) 2026 Ryan "rj45" Sanche, MIT License
//
// VdpState for emulating the Video Display Processor hardware

const std = @import("std");

const types = @import("types.zig");
const TilemapEntry = types.TilemapEntry;

pub const Cycle = u64;

const CYCLES_PER_SCANLINE: Cycle = 1440; // 1280 plus h-blank
const SCANLINES_PER_SCREEN: u16 = 741;

const palette_data = loadHex(u32, "palette.hex");
const tile_map_data = loadHex(u16, "tilemap.hex");
const tile_set_data = loadHex(u16, "tiles.hex");
const sprite_data = loadHex(u108, "sprites.hex");

pub const VdpState = @This();



pub const FrameBuffer = struct {
    width: u32,
    height: u32,
    pitch: u32,
    pixels: [*]u32,
};

cycle: Cycle,

sy: u16,

frame_buffer: FrameBuffer,

line_buffer: [256]u128,

pub fn init(self: *VdpState, allocator: std.mem.Allocator, frame_buffer: FrameBuffer) void {
    _ = allocator;
    self.* = VdpState{
        .cycle = 0,
        .sy = 0,
        .frame_buffer = frame_buffer,
        .line_buffer = .{0} ** 256,
    };
}

pub fn emulate_line(self: *VdpState) void {
    if (self.sy < self.frame_buffer.height) {
        const screen_offset: usize = self.frame_buffer.pitch * @as(usize, self.sy);
        const tile_y = (self.sy >> 1) & 7; // each row drawn twice (vertical doubling)
        const tilemap_y = (self.sy >> 4) & 31; // 16 scanlines per tilemap row (8 tile rows × 2)

        const tile_set_offset = tile_y << 9; // tiles stored in row-major, two words each tile

        var linebuffer_x: usize = 0;

        for (0..32) |tm_x| {
            const tilemap_index = @as(usize, tilemap_y) * 32 + tm_x;
            const tilemap_entry: TilemapEntry = @bitCast(tile_map_data[tilemap_index]);
            const tile_address = tile_set_offset + (@as(usize, tilemap_entry.tile_index) << 1);

            for (0..2) |i| {
                const tile_pixels = tile_set_data[tile_address+i];
                const combined_pixels = splitPixelsCombinePalette(tilemap_entry.palette_index, tile_pixels);
                self.line_buffer[linebuffer_x] = combined_pixels;
                linebuffer_x += 1;
            }
        }

        for (0..self.frame_buffer.width >> 3) |x| {
            const pixel_data: @Vector(8, u16) = @bitCast(self.line_buffer[x]);

            // Gather RGB values from palette (indexed lookups are inherently scalar)
            var rgb_values: @Vector(8, u32) = undefined;
            inline for (0..8) |i| {
                rgb_values[i] = palette_data[pixel_data[i]];
            }

            // SIMD: Add alpha channel to all 8 pixels at once
            const alpha_mask: @Vector(8, u32) = @splat(0xFF000000);
            const argb_values = rgb_values | alpha_mask;

            // Store all 8 pixels at once
            const dest_ptr: *[8]u32 = @ptrCast(self.frame_buffer.pixels + screen_offset + (x << 3));
            dest_ptr.* = argb_values;
        }
    }

    self.sy += 1;
    self.cycle += CYCLES_PER_SCANLINE;
}

pub fn emulate_frame(self: *VdpState) void {
    self.sy = 0;
    for (0..SCANLINES_PER_SCREEN) |_| {
        self.emulate_line();
    }
}

fn HexArray(comptime T: type, comptime path: []const u8) type {
    @setEvalBranchQuota(1_000_000);
    const data = @embedFile(path);
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, data, " \t\n\r");
    while (iter.next()) |_| count += 1;
    return [count]T;
}

fn loadHex(comptime T: type, comptime path: []const u8) HexArray(T, path) {
    @setEvalBranchQuota(1_000_000);
    const data = @embedFile(path);
    var result: HexArray(T, path) = undefined;
    var iter = std.mem.tokenizeAny(u8, data, " \t\n\r");
    var i: usize = 0;
    while (iter.next()) |token| : (i += 1) {
        result[i] = std.fmt.parseInt(T, token, 16) catch @compileError("invalid hex");
    }
    return result;
}



/// Splits a 16 bit tile bitmap data (4 pixels of 4bits each) into 8 u16 pixels,
/// combining each with the given 5-bit palette index shifted left by 4 bits.
fn splitPixelsCombinePalette(palette: u5, pixels: u16) u128 {
    const paletteSplat: @Vector(8, u16) = @splat(palette);
    const paletteShifted = paletteSplat << @splat(4);

    const pixelSplat: @Vector(8, u16) = @splat(pixels);
    const shifts = @Vector(8, u4){ 0, 0, 4, 4, 8, 8, 12, 12 };
    const mask: @Vector(8, u16) = @splat(0x000F);
    const pixelMasked = (pixelSplat >> shifts) & mask;

    const combined: @Vector(8, u16) = paletteShifted | pixelMasked;

    return @bitCast(combined);
}

test "zero inputs produce zero output" {
    try std.testing.expectEqual(@as(u128, 0), splitPixelsCombinePalette(0, 0));
}

test "palette-only: pixels=0 isolates palette contribution" {
    // palette=31 (0b11111), shifted left 4 → 0x1F0 per element
    // 8 elements of 0x1F0 as u128
    const expected: @Vector(8, u16) = @splat(0x1F0);
    try std.testing.expectEqual(@as(u128, @bitCast(expected)), splitPixelsCombinePalette(31, 0));
}

test "pixels-only: palette=0 isolates pixel extraction" {
    // pixels=0xFFFF → each nibble is 0xF, duplicated
    const expected: @Vector(8, u16) = @splat(0x000F);
    try std.testing.expectEqual(@as(u128, @bitCast(expected)), splitPixelsCombinePalette(0, 0xFFFF));
}

test "distinct nibbles verify correct extraction order" {
    // pixels=0x1234 → nibbles are: 4, 3, 2, 1 (LSB to MSB)
    // After shifts {0,0,4,4,8,8,12,12}: extracts nibble 0,0,1,1,2,2,3,3
    // So: 4, 4, 3, 3, 2, 2, 1, 1
    const result: @Vector(8, u16) = @bitCast(splitPixelsCombinePalette(0, 0x1234));
    try std.testing.expectEqual(@as(u16, 4), result[0]);
    try std.testing.expectEqual(@as(u16, 4), result[1]);
    try std.testing.expectEqual(@as(u16, 3), result[2]);
    try std.testing.expectEqual(@as(u16, 3), result[3]);
    try std.testing.expectEqual(@as(u16, 2), result[4]);
    try std.testing.expectEqual(@as(u16, 2), result[5]);
    try std.testing.expectEqual(@as(u16, 1), result[6]);
    try std.testing.expectEqual(@as(u16, 1), result[7]);
}

test "single nibble isolation catches shift errors" {
    // Only set nibble 2 (bits 8-11) → 0x0F00
    // Should appear only at positions 4,5
    const result: @Vector(8, u16) = @bitCast(splitPixelsCombinePalette(0, 0x0F00));
    try std.testing.expectEqual(@as(u16, 0), result[0]);
    try std.testing.expectEqual(@as(u16, 0), result[1]);
    try std.testing.expectEqual(@as(u16, 0), result[2]);
    try std.testing.expectEqual(@as(u16, 0), result[3]);
    try std.testing.expectEqual(@as(u16, 0xF), result[4]);
    try std.testing.expectEqual(@as(u16, 0xF), result[5]);
    try std.testing.expectEqual(@as(u16, 0), result[6]);
    try std.testing.expectEqual(@as(u16, 0), result[7]);
}

test "palette and pixel bits don't overlap" {
    // palette=31 (max), pixels=0xFFFF (max)
    // Each element should be 0x1FF = (31 << 4) | 0xF
    const expected: @Vector(8, u16) = @splat(0x1FF);
    try std.testing.expectEqual(@as(u128, @bitCast(expected)), splitPixelsCombinePalette(31, 0xFFFF));
}

test "palette single bit verifies shift amount" {
    // palette=1, pixels=0 → each element should be 0x010
    const expected: @Vector(8, u16) = @splat(0x010);
    try std.testing.expectEqual(@as(u128, @bitCast(expected)), splitPixelsCombinePalette(1, 0));
}

test "adjacent pairs are identical (duplication correctness)" {
    // Use pixels where all nibbles differ: 0xABCD
    const result: @Vector(8, u16) = @bitCast(splitPixelsCombinePalette(0, 0xABCD));
    try std.testing.expectEqual(result[0], result[1]); // nibble 0 duplicated
    try std.testing.expectEqual(result[2], result[3]); // nibble 1 duplicated
    try std.testing.expectEqual(result[4], result[5]); // nibble 2 duplicated
    try std.testing.expectEqual(result[6], result[7]); // nibble 3 duplicated
    // Also verify they're different from each other
    try std.testing.expect(result[0] != result[2]);
    try std.testing.expect(result[2] != result[4]);
    try std.testing.expect(result[4] != result[6]);
}
