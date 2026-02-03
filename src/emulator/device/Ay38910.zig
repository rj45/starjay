// Copied from: https://github.com/floooh/chipz/blob/main/src/chips/ay3891.zig
// Copyright (c) 2024 Andre Weissflog, MIT License
// Heavily modified by and Copyright (c) 2026 Ryan "rj45" Sanche, MIT License

const std = @import("std");
const spsc_queue = @import("spsc_queue");

const Bus = @import("Bus.zig");

const Word = Bus.Word;
const Addr = Bus.Addr;
const Cycle = Bus.Cycle;
const Transaction = Bus.Transaction;

pub const Queue = spsc_queue.SpscQueuePo2Unmanaged(f32);

// const CHIP_FREQ = 1_773_500; // Hz -- PAL ZXSpectrum

const CHIP_FREQ = 1_750_000; // Hz -- Pentagon ZXSpectrum clone


// system bus runs at 64 MHz, so to get the CHIP_FREQ we count this many ticks
const COUNT_PER_TICK: comptime_float = 64000000 / CHIP_FREQ;

pub const Ay38910 = @This();

pub const Options = struct {
    sound_hz: u32, // host sound frequency (number of samples per second)
};

// misc constants
const NUM_CHANNELS = 3;
const FIXEDPOINT_SCALE = 16; // error accumulation precision boost

// registers
pub const REG = struct {
    pub const PERIOD_A_FINE: u4 = 0;
    pub const PERIOD_A_COARSE: u4 = 1;
    pub const PERIOD_B_FINE: u4 = 2;
    pub const PERIOD_B_COARSE: u4 = 3;

    pub const PERIOD_C_FINE: u4 = 4;
    pub const PERIOD_C_COARSE: u4 = 5;
    pub const PERIOD_NOISE: u4 = 6;
    pub const ENABLE: u4 = 7;

    pub const AMP_A: u4 = 8;
    pub const AMP_B: u4 = 9;
    pub const AMP_C: u4 = 10;
    pub const ENV_PERIOD_FINE: u4 = 11;

    pub const ENV_PERIOD_COARSE: u4 = 12;
    pub const ENV_SHAPE_CYCLE: u4 = 13;
    pub const IO_PORT_A: u4 = 14;
    pub const IO_PORT_B: u4 = 15;

    pub const NUM = 16;
};

// register bit widths
const REGMASK = [REG.NUM]u8{
    0xFF, // REG.PERIOD_A_FINE
    0x0F, // REG.PERIOD_A_COARSE
    0xFF, // REG.PERIOD_B_FINE
    0x0F, // REG.PERIOD_B_COARSE
    0xFF, // REG.PERIOD_C_FINE
    0x0F, // REG.PERIOD_C_COARSE
    0x1F, // REG.PERIOD_NOISE
    0xFF, // REG.ENABLE,
    0x1F, // REG.AMP_A (0..3: 4-bit volume, 4: use envelope)
    0x1F, // REG.AMP_B (^^^)
    0x1F, // REG.AMP_C (^^^)
    0xFF, // REG.ENV_PERIOD_FINE
    0xFF, // REG.ENV_PERIOD_COARSE
    0x0F, // REG.ENV_SHAPE_CYCLE
    0xFF, // REG.IO_PORT_A
    0xFF, // REG.IO_PORT_B
};

// port names
pub const Port = enum { A, B };

// envelope shape bits
pub const ENV = struct {
    pub const HOLD: u8 = (1 << 0);
    pub const ALTERNATE: u8 = (1 << 1);
    pub const ATTACK: u8 = (1 << 2);
    pub const CONTINUE: u8 = (1 << 3);
};

pub const Tone = struct {
    period: u16 = 0,
    counter: u16 = 0,
    phase: u1 = 0,
    tone_disable: u1 = 0,
    noise_disable: u1 = 0,
};

pub const Noise = struct {
    period: u16 = 0,
    counter: u16 = 0,
    rng: u32 = 0,
    phase: u1 = 0,
};

pub const Envelope = struct {
    period: u16 = 0,
    counter: u16 = 0,
    shape: struct {
        holding: bool = false,
        hold: bool = false,
        counter: u5 = 0,
        state: u4 = 0,
    } = .{},
};

pub const Sample = struct {
    period: i32 = 0,
    counter: i32 = 0,
};

bus_cycles: Bus.Cycle = 0, // total cycle count
partial_tick: f64 = 0,
tick_count: u32 = 0, // tick counter for internal clock division
regs: [REG.NUM]u8 = [_]u8{0} ** REG.NUM,
tone: [NUM_CHANNELS]Tone = [_]Tone{.{}} ** NUM_CHANNELS, // tone generator states (3 channels)
noise: Noise = .{}, // noise generator state
env: Envelope = .{}, // envelope generator state
sample: Sample = .{}, // sample generator state
queue: Queue = undefined, // output sample queue


pub inline fn setReg(self: *Ay38910, comptime r: comptime_int, data: u8) void {
    self.regs[r] = data & REGMASK[r];
}

inline fn reg16(self: *const Ay38910, comptime r_hi: comptime_int, comptime r_lo: comptime_int) u16 {
    return (@as(u16, self.regs[r_hi]) << 8) | self.regs[r_lo];
}

pub fn init(opts: Options, gpa: std.mem.Allocator) !Ay38910 {
    const sample_period: i32 = @intCast((CHIP_FREQ * FIXEDPOINT_SCALE) / opts.sound_hz);
    var self = Ay38910{
        .noise = .{
            .rng = 1,
        },
        .sample = .{
            .period = sample_period,
            .counter = sample_period,
        },
    };
    self.queue = try Queue.initCapacity(gpa, 8192);
    self.reset();
    return self;
}

pub fn deinit(self: *Ay38910, gpa: std.mem.Allocator) void {
    self.queue.deinit(gpa);
}

pub fn reset(self: *Ay38910) void {
    self.partial_tick = 0.0;
    self.tick_count = 0;
    for (&self.regs) |*r| {
        r.* = 0;
    }
    self.updateValues();
    self.restartEnvelope();
}

pub fn access(self: *Ay38910, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1; // assume 1 cycle per access

    if (transaction.write) {
        self.runUntil(transaction.start_cycle());

        var word = transaction.data;
        const addr = (transaction.address & ~@as(Word, 3)) & 0xF;
        for (0..4) |i| {
            if ((transaction.bytes & (@as(Word, 1) << @as(u5, @truncate(i)))) != 0) {
                self.regs[addr+i] = @as(u8, @truncate(word & REGMASK[addr+i])) ;
            }
            word >>= 8;
        }
        result.valid = true;
        self.updateValues();
    } else {
        var data: u32 = 0;
        var addr = transaction.address;
        var mask = transaction.bytes;
        for (0..4) |_| {
            if ((mask & 1) != 0) {
                data <<= 8;
                data |= self.regs[addr & 0xF];
                addr += 1;
            }
            mask >>= 1;
        }
        result.data = data;
        result.valid = true;
    }

    return result;
}

pub fn runUntil(self: *Ay38910, bus_cycles: Bus.Cycle) void {
    while (self.bus_cycles < bus_cycles) {
        self.tick();
    }
}

pub inline fn tick(self: *Ay38910) void {
    self.bus_cycles += 1;
    // perform tick operations
    self.partial_tick += 1.0;
    if (self.partial_tick >= COUNT_PER_TICK) {
        self.tick_count +%= 1;
        self.partial_tick -= COUNT_PER_TICK;

        if ((self.tick_count & 7) == 0) {
            // tick tone channels
            for (&self.tone) |*chn| {
                chn.counter +%= 1;
                if (chn.counter >= chn.period) {
                    chn.counter = 0;
                    chn.phase ^= 1;
                }
            }
            // tick the noise channel
            self.noise.counter +%= 1;
            if (self.noise.counter >= self.noise.period) {
                self.noise.counter = 0;
                // random number generator from MAME:
                // https://github.com/mamedev/mame/blob/master/src/devices/sound/ay8910.cpp
                // The Random Number Generator of the 8910 is a 17-bit shift
                // register. The input to the shift register is bit0 XOR bit3
                // (bit0 is the output). This was verified on AY-3-8910 and YM2149 chips.
                self.noise.rng ^= ((self.noise.rng & 1) ^ ((self.noise.rng >> 3) & 1)) << 17;
                self.noise.rng >>= 1;
            }
        }


        // tick the envelope generator
        if ((self.tick_count & 15) == 0) {
            self.env.counter +%= 1;
            if (self.env.counter >= self.env.period) {
                self.env.period = 0;
                if (!self.env.shape.holding) {
                    self.env.shape.counter +%= 1;
                    if (self.env.shape.hold and (0x1F == self.env.shape.counter)) {
                        self.env.shape.holding = true;
                    }
                }
            }
            self.env.shape.state = env_shapes[self.regs[REG.ENV_SHAPE_CYCLE]][self.env.shape.counter];
        }

        // FIXME: add some oversampling for anti-aliasing(?)
        // generate sample
        self.sample.counter -= FIXEDPOINT_SCALE;
        if (self.sample.counter <= 0) {
            self.sample.counter += self.sample.period;
            var sm: f32 = 0.0;
            inline for (&self.tone, .{ REG.AMP_A, REG.AMP_B, REG.AMP_C }) |chn, ampReg| {
                const noise_enable: u1 = @truncate((self.noise.rng & 1) | chn.noise_disable);
                const tone_enable: u1 = chn.phase | chn.tone_disable;
                if ((tone_enable & noise_enable) != 0) {
                    const amp = self.regs[ampReg];
                    if (0 == (amp & (1 << 4))) {
                        // fixed amplitude
                        sm += volumes[amp & 0x0F];
                    } else {
                        // envelope control
                        sm += volumes[self.env.shape.state];
                    }
                }
            }
            // don't block if the queue isn't being drained.
            if(!self.queue.tryPush(sm)) {
                std.debug.print("AY-3-8910 sample queue full, dropping sample\r\n", .{});
            }
        }
    }
}

// called after register values change
fn updateValues(self: *Ay38910) void {
    // update tone generator values...
    inline for (&self.tone, 0..) |*chn, i| {
        // "...Note also that due to the design technique used in the Tone Period
        // count-down, the lowest period value is 000000000001 (divide by 1)
        // and the highest period value is 111111111111 (divide by 4095)
        chn.period = self.reg16(2 * i + 1, 2 * i);
        if (chn.period == 0) {
            chn.period = 1;
        }
        // a set 'enabled bit' actually means 'disabled'
        chn.tone_disable = @truncate((self.regs[REG.ENABLE] >> i) & 1);
        chn.noise_disable = @truncate((self.regs[REG.ENABLE] >> (3 + i)) & 1);
    }
    // update noise generator values
    self.noise.period = self.regs[REG.PERIOD_NOISE];
    if (self.noise.period == 0) {
        self.noise.period = 1;
    }
    // update envelope generator values
    self.env.period = self.reg16(REG.ENV_PERIOD_COARSE, REG.ENV_PERIOD_FINE);
    if (self.env.period == 0) {
        self.env.period = 1;
    }
}

// restart envelope shape generator, only called when env-shape register is updated
fn restartEnvelope(self: *Ay38910) void {
    self.env.shape.holding = false;
    self.env.shape.counter = 0;
    const cycle = self.regs[REG.ENV_SHAPE_CYCLE];
    self.env.shape.hold = 0 == (cycle & ENV.CONTINUE) and 0 != (cycle & ENV.HOLD);
}

// volume table from: https://github.com/true-grue/ayumi/blob/master/ayumi.c
const volumes = [16]f32{
    0.0,
    0.00999465934234,
    0.0144502937362,
    0.0210574502174,
    0.0307011520562,
    0.0455481803616,
    0.0644998855573,
    0.107362478065,
    0.126588845655,
    0.20498970016,
    0.292210269322,
    0.372838941024,
    0.492530708782,
    0.635324635691,
    0.805584802014,
    1.0,
};

// canned envelope generator shapes
const env_shapes = [16][32]u4{
    // CONTINUE ATTACK ALTERNATE HOLD
    // 0 0 X X
    .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // 0 1 X X
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // 1 0 0 0
    .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 },
    // 1 0 0 1
    .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // 1 0 1 0
    .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    // 1 0 1 1
    .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15 },
    // 1 1 0 0
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    // 1 1 0 1
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15 },
    // 1 1 1 0
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 },
    // 1 1 1 1
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};
