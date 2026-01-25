// (C) 2026 Ryan "rj45" Sanche, MIT License
//
// Data types for sprite handling

const std = @import("std");

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

pub const SpriteYHeight = packed struct(u36) {
    screen_y: FixedPoint,
    tilemap_y: u8,
    height: u8,
    tilemap_size_b: u2,
    tilemap_size_a: u2,
};

pub const SpriteXWidth = packed struct(u36) {
    screen_x: FixedPoint,
    tilemap_x: u8,
    width: u8,
    x_flip: bool,
    y_flip: bool,
    unused: u2,
};

pub const SpriteAddr = packed struct(u36) {
    tile_bitmap_addr: u16,
    tilemap_addr: u16,
    unused: u4,
};

pub const SpriteVelocity = packed struct(u36) {
    y_velocity: FixedPoint,
    x_velocity: FixedPoint,
    unused: u4,
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
