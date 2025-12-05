
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
                std.log.info("{x} SHI {}", .{ir, value});
                try self.push((try self.pop() << 7) | value);
            } else if ((ir & 0xc0) == 0x40) {
                const value = signExtend(ir & 0x3f, 6);
                std.log.info("{x} PUSH {}", .{ir, @as(i16, @bitCast(value))});
                try self.push(value);
            } else {
                switch (ir & 0x3f) {
                    0x00 => { // HALT
                        if (self.csr.status & StatusFlags.TH == 0) {
                            std.log.info("{x} HALT - halting execution as requested", .{ir});
                            return;
                        }
                    },
                    0x03 => { // RETS
                        std.log.info("{x} RETS", .{ir});
                        self.csr.status = self.csr.estatus;
                        self.reg.pc = self.csr.epc;
                    },
                    0x04 => { // BEQZ
                        const offset = try self.pop();
                        const t = try self.pop();
                        if (t == 0) {
                            std.log.info("{x} BEQZ {}, {} taken", .{ir, @as(i16, @bitCast(t)), @as(i16, @bitCast(offset))});
                            self.reg.pc = @addWithOverflow(self.reg.pc, @as(Word, @bitCast(offset)))[0];
                        } else {
                            std.log.info("{x} BEQZ {}, {} not taken", .{ir, @as(i16, @bitCast(t)), @as(i16, @bitCast(offset))});
                        }
                    },
                    0x05 => { // BNEZ
                        const offset = try self.pop();
                        const t = try self.pop();
                        if (t != 0) {
                            std.log.info("{x} BNEZ {}, {} taken", .{ir, @as(i16, @bitCast(t)), @as(i16, @bitCast(offset))});
                            self.reg.pc = @addWithOverflow(self.reg.pc, @as(Word, @bitCast(offset)))[0];
                        } else {
                            std.log.info("{x} BNEZ {}, {} not taken", .{ir, @as(i16, @bitCast(t)), @as(i16, @bitCast(offset))});
                        }
                    },
                    0x0c => { // ADD
                        const b = try self.pop();
                        const a = try self.pop();
                        std.log.info("{x} ADD {} + {}", .{ir, a, b});
                        try self.push(@addWithOverflow(a, b)[0]);
                    },
                    0x0e => { // XOR
                        const b = try self.pop();
                        const a = try self.pop();
                        std.log.info("{x} XOR {} ^ {}", .{ir, a, b});
                        try self.push(a ^ b);
                    },
                    0x10, 0x11, 0x12, 0x13 => { // PUSH <reg>
                        const reg = ir & 0x03;
                        var value: Word = 0;
                        switch (reg) {
                            // 0 => value = self.reg.pc,
                            1 => value = self.framePointer(),
                            // 2 => value = self.reg.ra,
                            // 3 => value = self.reg.ar,
                            else => return Error.IllegalInstruction,
                        }
                        std.log.info("{x} PUSH REG[{}] = {}", .{ir, reg, value});
                        try self.push(value);
                    },
                    0x14, 0x15, 0x16, 0x17 => { // POP <reg>
                        const reg = ir & 0x03;
                        const value = try self.pop();
                        std.log.info("{x} POP REG[{}] = {}", .{ir, reg, value});
                        switch (reg) {
                            // 0 => npc = value,
                            1 => if (self.inKernel()) {
                                self.csr.afp = value;
                            } else {
                                self.reg.fp = value;
                            },
                            // 2 => self.reg.ra = value,
                            // 3 => self.reg.ar = value,
                            else => return Error.IllegalInstruction,
                        }
                    },
                    0x18, 0x19, 0x1a, 0x1b => { // ADD <reg>
                        const addend = try self.pop();
                        const reg = ir & 0x03;
                        switch (reg) {
                            0 => { // ADD PC aka JUMP
                                self.reg.pc = @addWithOverflow(self.reg.pc, addend)[0];
                                std.log.info("{x} JUMP {} to {x}", .{ir, addend, self.reg.pc});
                            },

                            else => return Error.IllegalInstruction,
                        }
                    },
                    0x1c => { // PUSH <csr>
                        const csr = try self.pop();
                        var csr_value: Word = 0;
                        switch (csr) {
                            0 => csr_value = self.csr.status,
                            1 => csr_value = self.csr.estatus,
                            2 => csr_value = self.csr.epc,
                            3 => csr_value = self.alternateFramePointer(),
                            6 => csr_value = self.csr.evec,
                            else => {
                                std.log.err("Illegal CSR: {x}", .{csr});
                                return Error.IllegalInstruction;
                            },
                        }
                        std.log.info("{x} PUSH CSR[{}] = {}", .{ir, csr, csr_value});
                        try self.push(csr_value);
                    },
                    0x1d => { // POP <csr>
                        const csr = try self.pop();
                        const value = try self.pop();
                        std.log.info("{x} POP CSR[{}] = {}", .{ir, csr, value});
                        switch (csr) {
                            0 => {
                                self.csr.status = value;
                            },
                            1 => self.csr.estatus = value,
                            2 => self.csr.epc = value,
                            3 => self.setAlternateFramePointer(value),
                            6 => self.csr.evec = value,
                            9 => std.log.info("Ignoring set of udset", .{}),
                            13 => std.log.info("Ignoring set of kdset", .{}),

                            else => {
                                std.log.err("Illegal CSR: {}", .{csr});
                                return Error.IllegalInstruction;
                            }
                        }
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

test "push instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_00_push.bin", 10, std.testing.allocator);
    try std.testing.expect(value == 7);
}

test "shi instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_01_push_shi.bin", 10, std.testing.allocator);
    try std.testing.expect(value == 0xABCD);
}

test "xor instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_02_xor.bin", 10, std.testing.allocator);
    try std.testing.expect(value == 2);
}

test "bnez not taken instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_03_bnez_not_taken.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 99);
}

test "bnez taken instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_04_bnez_taken.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 99);
}

test "add instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_05_add.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 0xFF);
}

test "beqz instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_06_beqz.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 99);
}

test "push status instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_07_csr.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "pop status and halt instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_08_halt.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "jump instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_09_jump.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 9);
}

test "push/pop fp instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_10_push_pop_fp.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 5);
}

test "push/pop afp instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_11_push_pop_afp.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 5);
}

test "push/pop evec instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_12_push_pop_evec.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 5);
}

test "push/pop estatus instruction" {
    const value = try runTest("starj/tests/bootstrap/boot_13_push_pop_estatus.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 5);
}

test "push/pop epc instruction" {
    // std.testing.log_level = .debug;
    const value = try runTest("starj/tests/bootstrap/boot_14_push_pop_epc.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 5);
}

test "rets instruction" {
    const gpa = std.testing.allocator;
    const memory = try gpa.alloc(u16, 128 * 1024);
    defer gpa.free(memory);

    var cpu = Cpu.init(memory);
    try cpu.loadRom("starj/tests/bootstrap/boot_15_rets.bin");
    cpu.haltOnSyscall = true;
    try cpu.run(40);

    if (cpu.csr.depth != 1) {
        std.log.err("Expected exactly one value on stack after execution, found {}", .{cpu.csr.depth});
        return Cpu.Error.StackUnderflow;
    }

    try std.testing.expect(!cpu.inKernel());
    try std.testing.expect(cpu.framePointer() == 20);

    const value = try cpu.pop();
    try std.testing.expect(value == 13);
}


// test "syscall" {
//     std.testing.log_level = .debug;
//     const value = try runTest("starj/tests/bootstrap/boot_10_syscall.bin", 100, std.testing.allocator);
//     try std.testing.expect(value == 0xffff); // AKA -1
// }
