// (C) 2026 Ryan "rj45" Sanche, MIT License
//
// Data types for sprite handling

const std = @import("std");

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

    const Parts = packed struct(u16) {
        f: u4 = 0,
        i: i12 = 0,
    };
};

pub const SpriteYHeight = packed struct(u36) {
    screen_y: FixedPoint = .{.value = 0},
    tilemap_y: u8 = 0,
    height: u8 = 0,
    tilemap_size_b: u2 = 0,
    tilemap_size_a: u2 = 0,
};

pub const SpriteXWidth = packed struct(u36) {
    screen_x: FixedPoint = .{.value = 0},
    tilemap_x: u8 = 0,
    width: u8 = 0,
    x_flip: bool = false,
    y_flip: bool = false,
    unused: u2 = 0,
};

pub const SpriteAddr = packed struct(u36) {
    tile_bitmap_addr: u16 = 0,
    tilemap_addr: u16 = 0,
    unused: u4 = 0,
};

pub const SpriteVelocity = packed struct(u36) {
    y_velocity: FixedPoint = .{.value = 0},
    x_velocity: FixedPoint = .{.value = 0},
    unused: u4 = 0,
};

pub const ActiveTilemapAddr = packed struct(u36) {
    tilemap_addr: u27,
    tile_count: u8,
    x_flip: bool,
};

pub const ActiveBitmapAddr = packed struct(u36) {
    tile_bitmap_addr: u18,
    lb_addr: u12,
    unused: u6,
};
