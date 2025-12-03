
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
    memory: [*]u16 = undefined,

    pub const Error = error{
        StackOverflow,
        StackUnderflow,
        IllegalInstruction,
    };

    pub fn init(memory: [*]u16) Cpu {
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
        return (self.csr.status & 1) == 0;
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
            var npc = self.reg.pc + 1;

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
                    0x00 => { // syscall
                        return; // TODO: implement syscall handling
                    },
                    0x02 => { // BEQZ
                        const offset = try self.pop();
                        const t = try self.pop();
                        if (t == 0) {
                            std.log.info("{x} BEQZ {}, {} taken", .{ir, @as(i16, @bitCast(t)), @as(i16, @bitCast(offset))});
                            npc = self.reg.pc + @as(Word, @bitCast(offset));
                        } else {
                            std.log.info("{x} BEQZ {}, {} not taken", .{ir, @as(i16, @bitCast(t)), @as(i16, @bitCast(offset))});
                        }
                    },
                    0x03 => { // BNEZ
                        const offset = try self.pop();
                        const t = try self.pop();
                        if (t != 0) {
                            std.log.info("{x} BNEZ {}, {} taken", .{ir, @as(i16, @bitCast(t)), @as(i16, @bitCast(offset))});
                            npc = self.reg.pc + @as(Word, @bitCast(offset));
                        } else {
                            std.log.info("{x} BNEZ {}, {} not taken", .{ir, @as(i16, @bitCast(t)), @as(i16, @bitCast(offset))});
                        }
                    },
                    0x09 => { // SUB
                        const b = try self.pop();
                        const a = try self.pop();
                        std.log.info("{x} SUB {} - {}", .{ir, a, b});
                        try self.push(a - b);
                    },
                    0x0d => { // OR
                        const b = try self.pop();
                        const a = try self.pop();
                        std.log.info("{x} OR {} | {}", .{ir, a, b});
                        try self.push(a | b);
                    },
                    0x1c => { // PUSH <csr>
                        const csr_id = try self.pop();
                        var csr_value: Word = 0;
                        switch (csr_id) {
                            4 => csr_value = self.csr.depth,
                            else => return Error.IllegalInstruction,
                        }
                        std.log.info("{x} PUSH CSR[{}] = {}", .{ir, csr_id, csr_value});
                        try self.push(csr_value);
                    },
                    else => return Error.IllegalInstruction,
                }
            }

            self.reg.pc = npc;
        }
    }
};

pub fn run(rom_file: []const u8, max_cycles: usize, gpa: std.mem.Allocator) !Word {
    var file = try std.fs.cwd().openFile(rom_file, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const word_count = (file_size + 1) / 2;
    const memory_buf = try gpa.alloc(u16, if (file_size < 256 * 1024) 256 * 1024 / 2 else word_count);
    defer gpa.free(memory_buf);

    for (memory_buf) |*word| {
        word.* = 0;
    }

    std.log.info("Load {} bytes as rom", .{file_size});
    _ = try file.readAll(@ptrCast(memory_buf));
    const memory: [*]u16 = @ptrCast(memory_buf);
    var cpu = Cpu.init(memory);
    try cpu.run(max_cycles);

    return try cpu.pop();
}

test "push instruction" {
    const value = try run("starj/tests/bootstrap/boot_00_push.bin", 10, std.testing.allocator);
    try std.testing.expect(value == 7);
}


test "shi instruction" {
    const value = try run("starj/tests/bootstrap/boot_01_push_shi.bin", 10, std.testing.allocator);
    try std.testing.expect(value == 0xABCD);
}

test "sub instruction" {
    const value = try run("starj/tests/bootstrap/boot_02_sub.bin", 10, std.testing.allocator);
    try std.testing.expect(value == 2);
}

test "bnez not taken instruction" {
    const value = try run("starj/tests/bootstrap/boot_03_bnez_not_taken.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 99);
}

test "bnez taken instruction" {
    const value = try run("starj/tests/bootstrap/boot_04_bnez_taken.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 99);
}

test "or instruction" {
    const value = try run("starj/tests/bootstrap/boot_05_or.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 0xFF);
}

test "beqz instruction" {
    const value = try run("starj/tests/bootstrap/boot_06_beqz.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 99);
}

test "push <csr> instruction" {
    std.testing.log_level = .debug;
    const value = try run("starj/tests/bootstrap/boot_07_csr.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 1);
}
