// (C) 2026 Ryan "rj45" Sanche, MIT License
//
// VdpState for emulating the Video Display Processor hardware

const std = @import("std");

const Bus = @import("../device/Bus.zig");

const types = @import("types.zig");
const TilemapEntry = types.TilemapEntry;
const SpriteYHeight = types.SpriteYHeight;
const SpriteXWidth = types.SpriteXWidth;
const SpriteAddr = types.SpriteAddr;
const SpriteVelocity = types.SpriteVelocity;
const ActiveTilemapAddr = types.ActiveTilemapAddr;
const ActiveBitmapAddr = types.ActiveBitmapAddr;
const Addr = Bus.Addr;
const Queue = Bus.Queue;

pub const Cycle = u64;

const CYCLES_PER_SCANLINE: Cycle = 1440; // 1280 plus h-blank
const SCANLINES_PER_SCREEN: u16 = 741;
pub const VRAM_SIZE: Addr = 0x4000;
pub const PALETTE_SIZE: Addr = 512*4;

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

palette: [512]u32,

sprite_y_height: [512]SpriteYHeight,
sprite_x_width: [512]SpriteXWidth,
sprite_addr: [512]SpriteAddr,
sprite_velocity: [512]SpriteVelocity,

active_tilemap_addr: [512]ActiveTilemapAddr,
active_bitmap_addr: [512]ActiveBitmapAddr,
active_count: u16,
initial_delay: u16,

// VRAM storage (tilemap and tile bitmap data)
vram: [VRAM_SIZE]u8 align(4),

pub fn init(self: *VdpState, allocator: std.mem.Allocator, frame_buffer: FrameBuffer) void {
    _ = allocator;
    self.* = VdpState{
        .cycle = 0,
        .sy = 0,
        .frame_buffer = frame_buffer,
        .line_buffer = .{0} ** 256,
        .sprite_addr = undefined,
        .sprite_velocity = undefined,
        .sprite_x_width = undefined,
        .sprite_y_height = undefined,
        .active_bitmap_addr = undefined,
        .active_tilemap_addr = undefined,
        .active_count = 0,
        .initial_delay = 3*60,
        .palette = .{0} ** 512,
        .vram = .{0} ** VRAM_SIZE,
    };
}

pub fn emulate_line(self: *VdpState, skip: bool) void {
    if (self.sy < self.frame_buffer.height and !skip) {
        // The following 3 phases occur simultaneously in hardware per scanline.
        // Since we are emulating on a sequential machine, we do them sequentially here.

        // Phase 1: Scan sprites looking for ones on the current line
        const sy: i32 = @intCast(self.sy);
        self.active_count = 0;
        for (0..512) |i| {
            const sprite_yh: SpriteYHeight = self.sprite_y_height[i];

            const sprite_top: i32 = @intCast(sprite_yh.screen_y.fp.i);
            const sprite_tile_height: i32 = @intCast(sprite_yh.height);
            const sprite_height: i32 = sprite_tile_height << 4; // height in tiles × 16 pixels
            const sprite_bottom = sprite_top + sprite_height;

            if (sy >= sprite_top and sy < sprite_bottom) {
                const sprite_xw: SpriteXWidth = self.sprite_x_width[i];
                const sprite_addr: SpriteAddr = self.sprite_addr[i];

                const sprite_line_y = sy - sprite_top;

                const sprite_offset_y:u32 = @bitCast(if (sprite_xw.y_flip)
                    (sprite_height - 1 - sprite_line_y)
                else sprite_line_y);

                std.debug.assert(sprite_yh.tilemap_size_a == 0);
                std.debug.assert(sprite_yh.tilemap_size_b == 0);

                const sprite_tilemap_y = (sprite_offset_y >> 4) + @as(u32, sprite_yh.tilemap_y);
                const tilemap_offset_y = (sprite_tilemap_y << (@as(u5, sprite_yh.tilemap_size_a)+4)) +
                    (sprite_tilemap_y << (@as(u5, sprite_yh.tilemap_size_b)+4));
                const tile_row:u18 = @truncate((sprite_offset_y >> 1) & 7);

                const trunc_tilemap_offset_y: u32 = @bitCast(tilemap_offset_y);
                const tilemap_addr: u32 = (@as(u32, sprite_addr.tilemap_addr) << 9) + trunc_tilemap_offset_y + @as(u32, sprite_xw.tilemap_x);
                self.active_tilemap_addr[self.active_count] = ActiveTilemapAddr{
                    .tilemap_addr = @truncate(tilemap_addr),
                    .tile_count = sprite_xw.width,
                    .x_flip = sprite_xw.x_flip,
                };

                self.active_bitmap_addr[self.active_count] = ActiveBitmapAddr{
                    .tile_bitmap_addr = @as(u18, sprite_addr.tile_bitmap_addr) + @as(u18, tile_row),
                    .lb_addr = @bitCast(sprite_xw.screen_x.fp.i),
                    .unused = 0,
                };

                self.active_count += 1;
            }
        }

        // Phase 2: Render sprite tiles to line buffer
        const screen_offset: usize = self.frame_buffer.pitch * @as(usize, self.sy);

        const vram_u16: []u16 = std.mem.bytesAsSlice(u16, self.vram[0..]);

        for (0..self.active_count) |sprite_index| {
            const tilemap_addr: ActiveTilemapAddr = self.active_tilemap_addr[sprite_index];
            const bitmap_addr: ActiveBitmapAddr = self.active_bitmap_addr[sprite_index];

            var lb_x = @as(usize, bitmap_addr.lb_addr);

            for (0..tilemap_addr.tile_count) |tile_index| {
                const tilemap_index = @as(usize, tilemap_addr.tilemap_addr) + @as(usize, tile_index);
                const tilemap_entry: TilemapEntry = @bitCast(vram_u16[tilemap_index]);
                const tile_address = (@as(usize, bitmap_addr.tile_bitmap_addr) << 9) +
                    (@as(usize, tilemap_entry.tile_index) << 1);

                for (0..2) |i| {
                    const tile_pixels = vram_u16[tile_address+i];
                    const combined_pixels = splitPixelsCombinePalette(tilemap_entry.palette_index, tile_pixels);

                    const linebuffer_u16: [*]u16 = @alignCast(@ptrCast(&self.line_buffer[0]));

                    inline for (0..8) |j| {
                        linebuffer_u16[(lb_x+j) & 2047] = combined_pixels[j];
                    }
                    lb_x += 8;
                }
            }
        }

        // Phase 3: Write line buffer to screen
        for (0..self.frame_buffer.width >> 3) |x| {
            const pixel_data: @Vector(8, u16) = @bitCast(self.line_buffer[x]);
            self.line_buffer[x] = 0; // Clear line buffer for next use

            // Gather RGB values from palette (indexed lookups are inherently scalar)
            var rgb_values: @Vector(8, u32) = undefined;
            inline for (0..8) |i| {
                rgb_values[i] = self.palette[pixel_data[i]];
            }

            // SIMD: Add alpha channel to all 8 pixels at once
            const alpha_mask: @Vector(8, u32) = @splat(0xFF000000);
            const argb_values = rgb_values | alpha_mask;

            // Store all 8 pixels at once
            const dest_ptr: *[8]u32 = @ptrCast(self.frame_buffer.pixels + screen_offset + (x << 3));
            dest_ptr.* = argb_values;
        }
    } else if (self.sy == self.frame_buffer.height) {
        if (self.initial_delay > 0) {
            self.initial_delay -= 1;
        } else {
            // Update sprite positions at the end of the visible frame
            for (0..512) |i| {
                const sprite_vel = self.sprite_velocity[i];
                self.sprite_x_width[i].screen_x.value +%= sprite_vel.x_velocity.value;
                self.sprite_y_height[i].screen_y.value +%= sprite_vel.y_velocity.value;
            }
        }
    }

    self.sy += 1;
    self.cycle += CYCLES_PER_SCANLINE;
}

pub fn emulate_frame(self: *VdpState, skip: bool) void {
    self.sy = 0;
    for (0..SCANLINES_PER_SCREEN) |_| {
        self.emulate_line(skip);
    }
}

/// Splits a 16 bit tile bitmap data (4 pixels of 4bits each) into 8 u16 pixels,
/// combining each with the given 5-bit palette index shifted left by 4 bits.
fn splitPixelsCombinePalette(palette: u5, pixels: u16) @Vector(8, u16) {
    const paletteSplat: @Vector(8, u16) = @splat(palette);
    const paletteShifted = paletteSplat << @splat(4);

    const pixelSplat: @Vector(8, u16) = @splat(pixels);
    const shifts = @Vector(8, u4){ 0, 0, 4, 4, 8, 8, 12, 12 };
    const mask: @Vector(8, u16) = @splat(0x000F);
    const pixelMasked = (pixelSplat >> shifts) & mask;

    return paletteShifted | pixelMasked;
}

test "zero inputs produce zero output" {
    const expected: @Vector(8, u16) = @splat(0);
    try std.testing.expectEqual(expected, splitPixelsCombinePalette(0, 0));
}

test "palette-only: pixels=0 isolates palette contribution" {
    // palette=31 (0b11111), shifted left 4 → 0x1F0 per element
    // 8 elements of 0x1F0 as u128
    const expected: @Vector(8, u16) = @splat(0x1F0);
    try std.testing.expectEqual(expected, splitPixelsCombinePalette(31, 0));
}

test "pixels-only: palette=0 isolates pixel extraction" {
    // pixels=0xFFFF → each nibble is 0xF, duplicated
    const expected: @Vector(8, u16) = @splat(0x000F);
    try std.testing.expectEqual(expected, splitPixelsCombinePalette(0, 0xFFFF));
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
    try std.testing.expectEqual(expected, splitPixelsCombinePalette(31, 0xFFFF));
}

test "palette single bit verifies shift amount" {
    // palette=1, pixels=0 → each element should be 0x010
    const expected: @Vector(8, u16) = @splat(0x010);
    try std.testing.expectEqual(expected, splitPixelsCombinePalette(1, 0));
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
