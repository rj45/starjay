
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
        const m = 1 << (bits - 1);
        return (value ^ m) - m;
    }

    pub fn run(self: *Cpu, cycles: usize) !void {
        var cycle: usize = 0;
        while (cycle < cycles) : (cycle += 1) {
            // fetch
            const ir = self.memory[self.reg.pc];
            const npc = self.reg.pc + 1;

            // decode & execute
            if ((ir & 0x80) == 0x80) {
                const value = ir & 0x7f;
                std.log.info("SHI {}", .{value});
                try self.push((try self.pop() << 7) | value);
            } else if ((ir & 0xc0) == 0x40) {
                const value = signExtend(ir & 0x3f, 6);
                std.log.info("PUSH {}", .{value});
                try self.push(value);
            } else {
                switch (ir & 0x3f) {
                    0x00 => { // syscall
                        return; // TODO: implement syscall handling
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
