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
pub const RegNum = types.RegNum;
pub const CsrNum = types.CsrNum;
pub const Regs = types.Regs;
pub const CpuState = types.CpuState;
pub const Opcode = common.opcode.Opcode;

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

const signExtend6 = utils.signExtend6;
const signExtend8 = utils.signExtend8;
const signExtend16 = utils.signExtend16;

pub const Error = error{
    StackOverflow,
    StackUnderflow,
    IllegalInstruction,
    DivideByZero,
    UnalignedAccess,
    Halt,
};

fn runForCycles(cpu: *CpuState, cycles: usize) !usize {
    const progMem: [*]u8 = @ptrCast(cpu.memory);
    var cycle: usize = 0;

    var tos = cpu.stack[@subWithOverflow(cpu.reg.depth, 1)[0] & STACK_MASK];
    var nos = cpu.stack[@subWithOverflow(cpu.reg.depth, 2)[0] & STACK_MASK];
    var ros = cpu.stack[@subWithOverflow(cpu.reg.depth, 3)[0] & STACK_MASK];

    loop: while (cycle < cycles) : (cycle += 1) {
        // fetch
        const ir = progMem[cpu.reg.pc];
        cpu.reg.pc += 1;

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

                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} SHI {} -> {} ({x:0>4})\n", .{ cpu.reg.pc - 1, ir, value, @as(SWord, @bitCast(result)), result });
                }
            },
            .push => {
                stackop = .push;
                result = signExtend6(@truncate(ir & 0x3f));
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} PUSH {}\n", .{ cpu.reg.pc - 1, ir, @as(SWord, @bitCast(result)) });
                }
            },
            .halt => {
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} HALT {} ({x:0>4})\n", .{ cpu.reg.pc - 1, ir, @as(SWord, @bitCast(tos)), tos });
                }
                if (!cpu.reg.status.th) {
                    cpu.halted = true;
                    break :loop;
                }
                return Error.Halt;
            },
            .callp => {
                read = 1;
                stackop = .pop1;
                result = nos;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} CALLP to {x}, return address {x}\n", .{ cpu.reg.pc - 1, ir, tos, cpu.reg.pc });
                }
                cpu.reg.rx = cpu.reg.pc;
                cpu.reg.pc = tos;
            },
            .beqz => {
                read = 2;
                stackop = .pop2;
                result = ros;
                if (nos == 0) {
                    if (cpu.log_enabled) {
                        std.debug.print("{x:0>4}: {x:0>2} BEQZ {}, {} taken\n", .{ cpu.reg.pc - 1, ir, @as(SWord, @bitCast(nos)), @as(SWord, @bitCast(tos)) });
                    }
                    cpu.reg.pc = @addWithOverflow(cpu.reg.pc, tos)[0];
                } else {
                    if (cpu.log_enabled) {
                        std.debug.print("{x:0>4}: {x:0>2} BEQZ {}, {} not taken\n", .{ cpu.reg.pc - 1, ir, @as(SWord, @bitCast(nos)), @as(SWord, @bitCast(tos)) });
                    }
                }
            },
            .bnez => {
                read = 2;
                stackop = .pop2;
                result = ros;
                if (nos != 0) {
                    if (cpu.log_enabled) {
                        std.debug.print("{x:0>4}: {x:0>2} BNEZ {}, {} taken\n", .{ cpu.reg.pc - 1, ir, @as(SWord, @bitCast(nos)), @as(SWord, @bitCast(tos)) });
                    }
                    cpu.reg.pc = @addWithOverflow(cpu.reg.pc, tos)[0];
                } else {
                    if (cpu.log_enabled) {
                        std.debug.print("{x:0>4}: {x:0>2} BNEZ {}, {} not taken\n", .{ cpu.reg.pc - 1, ir, @as(SWord, @bitCast(nos)), @as(SWord, @bitCast(tos)) });
                    }
                }
            },
            .swap => {
                read = 2;
                stackop = .swap;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} SWAP {} <-> {}\n", .{ cpu.reg.pc - 1, ir, tos, nos });
                }
            },
            .over => {
                read = 2;
                result = nos;
                stackop = .push;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} OVER {}\n", .{ cpu.reg.pc - 1, ir, nos });
                }
            },
            .drop => {
                read = 1;
                stackop = .pop1;
                result = nos;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} DROP {}\n", .{ cpu.reg.pc - 1, ir, tos });
                }
            },
            .dup => {
                read = 1;
                result = tos;
                stackop = .push;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} DUP {}\n", .{ cpu.reg.pc - 1, ir, tos });
                }
            },
            .ltu => {
                read = 2;
                stackop = .pop1;
                result = if (nos < tos) 1 else 0;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} LTU {} < {} = {}\n", .{ cpu.reg.pc - 1, ir, nos, tos, result });
                }
            },
            .lt => {
                read = 2;
                stackop = .pop1;
                const b: SWord = @bitCast(tos);
                const a: SWord = @bitCast(nos);
                result = if (a < b) 1 else 0;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} LT {} < {} = {}\n", .{ cpu.reg.pc - 1, ir, a, b, result });
                }
            },
            .add => {
                read = 2;
                stackop = .pop1;
                result = @addWithOverflow(nos, tos)[0];
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} ADD {} + {} = {}\n", .{ cpu.reg.pc - 1, ir, nos, tos, result });
                }
            },
            .and_op => {
                read = 2;
                stackop = .pop1;
                result = nos & tos;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} AND {} & {} = {}\n", .{ cpu.reg.pc - 1, ir, nos, tos, result });
                }
            },
            .xor_op => {
                read = 2;
                stackop = .pop1;
                result = nos ^ tos;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} XOR {} ^ {} = {}\n", .{ cpu.reg.pc - 1, ir, nos, tos, result });
                }
            },
            .fsl => {
                read = 3;
                stackop = .pop2;
                // stack: ros=upper, nos=lower, tos=shift
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} FSL ({x} @ {x} << {}) >> 16\n", .{ cpu.reg.pc - 1, ir, ros, nos, tos });
                }
                const value: u32 = (@as(u32, ros) << 16) | @as(u32, nos);
                const shifted = value << @truncate(tos & 0x1f);
                result = @as(Word, @truncate(shifted >> 16));
            },
            .rel_pc, .rel_fp, .rel_rx, .rel_ry => {
                stackop = .replace;
                const reg: RegNum = @enumFromInt(ir & 3);
                switch (reg) {
                    .pc => result = tos + cpu.reg.pc,
                    .fp => result = tos + cpu.reg.fp(),
                    .rx => result = tos + cpu.reg.rx,
                    .ry => result = tos + cpu.reg.ry,
                }
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} REL {s} = {}\n", .{ cpu.reg.pc - 1, ir, @tagName(reg), result });
                }
            },
            .pop_pc, .pop_fp, .pop_rx, .pop_ry => {
                read = 1;
                stackop = .pop1;
                result = nos;
                const reg: RegNum = @enumFromInt(ir & 3);
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} POP {s} = {}\n", .{ cpu.reg.pc - 1, ir, @tagName(reg), tos });
                }
                switch (reg) {
                    .pc => cpu.reg.pc = tos,
                    .fp => cpu.reg.setFp(tos),
                    .rx => cpu.reg.rx = tos,
                    .ry => cpu.reg.ry = tos,
                }
            },
            .jump, .add_fp, .add_rx, .add_ry => { // ADD <reg> / JUMP
                read = 1;
                stackop = .pop1;
                result = nos;
                const reg: RegNum = @enumFromInt(ir & 3);
                switch (reg) {
                    .pc => { // JUMP
                        const dest = @addWithOverflow(cpu.reg.pc, tos)[0];
                        if (cpu.log_enabled) {
                            std.debug.print("{x:0>4}: {x:0>2} JUMP {} to {x:0>4}\n", .{ cpu.reg.pc - 1, ir, @as(SWord, @bitCast(tos)), dest });
                        }
                        cpu.reg.pc = dest;
                    },
                    .fp => { // ADD FP
                        const fp = cpu.reg.fp();
                        const new_fp = @addWithOverflow(fp, tos)[0];
                        cpu.reg.setFp(new_fp);
                        if (cpu.log_enabled) {
                            std.debug.print("{x:0>4}: {x:0>2} ADD FP {} + {} = {}\n", .{ cpu.reg.pc - 1, ir, fp, tos, new_fp });
                        }
                    },
                    .rx => { // ADD RX
                        const rx = cpu.reg.rx;
                        const new_rx = @addWithOverflow(rx, tos)[0];
                        cpu.reg.rx = new_rx;
                        if (cpu.log_enabled) {
                            std.debug.print("{x:0>4}: {x:0>2} ADD RX {} + {} = {}\n", .{ cpu.reg.pc - 1, ir, rx, tos, new_rx });
                        }
                    },
                    .ry => { // ADD RY
                        const ry = cpu.reg.ry;
                        const new_ry = @addWithOverflow(ry, tos)[0];
                        cpu.reg.ry = new_ry;
                        if (cpu.log_enabled) {
                            std.debug.print("{x:0>4}: {x:0>2} ADD RY {} + {} = {}\n", .{ cpu.reg.pc - 1, ir, ry, tos, new_ry });
                        }
                    },
                }
            },
            .pushcsr => {
                read = 1;
                stackop = .replace;
                result = cpu.reg.readCsr(tos);
                const csr: CsrNum = @enumFromInt(tos);
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} PUSH {s} = {}\n", .{ cpu.reg.pc - 1, ir, @tagName(csr), result });
                }
            },
            .popcsr => {
                read = 2;
                stackop = .pop2;
                result = ros;
                const csr: CsrNum = @enumFromInt(tos);
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} POP {s} = {}\n", .{ cpu.reg.pc - 1, ir, @tagName(csr), nos });
                }
                cpu.reg.writeCsr(tos, nos);
            },
            .lw => {
                read = 1;
                stackop = .replace;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} LW from {x}\n", .{ cpu.reg.pc - 1, ir, tos });
                }
                if ((tos & (WORDBYTES-1)) != 0) {
                    std.log.err("Unaligned LW from {x}", .{tos});
                    return Error.UnalignedAccess;
                }
                result = cpu.readWord(tos);
            },
            .sw => {
                read = 2;
                stackop = .pop2;
                result = ros;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} SW to {x} = {}\n", .{ cpu.reg.pc - 1, ir, tos, nos });
                }
                if ((tos & (WORDBYTES-1)) != 0) {
                    std.log.err("Unaligned SW to {x}", .{tos});
                    return Error.UnalignedAccess;
                }
                cpu.writeWord(tos, nos);
            },
            .div => {
                // TODO: this should always jump to macro vector; implement after exceptions are implemented
                read = 2;
                stackop = .replace;
                const divisor: SWord = @bitCast(tos);
                const dividend: SWord = @bitCast(nos);
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} DIV {} / {}\n", .{ cpu.reg.pc - 1, ir, dividend, divisor });
                }
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
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} DIV {} / {}\n", .{ cpu.reg.pc - 1, ir, dividend, divisor });
                }
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
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} MUL {} * {} = {}, {}\n", .{ cpu.reg.pc - 1, ir, a, b, result, nos });
                }
            },
            .rot => {
                read = 3;
                stackop = .rotate;
                // a b c -> c a b (ros nos tos -> tos ros nos)
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} ROT {} {} {}\n", .{ cpu.reg.pc - 1, ir, ros, nos, tos });
                }
            },
            .srl => {
                read = 2;
                stackop = .pop1;
                result = nos >> @truncate(tos & SHIFTMASK);
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} SRL {} >> {} = {}\n", .{ cpu.reg.pc - 1, ir, nos, tos, result });
                }
            },
            .sra => {
                read = 2;
                stackop = .pop1;
                const value: SWord = @bitCast(nos);
                const shifted: SWord = value >> @truncate(tos & SHIFTMASK);
                result = @bitCast(shifted);
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} SRA {} >> {} = {}\n", .{ cpu.reg.pc - 1, ir, value, tos, result });
                }
            },
            .sll => {
                read = 2;
                stackop = .pop1;
                result = nos << @truncate(tos & SHIFTMASK);
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} SLL {} << {} = {}\n", .{ cpu.reg.pc - 1, ir, nos, tos, result });
                }
            },
            .or_op => {
                read = 2;
                stackop = .pop1;
                result = nos | tos;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} OR {} | {} = {}\n", .{ cpu.reg.pc - 1, ir, nos, tos, result });
                }
            },
            .sub => {
                read = 2;
                stackop = .pop1;
                result = @subWithOverflow(nos, tos)[0];
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} SUB {} - {} = {}\n", .{ cpu.reg.pc - 1, ir, nos, tos, result });
                }
            },
            .clz => {
                read = 1;
                stackop = .replace;
                result = @as(Word, @clz(tos));
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} CLZ {} = {}\n", .{ cpu.reg.pc - 1, ir, tos, result });
                }
            },
            .lb => {
                read = 1;
                stackop = .replace;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} LB from {x}\n", .{ cpu.reg.pc - 1, ir, tos });
                }
                result = signExtend8(cpu.readByte(tos));
            },
            .sb => {
                read = 2;
                stackop = .pop2;
                result = ros;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} SB to {x} = {}\n", .{ cpu.reg.pc - 1, ir, tos, nos });
                }
                cpu.writeByte(tos, @truncate(nos & 0xff));
            },
            .lh => {
                read = 1;
                stackop = .replace;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} LH from {x}\n", .{ cpu.reg.pc - 1, ir, tos });
                }
                if ((tos & ((WORDBYTES/2)-1)) != 0) {
                    std.log.err("Unaligned LW from {x}", .{tos});
                    return Error.UnalignedAccess;
                }
                result = cpu.readHalf(tos);
            },
            .sh => {
                read = 2;
                stackop = .pop2;
                result = ros;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} SH to {x} = {}\n", .{ cpu.reg.pc - 1, ir, tos, nos });
                }
                if ((tos & ((WORDBYTES/2)-1)) != 0) {
                    std.log.err("Unaligned SH to {x}", .{tos});
                    return Error.UnalignedAccess;
                }
                cpu.writeHalf(tos, nos);
            },
            .lnw => {
                stackop = .push;
                const addr = cpu.reg.ry;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} LNW from {x}\n", .{ cpu.reg.pc - 1, ir, addr });
                }
                if ((addr & (WORDBYTES-1)) != 0) {
                    std.log.err("Unaligned LNW from {x}", .{addr});
                    return Error.UnalignedAccess;
                }
                cpu.reg.ry = @addWithOverflow(cpu.reg.ry, 2)[0];
                result = cpu.readWord(addr);
            },
            .snw => {
                read = 1;
                stackop = .pop1;
                result = nos;
                const addr = cpu.reg.ry;
                if (cpu.log_enabled) {
                    std.debug.print("{x:0>4}: {x:0>2} SNW to {x} = {}\n", .{ cpu.reg.pc - 1, ir, addr, tos });
                }
                if ((addr & (WORDBYTES-1)) != 0) {
                    std.log.err("Unaligned SNW to {x}", .{addr});
                    return Error.UnalignedAccess;
                }
                cpu.reg.ry = @addWithOverflow(cpu.reg.ry, 2)[0];
                cpu.writeWord(addr, tos);
            },
            else => {
                std.log.err("Illegal instruction: {x}", .{ir});
                return Error.IllegalInstruction;
            },
        }

        // check stack underflow
        if (@subWithOverflow(cpu.reg.depth, read)[1] == 1) {
            return Error.StackUnderflow;
        }

        // update stack
        switch (stackop) {
            .replace => {
                tos = result;
            },
            .push => {
                if (cpu.inKernel()) {
                    if ((cpu.reg.depth + 1) >= KERNEL_HIGH_WATER) {
                        return Error.StackOverflow;
                    }
                } else {
                    if ((cpu.reg.depth + 1) >= USER_HIGH_WATER) {
                        return Error.StackOverflow;
                    }
                }

                cpu.stack[@subWithOverflow(cpu.reg.depth, 3)[0] & STACK_MASK] = ros;
                cpu.reg.depth += 1;

                ros = nos;
                nos = tos;
                tos = result;
            },
            .pop1 => {
                cpu.reg.depth -= 1;
                tos = result;
                nos = ros;
                ros = cpu.stack[@subWithOverflow(cpu.reg.depth, 3)[0] & STACK_MASK];
            },
            .pop2 => {
                cpu.reg.depth -= 2;
                tos = result;
                nos = cpu.stack[@subWithOverflow(cpu.reg.depth, 2)[0] & STACK_MASK];
                ros = cpu.stack[@subWithOverflow(cpu.reg.depth, 3)[0] & STACK_MASK];
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

    cpu.reg.tos = tos;
    cpu.reg.nos = nos;
    cpu.reg.ros = ros;

    cpu.stack[@subWithOverflow(cpu.reg.depth, 1)[0] & STACK_MASK] = tos;
    cpu.stack[@subWithOverflow(cpu.reg.depth, 2)[0] & STACK_MASK] = nos;
    cpu.stack[@subWithOverflow(cpu.reg.depth, 3)[0] & STACK_MASK] = ros;

    cpu.cycles += cycles;

    return cycle;
}

pub fn run(rom_file: []const u8, max_cycles: usize, quiet: bool, gpa: std.mem.Allocator) !Word {
    const memory = try gpa.alloc(u16, 128 * 1024);
    defer gpa.free(memory);

    var cpu = CpuState.init(memory);
    cpu.log_enabled = !quiet;
    try cpu.loadRom(rom_file);

    const start = try std.time.Instant.now();
    const cycles = try runForCycles(&cpu, max_cycles);
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

    return cpu.reg.tos;
}

/// Helper function for tests to run a ROM and return the top of stack value, checking the depth is 1
pub fn runTest(rom_file: []const u8, max_cycles: usize, gpa: std.mem.Allocator) !Word {
    const memory = try gpa.alloc(u16, 128 * 1024);
    defer gpa.free(memory);

    var cpu = CpuState.init(memory);
    cpu.log_enabled = false;
    try cpu.loadRom(rom_file);
    _ = try runForCycles(&cpu, max_cycles);

    if (cpu.reg.depth != 1) {
        std.log.err("Expected exactly one value on stack after execution, found {}", .{cpu.reg.depth});
        return Error.StackUnderflow;
    }

    return cpu.reg.tos;
}

///////////////////////////////////////////////////////
// Bootstrap tests
///////////////////////////////////////////////////////

test "bootstrap push instruction" {
    const value = try runTest("starjette/tests/bootstrap/boot_00_push.bin", 10, std.testing.allocator);
    try std.testing.expect(value == 7);
}

test "bootstrap shi instruction" {
    const value = try runTest("starjette/tests/bootstrap/boot_01_push_shi.bin", 10, std.testing.allocator);
    try std.testing.expect(value == 0xABCD);
}

test "bootstrap xor instruction" {
    const value = try runTest("starjette/tests/bootstrap/boot_02_xor.bin", 10, std.testing.allocator);
    try std.testing.expect(value == 2);
}

test "bootstrap bnez not taken instruction" {
    const value = try runTest("starjette/tests/bootstrap/boot_03_bnez_not_taken.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 99);
}

test "bootstrap bnez taken instruction" {
    const value = try runTest("starjette/tests/bootstrap/boot_04_bnez_taken.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 99);
}

test "bootstrap add instruction" {
    const value = try runTest("starjette/tests/bootstrap/boot_05_add.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 0xFF);
}

test "bootstrap beqz instruction" {
    const value = try runTest("starjette/tests/bootstrap/boot_06_beqz.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 99);
}

test "bootstrap halt instruction" {
    const value = try runTest("starjette/tests/bootstrap/boot_08_halt.bin", 20, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "bootstrap jump instruction" {
    const value = try runTest("starjette/tests/bootstrap/boot_09_jump.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 9);
}

test "bootstrap push/pop fp instruction" {
    const value = try runTest("starjette/tests/bootstrap/boot_10_push_pop_fp.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 5);
}

test "bootstrap push/pop afp instruction" {
    const value = try runTest("starjette/tests/bootstrap/boot_11_push_pop_afp.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 5);
}

test "bootstrap push/pop evec instruction" {
    const value = try runTest("starjette/tests/bootstrap/boot_12_push_pop_evec.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 5);
}

test "bootstrap push/pop ecause instruction" {
    const value = try runTest("starjette/tests/bootstrap/boot_13_push_pop_ecause.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 5);
}

// TODO: won't pass until exceptions are implemented
// test "bootstrap div instructions" {
//     const value = try runTest("starjette/tests/bootstrap/boot_14_div.bin", 200, std.testing.allocator);
//     try std.testing.expect(value == 1);
// }

// TODO: won't pass until exceptions are implemented
// test "bootstrap divu instructions" {
//     const value = try runTest("starjette/tests/bootstrap/boot_15_divu.bin", 200, std.testing.allocator);
//     try std.testing.expect(value == 1);
// }

///////////////////////////////////////////////////////
// Regular instruction tests
///////////////////////////////////////////////////////

test "add instruction" {
    const value = try runTest("starjette/tests/add.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "swap instruction" {
    const value = try runTest("starjette/tests/swap.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "add <reg> instruction" {
    const value = try runTest("starjette/tests/add_reg.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "and instruction" {
    const value = try runTest("starjette/tests/and.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "beqz instruction" {
    const value = try runTest("starjette/tests/beqz.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "bnez instruction" {
    const value = try runTest("starjette/tests/bnez.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "call/ret instructions" {
    const value = try runTest("starjette/tests/call_ret.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "callp instructions" {
    const value = try runTest("starjette/tests/callp.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "clz instruction" {
    const value = try runTest("starjette/tests/clz.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "drop instructions" {
    const value = try runTest("starjette/tests/drop.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "dup instructions" {
    const value = try runTest("starjette/tests/dup.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "fsl instructions" {
    const value = try runTest("starjette/tests/fsl.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "llw slw instructions" {
    const value = try runTest("starjette/tests/llw_slw.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "lw sw instructions" {
    const value = try runTest("starjette/tests/lw_sw.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "lh sh instructions" {
    const value = try runTest("starjette/tests/lh_sh.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "lb sb instructions" {
    const value = try runTest("starjette/tests/lb_sb.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "lnw snw instructions" {
    const value = try runTest("starjette/tests/lnw_snw.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "lt instruction" {
    const value = try runTest("starjette/tests/lt.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "ltu instruction" {
    const value = try runTest("starjette/tests/ltu.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "mul instruction" {
    const value = try runTest("starjette/tests/mul.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "or instruction" {
    const value = try runTest("starjette/tests/or.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "over instruction" {
    const value = try runTest("starjette/tests/over.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "push/pop <reg> instructions" {
    const value = try runTest("starjette/tests/push_pop_reg.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "rot instruction" {
    const value = try runTest("starjette/tests/rot.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "shi instruction" {
    const value = try runTest("starjette/tests/shi.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "sll instruction" {
    const value = try runTest("starjette/tests/sll.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "srl instruction" {
    const value = try runTest("starjette/tests/srl.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "sra instruction" {
    const value = try runTest("starjette/tests/sra.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "sub instruction" {
    const value = try runTest("starjette/tests/sub.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "xor instruction" {
    const value = try runTest("starjette/tests/xor.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "call deep instruction" {
    const value = try runTest("starjette/tests/call_deep.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}
