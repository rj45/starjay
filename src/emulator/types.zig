//! Common types shared between emulator implementations.

pub const WORDSIZE: comptime_int = 16;
pub const WORDBYTES: comptime_int = WORDSIZE / 8;
pub const WORDMASK: comptime_int = (1 << WORDSIZE) - 1;
pub const SHIFTMASK: comptime_int = if (WORDSIZE == 16) 0xf else 0x1f;

pub const Word = if (WORDSIZE == 16) u16 else u32;
pub const SWord = if (WORDSIZE == 16) i16 else i32;

/// Stack depth limits
pub const MAX_STACK_DEPTH: Word = 256;
pub const USER_MAX_DEPTH: Word = MAX_STACK_DEPTH - 8;
pub const KERNEL_MAX_DEPTH: Word = MAX_STACK_DEPTH - 4;

/// CPU status register as a packed struct with conversion methods.
pub const Status = packed struct(u16) {
    /// Kernel Mode
    km: bool = false,
    /// Interrupt Enable
    ie: bool = false,
    /// Trap on Halt
    th: bool = false,
    _reserved: u13 = 0,

    pub fn toWord(self: Status) Word {
        return @bitCast(self);
    }

    pub fn fromWord(w: Word) Status {
        return @bitCast(w);
    }
};

/// Exception cause values
pub const ECause = enum(u3) {
    none = 0,
    syscall = 1,
    illegal_instr = 2,
    halt_trap = 3,
    stack_underflow = 4,
    stack_overflow = 5,

    /// Convert to full 8-bit ecause value.
    /// Upper nibble encodes exception class: 0x0=syscall, 0x1=illegal, 0x3=stack, 0x5=irq
    pub fn toU8(self: ECause) u8 {
        return switch (self) {
            .none => 0x00,
            .syscall => 0x00,
            .illegal_instr => 0x10,
            .halt_trap => 0x12,
            .stack_underflow => 0x30,
            .stack_overflow => 0x31,
        };
    }

    pub fn interrupt(irq_num: u4) u8 {
        return 0x50 | @as(u8, irq_num);
    }
};

/// Register numbers for PUSH/POP/ADD <reg> instructions
pub const RegNum = enum(u2) {
    pc = 0,
    fp = 1,
    ra = 2,
    ar = 3,
};

/// CSR (Control/Status Register) numbers
pub const CsrNum = enum(u4) {
    status = 0,
    estatus = 1,
    epc = 2,
    afp = 3,
    depth = 4,
    ecause = 5,
    evec = 6,
    // 7 reserved
    udmask = 8,
    udset = 9,
    upmask = 10,
    upset = 11,
    kdmask = 12,
    kdset = 13,
    kpmask = 14,
    kpset = 15,
};


pub const Regs = struct {
    // Registers
    pc: Word = 0,
    ufp: Word = 0,
    kfp: Word = 0,
    ra: Word = 0,
    ar: Word = 0,

    // Stack cache
    tos: Word = 0,
    nos: Word = 0,
    ros: Word = 0,

    // CSRs
    depth: Word = 0,
    status: Status = .{ .km = true }, // boot in kernel mode
    estatus: Status = .{},
    epc: Word = 0,
    evec: Word = 0,
    ecause: Word = 0,

    pub fn fp(self: *const Regs) Word {
        return if (self.status.km) self.kfp else self.ufp;
    }

    pub fn setFp(self: *Regs, value: Word) void {
        if (self.status.km) {
            self.kfp = value;
        } else {
            self.ufp = value;
        }
    }

    pub fn afp(self: *const Regs) Word {
        return if (self.status.km) self.ufp else self.kfp;
    }

    pub fn setAfp(self: *Regs, value: Word) void {
        if (self.status.km) {
            self.ufp = value;
        } else {
            self.kfp = value;
        }
    }

    pub fn readCsr(self: *const Regs, index: Word) Word {
        if (index >= 16 or index == 7) {
            return 0;
        }
        const csr:CsrNum = @enumFromInt(index);
        return switch (csr) {
            .status => self.status.toWord(),
            .estatus => self.estatus.toWord(),
            .epc => self.epc,
            .afp => self.afp(),
            .depth => self.depth,
            .ecause => self.ecause,
            .evec => self.evec,
            else => 0,
        };
    }

    pub fn writeCsr(self: *Regs, index: Word, value: Word) void {
        if (index >= 16 or index == 7) {
            return;
        }
        const csr:CsrNum = @enumFromInt(index);
        switch (csr) {
            .status => self.status = Status.fromWord(value),
            .estatus => self.estatus = Status.fromWord(value),
            .epc => self.epc = value,
            .afp => {
                if (self.status.km) {
                    self.ufp = value;
                } else {
                    self.kfp = value;
                }
            },
            .depth => self.depth = 0,
            .ecause => self.ecause = value,
            .evec => self.evec = value,
            else => {},
        }
    }
};
