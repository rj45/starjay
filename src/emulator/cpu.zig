
const std = @import("std");
const types = @import("types.zig");

const Word = types.Word;
const WORDSIZE = types.WORDSIZE;
const WORDBYTES = types.WORDBYTES;
const WORDMASK = types.WORDMASK;

const STACK_SIZE: comptime_int = (1 << WORDSIZE) - 1;
const USER_HIGH_WATER: comptime_int = STACK_SIZE - 8;
const KERNEL_HIGH_WATER: comptime_int = STACK_SIZE - 4;

pub const Registers = struct {
    /// Program Counter
    pc: Word = 0,
    /// Frame Pointer
    fp: Word = 0,
    /// Return Address
    ra: Word = 0,
    /// Address Register
    ar: Word = 0,
};

pub const StatusFlags = struct {
    pub const KM: Word = 0x1;
    pub const IE: Word = 0x2;
    pub const TH: Word = 0x4;
};

pub const Csrs = struct {
   status: Word = 1,
   estatus: Word = 0,
   afp: Word = 0,
   depth: Word = 0,
   epc: Word = 0,
   evec: Word = 0,
   ecause: Word = 0,
};

pub const Cpu = struct {
    reg: Registers = .{},
    csr: Csrs = .{},
    stack: [STACK_SIZE]Word = undefined,
    memory: []u16 = undefined,
    haltOnSyscall: bool = false,

    pub const Error = error{
        StackOverflow,
        StackUnderflow,
        IllegalInstruction,
    };

    pub fn init(memory: []u16) Cpu {
        return .{
            .reg = .{},
            .csr = .{},
            .stack = [_]Word{0} ** STACK_SIZE,
            .memory = memory,
        };
    }

    pub fn reset(self: *Cpu) void {
        self.reg = .{};
        self.csr = .{};
        for (self.stack) |*slot| {
            slot.* = 0;
        }
    }

    pub inline fn inKernel(self: *Cpu) bool {
        return (self.csr.status & StatusFlags.KM) != 0;
    }

    pub inline fn framePointer(self: *Cpu) Word {
        return if (self.inKernel()) self.csr.afp else self.reg.fp;
    }

    pub inline fn setFramePointer(self: *Cpu, value: u16) void {
        if (self.inKernel()) {
            self.csr.afp = value;
        } else {
            self.reg.fp = value;
        }
    }

    pub inline fn alternateFramePointer(self: *Cpu) Word {
        return if (self.inKernel()) self.reg.fp else self.csr.afp;
    }

    pub inline fn setAlternateFramePointer(self: *Cpu, value: u16) void {
        if (self.inKernel()) {
            self.reg.fp = value;
        } else {
            self.csr.afp = value;
        }
    }

    inline fn push(self: *Cpu, value: Word) !void {
        // depth is checked before it's modified
        if (self.inKernel()) {
            if ((self.csr.depth + 1) >= KERNEL_HIGH_WATER) {
                return Error.StackOverflow;
            }
        } else {
            if ((self.csr.depth + 1) >= USER_HIGH_WATER) {
                return Error.StackOverflow;
            }
        }
        self.stack[self.csr.depth] = value;
        self.csr.depth += 1;
    }

    inline fn pop(self: *Cpu) !Word {
        // depth is checked before it's modified
        if (self.csr.depth == 0) {
            return Error.StackUnderflow;
        }
        self.csr.depth -= 1;
        return self.stack[self.csr.depth];
    }

    inline fn signExtend(value: Word, bits: Word) Word {
        const m: Word = 1 << (bits - 1);
        return @subWithOverflow(value ^ m, m)[0];
    }

    pub fn run(self: *Cpu, cycles: usize) !void {
        const progMem: [*]u8 = @ptrCast(self.memory);
        var cycle: usize = 0;
        while (cycle < cycles) : (cycle += 1) {
            // fetch
            const ir = progMem[self.reg.pc];
            self.reg.pc += 1;

            // decode & execute
            if ((ir & 0x80) == 0x80) {
                const value = ir & 0x7f;
                std.log.info("{x}: {x} SHI {}", .{self.reg.pc-1, ir, value});
                try self.push((try self.pop() << 7) | value);
            } else if ((ir & 0xc0) == 0x40) {
                const value = signExtend(ir & 0x3f, 6);
                std.log.info("{x}: {x} PUSH {}", .{self.reg.pc-1, ir, @as(i16, @bitCast(value))});
                try self.push(value);
            } else {
                switch (ir & 0x3f) {
                    0x00 => { // HALT
                        if (self.csr.status & StatusFlags.TH == 0) {
                            std.log.info("{x}: {x} HALT - halting execution as requested", .{self.reg.pc-1, ir});
                            return;
                        }
                    },
                    0x04 => { // BEQZ
                        const offset = try self.pop();
                        const t = try self.pop();
                        if (t == 0) {
                            std.log.info("{x}: {x} BEQZ {}, {} taken", .{self.reg.pc-1, ir, @as(i16, @bitCast(t)), @as(i16, @bitCast(offset))});
                            self.reg.pc = @addWithOverflow(self.reg.pc, @as(Word, @bitCast(offset)))[0];
                        } else {
                            std.log.info("{x}: {x} BEQZ {}, {} not taken", .{self.reg.pc-1, ir, @as(i16, @bitCast(t)), @as(i16, @bitCast(offset))});
                        }
                    },
                    0x05 => { // BNEZ
                        const offset = try self.pop();
                        const t = try self.pop();
                        if (t != 0) {
                            std.log.info("{x}: {x} BNEZ {}, {} taken", .{self.reg.pc-1, ir, @as(i16, @bitCast(t)), @as(i16, @bitCast(offset))});
                            self.reg.pc = @addWithOverflow(self.reg.pc, @as(Word, @bitCast(offset)))[0];
                        } else {
                            std.log.info("{x}: {x} BNEZ {}, {} not taken", .{self.reg.pc-1, ir, @as(i16, @bitCast(t)), @as(i16, @bitCast(offset))});
                        }
                    },
                    0x06 => { // SWAP
                        const b = try self.pop();
                        const a = try self.pop();
                        std.log.info("{x}: {x} SWAP {} <-> {}", .{self.reg.pc-1, ir, a, b});
                        try self.push(b);
                        try self.push(a);
                    },
                    0x0c => { // ADD
                        const b = try self.pop();
                        const a = try self.pop();
                        std.log.info("{x}: {x} ADD {} + {}", .{self.reg.pc-1, ir, a, b});
                        try self.push(@addWithOverflow(a, b)[0]);
                    },
                    0x0d => { // AND
                        const b = try self.pop();
                        const a = try self.pop();
                        std.log.info("{x}: {x} AND {} & {}", .{self.reg.pc-1, ir, a, b});
                        try self.push(a & b);
                    },
                    0x0e => { // XOR
                        const b = try self.pop();
                        const a = try self.pop();
                        std.log.info("{x}: {x} XOR {} ^ {}", .{self.reg.pc-1, ir, a, b});
                        try self.push(a ^ b);
                    },
                    0x10, 0x11, 0x12, 0x13 => { // PUSH <reg>
                        const reg = ir & 0x03;
                        var value: Word = 0;
                        switch (reg) {
                            // 0 => value = self.reg.pc,
                            1 => value = self.framePointer(),
                            2 => value = self.reg.ra,
                            3 => value = self.reg.ar,
                            else => return Error.IllegalInstruction,
                        }
                        std.log.info("{x}: {x} PUSH REG[{}] = {}", .{self.reg.pc-1, ir, reg, value});
                        try self.push(value);
                    },
                    0x14, 0x15, 0x16, 0x17 => { // POP <reg>
                        const reg = ir & 0x03;
                        const value = try self.pop();
                        std.log.info("{x}: {x} POP REG[{}] = {}", .{self.reg.pc-1, ir, reg, value});
                        switch (reg) {
                            0 => self.reg.pc = value,
                            1 => if (self.inKernel()) {
                                self.csr.afp = value;
                            } else {
                                self.reg.fp = value;
                            },
                            2 => self.reg.ra = value,
                            3 => self.reg.ar = value,
                            else => return Error.IllegalInstruction,
                        }
                    },
                    0x18, 0x19, 0x1a, 0x1b => { // ADD <reg>
                        const addend = try self.pop();
                        const reg = ir & 0x03;
                        switch (reg) {
                            0 => { // ADD PC aka JUMP
                                self.reg.pc = @addWithOverflow(self.reg.pc, addend)[0];
                                std.log.info("{x}: {x} JUMP {} to {x}", .{self.reg.pc-1, ir, addend, self.reg.pc});
                            },
                            1 => { // ADD FP
                                const fp = self.framePointer();
                                const new_fp = @addWithOverflow(fp, addend)[0];
                                self.setFramePointer(new_fp);
                                std.log.info("{x}: {x} ADD FP {} + {} = {}", .{self.reg.pc-1, ir, fp, addend, new_fp});
                            },
                            2 => { // ADD RA
                                const ra = self.reg.ra;
                                const new_ra = @addWithOverflow(ra, addend)[0];
                                self.reg.ra = new_ra;
                                std.log.info("{x}: {x} ADD RA {} + {} = {}", .{self.reg.pc-1, ir, ra, addend, new_ra});
                            },
                            3 => { // ADD AR
                                const ar = self.reg.ar;
                                const new_ar = @addWithOverflow(ar, addend)[0];
                                self.reg.ar = new_ar;
                                std.log.info("{x}: {x} ADD AR {} + {} = {}", .{self.reg.pc-1, ir, ar, addend, new_ar});
                            },

                            else => return Error.IllegalInstruction,
                        }
                    },
                    0x1c => { // PUSH <csr>
                        const csr = try self.pop();
                        var csr_value: Word = 0;
                        switch (csr) {
                            3 => csr_value = self.alternateFramePointer(),
                            5 => csr_value = self.csr.ecause,
                            6 => csr_value = self.csr.evec,
                            else => {
                                std.log.err("Illegal CSR: {x}", .{csr});
                                return Error.IllegalInstruction;
                            },
                        }
                        std.log.info("{x}: {x} PUSH CSR[{}] = {}", .{self.reg.pc-1, ir, csr, csr_value});
                        try self.push(csr_value);
                    },
                    0x1d => { // POP <csr>
                        const csr = try self.pop();
                        const value = try self.pop();
                        std.log.info("{x}: {x} POP CSR[{}] = {}", .{self.reg.pc-1, ir, csr, value});
                        switch (csr) {
                            3 => self.setAlternateFramePointer(value),
                            5 => self.csr.ecause = value,
                            6 => self.csr.evec = value,

                            else => {
                                std.log.err("Illegal CSR: {}", .{csr});
                                return Error.IllegalInstruction;
                            }
                        }
                    },
                    // -------- extended instructions --------
                    0x20 => { // DIV
                        const divisor = try self.pop();
                        const dividend = try self.pop();
                        std.log.info("{x}: {x} DIV {} / {}", .{self.reg.pc-1, ir, dividend, divisor});
                        if (divisor == 0) {
                            // TODO: throw exception instead
                            try self.push(0);
                        } else {
                            const signed_divisor = @as(i16, @bitCast(divisor));
                            const signed_dividend = @as(i16, @bitCast(dividend));
                            const signed_result = @divFloor(signed_dividend, signed_divisor);
                            try self.push(@bitCast(signed_result));
                        }
                    },
                    0x21 => { // DIVU
                        const divisor = try self.pop();
                        const dividend = try self.pop();
                        std.log.info("{x}: {x} DIVU {} / {}", .{self.reg.pc-1, ir, dividend, divisor});
                        if (divisor == 0) {
                            // TODO: throw exception instead
                            try self.push(0);
                        } else {
                            try self.push(@divFloor(dividend, divisor));
                        }
                    },
                    0x38 => { // CALL
                        const pcrel = try self.pop();
                        std.log.info("{x}: {x} CALL to {x}, return address {x}", .{self.reg.pc-1, ir, self.reg.pc+pcrel, self.reg.pc});
                        self.reg.ra = self.reg.pc;
                        self.reg.pc += pcrel;
                    },
                    0x39 => { // CALLP
                        const addr = try self.pop();
                        std.log.info("{x}: {x} CALLP to {x}, return address {x}", .{self.reg.pc-1, ir, addr, self.reg.pc});
                        self.reg.ra = self.reg.pc;
                        self.reg.pc = addr;
                    },
                    else => {
                        std.log.err("Illegal instruction: {x}", .{ir});
                        return Error.IllegalInstruction;
                    },
                }
            }
        }
    }

    pub fn loadRom(self: *Cpu, rom_file: []const u8) !void {
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

pub fn run(rom_file: []const u8, max_cycles: usize, gpa: std.mem.Allocator) !Word {
    const memory = try gpa.alloc(u16, 128 * 1024);
    defer gpa.free(memory);

    var cpu = Cpu.init(memory);
    try cpu.loadRom(rom_file);
    try cpu.run(max_cycles);

    return try cpu.pop();
}

/// Helper function for tests to run a ROM and return the top of stack value, checking the depth is 1
pub fn runTest(rom_file: []const u8, max_cycles: usize, gpa: std.mem.Allocator) !Word {
    const memory = try gpa.alloc(u16, 128 * 1024);
    defer gpa.free(memory);

    var cpu = Cpu.init(memory);
    try cpu.loadRom(rom_file);
    cpu.haltOnSyscall = true;
    try cpu.run(max_cycles);

    if (cpu.csr.depth != 1) {
        std.log.err("Expected exactly one value on stack after execution, found {}", .{cpu.csr.depth});
        return Cpu.Error.StackUnderflow;
    }

    return try cpu.pop();
}

///////////////////////////////////////////////////////
// Bootstrap tests
///////////////////////////////////////////////////////

test "bootstrap push instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_00_push.bin", 10, std.testing.allocator);
    try std.testing.expect(value == 7);
}

test "bootstrap shi instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_01_push_shi.bin", 10, std.testing.allocator);
    try std.testing.expect(value == 0xABCD);
}

test "bootstrap xor instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_02_xor.bin", 10, std.testing.allocator);
    try std.testing.expect(value == 2);
}

test "bootstrap bnez not taken instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_03_bnez_not_taken.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 99);
}

test "bootstrap bnez taken instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_04_bnez_taken.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 99);
}

test "bootstrap add instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_05_add.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 0xFF);
}

test "bootstrap beqz instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_06_beqz.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 99);
}

test "bootstrap halt instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_08_halt.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "bootstrap jump instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_09_jump.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 9);
}

test "bootstrap push/pop fp instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_10_push_pop_fp.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 5);
}

test "bootstrap push/pop afp instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_11_push_pop_afp.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 5);
}

test "bootstrap push/pop evec instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_12_push_pop_evec.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 5);
}

test "bootstrap push/pop ecause instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_13_push_pop_ecause.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 5);
}

///////////////////////////////////////////////////////
// Regular instruction tests
///////////////////////////////////////////////////////

test "add instruction" {
    const value = try runTest("starj/tests/add.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "swap instruction" {
    const value = try runTest("starj/tests/swap.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "add <reg> instruction" {
    const value = try runTest("starj/tests/add_reg.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "and instruction" {
    const value = try runTest("starj/tests/and.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "beqz instruction" {
    const value = try runTest("starj/tests/beqz.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "bnez instruction" {
    const value = try runTest("starj/tests/bnez.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "call/ret instructions" {
    const value = try runTest("starj/tests/call_ret.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "callp instructions" {
    const value = try runTest("starj/tests/callp.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "div instructions" {
    const value = try runTest("starj/tests/div.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "divu instructions" {
    // std.testing.log_level = .debug;
    const value = try runTest("starj/tests/divu.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}
