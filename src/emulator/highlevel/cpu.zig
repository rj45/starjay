const std = @import("std");

const common = @import("../root.zig");
pub const types = common.types;
pub const utils = common.utils;

pub const WORDSIZE = types.WORDSIZE;
pub const WORDBYTES = types.WORDBYTES;
pub const WORDMASK = types.WORDMASK;
pub const SHIFTMASK = types.SHIFTMASK;
pub const Word = types.Word;
pub const SWord = types.SWord;
pub const Status = types.Status;
pub const Opcode = common.opcode.Opcode;
pub const RegNum = types.RegNum;
pub const CsrNum = types.CsrNum;
pub const Regs = types.Regs;

const STACK_SIZE: comptime_int = 1024;
const STACK_MASK: comptime_int = STACK_SIZE - 1;
const USER_HIGH_WATER: comptime_int = STACK_SIZE - 8;
const KERNEL_HIGH_WATER: comptime_int = STACK_SIZE - 4;

pub const StackOp = enum {
    none,
    replace,
    push,
    pop1,
    pop2,
    swap,
    rotate,
};

pub const Cpu = struct {
    reg: Regs = .{},
    stack: [STACK_SIZE]Word = undefined,
    memory: []u16 = undefined,

    pub const Error = error{
        StackOverflow,
        StackUnderflow,
        IllegalInstruction,
        DivideByZero,
        UnalignedAccess,
        Halt,
    };

    pub fn init(memory: []u16) Cpu {
        return .{
            .reg = .{},
            .stack = [_]Word{0} ** STACK_SIZE,
            .memory = memory,
        };
    }

    pub fn reset(self: *Cpu) void {
        self.reg = .{};
        self.reg = .{};
        for (self.stack) |*slot| {
            slot.* = 0;
        }
    }

    pub inline fn inKernel(self: *Cpu) bool {
        return self.reg.status.km;
    }

    inline fn push(self: *Cpu, value: Word) !void {
        // depth is checked before it's modified
        if (self.inKernel()) {
            if ((self.reg.depth + 1) >= KERNEL_HIGH_WATER) {
                return Error.StackOverflow;
            }
        } else {
            if ((self.reg.depth + 1) >= USER_HIGH_WATER) {
                return Error.StackOverflow;
            }
        }
        self.stack[self.reg.depth] = value;
        self.reg.depth += 1;
    }

    inline fn pop(self: *Cpu) !Word {
        // depth is checked before it's modified
        if (self.reg.depth == 0) {
            return Error.StackUnderflow;
        }
        self.reg.depth -= 1;
        return self.stack[self.reg.depth];
    }

    const signExtend6 = utils.signExtend6;
    const signExtend8 = utils.signExtend8;

    pub fn run(self: *Cpu, cycles: usize) !usize {
        const progMem: [*]u8 = @ptrCast(self.memory);
        var cycle: usize = 0;

        var tos = self.stack[@subWithOverflow(self.reg.depth, 1)[0] & STACK_MASK];
        var nos = self.stack[@subWithOverflow(self.reg.depth, 2)[0] & STACK_MASK];
        var ros = self.stack[@subWithOverflow(self.reg.depth, 3)[0] & STACK_MASK];

        loop: while (cycle < cycles) : (cycle += 1) {
            // fetch
            const ir = progMem[self.reg.pc];
            self.reg.pc += 1;

            // decode
            const opcode = Opcode.fromByte(ir);

            // execute
            var result: Word = 0;
            var read: u2 = 0;
            var stackop = StackOp.none;
            switch (opcode) {
                .shi => {
                    const value = ir & 0x7f;
                    result = (tos << 7) | value;
                    read = 1;
                    stackop = .replace;

                    std.log.info("{x:0>4}: {x:0>2} SHI {} -> {} ({x:0>4})", .{ self.reg.pc - 1, ir, value, @as(SWord, @bitCast(result)), result });
                },
                .push => {
                    stackop = .push;
                    result = signExtend6(@truncate(ir & 0x3f));
                    std.log.info("{x:0>4}: {x:0>2} PUSH {}", .{ self.reg.pc - 1, ir, @as(SWord, @bitCast(result)) });
                },
                .halt => {
                    std.log.info("{x:0>4}: {x:0>2} HALT {} ({x:0>4})", .{ self.reg.pc - 1, ir, @as(SWord, @bitCast(tos)), tos });
                    if (!self.reg.status.th) {
                        break :loop;
                    }
                    return Error.Halt;
                },
                .beqz => {
                    read = 2;
                    stackop = .pop2;
                    result = ros;
                    if (nos == 0) {
                        std.log.info("{x:0>4}: {x:0>2} BEQZ {}, {} taken", .{ self.reg.pc - 1, ir, @as(SWord, @bitCast(nos)), @as(SWord, @bitCast(tos)) });
                        self.reg.pc = @addWithOverflow(self.reg.pc, tos)[0];
                    } else {
                        std.log.info("{x:0>4}: {x:0>2} BEQZ {}, {} not taken", .{ self.reg.pc - 1, ir, @as(SWord, @bitCast(nos)), @as(SWord, @bitCast(tos)) });
                    }
                },
                .bnez => {
                    read = 2;
                    stackop = .pop2;
                    result = ros;
                    if (nos != 0) {
                        std.log.info("{x:0>4}: {x:0>2} BNEZ {}, {} taken", .{ self.reg.pc - 1, ir, @as(SWord, @bitCast(nos)), @as(SWord, @bitCast(tos)) });
                        self.reg.pc = @addWithOverflow(self.reg.pc, tos)[0];
                    } else {
                        std.log.info("{x:0>4}: {x:0>2} BNEZ {}, {} not taken", .{ self.reg.pc - 1, ir, @as(SWord, @bitCast(nos)), @as(SWord, @bitCast(tos)) });
                    }
                },
                .swap => {
                    read = 2;
                    stackop = .swap;
                    std.log.info("{x:0>4}: {x:0>2} SWAP {} <-> {}", .{ self.reg.pc - 1, ir, tos, nos });
                },
                .over => {
                    read = 2;
                    result = nos;
                    stackop = .push;
                    std.log.info("{x:0>4}: {x:0>2} OVER {}", .{ self.reg.pc - 1, ir, nos });
                },
                .drop => {
                    read = 1;
                    stackop = .pop1;
                    result = nos;
                    std.log.info("{x:0>4}: {x:0>2} DROP {}", .{ self.reg.pc - 1, ir, tos });
                },
                .dup => {
                    read = 1;
                    result = tos;
                    stackop = .push;
                    std.log.info("{x:0>4}: {x:0>2} DUP {}", .{ self.reg.pc - 1, ir, tos });
                },
                .ltu => {
                    read = 2;
                    stackop = .pop1;
                    result = if (nos < tos) 1 else 0;
                    std.log.info("{x:0>4}: {x:0>2} LTU {} < {} = {}", .{ self.reg.pc - 1, ir, nos, tos, result });
                },
                .lt => {
                    read = 2;
                    stackop = .pop1;
                    const b: SWord = @bitCast(tos);
                    const a: SWord = @bitCast(nos);
                    result = if (a < b) 1 else 0;
                    std.log.info("{x:0>4}: {x:0>2} LT {} < {} = {}", .{ self.reg.pc - 1, ir, a, b, result });
                },
                .add => {
                    read = 2;
                    stackop = .pop1;
                    result = @addWithOverflow(nos, tos)[0];
                    std.log.info("{x:0>4}: {x:0>2} ADD {} + {} = {}", .{ self.reg.pc - 1, ir, nos, tos, result });
                },
                .and_op => {
                    read = 2;
                    stackop = .pop1;
                    result = nos & tos;
                    std.log.info("{x:0>4}: {x:0>2} AND {} & {} = {}", .{ self.reg.pc - 1, ir, nos, tos, result });
                },
                .xor_op => {
                    read = 2;
                    stackop = .pop1;
                    result = nos ^ tos;
                    std.log.info("{x:0>4}: {x:0>2} XOR {} ^ {} = {}", .{ self.reg.pc - 1, ir, nos, tos, result });
                },
                .fsl => {
                    read = 3;
                    stackop = .pop2;
                    // stack: ros=upper, nos=lower, tos=shift
                    std.log.info("{x:0>4}: {x:0>2} FSL ({x} @ {x} << {}) >> 16", .{ self.reg.pc - 1, ir, ros, nos, tos });
                    const value: u32 = (@as(u32, ros) << 16) | @as(u32, nos);
                    const shifted = value << @truncate(tos & 0x1f);
                    result = @as(Word, @truncate(shifted >> 16));
                },
                .push_pc, .push_fp, .push_ra, .push_ar => {
                    stackop = .push;
                    const reg: RegNum = @enumFromInt(ir & 3);
                    switch (reg) {
                        .pc => result = self.reg.pc,
                        .fp => result = self.reg.fp(),
                        .ra => result = self.reg.ra,
                        .ar => result = self.reg.ar,
                    }
                    std.log.info("{x:0>4}: {x:0>2} PUSH {s} = {}", .{ self.reg.pc - 1, ir, @tagName(reg), result });
                },
                .pop_pc, .pop_fp, .pop_ra, .pop_ar => {
                    read = 1;
                    stackop = .pop1;
                    result = nos;
                    const reg: RegNum = @enumFromInt(ir & 3);
                    std.log.info("{x:0>4}: {x:0>2} POP {s} = {}", .{ self.reg.pc - 1, ir, @tagName(reg), tos });
                    switch (reg) {
                        .pc => self.reg.pc = tos,
                        .fp => self.reg.setFp(tos),
                        .ra => self.reg.ra = tos,
                        .ar => self.reg.ar = tos,
                    }
                },
                .jump, .add_fp, .add_ra, .add_ar => { // ADD <reg> / JUMP
                    read = 1;
                    stackop = .pop1;
                    result = nos;
                    const reg: RegNum = @enumFromInt(ir & 3);
                    switch (reg) {
                        .pc => { // JUMP
                            const dest = @addWithOverflow(self.reg.pc, tos)[0];
                            std.log.info("{x:0>4}: {x:0>2} JUMP {} to {x:0>4}", .{ self.reg.pc - 1, ir, @as(SWord, @bitCast(tos)), dest });
                            self.reg.pc = dest;
                        },
                        .fp => { // ADD FP
                            const fp = self.reg.fp();
                            const new_fp = @addWithOverflow(fp, tos)[0];
                            self.reg.setFp(new_fp);
                            std.log.info("{x:0>4}: {x:0>2} ADD FP {} + {} = {}", .{ self.reg.pc - 1, ir, fp, tos, new_fp });
                        },
                        .ra => { // ADD RA
                            const ra = self.reg.ra;
                            const new_ra = @addWithOverflow(ra, tos)[0];
                            self.reg.ra = new_ra;
                            std.log.info("{x:0>4}: {x:0>2} ADD RA {} + {} = {}", .{ self.reg.pc - 1, ir, ra, tos, new_ra });
                        },
                        .ar => { // ADD AR
                            const ar = self.reg.ar;
                            const new_ar = @addWithOverflow(ar, tos)[0];
                            self.reg.ar = new_ar;
                            std.log.info("{x:0>4}: {x:0>2} ADD AR {} + {} = {}", .{ self.reg.pc - 1, ir, ar, tos, new_ar });
                        },
                    }
                },
                .pushcsr => {
                    read = 1;
                    stackop = .replace;
                    result = self.reg.readCsr(tos);
                    const csr: CsrNum = @enumFromInt(tos);
                    std.log.info("{x:0>4}: {x:0>2} PUSH {s} = {}", .{ self.reg.pc - 1, ir, @tagName(csr), result });
                },
                .popcsr => {
                    read = 2;
                    stackop = .pop2;
                    result = ros;
                    const csr: CsrNum = @enumFromInt(tos);
                    std.log.info("{x:0>4}: {x:0>2} POP {s} = {}", .{ self.reg.pc - 1, ir, @tagName(csr), nos });
                    self.reg.writeCsr(tos, nos);
                },
                .llw => {
                    read = 1;
                    stackop = .replace;
                    const addr = @addWithOverflow(self.reg.fp(), tos)[0];
                    if ((addr) & 1 == 1) {
                        std.log.err("Unaligned LLW from fp+{} = {x}", .{ tos, addr });
                        return Error.UnalignedAccess;
                    }
                    result = self.memory[addr >> 1];
                    std.log.info("{x:0>4}: {x:0>2} LLW from fp+{} = {}", .{ self.reg.pc - 1, ir, tos, result });
                },
                .slw => {
                    read = 2;
                    stackop = .pop2;
                    result = ros;
                    const addr = @addWithOverflow(self.reg.fp(), tos)[0];
                    std.log.info("{x:0>4}: {x:0>2} SLW to fp+{} = {}", .{ self.reg.pc - 1, ir, tos, nos });
                    if ((addr) & 1 == 1) {
                        std.log.err("Unaligned SLW from fp+{} = {x}", .{ tos, addr });
                        return Error.UnalignedAccess;
                    }
                    self.memory[addr >> 1] = nos;
                },
                .div => {
                    // TODO: this should always jump to macro vector; implement after exceptions are implemented
                    read = 2;
                    stackop = .replace;
                    const divisor: SWord = @bitCast(tos);
                    const dividend: SWord = @bitCast(nos);
                    std.log.info("{x:0>4}: {x:0>2} DIV {} / {}", .{ self.reg.pc - 1, ir, dividend, divisor });
                    if (divisor == 0) {
                        return Error.DivideByZero;
                    }
                    const quotient: SWord = @divTrunc(dividend, divisor);
                    const remainder: SWord = @rem(dividend, divisor);
                    result = @bitCast(remainder);
                    nos = @bitCast(quotient);
                },
                .divu => {
                    // TODO: this should always jump to macro vector; implement after exceptions are implemented
                    read = 2;
                    stackop = .replace;
                    const divisor: Word = @bitCast(tos);
                    const dividend: Word = @bitCast(nos);
                    std.log.info("{x:0>4}: {x:0>2} DIV {} / {}", .{ self.reg.pc - 1, ir, dividend, divisor });
                    if (divisor == 0) {
                        return Error.DivideByZero;
                    }
                    nos = @divTrunc(dividend, divisor);
                    result = dividend % divisor;
                },
                .mul => {
                    read = 2;
                    stackop = .replace;
                    const b: i32 = @intCast(tos);
                    const a: i32 = @intCast(nos);
                    const full_result: i32 = @mulWithOverflow(a, b)[0];
                    const unsigned_result: u32 = @bitCast(full_result);
                    result = @truncate(unsigned_result >> 16);
                    nos = @truncate(unsigned_result & WORDMASK);
                    std.log.info("{x:0>4}: {x:0>2} MUL {} * {} = {}, {}", .{ self.reg.pc - 1, ir, a, b, result, nos });
                },
                .rot => {
                    read = 3;
                    stackop = .rotate;
                    // a b c -> c a b (ros nos tos -> tos ros nos)
                    std.log.info("{x:0>4}: {x:0>2} ROT {} {} {}", .{ self.reg.pc - 1, ir, ros, nos, tos });
                },
                .srl => {
                    read = 2;
                    stackop = .pop1;
                    result = nos >> @truncate(tos & SHIFTMASK);
                    std.log.info("{x:0>4}: {x:0>2} SRL {} >> {} = {}", .{ self.reg.pc - 1, ir, nos, tos, result });
                },
                .sra => {
                    read = 2;
                    stackop = .pop1;
                    const value: SWord = @bitCast(nos);
                    const shifted: SWord = value >> @truncate(tos & SHIFTMASK);
                    result = @bitCast(shifted);
                    std.log.info("{x:0>4}: {x:0>2} SRA {} >> {} = {}", .{ self.reg.pc - 1, ir, value, tos, result });
                },
                .sll => {
                    read = 2;
                    stackop = .pop1;
                    result = nos << @truncate(tos & SHIFTMASK);
                    std.log.info("{x:0>4}: {x:0>2} SLL {} << {} = {}", .{ self.reg.pc - 1, ir, nos, tos, result });
                },
                .or_op => {
                    read = 2;
                    stackop = .pop1;
                    result = nos | tos;
                    std.log.info("{x:0>4}: {x:0>2} OR {} | {} = {}", .{ self.reg.pc - 1, ir, nos, tos, result });
                },
                .sub => {
                    read = 2;
                    stackop = .pop1;
                    result = @subWithOverflow(nos, tos)[0];
                    std.log.info("{x:0>4}: {x:0>2} SUB {} - {} = {}", .{ self.reg.pc - 1, ir, nos, tos, result });
                },
                .lb => {
                    read = 1;
                    stackop = .replace;
                    std.log.info("{x:0>4}: {x:0>2} LB from {x}", .{ self.reg.pc - 1, ir, tos });
                    const mem_byte: [*]u8 = @ptrCast(self.memory);
                    const byte = mem_byte[tos];
                    result = signExtend8(byte);
                },
                .sb => {
                    read = 2;
                    stackop = .pop2;
                    result = ros;
                    std.log.info("{x:0>4}: {x:0>2} SB to {x} = {}", .{ self.reg.pc - 1, ir, tos, nos });
                    const mem_byte: [*]u8 = @ptrCast(self.memory);
                    mem_byte[tos] = @truncate(nos & 0xff);
                },
                .lh, .lw => {
                    read = 1;
                    stackop = .replace;
                    std.log.info("{x:0>4}: {x:0>2} LW from {x}", .{ self.reg.pc - 1, ir, tos });
                    if ((tos & 1) == 1) {
                        std.log.err("Unaligned LW from {x}", .{tos});
                        return Error.UnalignedAccess;
                    }
                    result = self.memory[tos >> 1];
                },
                .sh, .sw => {
                    read = 2;
                    stackop = .pop2;
                    result = ros;
                    std.log.info("{x:0>4}: {x:0>2} SW to {x} = {}", .{ self.reg.pc - 1, ir, tos, nos });
                    if ((tos & 1) == 1) {
                        std.log.err("Unaligned SW to {x}", .{tos});
                        return Error.UnalignedAccess;
                    }
                    self.memory[tos >> 1] = nos;
                },
                .lnw => {
                    stackop = .push;
                    const addr = self.reg.ar;
                    std.log.info("{x:0>4}: {x:0>2} LNW from {x}", .{ self.reg.pc - 1, ir, addr });
                    if ((addr & 1) == 1) {
                        std.log.err("Unaligned LNW from {x}", .{addr});
                        return Error.UnalignedAccess;
                    }
                    self.reg.ar = @addWithOverflow(self.reg.ar, 2)[0];
                    result = self.memory[addr >> 1];
                },
                .snw => {
                    read = 1;
                    stackop = .pop1;
                    result = nos;
                    const addr = self.reg.ar;
                    std.log.info("{x:0>4}: {x:0>2} SNW to {x} = {}", .{ self.reg.pc - 1, ir, addr, tos });
                    if ((addr & 1) == 1) {
                        std.log.err("Unaligned SNW to {x}", .{addr});
                        return Error.UnalignedAccess;
                    }
                    self.reg.ar = @addWithOverflow(self.reg.ar, 2)[0];
                    self.memory[addr >> 1] = tos;
                },
                .call => {
                    read = 1;
                    stackop = .pop1;
                    result = nos;
                    std.log.info("{x:0>4}: {x:0>2} CALL to {x}, return address {x}", .{ self.reg.pc - 1, ir, self.reg.pc + tos, self.reg.pc });
                    self.reg.ra = self.reg.pc;
                    self.reg.pc = @addWithOverflow(self.reg.pc, tos)[0];
                },
                .callp => {
                    read = 1;
                    stackop = .pop1;
                    result = nos;
                    std.log.info("{x:0>4}: {x:0>2} CALLP to {x}, return address {x}", .{ self.reg.pc - 1, ir, tos, self.reg.pc });
                    self.reg.ra = self.reg.pc;
                    self.reg.pc = tos;
                },
                else => {
                    std.log.err("Illegal instruction: {x}", .{ir});
                    return Error.IllegalInstruction;
                },
            }

            // check stack underflow
            if (@subWithOverflow(self.reg.depth, read)[1] == 1) {
                return Error.StackUnderflow;
            }

            // update stack
            switch (stackop) {
                .replace => {
                    tos = result;
                },
                .push => {
                    if (self.inKernel()) {
                        if ((self.reg.depth + 1) >= KERNEL_HIGH_WATER) {
                            return Error.StackOverflow;
                        }
                    } else {
                        if ((self.reg.depth + 1) >= USER_HIGH_WATER) {
                            return Error.StackOverflow;
                        }
                    }

                    self.stack[@subWithOverflow(self.reg.depth, 3)[0] & STACK_MASK] = ros;
                    self.reg.depth += 1;

                    ros = nos;
                    nos = tos;
                    tos = result;
                },
                .pop1 => {
                    self.reg.depth -= 1;
                    tos = result;
                    nos = ros;
                    ros = self.stack[@subWithOverflow(self.reg.depth, 3)[0] & STACK_MASK];
                },
                .pop2 => {
                    self.reg.depth -= 2;
                    tos = result;
                    nos = self.stack[@subWithOverflow(self.reg.depth, 2)[0] & STACK_MASK];
                    ros = self.stack[@subWithOverflow(self.reg.depth, 3)[0] & STACK_MASK];
                },
                .swap => {
                    const temp = tos;
                    tos = nos;
                    nos = temp;
                },
                .rotate => {
                    // a b c -> c a b (ros tos nos -> tos ros nos)
                    const temp = tos;
                    tos = nos;
                    nos = ros;
                    ros = temp;
                },
                .none => {},
            }
        }

        self.stack[@subWithOverflow(self.reg.depth, 1)[0] & STACK_MASK] = tos;
        self.stack[@subWithOverflow(self.reg.depth, 2)[0] & STACK_MASK] = nos;
        self.stack[@subWithOverflow(self.reg.depth, 3)[0] & STACK_MASK] = ros;

        return cycle;
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

    const start = try std.time.Instant.now();
    const cycles = try cpu.run(max_cycles);
    const elapsed = (try std.time.Instant.now()).since(start);
    const cycles_per_sec = if (elapsed > 0)
        @as(f64, @floatFromInt(cycles)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0)
    else
        0.0;
    std.debug.print("Execution completed in {d} cycles, elapsed time: {d} ms, {d:.2} cycles/sec\n", .{
        cycles,
        elapsed / 1_000_000,
        cycles_per_sec,
    });

    return try cpu.pop();
}

/// Helper function for tests to run a ROM and return the top of stack value, checking the depth is 1
pub fn runTest(rom_file: []const u8, max_cycles: usize, gpa: std.mem.Allocator) !Word {
    const memory = try gpa.alloc(u16, 128 * 1024);
    defer gpa.free(memory);

    var cpu = Cpu.init(memory);
    try cpu.loadRom(rom_file);
    _ = try cpu.run(max_cycles);

    if (cpu.reg.depth != 1) {
        std.log.err("Expected exactly one value on stack after execution, found {}", .{cpu.reg.depth});
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

// TODO: won't pass until exceptions are implemented
// test "bootstrap div instructions" {
//     const value = try runTest("starj/tests/bootstrap/boot_14_div.bin", 200, std.testing.allocator);
//     try std.testing.expect(value == 1);
// }

// TODO: won't pass until exceptions are implemented
// test "bootstrap divu instructions" {
//     const value = try runTest("starj/tests/bootstrap/boot_15_divu.bin", 200, std.testing.allocator);
//     try std.testing.expect(value == 1);
// }

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

test "drop instructions" {
    const value = try runTest("starj/tests/drop.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "dup instructions" {
    const value = try runTest("starj/tests/dup.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "fsl instructions" {
    const value = try runTest("starj/tests/fsl.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "llw slw instructions" {
    const value = try runTest("starj/tests/llw_slw.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "lw sw instructions" {
    const value = try runTest("starj/tests/lw_sw.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "lh sh instructions" {
    const value = try runTest("starj/tests/lh_sh.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "lb sb instructions" {
    const value = try runTest("starj/tests/lb_sb.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "lnw snw instructions" {
    const value = try runTest("starj/tests/lnw_snw.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "lt instruction" {
    const value = try runTest("starj/tests/lt.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "ltu instruction" {
    const value = try runTest("starj/tests/ltu.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "mul instruction" {
    const value = try runTest("starj/tests/mul.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "or instruction" {
    const value = try runTest("starj/tests/or.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "over instruction" {
    const value = try runTest("starj/tests/over.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "push/pop <reg> instructions" {
    const value = try runTest("starj/tests/push_pop_reg.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "rot instruction" {
    const value = try runTest("starj/tests/rot.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "shi instruction" {
    const value = try runTest("starj/tests/shi.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "sll instruction" {
    const value = try runTest("starj/tests/sll.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "srl instruction" {
    const value = try runTest("starj/tests/srl.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "sra instruction" {
    const value = try runTest("starj/tests/sra.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "sub instruction" {
    const value = try runTest("starj/tests/sub.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "xor instruction" {
    const value = try runTest("starj/tests/xor.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "call deep instruction" {
    const value = try runTest("starj/tests/call_deep.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}
