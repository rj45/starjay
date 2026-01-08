//! Common types shared between emulator implementations.

const std = @import("std");

pub const WORDSIZE: comptime_int = 16;
pub const WORDBYTES: comptime_int = WORDSIZE / 8;
pub const WORDMASK: comptime_int = (1 << WORDSIZE) - 1;
pub const SHIFTMASK: comptime_int = if (WORDSIZE == 16) 0xf else 0x1f;

pub const Word = if (WORDSIZE == 16) u16 else u32;
pub const SWord = if (WORDSIZE == 16) i16 else i32;

/// Stack depth limits
pub const STACK_SIZE: comptime_int = 1024;
pub const STACK_MASK: comptime_int = STACK_SIZE - 1;
pub const USER_HIGH_WATER: comptime_int = STACK_SIZE - 8;
pub const KERNEL_HIGH_WATER: comptime_int = STACK_SIZE - 4;

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
    rx = 2,
    ry = 3,
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
    rx: Word = 0,
    ry: Word = 0,

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

pub const CpuState = struct {
    reg: Regs = .{},
    stack: [STACK_SIZE]Word = [_]Word{0} ** STACK_SIZE,
    memory: []Word,
    cycles: usize = 0,
    halted: bool = false,
    log_enabled: bool = true,

    pub fn init(memory: []Word) CpuState {
        return .{
            .memory = memory,
        };
    }

    pub fn reset(self: *CpuState) void {
        self.reg = .{};
        self.reg = .{};
        for (self.stack) |*slot| {
            slot.* = 0;
        }
    }

    pub inline fn inKernel(self: *CpuState) bool {
        return self.reg.status.km;
    }

    pub inline fn readStackMem(self: *const CpuState, index: usize) Word {
        return self.stack[index & STACK_MASK];
    }

    pub inline fn writeStackMem(self: *CpuState, index: usize, value: Word) void {
        self.stack[index & STACK_MASK] = value;
    }

    pub inline fn readByte(self: *const CpuState, addr: Word) u8 {
        const phys = self.translateDataAddr(addr);
        if (phys / WORDBYTES < self.memory.len) {
            return @truncate((self.memory[phys / WORDBYTES] >> @intCast((phys % WORDBYTES) * 8)) & 0xff);
        }
        return 0;
    }

    pub inline fn readHalf(self: *const CpuState, addr: Word) Word {
        const phys = self.translateDataAddr(addr);
        const WORDHALVES = WORDBYTES / 2;
        if (phys / WORDBYTES < self.memory.len) {
            return (self.memory[phys / WORDBYTES] >> @intCast((phys % WORDHALVES) * 16)) & 0xffff;
        }
        return 0;
    }

    pub inline fn readWord(self: *const CpuState, addr: Word) Word {
        const phys = self.translateDataAddr(addr);
        if (phys / WORDBYTES < self.memory.len) {
            return self.memory[phys / WORDBYTES];
        }
        return 0;
    }

    pub inline fn writeByte(self: *CpuState, addr: Word, value: u8) void {
        const phys = self.translateDataAddr(addr);
        if (phys / WORDBYTES < self.memory.len) {
            const shift = (phys % WORDBYTES) * 8;
            const mask: u16 = @as(u16, 0xff) << @truncate(shift);
            const new_value: u16 = (@as(u16, value) << @truncate(shift)) | (self.memory[phys / WORDBYTES] & ~mask);
            self.memory[phys / WORDBYTES] = new_value;
        }
    }

    pub inline fn writeHalf(self: *CpuState, addr: Word, value: Word) void {
        const phys = self.translateDataAddr(addr);
        if (phys / WORDBYTES < self.memory.len) {
            const shift = (phys % (WORDBYTES / 2)) * 16;
            const mask: u16 = @as(u16, 0xffff) << @truncate(shift);
            const new_value: u16 = (@as(u16, value) << @truncate(shift)) | (self.memory[phys / WORDBYTES] & ~mask);
            self.memory[phys / WORDBYTES] = new_value;
        }
    }

    pub inline fn writeWord(self: *CpuState, addr: Word, value: Word) void {
        const phys = self.translateDataAddr(addr);
        if (phys / WORDBYTES < self.memory.len) {
            self.memory[phys / WORDBYTES] = value;
        }
    }

    inline fn translateDataAddr(self: *const CpuState, vaddr: Word) usize {
        _ = self;
        return @intCast(vaddr);
    }

    pub fn loadRom(self: *CpuState, rom_file: []const u8) !void {
        var file = try std.fs.cwd().openFile(rom_file, .{});
        defer file.close();

        const file_size = try file.getEndPos();

        for (self.memory) |*word| {
            word.* = 0;
        }

        std.log.info("Load {} bytes as rom", .{file_size});
        _ = try file.readAll(@ptrCast(self.memory));
    }
};
