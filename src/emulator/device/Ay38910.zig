// Copied from: https://github.com/true-grue/ayumi/
// Copyright (c) Peter Sovietov, http://sovietov.com, MIT License
// Heavily modified by and Copyright (c) 2026 Ryan "rj45" Sanche, MIT License

const std = @import("std");
const spsc_queue = @import("spsc_queue");

const Bus = @import("Bus.zig");

const Word = Bus.Word;
const Addr = Bus.Addr;
const Cycle = Bus.Cycle;
const Transaction = Bus.Transaction;

pub const Queue = spsc_queue.SpscQueuePo2Unmanaged(f32);

pub const Ay38910 = @This();

// const CHIP_FREQ = 1_773_500; // Hz -- PAL ZXSpectrum

const CHIP_FREQ = 1_750_000; // Hz -- Pentagon ZXSpectrum clone
const BUS_FREQ = 64_000_000; // Hz -- 64 MHz bus clock

// ayumi constants
const DECIMATE_FACTOR = 8;
const FIR_SIZE = 192;
const DC_FILTER_SIZE = 1024;

// Internal state structures
const ToneChannel = struct {
    tone_period: i32 = 1,
    tone_counter: i32 = 0,
    tone: i32 = 0,
    t_off: i32 = 0,
    n_off: i32 = 0,
    e_on: bool = false,
    volume: i32 = 0,
    pan_left: f64 = @sqrt(0.5),
    pan_right: f64 = @sqrt(0.5),
};

const Interpolator = struct {
    c: [4]f64 = .{ 0, 0, 0, 0 },
    y: [4]f64 = .{ 0, 0, 0, 0 },
};

const DcFilter = struct {
    sum: f64 = 0,
    delay: [DC_FILTER_SIZE]f64 = .{0} ** DC_FILTER_SIZE,
};


pub const PanMode = enum { linear, equal_power };

pub const Options = struct {
    sound_hz: u32, // host sound frequency (number of samples per second)
    clock_rate: f64 = CHIP_FREQ, // chip clock rate in Hz
    is_ym: bool = false, // true for YM2149, false for AY-3-8910
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
    pub const IO_PORT_A: u4 = 14; // (not used)
    pub const IO_PORT_B: u4 = 15; // (not used)

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

pub const Regs = packed struct(u128) {
    tone_a: u12 = 0,
    _unused1: u4 = 0,
    tone_b: u12 = 0,
    _unused2: u4 = 0,
    tone_c: u12 = 0,
    _unused3: u4 = 0,
    noise_period: u5 = 0,
    _unused4: u3 = 0,
    mixer: Mixer = .{},
    volume_a: Volume = .{},
    volume_b: Volume = .{},
    volume_c: Volume = .{},
    envelope_period: u16 = 0,
    envelope_shape: u4 = 0,
    _unused5: u20 = 0,


    pub const Mixer = packed struct(u8) {
        tone_a_disable: bool = true,
        tone_b_disable: bool = true,
        tone_c_disable: bool = true,
        noise_a_disable: bool = true,
        noise_b_disable: bool = true,
        noise_c_disable: bool = true,
        _unused: u2 = 0,
    };

    pub const Volume = packed struct(u8) {
        level: u4 = 0,
        envelope_enable: bool = false,
        _unused: u3 = 0,
    };
};

bus_cycles: Bus.Cycle = 0, // total cycle count
partial_tick: f64 = 0,
partial_tick_amt: f64 = 0,
partial_sample_amt: f64 = 0, // number of samples per bus cycle
partial_sample: f64 = 0, // accumulator for sample timing
regs: Regs = .{},
left_queue: Queue = undefined, // output sample queue
right_queue: Queue = undefined, // output sample queue

// Tone channels
channels: [NUM_CHANNELS]ToneChannel = [_]ToneChannel{.{}} ** NUM_CHANNELS,

// Noise generator
noise_period: i32 = 1,
noise_counter: i32 = 0,
noise: i32 = 1, // LFSR seed must be 1

// Envelope generator
envelope_counter: i32 = 0,
envelope_period: i32 = 1,
envelope_shape: u4 = 0,
envelope_segment: u1 = 0,
envelope: i32 = 0,

// DAC table (AY vs YM)
dac_table: *const [32]f64 = &AY_dac_table,

// Interpolators
interpolator_left: Interpolator = .{},
interpolator_right: Interpolator = .{},

// FIR filter
fir_left: [FIR_SIZE * 2]f64 = .{0} ** (FIR_SIZE * 2),
fir_right: [FIR_SIZE * 2]f64 = .{0} ** (FIR_SIZE * 2),
fir_index: u32 = 0,

// DC filters
dc_left: DcFilter = .{},
dc_right: DcFilter = .{},
dc_index: u32 = 0,

// Current output
left: f64 = 0,
right: f64 = 0,

// Track last envelope shape for edge-triggered reset
last_envelope_shape: u4 = 0,

pub fn init(opts: Options, gpa: std.mem.Allocator) !Ay38910 {
    // The number of samples per bus cycle (which will be less than 1.0)
    const partial_sample_amt: f64 = @as(f64, @floatFromInt(opts.sound_hz)) / BUS_FREQ;

    // internal operations happen every 8 clock ticks
    // partial_tick_amt = clock_rate / (sr * 8 * DECIMATE_FACTOR)
    const partial_tick_amt = opts.clock_rate / (@as(f64, @floatFromInt(opts.sound_hz)) * 8.0 * DECIMATE_FACTOR);
    std.debug.assert(partial_tick_amt < 1.0);

    var self = Ay38910{
        .partial_sample_amt = partial_sample_amt,
        .partial_tick_amt = partial_tick_amt,
        .dac_table = if (opts.is_ym) &YM_dac_table else &AY_dac_table,
    };
    self.left_queue = try Queue.initCapacity(gpa, 65536);
    self.right_queue = try Queue.initCapacity(gpa, 65536);
    self.reset();
    return self;
}

pub fn deinit(self: *Ay38910, gpa: std.mem.Allocator) void {
    self.left_queue.deinit(gpa);
    self.right_queue.deinit(gpa);
}

pub fn reset(self: *Ay38910) void {
    self.partial_tick = 0.0;
    self.partial_sample = 0.0;
    self.regs = .{};

    // Reset tone channels
    for (&self.channels) |*ch| {
        ch.* = .{};
    }

    // Reset noise generator (LFSR seed must be 1)
    self.noise_period = 1;
    self.noise_counter = 0;
    self.noise = 1;

    // Reset envelope generator
    self.envelope_counter = 0;
    self.envelope_period = 1;
    self.envelope_shape = 0;
    self.envelope_segment = 0;
    self.envelope = 0;
    self.last_envelope_shape = 0;

    // Reset sample rate conversion
    self.partial_tick = 0;

    // Reset interpolators
    self.interpolator_left = .{};
    self.interpolator_right = .{};

    // Reset FIR filters
    self.fir_left = .{0} ** (FIR_SIZE * 2);
    self.fir_right = .{0} ** (FIR_SIZE * 2);
    self.fir_index = 0;

    // Reset DC filters
    self.dc_left = .{};
    self.dc_right = .{};
    self.dc_index = 0;

    // Reset output
    self.left = 0;
    self.right = 0;

    self.updateValues();
}

// do not modify this function, it should be working fine
// this runs at the bus speed (64 MHz) and handles register accesses
pub fn access(self: *Ay38910, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1; // assume 1 cycle per access

    var regptr: *[16]u8 = std.mem.asBytes(&self.regs);

    if (transaction.write) {
        // simulate up to the cycle where this transaction starts
        self.runUntil(transaction.start_cycle());

        const previous_value = regptr.*;

        var word = transaction.data;
        const addr = transaction.address & 0xF;
        var mask = transaction.bytes;
        for (0..4) |i| {
            if ((mask & 1) != 0) {
                regptr[addr+i] = @as(u8, @truncate(word & REGMASK[addr+i]));
                word >>= 8;
            }
            mask >>= 1;
        }
        result.valid = true;

        if (!std.mem.eql(u8, previous_value[0..16], regptr[0..16])) {
            self.updateValues();

            // for (0..3) |ch| {
            //     std.debug.print("Channel {d}: tone_period={d}, t_off={d}, n_off={d}, e_on={d}, volume={d}\r\n",
            //         .{ ch,
            //            self.channels[ch].tone_period,
            //            self.channels[ch].t_off,
            //            self.channels[ch].n_off,
            //            @intFromBool(self.channels[ch].e_on),
            //            self.channels[ch].volume });
            // }
            // std.debug.print("Envelope: period={d}, shape={d}\r\n",
            //     .{ self.envelope_period, self.envelope_shape });
            // std.debug.print("Noise period: {d}\r\n", .{ self.noise_period });
            // std.debug.print("\r\n", .{});
        }
    } else {
        var data: u32 = 0;
        var addr = transaction.address;
        var mask = transaction.bytes;
        for (0..4) |_| {
            if ((mask & 1) != 0) {
                data <<= 8;
                data |= regptr[addr & 0xF];
                addr += 1;
            }
            mask >>= 1;
        }
        result.data = data;
        result.valid = true;
    }

    return result;
}

// Core sound generation functions (matching ayumi.c behavior)

fn updateTone(self: *Ay38910, index: usize) i32 {
    var ch = &self.channels[index];
    ch.tone_counter += 1;
    if (ch.tone_counter >= ch.tone_period) {
        ch.tone_counter = 0;
        ch.tone ^= 1;
    }
    return ch.tone;
}

fn updateNoise(self: *Ay38910) i32 {
    self.noise_counter += 1;
    if (self.noise_counter >= (self.noise_period << 1)) {
        self.noise_counter = 0;
        // 17-bit LFSR: feedback from bits 0 and 3
        const bit0x3: i32 = (self.noise ^ (self.noise >> 3)) & 1;
        self.noise = (self.noise >> 1) | (bit0x3 << 16);
    }
    return self.noise & 1;
}

fn resetSegment(self: *Ay38910) void {
    const action = envelope_shapes[self.envelope_shape][self.envelope_segment];
    if (action == .slide_down or action == .hold_top) {
        self.envelope = 31;
    } else {
        self.envelope = 0;
    }
}

fn executeEnvelopeAction(self: *Ay38910, action: EnvelopeAction) void {
    switch (action) {
        .slide_up => {
            self.envelope += 1;
            if (self.envelope > 31) {
                self.envelope_segment ^= 1;
                self.resetSegment();
            }
        },
        .slide_down => {
            self.envelope -= 1;
            if (self.envelope < 0) {
                self.envelope_segment ^= 1;
                self.resetSegment();
            }
        },
        .hold_top, .hold_bottom => {
            // No action needed - envelope stays at current value
        },
    }
}

fn updateEnvelope(self: *Ay38910) i32 {
    self.envelope_counter += 1;
    if (self.envelope_counter >= self.envelope_period) {
        self.envelope_counter = 0;
        const action = envelope_shapes[self.envelope_shape][self.envelope_segment];
        self.executeEnvelopeAction(action);
    }
    return self.envelope;
}

fn updateMixer(self: *Ay38910) void {
    const noise = self.updateNoise();
    const envelope = self.updateEnvelope();
    self.left = 0;
    self.right = 0;

    for (0..NUM_CHANNELS) |i| {
        const tone = self.updateTone(i);
        const ch = &self.channels[i];
        // Combine tone and noise with their disable flags
        const out_bit = (tone | ch.t_off) & (noise | ch.n_off);
        // Calculate amplitude: use envelope or fixed volume
        const amplitude: i32 = if (ch.e_on) envelope else ch.volume * 2 + 1;
        const out: i32 = out_bit * amplitude;
        // Apply DAC and panning
        const dac_value = self.dac_table[@as(usize, @intCast(out))];
        self.left += dac_value * ch.pan_left;
        self.right += dac_value * ch.pan_right;
    }
}

pub fn updateValues(self: *Ay38910) void {
    // Sync register values to internal state

    // Tone periods (min 1 to avoid division issues)
    const tone_a: i32 = @intCast(self.regs.tone_a);
    const tone_b: i32 = @intCast(self.regs.tone_b);
    const tone_c: i32 = @intCast(self.regs.tone_c);
    self.channels[0].tone_period = if (tone_a == 0) 1 else tone_a;
    self.channels[1].tone_period = if (tone_b == 0) 1 else tone_b;
    self.channels[2].tone_period = if (tone_c == 0) 1 else tone_c;

    // Noise period (min 1)
    const noise_p: i32 = @intCast(self.regs.noise_period);
    self.noise_period = if (noise_p == 0) 1 else noise_p;

    // Mixer settings (t_off/n_off are inverted: disable=1 means tone passes through)
    self.channels[0].t_off = @intFromBool(self.regs.mixer.tone_a_disable);
    self.channels[0].n_off = @intFromBool(self.regs.mixer.noise_a_disable);
    self.channels[1].t_off = @intFromBool(self.regs.mixer.tone_b_disable);
    self.channels[1].n_off = @intFromBool(self.regs.mixer.noise_b_disable);
    self.channels[2].t_off = @intFromBool(self.regs.mixer.tone_c_disable);
    self.channels[2].n_off = @intFromBool(self.regs.mixer.noise_c_disable);

    // Volume and envelope enable
    self.channels[0].volume = @intCast(self.regs.volume_a.level);
    self.channels[0].e_on = self.regs.volume_a.envelope_enable;
    self.channels[1].volume = @intCast(self.regs.volume_b.level);
    self.channels[1].e_on = self.regs.volume_b.envelope_enable;
    self.channels[2].volume = @intCast(self.regs.volume_c.level);
    self.channels[2].e_on = self.regs.volume_c.envelope_enable;

    // Envelope period (min 1)
    const env_p: i32 = @intCast(self.regs.envelope_period);
    self.envelope_period = if (env_p == 0) 1 else env_p;

    // Envelope shape - reset envelope state when shape register is written
    if (self.regs.envelope_shape != self.last_envelope_shape) {
        self.envelope_shape = self.regs.envelope_shape;
        self.envelope_counter = 0;
        self.envelope_segment = 0;
        self.resetSegment();
        self.last_envelope_shape = self.regs.envelope_shape;
    }
}

// Sample rate conversion functions

// 192-tap FIR decimation filter (all coefficients from ayumi.c)
fn decimate(fir_index: u32, fir: *[FIR_SIZE * 2]f64) f64 {
    // Get the window into the circular buffer
    const base = FIR_SIZE - fir_index * DECIMATE_FACTOR;
    const x = fir[base..][0..FIR_SIZE];

    const y = -0.0000046183113992051936 * (x[1] + x[191]) +
        -0.00001117761640887225 * (x[2] + x[190]) +
        -0.000018610264502005432 * (x[3] + x[189]) +
        -0.000025134586135631012 * (x[4] + x[188]) +
        -0.000028494281690666197 * (x[5] + x[187]) +
        -0.000026396828793275159 * (x[6] + x[186]) +
        -0.000017094212558802156 * (x[7] + x[185]) +
        0.000023798193576966866 * (x[9] + x[183]) +
        0.000051281160242202183 * (x[10] + x[182]) +
        0.00007762197826243427 * (x[11] + x[181]) +
        0.000096759426664120416 * (x[12] + x[180]) +
        0.00010240229300393402 * (x[13] + x[179]) +
        0.000089344614218077106 * (x[14] + x[178]) +
        0.000054875700118949183 * (x[15] + x[177]) +
        -0.000069839082210680165 * (x[17] + x[175]) +
        -0.0001447966132360757 * (x[18] + x[174]) +
        -0.00021158452917708308 * (x[19] + x[173]) +
        -0.00025535069106550544 * (x[20] + x[172]) +
        -0.00026228714374322104 * (x[21] + x[171]) +
        -0.00022258805927027799 * (x[22] + x[170]) +
        -0.00013323230495695704 * (x[23] + x[169]) +
        0.00016182578767055206 * (x[25] + x[167]) +
        0.00032846175385096581 * (x[26] + x[166]) +
        0.00047045611576184863 * (x[27] + x[165]) +
        0.00055713851457530944 * (x[28] + x[164]) +
        0.00056212565121518726 * (x[29] + x[163]) +
        0.00046901918553962478 * (x[30] + x[162]) +
        0.00027624866838952986 * (x[31] + x[161]) +
        -0.00032564179486838622 * (x[33] + x[159]) +
        -0.00065182310286710388 * (x[34] + x[158]) +
        -0.00092127787309319298 * (x[35] + x[157]) +
        -0.0010772534348943575 * (x[36] + x[156]) +
        -0.0010737727700273478 * (x[37] + x[155]) +
        -0.00088556645390392634 * (x[38] + x[154]) +
        -0.00051581896090765534 * (x[39] + x[153]) +
        0.00059548767193795277 * (x[41] + x[151]) +
        0.0011803558710661009 * (x[42] + x[150]) +
        0.0016527320270369871 * (x[43] + x[149]) +
        0.0019152679330965555 * (x[44] + x[148]) +
        0.0018927324805381538 * (x[45] + x[147]) +
        0.0015481870327877937 * (x[46] + x[146]) +
        0.00089470695834941306 * (x[47] + x[145]) +
        -0.0010178225878206125 * (x[49] + x[143]) +
        -0.0020037400552054292 * (x[50] + x[142]) +
        -0.0027874356824117317 * (x[51] + x[141]) +
        -0.003210329988021943 * (x[52] + x[140]) +
        -0.0031540624117984395 * (x[53] + x[139]) +
        -0.0025657163651900345 * (x[54] + x[138]) +
        -0.0014750752642111449 * (x[55] + x[137]) +
        0.0016624165446378462 * (x[57] + x[135]) +
        0.0032591192839069179 * (x[58] + x[134]) +
        0.0045165685815867747 * (x[59] + x[133]) +
        0.0051838984346123896 * (x[60] + x[132]) +
        0.0050774264697459933 * (x[61] + x[131]) +
        0.0041192521414141585 * (x[62] + x[130]) +
        0.0023628575417966491 * (x[63] + x[129]) +
        -0.0026543507866759182 * (x[65] + x[127]) +
        -0.0051990251084333425 * (x[66] + x[126]) +
        -0.0072020238234656924 * (x[67] + x[125]) +
        -0.0082672928192007358 * (x[68] + x[124]) +
        -0.0081033739572956287 * (x[69] + x[123]) +
        -0.006583111539570221 * (x[70] + x[122]) +
        -0.0037839040415292386 * (x[71] + x[121]) +
        0.0042781252851152507 * (x[73] + x[119]) +
        0.0084176358598320178 * (x[74] + x[118]) +
        0.01172566057463055 * (x[75] + x[117]) +
        0.013550476647788672 * (x[76] + x[116]) +
        0.013388189369997496 * (x[77] + x[115]) +
        0.010979501242341259 * (x[78] + x[114]) +
        0.006381274941685413 * (x[79] + x[113]) +
        -0.007421229604153888 * (x[81] + x[111]) +
        -0.01486456304340213 * (x[82] + x[110]) +
        -0.021143584622178104 * (x[83] + x[109]) +
        -0.02504275058758609 * (x[84] + x[108]) +
        -0.025473530942547201 * (x[85] + x[107]) +
        -0.021627310017882196 * (x[86] + x[106]) +
        -0.013104323383225543 * (x[87] + x[105]) +
        0.017065133989980476 * (x[89] + x[103]) +
        0.036978919264451952 * (x[90] + x[102]) +
        0.05823318062093958 * (x[91] + x[101]) +
        0.079072012081405949 * (x[92] + x[100]) +
        0.097675998716952317 * (x[93] + x[99]) +
        0.11236045936950932 * (x[94] + x[98]) +
        0.12176343577287731 * (x[95] + x[97]) +
        0.125 * x[96];

    // Copy first DECIMATE_FACTOR samples to after FIR_SIZE for wrap-around
    // This matches the C: memcpy(&x[FIR_SIZE - DECIMATE_FACTOR], x, DECIMATE_FACTOR * sizeof(double));
    // x points to base, so x[FIR_SIZE - DECIMATE_FACTOR] = fir[base + FIR_SIZE - DECIMATE_FACTOR]
    @memcpy(fir[base + FIR_SIZE - DECIMATE_FACTOR ..][0..DECIMATE_FACTOR], x[0..DECIMATE_FACTOR]);

    return y;
}

fn processOneSample(self: *Ay38910) void {
    var c_left = &self.interpolator_left.c;
    var y_left = &self.interpolator_left.y;
    var c_right = &self.interpolator_right.c;
    var y_right = &self.interpolator_right.y;

    // Get FIR buffer offset using current fir_index (before incrementing)
    const current_fir_index = self.fir_index;
    const fir_offset = FIR_SIZE - current_fir_index * DECIMATE_FACTOR;
    // Increment fir_index for next call (matches C behavior)
    self.fir_index = (self.fir_index + 1) % (FIR_SIZE / DECIMATE_FACTOR - 1);

    // Process DECIMATE_FACTOR samples in reverse order
    var i: i32 = DECIMATE_FACTOR - 1;
    while (i >= 0) : (i -= 1) {
        self.partial_tick += self.partial_tick_amt;
        if (self.partial_tick >= 1) {
            self.partial_tick -= 1;
            // Shift y values
            y_left[0] = y_left[1];
            y_left[1] = y_left[2];
            y_left[2] = y_left[3];
            y_right[0] = y_right[1];
            y_right[1] = y_right[2];
            y_right[2] = y_right[3];
            // Generate new sample
            self.updateMixer();
            y_left[3] = self.left;
            y_right[3] = self.right;
            // Calculate cubic interpolation coefficients
            const y1_left = y_left[2] - y_left[0];
            c_left[0] = 0.5 * y_left[1] + 0.25 * (y_left[0] + y_left[2]);
            c_left[1] = 0.5 * y1_left;
            c_left[2] = 0.25 * (y_left[3] - y_left[1] - y1_left);
            const y1_right = y_right[2] - y_right[0];
            c_right[0] = 0.5 * y_right[1] + 0.25 * (y_right[0] + y_right[2]);
            c_right[1] = 0.5 * y1_right;
            c_right[2] = 0.25 * (y_right[3] - y_right[1] - y1_right);
        }
        // Write interpolated sample to FIR buffer
        const idx = fir_offset + @as(usize, @intCast(i));
        self.fir_left[idx] = (c_left[2] * self.partial_tick + c_left[1]) * self.partial_tick + c_left[0];
        self.fir_right[idx] = (c_right[2] * self.partial_tick + c_right[1]) * self.partial_tick + c_right[0];
    }

    // Decimate to output sample rate (use the fir_index we captured at the start)
    self.left = decimate(current_fir_index, &self.fir_left);
    self.right = decimate(current_fir_index, &self.fir_right);
}

fn dcFilter(dc: *DcFilter, index: u32, in: f64) f64 {
    dc.sum += -dc.delay[index] + in;
    dc.delay[index] = in;
    return in - dc.sum / DC_FILTER_SIZE;
}

fn removeDc(self: *Ay38910) void {
    self.left = dcFilter(&self.dc_left, self.dc_index, self.left);
    self.right = dcFilter(&self.dc_right, self.dc_index, self.right);
    self.dc_index = (self.dc_index + 1) & (DC_FILTER_SIZE - 1);
}

pub fn runUntil(self: *Ay38910, bus_cycles: Bus.Cycle) void {
    while (self.bus_cycles < bus_cycles) {
        self.tick();
    }
}

pub inline fn tick(self: *Ay38910) void {
    self.bus_cycles += 1;

    // Figure out if we need to generate an output sample
    self.partial_sample += self.partial_sample_amt;
    if (self.partial_sample >= 1.0) {
        self.partial_sample -= 1.0;
        self.processOneSample();
        self.removeDc();

        // Push stereo samples to output queue
        if (!self.left_queue.tryPush(@floatCast(self.left))) {
            std.debug.print("Warning: AY-3-8910 sample queue full, dropping left sample\r\n", .{});
        }
        if (!self.right_queue.tryPush(@floatCast(self.right))) {
            std.debug.print("Warning: AY-3-8910 sample queue full, dropping right sample\r\n", .{});
        }
    }
}

// Additional API functions

/// Set stereo panning for a channel.
/// pan: 0.0 = full left, 0.5 = center, 1.0 = full right
/// mode: linear or equal_power panning law
pub fn setPan(self: *Ay38910, channel: u2, pan: f64, mode: PanMode) void {
    if (channel >= NUM_CHANNELS) return;
    switch (mode) {
        .equal_power => {
            self.channels[channel].pan_left = @sqrt(1.0 - pan);
            self.channels[channel].pan_right = @sqrt(pan);
        },
        .linear => {
            self.channels[channel].pan_left = 1.0 - pan;
            self.channels[channel].pan_right = pan;
        },
    }
}

/// Switch between AY-3-8910 and YM2149 DAC characteristics.
pub fn setChipType(self: *Ay38910, is_ym: bool) void {
    self.dac_table = if (is_ym) &YM_dac_table else &AY_dac_table;
}


const EnvelopeAction = enum { slide_up, slide_down, hold_top, hold_bottom };

const envelope_shapes: [16][2]EnvelopeAction = .{
    .{ .slide_down, .hold_bottom }, // 0
    .{ .slide_down, .hold_bottom }, // 1
    .{ .slide_down, .hold_bottom }, // 2
    .{ .slide_down, .hold_bottom }, // 3
    .{ .slide_up, .hold_bottom },   // 4
    .{ .slide_up, .hold_bottom },   // 5
    .{ .slide_up, .hold_bottom },   // 6
    .{ .slide_up, .hold_bottom },   // 7
    .{ .slide_down, .slide_down },  // 8
    .{ .slide_down, .hold_bottom }, // 9
    .{ .slide_down, .slide_up },    // 10
    .{ .slide_down, .hold_top },    // 11
    .{ .slide_up, .slide_up },      // 12
    .{ .slide_up, .hold_top },      // 13
    .{ .slide_up, .slide_down },    // 14
    .{ .slide_up, .hold_bottom },   // 15
};

// AY-3-8910 DAC table (32 values, pairs are identical for 5-bit envelope indexing)
const AY_dac_table: [32]f64 = .{
    0.0,                0.0,
    0.00999465934234,   0.00999465934234,
    0.0144502937362,    0.0144502937362,
    0.0210574502174,    0.0210574502174,
    0.0307011520562,    0.0307011520562,
    0.0455481803616,    0.0455481803616,
    0.0644998855573,    0.0644998855573,
    0.107362478065,     0.107362478065,
    0.126588845655,     0.126588845655,
    0.20498970016,      0.20498970016,
    0.292210269322,     0.292210269322,
    0.372838941024,     0.372838941024,
    0.492530708782,     0.492530708782,
    0.635324635691,     0.635324635691,
    0.805584802014,     0.805584802014,
    1.0,                1.0,
};

// YM2149 DAC table (32 values, 5-bit envelope indexing)
const YM_dac_table: [32]f64 = .{
    0.0,                0.0,
    0.00465400167849,   0.00772106507973,
    0.0109559777218,    0.0139620050355,
    0.0169985503929,    0.0200198367285,
    0.024368657969,     0.029694056611,
    0.0350652323186,    0.0403906309606,
    0.0485389486534,    0.0583352407111,
    0.0680552376593,    0.0777752346075,
    0.0925154497597,    0.111085679408,
    0.129747463188,     0.148485542077,
    0.17666895552,      0.211551079576,
    0.246387426566,     0.281101701381,
    0.333730067903,     0.400427252613,
    0.467383840696,     0.53443198291,
    0.635172045472,     0.75800717174,
    0.879926756695,     1.0,
};
