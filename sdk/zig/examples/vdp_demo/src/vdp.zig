const std = @import("std");

pub const vdp = @This();

pub const SPRITE_TABLE_ADDR:usize = 0x20000000;
pub const PALETTE_BASE: usize = 0x20003000;
pub const VRAM_BASE: usize = 0x20004000;

pub const sprite_table: * volatile SpriteTable = @ptrFromInt(SPRITE_TABLE_ADDR);
pub const palette: * volatile [512]u32 = @ptrFromInt(PALETTE_BASE);
pub const vram: * volatile [0x8000]u8 = @ptrFromInt(VRAM_BASE);
pub const vram_u16: * volatile [0x4000]u16 = @ptrFromInt(VRAM_BASE);

pub const TilemapEntry = packed struct(u16) {
    tile_index: u8,
    unused: u1,
    transparent: bool,
    palette_index: u5,
    x_flip: bool,
};

pub const FixedPoint = packed union {
    value: i16,
    fp: Parts,

    const Parts = packed struct(i16) {
        f: u4 = 0,
        i: i12 = 0,
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
    y_velocity: FixedPoint = .{.value = 0},
    x_velocity: FixedPoint = .{.value = 0},
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
