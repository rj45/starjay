const std = @import("std");

// I am not really sure why using the root namespace here doesn't work. The workaround
// was to export a variable assigned to @This(), and that worked. Maybe a Zig bug?
const term = @import("term.zig").term;
const ay3 = @import("ay38910.zig").ay38910;
const pt3 = @import("pt3.zig").pt3;

const song_data = @embedFile("we'll_be_alright.pt3");

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
const CLINT_BASE: u32 = 0x1100_0000;
const SYSCON_REG_ADDR:usize = 0x11100000;
const SPRITE_TABLE_ADDR:usize = 0x20000000;
const PALETTE_BASE: usize = 0x20003000;
const VRAM_BASE: usize = 0x20004000;
pub const PSG1_BASE: u32 = 0x1300_0000;
pub const PSG1_SIZE: u32 = 0x0000_0010;
pub const PSG2_BASE: u32 = PSG1_BASE + PSG1_SIZE;
pub const PSG2_SIZE: u32 = PSG1_SIZE;

// NOTE: volatile here is important as MMIO devices can have side-effects and the compiler
// needs to know this in order not to optimize them away.
const uart_buf_reg: * volatile u32 = @ptrFromInt(UART_BUF_REG_ADDR);
const clint_mtime_lo: * volatile u32 = @ptrFromInt(CLINT_BASE+0xBFF8);
const clint_mtime_hi: * volatile u32 = @ptrFromInt(CLINT_BASE+0xBFFC);
const syscon: * volatile u32 = @ptrFromInt(SYSCON_REG_ADDR);
const sprite_table: * volatile SpriteTable = @ptrFromInt(SPRITE_TABLE_ADDR);
const palette: * volatile [512]u32 = @ptrFromInt(PALETTE_BASE);
const vram: * volatile [16384]u8 = @ptrFromInt(VRAM_BASE);
const psg1: * volatile [4]u32 = @ptrFromInt(PSG1_BASE);
const psg2: * volatile [4]u32 = @ptrFromInt(PSG2_BASE);

// volatile spin counter to prevent optimization out of spin wait loops
var spin_counter: u32 = 0;
const vol_spin_counter: *volatile u32 = &spin_counter;

const palette_data = @embedFile("palette.bin");
const tilemap_data = @embedFile("tilemap.bin");
const tile_bitmap_data = @embedFile("tiles.bin");

var player: pt3.Pt3Player = undefined;

fn readClintMtime() u64 {
    // Read the 64-bit mtime value atomically
    while (true) {
        const hi1 = clint_mtime_hi.*;
        const lo = clint_mtime_lo.*;
        const hi2 = clint_mtime_hi.*;
        if (hi1 == hi2) {
            return (@as(u64, hi1) << 32) | @as(u64, lo);
        }
    }
}

export fn kmain() noreturn {
    const console = term.getWriter();
    const tile_bitmap_addr = if ((tilemap_data.len & 0x1ff) == 0) tilemap_data.len >> 9 else (tilemap_data.len >> 9) + 1;

    for (0..512) |i| {
        const i_mod_32: u11 = @truncate(i % 32);
        const i_div_32: u11 = @truncate(i / 32);

        sprite_table.sprite[i].sprite_velocity = SpriteVelocity{
            .x_velocity = .{
                .value = 0,
            },
            .y_velocity = .{
                .value = 0,
            },
        };

        sprite_table.sprite[i].sprite_addr = .{
            .tile_bitmap_addr = @truncate(tile_bitmap_addr),
            .tilemap_addr = 0,
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

    const tile_bitmap_addr_start = tile_bitmap_addr << 10;

    @memcpy(vram[0..tilemap_data.len], tilemap_data);
    @memcpy(vram[tile_bitmap_addr_start..tile_bitmap_addr_start+tile_bitmap_data.len], tile_bitmap_data);

    player.init(song_data) catch |err| {
        console.print("Failed to init PT3 player: {}\r\n", .{err}) catch {};
        console.flush() catch {};
        while (true) {}
    };

    console.print("Hellorld from StarJay land!!!\r\n", .{}) catch {};
    console.print("You are listening to: {s}\r\n", .{player.header.songinfo}) catch {};
    console.print("  Dual AY3 (TurboSound)? {}\r\n", .{player.is_turbosound}) catch {};
    console.flush() catch {};

    const initial_time = readClintMtime();
    const tick_duration = 2500; // 64 MHz clock is divided by 512 for the clint, so 50 Hz is (64M/512) / 50 = 2500
    var next_tick = initial_time + tick_duration;

    var initial_delay: i32 = 14*50+25; // 14 sec

    console.print("Clint time: {}, next tick: {}\r\n", .{initial_time, next_tick}) catch {};
    console.flush() catch {};

    while (true) {
        const current_time = readClintMtime();

        // console.print("Clint time: {}, next tick: {}\r\n", .{current_time, next_tick}) catch {};
        // console.flush() catch {};

        if (current_time >= next_tick) {
            next_tick += tick_duration;

            const regs = player.playFrame();
            // console.print("PT3 Frame: Tone A: {}, Tone B: {}, Tone C: {}\r\n", .{regs.psg1.tone_a, regs.psg1.tone_b, regs.psg1.tone_c}) catch {};
            // console.flush() catch {};
            regs.psg1.write(psg1);
            // regs.psg2.write(psg2);

            const time_after = readClintMtime();
            if (time_after > next_tick) {
                console.print("Warning: PT3 frame took too long! time_after: {}, next_tick: {}\r\n", .{time_after, next_tick}) catch {};
                console.flush() catch {};
            }

            if (initial_delay >= 0) {
                initial_delay -= 1;
            }
            if (initial_delay == 0) {
                for (0..512) |i| {
                    // my lame attempt at pseudo-randomness (doesn't work, but the pattern is pretty)
                    const i_32: u32 = @truncate(i);
                    const x_vel_32: u32 = (((((i_32 + ((i_32 / 32)*13) +% 0x811c9dc5) & 0xffffffff) *% 0x01000193) & 0xffffffff) % 32);
                    const x_vel_u16: u15 = @truncate(x_vel_32);
                    const x_vel_i16: i16 = @as(i16, x_vel_u16) - 16;

                    const y_vel_32: u32 = (((((i_32 + ((i_32 / 32)*13) + 512 +% 0x811c9dc5) & 0xffffffff) *% 0x01000193) & 0xffffffff) % 32);
                    const y_vel_u16: u15 = @truncate(y_vel_32);
                    const y_vel_i16: i16 = @as(i16, y_vel_u16) - 16;

                    sprite_table.sprite[i].sprite_velocity = SpriteVelocity{
                        .x_velocity = .{
                            .value = x_vel_i16,
                        },
                        .y_velocity = .{
                            .value = y_vel_i16,
                        },
                    };
                }
            }
        }

        // spin wait for a bit -- this avoids hitting the clint every cycle
        // MMIO in the emulator is slow and thus utilizes more CPU / power
        // even better would be to use an interrupt and WFI instruction
        if ((next_tick - current_time) > 250) {
            for (0..10000) |i| {
                vol_spin_counter.* +%= i; // volatile to prevent it from being optimized out
            }
        }
    }

    // You can send a power down like so if you wish to exit the emulator:
    // syscon.* = 0x5555;

    // spin wait forever
    while (true) {}
}
