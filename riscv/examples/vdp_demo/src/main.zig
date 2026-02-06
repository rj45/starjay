const std = @import("std");

// I am not really sure why using the root namespace here doesn't work. The workaround
// was to export a variable assigned to @This(), and that worked. Maybe a Zig bug?
const term = @import("term.zig").term;
const ay3 = @import("ay38910.zig").ay38910;
const pt3 = @import("pt3.zig").pt3;
const vdp = @import("vdp.zig").vdp;
const anim = @import("anim.zig").anim;

const song_data = @embedFile("assets/KUVO-plasticcake.pt3");

const UART_BUF_REG_ADDR:usize = 0x10000000;
const CLINT_BASE: u32 = 0x1100_0000;
const SYSCON_REG_ADDR:usize = 0x11100000;

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

const psg1: * volatile [4]u32 = @ptrFromInt(PSG1_BASE);
const psg2: * volatile [4]u32 = @ptrFromInt(PSG2_BASE);

// volatile spin counter to prevent optimization out of spin wait loops
var spin_counter: u32 = 0;
const vol_spin_counter: *volatile u32 = &spin_counter;

const bird_palette_data = @embedFile("assets/palette.bin");
const bird_tilemap_data = @embedFile("assets/tilemap.bin");
const bird_tile_bitmap_data = @embedFile("assets/tiles.bin");

const cover_palette_data = @embedFile("assets/plasticcake-palette.bin");
const cover_tilemap_data = @embedFile("assets/plasticcake-tilemap.bin");
const cover_tile_bitmap_data = @embedFile("assets/plasticcake-tiles.bin");

const font_tile_bitmap_data = @embedFile("assets/font8x16x4bpp.bin");

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
    // const tile_bitmap_addr = if ((bird_tilemap_data.len & 0x1ff) == 0) bird_tilemap_data.len >> 9 else (bird_tilemap_data.len >> 9) + 1;

    // for (0..512) |i| {
    //     const i_mod_32: u11 = @truncate(i % 32);
    //     const i_div_32: u11 = @truncate(i / 32);

    //     vdp.sprite_table.sprite[i].sprite_velocity = SpriteVelocity{
    //         .x_velocity = .{
    //             .value = 0,
    //         },
    //         .y_velocity = .{
    //             .value = 0,
    //         },
    //     };

    //     vdp.sprite_table.sprite[i].sprite_addr = .{
    //         .tile_bitmap_addr = @truncate(tile_bitmap_addr),
    //         .tilemap_addr = 0,
    //     };



    //     vdp.sprite_table.sprite[i].sprite_x_width = SpriteXWidth{
    //         .screen_x = .{ .fp = .{.i = @as(i12, (i_mod_32*17)+384), .f = 0} },
    //         .tilemap_x = @truncate(i_mod_32),
    //         .width = 1,
    //     };

    //     vdp.sprite_table.sprite[i].sprite_y_height = SpriteYHeight{
    //         .screen_y = .{ .fp = .{.i = @as(i12, (i_div_32 * 33)+104), .f = 0} },
    //         .tilemap_y = @truncate(i_div_32*2),
    //         .height = 2,
    //     };
    //     vdp.sprite_table.sprite_extra[i] = SpriteHigh{
    //         // width/stride of tilemap given by formula ((1 << (tilemap_size_a+4)) + (1 << (tilemap_size_b+4)))
    //         // This allows sizes of 32 to 256 tiles in width, but also odd sizes like 80 for text buffers
    //         // Height is not specified -- it's just the height of the sprite plus its Y position, so up to 512 tiles
    //         .tilemap_size_b = 0,
    //         .tilemap_size_a = 0,
    //         .x_flip = false,
    //         .y_flip = false,
    //         .unused1 = 0,
    //         .unused2 = 0,
    //         .unused3 = 0,
    //         .unused4 = 0,
    //     };
    // }

    // const bird_palette_data_u32 = std.mem.bytesAsSlice(u32, bird_palette_data);
    // for (0..512) |i| {
    //     palette[i] = bird_palette_data_u32[i];
    // }

    // const tile_bitmap_addr_start = tile_bitmap_addr << 10;

    // @memcpy(vdp.vram[0..bird_tilemap_data.len], bird_tilemap_data);
    // @memcpy(vdp.vram[tile_bitmap_addr_start..tile_bitmap_addr_start+bird_tile_bitmap_data.len], bird_tile_bitmap_data);

    const cover_palette_data_u32 = std.mem.bytesAsSlice(u32, cover_palette_data);
    for (0..496) |i| {
        vdp.palette[i] = cover_palette_data_u32[i];
    }

    vdp.palette[496] = 0x00000000; // transparent color for text
    var value: u32 = 0;
    for (496..512) |i| {
        vdp.palette[i] = value;
        value += 0x00121212;
    }
    vdp.palette[511] = 0x00FFFFFF;

    const font_tile_bitmap_addr = vdp.vram.len - font_tile_bitmap_data.len;
    const text_buffer_top = (font_tile_bitmap_addr - 2048) >> 1;
    const text_buffer_bot = (font_tile_bitmap_addr - 1024) >> 1;
    @memcpy(vdp.vram[font_tile_bitmap_addr..font_tile_bitmap_addr+font_tile_bitmap_data.len], font_tile_bitmap_data);

    const cover_tilemap_addr = cover_tile_bitmap_data.len;
    @memcpy(vdp.vram[0..cover_tile_bitmap_data.len], cover_tile_bitmap_data);
    @memcpy(vdp.vram[cover_tilemap_addr..cover_tilemap_addr+cover_tilemap_data.len], cover_tilemap_data);

    // set up a text buffer using a sprite for the top and bottom half of each character
    vdp.sprite_table.sprite[0].sprite_addr = .{
        .tile_bitmap_addr = font_tile_bitmap_addr >> 10,
        .tilemap_addr = text_buffer_top >> 9,
    };
    vdp.sprite_table.sprite[0].sprite_x_width = .{
        .screen_x = .{ .fp = .{.i = @as(i12, 384), .f = 0} },
        .tilemap_x = 0,
        .width = 32,
    };
    vdp.sprite_table.sprite[0].sprite_y_height = .{
        .screen_y = .{ .fp = .{.i = @as(i12, 352), .f = 0} },
        .tilemap_y = 0,
        .height = 1,
    };
    vdp.sprite_table.sprite[1].sprite_addr = .{
        .tile_bitmap_addr = font_tile_bitmap_addr >> 10,
        .tilemap_addr = text_buffer_bot >> 9,
    };
    vdp.sprite_table.sprite[1].sprite_x_width = .{
        .screen_x = .{ .fp = .{.i = @as(i12, 384), .f = 0} },
        .tilemap_x = 0,
        .width = 32,
    };
    vdp.sprite_table.sprite[1].sprite_y_height = .{
        .screen_y = .{ .fp = .{.i = @as(i12, 352+16), .f = 0} },
        .tilemap_y = 0,
        .height = 1,
    };

    for (0..32) |i| {
        vdp.vram_u16[text_buffer_top+i] = @as(u16, ' ') | (31 << 10);
        vdp.vram_u16[text_buffer_bot+i] = @as(u16, ' '+128) | (31 << 10);
    }

    player.init(song_data) catch |err| {
        console.print("Failed to init PT3 player: {}\r\n", .{err}) catch {};
        console.flush() catch {};
        while (true) {}
    };

    console.print("Hellorld from StarJay land!!!\r\n", .{}) catch {};
    console.print("You are listening to: {s}\r\n", .{player.header().songinfo}) catch {};
    console.print("  Dual AY3 (TurboSound)? {}\r\n", .{player.is_turbosound}) catch {};
    console.flush() catch {};

    const initial_time = readClintMtime();
    // const tick_duration = 2500; // 64 MHz clock is divided by 512 for the clint, so 50 Hz is (64M/512) / 50 = 2500
    const tick_duration = ((64_000_000 / 512)*1000) / 48_828; // 48.828 Hz for KUVO's settings
    var next_tick = initial_time + tick_duration;

    // var initial_delay: i32 = 14*50+25; // 14.5 sec, when the intro beat drop happens

    console.print("Clint time: {}, next tick: {}\r\n", .{initial_time, next_tick}) catch {};
    console.flush() catch {};

    const State = struct {
        playing: bool = false,

        fn fn1(self: *@This(), ctx: *anim.Ctx) void {
            _ = ctx; // unused

            self.playing = true;

            const text = "Hello,                 ";
            for (text, 0..) |c, i| {
                const char_code = @as(u8, c);

                vdp.vram_u16[text_buffer_top+i+((32 - text.len) >> 1)] = @as(u16, char_code) | (31 << 10); // palette 31
                vdp.vram_u16[text_buffer_bot+i+((32 - text.len) >> 1)] = @as(u16, char_code+128) | (31 << 10); // palette 31, bottom half of character
            }
        }

        fn fn2(self: *@This(), ctx: *anim.Ctx) void {
            _ = ctx; // unused
            _ = self; // unused

            const text = "Hello, Welcome,        ";
            for (text, 0..) |c, i| {
                const char_code = @as(u8, c);

                vdp.vram_u16[text_buffer_top+i+((32 - text.len) >> 1)] = @as(u16, char_code) | (31 << 10); // palette 31
                vdp.vram_u16[text_buffer_bot+i+((32 - text.len) >> 1)] = @as(u16, char_code+128) | (31 << 10); // palette 31, bottom half of character
            }
        }

        fn fn3(self: *@This(), ctx: *anim.Ctx) void {
            _ = ctx; // unused
            _ = self; // unused

            const text = "Hello, Welcome, Welcome";
            for (text, 0..) |c, i| {
                const char_code = @as(u8, c);

                vdp.vram_u16[text_buffer_top+i+((32 - text.len) >> 1)] = @as(u16, char_code) | (31 << 10); // palette 31
                vdp.vram_u16[text_buffer_bot+i+((32 - text.len) >> 1)] = @as(u16, char_code+128) | (31 << 10); // palette 31, bottom half of character
            }
        }

        fn fn4(self: *@This(), ctx: *anim.Ctx) void {
            _ = ctx; // unused
            _ = self; // unused

            // cover art is 48x36 tiles
            const cover_y = (720 >> 1) - (((36 << 4) + 16 + 8) >> 1);
            const text_y = cover_y + 36*16 + 8;

            vdp.sprite_table.sprite[0].sprite_y_height.screen_y.fp.i = text_y;
            vdp.sprite_table.sprite[1].sprite_y_height.screen_y.fp.i = text_y+16;

            vdp.sprite_table.sprite[2] = .{
                .sprite_addr = .{
                    .tile_bitmap_addr = 0,
                    .tilemap_addr = cover_tilemap_addr >> 10,
                },
                .sprite_x_width = .{
                    .screen_x = .{ .fp = .{.i = @as(i12, (1280 >> 1) - ((48 << 4) >> 1)), .f = 0} },
                    .tilemap_x = 0,
                    .width = 48,
                },
                .sprite_y_height = .{
                    .screen_y = .{ .fp = .{.i = cover_y, .f = 0} },
                    .tilemap_y = 0,
                    .height = 36,
                },
                .sprite_velocity = .{
                    .x_velocity = .{ .fp = .{.i = 0, .f = 0} },
                    .y_velocity = .{ .fp = .{.i = 0, .f = 0} },
                },
            };
            vdp.sprite_table.sprite_extra[2].tilemap_size_b = 0;
            vdp.sprite_table.sprite_extra[2].tilemap_size_a = 1; // 48 tiles wide

            const text = "Music: Plastic Cake by KUVO";
            for (text, 0..) |c, i| {
                const char_code = @as(u8, c);

                vdp.vram_u16[text_buffer_top+i+((32 - text.len) >> 1)] = @as(u16, char_code) | (31 << 10); // palette 31
                vdp.vram_u16[text_buffer_bot+i+((32 - text.len) >> 1)] = @as(u16, char_code+128) | (31 << 10); // palette 31, bottom half of character
            }
        }
    };

    var state = State{};

    const keyframes: [] const anim.Keyframe(State) = &.{
        .{
            .delay = 1,
            .duration = 1,
            .do = State.fn1,
        },
        .{
            .delay = 50,
            .duration = 1,
            .do = State.fn2,
        },
        .{
            .delay = 50,
            .duration = 1,
            .do = State.fn3,
        },
        .{
            .delay = 50,
            .duration = 1,
            .do = State.fn4,
        },
    };

    var animation = anim.Animation(State).init(&state, keyframes);

    var psgregs = player.playFrame();

    while (true) {
        const current_time = readClintMtime();

        // console.print("Clint time: {}, next tick: {}\r\n", .{current_time, next_tick}) catch {};
        // console.flush() catch {};

        if (current_time >= next_tick) {
            if (current_time > next_tick) {
                console.print("Warning: PT3 frame was late! current_time: {}, next_tick: {}\r\n", .{current_time, next_tick}) catch {};
                console.flush() catch {};
            }

            next_tick += tick_duration;

            animation.tick(current_time);

            if (state.playing) {
                // Update the registers right on the tick (for tighter timing)
                psgregs.psg1.write(psg1);
                psgregs.psg2.write(psg2);

                psgregs = player.playFrame();
                // console.print("PT3 Frame: Tone A: {}, Tone B: {}, Tone C: {}\r\n", .{regs.psg1.tone_a, regs.psg1.tone_b, regs.psg1.tone_c}) catch {};
                // console.flush() catch {};
            }



            const time_after = readClintMtime();
            if (time_after > next_tick) {
                console.print("Warning: PT3 frame took too long! time_after: {}, next_tick: {}\r\n", .{time_after, next_tick}) catch {};
                console.flush() catch {};
            }

            // if (initial_delay >= 0) {
            //     initial_delay -= 1;
            // }
            // if (initial_delay == 0) {
            //     for (0..512) |i| {
            //         // my lame attempt at pseudo-randomness (doesn't work, but the pattern is pretty)
            //         const i_32: u32 = @truncate(i);
            //         const x_vel_32: u32 = (((((i_32 + ((i_32 / 32)*13) +% 0x811c9dc5) & 0xffffffff) *% 0x01000193) & 0xffffffff) % 32);
            //         const x_vel_u16: u15 = @truncate(x_vel_32);
            //         const x_vel_i16: i16 = @as(i16, x_vel_u16) - 16;

            //         const y_vel_32: u32 = (((((i_32 + ((i_32 / 32)*13) + 512 +% 0x811c9dc5) & 0xffffffff) *% 0x01000193) & 0xffffffff) % 32);
            //         const y_vel_u16: u15 = @truncate(y_vel_32);
            //         const y_vel_i16: i16 = @as(i16, y_vel_u16) - 16;

            //         vdp.sprite_table.sprite[i].sprite_velocity = SpriteVelocity{
            //             .x_velocity = .{
            //                 .value = x_vel_i16,
            //             },
            //             .y_velocity = .{
            //                 .value = y_vel_i16,
            //             },
            //         };
            //     }
            // }
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
