// AY-3-8910 Programmable Sound Generator (PSG) registers and utilities
// Warning: Mostly AI generated code ahead - review carefully!

pub const psg = @This();

// pub const CHIP_FREQ = 1773500; // Hz -- PAL ZXSpectrum
pub const CHIP_FREQ = 1750000; // Hz -- Pentagon ZXSpectrum clone

pub const PSG1_BASE: u32 = 0x1300_0000;
pub const PSG1_SIZE: u32 = 0x0000_0010;
pub const PSG2_BASE: u32 = PSG1_BASE + PSG1_SIZE;
pub const PSG2_SIZE: u32 = PSG1_SIZE;

const psg1: * volatile [4]u32 = @ptrFromInt(PSG1_BASE);
const psg2: * volatile [4]u32 = @ptrFromInt(PSG2_BASE);

pub const Chip = enum {
    psg1,
    psg2,
};

// compiler bug: nested packed structs cause a hang in symantic analysis
pub const Regs = struct {
    tone_a: u12 = 0,
    tone_b: u12 = 0,
    tone_c: u12 = 0,
    noise_period: u5 = 0,
    mixer: Mixer = .{},
    volume_a: Volume = .{},
    volume_b: Volume = .{},
    volume_c: Volume = .{},
    envelope_period: u16 = 0,
    envelope_shape: u4 = 0,


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

    pub fn init() Regs {
        return .{
            .tone_a = 0,
            .tone_b = 0,
            .tone_c = 0,
            .noise_period = 0,
            .mixer = .{},
            .volume_a = .{},
            .volume_b = .{},
            .volume_c = .{},
            .envelope_period = 0,
            .envelope_shape = 0,
        };
    }

    pub fn write(self: *const Regs, chip: Chip) void {
        // work around the compiler bug with nested packed structs by manually packing the data

        const base_addr: *volatile [4]u32 = switch (chip) {
          .psg1 => psg1,
          .psg2 => psg2,
        };

        // word[0]:
        // tone_a: u12 = 0,
        // _pad0: u4 = 0,
        // tone_b: u12 = 0,
        // _pad1: u4 = 0,
        base_addr[0] = @as(u32, self.tone_a & 0xFFF) | (@as(u32, self.tone_b & 0xFFF) << 16);

        // word[1]:
        // tone_c: u12 = 0,
        // _pad2: u4 = 0,
        // noise_period: u5 = 0,
        // _pad3: u3 = 0,
        // mixer: Mixer = .{},
        base_addr[1] = @as(u32, self.tone_c & 0xFFF) | (@as(u32, self.noise_period & 0x1F) << 16) |
                       ((@as(u32, @intCast(@as(u8,@bitCast(self.mixer))))) << 24);

        // word[2]:
        // volume_a: Volume = .{},
        // volume_b: Volume = .{},
        // volume_c: Volume = .{},
        // envelope_period_lo: u8 = 0,
        base_addr[2] =
            ((@as(u32, @intCast(@as(u8,@bitCast(self.volume_a))))) << 0) |
            ((@as(u32, @intCast(@as(u8,@bitCast(self.volume_b))))) << 8) |
            ((@as(u32, @intCast(@as(u8,@bitCast(self.volume_c))))) << 16) |
            ((@as(u32, self.envelope_period) & 0xFF) << 24);

        // word[3]:
        // envelope_period_hi: u8 = 0,
        // envelope_shape: u4 = 0,
        // _pad4: u20 = 0,
        base_addr[3] = ((@as(u32, self.envelope_period) >> 8) & 0xFF) | (@as(u32, self.envelope_shape & 0x0F) << 8);
    }
};

/// TurboSound (Dual AY3) registers
pub const TurboSoundRegs = struct {
    psg1: Regs,
    psg2: Regs,

    pub fn init() TurboSoundRegs {
        return .{
            .psg1 = Regs.init(),
            .psg2 = Regs.init(),
        };
    }

    pub fn chip(self: *TurboSoundRegs, index: usize) *Regs {
        return switch (index) {
            0 => &self.psg1,
            1 => &self.psg2,
            else => @panic("Invalid PSG index"),
        };
    }

    pub fn write(self: *const TurboSoundRegs) void {
        self.psg1.write(.psg1);
        self.psg2.write(.psg2);
    }
};
