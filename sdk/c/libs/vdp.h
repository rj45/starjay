/**
 * Copyright (c) 2026 Ryan "rj45" Sanche, MIT License
 *
 * VDP (Video Display Processor) Single Header Library.
 *
 * Do this:
 *     #define SDK_IMPL_VDP
 * before you include this file in *one* C or C++ file to create the implementation.
 *
 * To implement all libs in this folder:
 *     #define SDK_IMPL_ALL
 */
#ifndef SDK_VDP_H
#define SDK_VDP_H

#include <stdint.h>

#define VDP_SPRITE_TABLE_ADDR 0x20000000
#define VDP_PALETTE_BASE      0x20003000
#define VDP_VRAM_BASE         0x20004000

/* Tilemap entry (16-bit packed) */
typedef struct __attribute__((packed)) {
    uint16_t tile_index    : 8;
    uint16_t unused        : 1;
    uint16_t transparent   : 1;
    uint16_t palette_index : 5;
    uint16_t x_flip        : 1;
} vdp_tilemap_entry_t;

/* 12.4 signed fixed point (16-bit) */
typedef union __attribute__((packed)) {
    int16_t value;
    struct __attribute__((packed)) {
        uint16_t f : 4;
        int16_t  i : 12;
    } fp;
} vdp_fixed_point_t;

/* Sprite Y + Height (32-bit packed) */
typedef struct __attribute__((packed)) {
    vdp_fixed_point_t screen_y;
    uint8_t tilemap_y;
    uint8_t height;
} vdp_sprite_y_height_t;

/* Sprite X + Width (32-bit packed) */
typedef struct __attribute__((packed)) {
    vdp_fixed_point_t screen_x;
    uint8_t tilemap_x;
    uint8_t width;
} vdp_sprite_x_width_t;

/* Sprite addresses (32-bit packed) */
typedef struct __attribute__((packed)) {
    uint16_t tile_bitmap_addr;
    uint16_t tilemap_addr;
} vdp_sprite_addr_t;

/* Sprite velocity (32-bit packed) */
typedef struct __attribute__((packed)) {
    vdp_fixed_point_t y_velocity;
    vdp_fixed_point_t x_velocity;
} vdp_sprite_velocity_t;

/* Sprite high bits (32-bit packed bitfield) */
typedef struct {
    uint32_t tilemap_size_b : 2;
    uint32_t tilemap_size_a : 2;
    uint32_t x_flip         : 1;
    uint32_t y_flip         : 1;
    uint32_t _unused        : 26;
} vdp_sprite_high_t;

/* Sprite low (4 x 32-bit = 16 bytes) */
typedef struct {
    vdp_sprite_y_height_t  sprite_y_height;
    vdp_sprite_x_width_t   sprite_x_width;
    vdp_sprite_addr_t      sprite_addr;
    vdp_sprite_velocity_t  sprite_velocity;
} vdp_sprite_low_t;

/* Sprite table: 512 low entries + 512 high entries */
typedef struct {
    vdp_sprite_low_t  sprite[512];
    vdp_sprite_high_t sprite_extra[512];
} vdp_sprite_table_t;

/** Sprite table at MMIO address. */
extern volatile vdp_sprite_table_t* vdp_sprite_table;

/** 512-entry palette (ARGB 32-bit). */
extern volatile uint32_t* vdp_palette;

/** VRAM byte access (0x8000 bytes). */
extern volatile uint8_t* vdp_vram;

/** VRAM 16-bit access (0x4000 entries). */
extern volatile uint16_t* vdp_vram_u16;

#ifdef SDK_IMPL_ALL
#define SDK_IMPL_VDP
#endif

#ifdef SDK_IMPL_VDP

_Static_assert(sizeof(vdp_tilemap_entry_t) == 2, "tilemap entry size");
_Static_assert(sizeof(vdp_fixed_point_t) == 2, "fixed point size");
_Static_assert(sizeof(vdp_sprite_y_height_t) == 4, "sprite y_height size");
_Static_assert(sizeof(vdp_sprite_x_width_t) == 4, "sprite x_width size");
_Static_assert(sizeof(vdp_sprite_addr_t) == 4, "sprite addr size");
_Static_assert(sizeof(vdp_sprite_velocity_t) == 4, "sprite velocity size");
_Static_assert(sizeof(vdp_sprite_high_t) == 4, "sprite high size");
_Static_assert(sizeof(vdp_sprite_low_t) == 16, "sprite low size");

volatile vdp_sprite_table_t* vdp_sprite_table = (volatile vdp_sprite_table_t*)VDP_SPRITE_TABLE_ADDR;
volatile uint32_t*  vdp_palette  = (volatile uint32_t*)VDP_PALETTE_BASE;
volatile uint8_t*   vdp_vram     = (volatile uint8_t*)VDP_VRAM_BASE;
volatile uint16_t*  vdp_vram_u16 = (volatile uint16_t*)VDP_VRAM_BASE;

#endif

#endif
