const std = @import("std");

// I am not really sure why using the root namespace here doesn't work. The workaround
// was to export a variable assigned to @This(), and that worked. Maybe a Zig bug?
const term = @import("term.zig").term;

pub const TilemapEntry = packed struct(u16) {
    tile_index: u8,
    unused: u2,
    palette_index: u5,
    x_flip: bool,
};

pub const FixedPoint = packed union {
    value: i16,
    fp: Parts,

    const Parts = packed struct(u16) {
        f: u4,
        i: i12,
    };
};

pub const SpriteYHeight = packed struct(u32) {
    screen_y: FixedPoint,
    tilemap_y: u8,
    height: u8,
};

pub const SpriteXWidth = packed struct(u32) {
    screen_x: FixedPoint,
    tilemap_x: u8,
    width: u8,
};

pub const SpriteAddr = packed struct(u32) {
    tile_bitmap_addr: u16,
    tilemap_addr: u16,
};

pub const SpriteVelocity = packed struct(u32) {
    y_velocity: FixedPoint,
    x_velocity: FixedPoint,
};

pub const SpriteHigh = packed struct(u32) {
    tilemap_size_b: u2,
    tilemap_size_a: u2,
    x_flip: bool,
    y_flip: bool,
    unused1: u2,
    unused2: u4,
    unused3: u4,
    unused4: u16,
};

pub const SpriteLow = struct {
    sprite_y_height: SpriteYHeight,
    sprite_x_width: SpriteXWidth,
    sprite_addr: SpriteAddr,
    sprite_velocity: SpriteVelocity,
};

pub const SpriteTable = struct {
    sprite: [512]SpriteLow,
    sprite_extra: [512]SpriteHigh,
};

const UART_BUF_REG_ADDR:usize = 0x10000000;
const SYSCON_REG_ADDR:usize = 0x11100000;
const SPRITE_TABLE_ADDR:usize = 0x20000000;
const PALETTE_BASE: usize = 0x20003000;
const VRAM_BASE: usize = 0x20004000;

const uart_buf_reg = @volatileCast(@as(*u32, @ptrFromInt(UART_BUF_REG_ADDR)));
const syscon = @volatileCast(@as(*u32, @ptrFromInt(SYSCON_REG_ADDR)));
const sprite_table = @volatileCast(@as(*SpriteTable, @ptrFromInt(SPRITE_TABLE_ADDR)));
const palette = @volatileCast(@as(*[512]u32, @ptrFromInt(PALETTE_BASE)));
const vram = @volatileCast(@as(*[16384]u8, @ptrFromInt(VRAM_BASE)));

const palette_data = @embedFile("palette.bin");
const tilemap_data = @embedFile("tilemap.bin");
const tile_bitmap_data = @embedFile("tiles.bin");

export fn kmain() noreturn {
    const console = term.getWriter();
    const tile_bitmap_addr = if ((tilemap_data.len % 512) == 0) tilemap_data.len / 512 else (tilemap_data.len / 512) + 1;

    for (0..512) |i| {
        // my lame attempt at pseudo-randomness (doesn't work, but the pattern is pretty)
        const i_32: u32 = @truncate(i);
        const x_vel_32: u32 = (((((i_32 + ((i_32 / 32)*13) +% 0x811c9dc5) & 0xffffffff) *% 0x01000193) & 0xffffffff) % 32);
        const x_vel_u16: u15 = @truncate(x_vel_32);
        const x_vel_i16: i16 = @as(i16, x_vel_u16) - 16;

        const y_vel_32: u32 = (((((i_32 + ((i_32 / 32)*13) + 512 +% 0x811c9dc5) & 0xffffffff) *% 0x01000193) & 0xffffffff) % 32);
        const y_vel_u16: u15 = @truncate(y_vel_32);
        const y_vel_i16: i16 = @as(i16, y_vel_u16) - 16;

        const i_mod_32: u11 = @truncate(i % 32);
        const i_div_32: u11 = @truncate(i / 32);

        sprite_table.sprite[i].sprite_addr = .{
            .tile_bitmap_addr = @truncate(tile_bitmap_addr),
            .tilemap_addr = 0,
        };

        sprite_table.sprite[i].sprite_velocity = SpriteVelocity{
            .x_velocity = .{
                .value = x_vel_i16,
            },
            .y_velocity = .{
                .value = y_vel_i16,
            },
        };

        sprite_table.sprite[i].sprite_x_width = SpriteXWidth{
            .screen_x = .{ .fp = .{.i = @as(i12, (i_mod_32*17)+384), .f = 0} },
            .tilemap_x = @truncate(i_mod_32),
            .width = 1,
        };

        sprite_table.sprite[i].sprite_y_height = SpriteYHeight{
            .screen_y = .{ .fp = .{.i = @as(i12, (i_div_32 * 33)+104), .f = 0} },
            .tilemap_y = @truncate(i_div_32*2),
            .height = 2,
        };
        sprite_table.sprite_extra[i] = SpriteHigh{
            // width/stride of tilemap given by formula ((1 << (tilemap_size_a+4)) + (1 << (tilemap_size_b+4)))
            // This allows sizes of 32 to 256 tiles in width, but also odd sizes like 80 for text buffers
            // Height is not specified -- it's just the height of the sprite plus its Y position, so up to 512 tiles
            .tilemap_size_b = 0,
            .tilemap_size_a = 0,
            .x_flip = false,
            .y_flip = false,
            .unused1 = 0,
            .unused2 = 0,
            .unused3 = 0,
            .unused4 = 0,
        };
    }

    const palette_data_u32 = std.mem.bytesAsSlice(u32, palette_data);
    for (0..512) |i| {
        palette[i] = palette_data_u32[i];
    }

    const tile_bitmap_addr_start = tile_bitmap_addr * 1024;

    @memcpy(vram[0..tilemap_data.len], tilemap_data);
    @memcpy(vram[tile_bitmap_addr_start..tile_bitmap_addr_start+tile_bitmap_data.len], tile_bitmap_data);

    console.print("Hellorld from StarJay land!!!\r\n", .{}) catch {};
    console.flush() catch {};

    // You can send a power down like so if you wish to exit the emulator:
    // syscon.* = 0x5555;

    while (true) {

    }
}
