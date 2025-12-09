const std = @import("std");

pub const WORDSIZE: comptime_int = 16;

pub const Word = if (WORDSIZE == 16) u16 else u32;
pub const SWord = if (WORDSIZE == 16) i16 else i32;

pub const WORDBYTES: comptime_int = WORDSIZE / 2;
pub const WORDMASK: comptime_int = (1 << WORDSIZE) - 1;

const STACK_SIZE: comptime_int = 1024;
const STACK_MASK: comptime_int = STACK_SIZE - 1;
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

pub const Opcode = enum(u8) {
    HALT = 0x00,
    BEQZ = 0x04,
    BNEZ = 0x05,
    SWAP = 0x06,
    OVER = 0x07,
    DROP = 0x08,
    DUP = 0x09,
    LTU = 0x0a,
    LT = 0x0b,
    ADD = 0x0c,
    AND = 0x0d,
    XOR = 0x0e,
    FSL = 0x0f,
    PUSH_PC = 0x10,
    PUSH_FP = 0x11,
    PUSH_RA = 0x12,
    PUSH_AR = 0x13,
    POP_PC = 0x14,
    POP_FP = 0x15,
    POP_RA = 0x16,
    POP_AR = 0x17,
    ADD_PC = 0x18,
    ADD_FP = 0x19,
    ADD_RA = 0x1a,
    ADD_AR = 0x1b,
    PUSH_CSR = 0x1c,
    POP_CSR = 0x1d,
    LLW = 0x1e,
    SLW = 0x1f,
    DIV = 0x20,
    DIVU = 0x21,
    MOD = 0x22,
    MODU = 0x23,
    MUL = 0x24,
    MULH = 0x25,
    SELECT = 0x26,
    ROT = 0x27,
    SRL = 0x28,
    SRA = 0x29,
    SLL = 0x2a,
    OR = 0x2b,
    SUB = 0x2c,
    LB = 0x30,
    SB = 0x31,
    LH = 0x32,
    SH = 0x33,
    LW = 0x34,
    SW = 0x35,
    LNW = 0x36,
    SNW = 0x37,
    CALL = 0x38,
    CALLP = 0x39,
    PUSH = 0x40,
    SHI = 0x80,
    _,
};

pub const RegNum = enum(u2) {
    PC = 0,
    FP = 1,
    RA = 2,
    AR = 3,
};

pub const CsrNum = enum(u3) {
    AFP = 3,
    ECAUSE = 5,
    EVEC = 6,
    _,
};

pub const StackOp = enum {
    NONE,
    REPLACE,
    PUSH,
    POP1,
    POP2,
    SWAP,
    ROT,
};

pub const Cpu = struct {
    reg: Registers = .{},
    csr: Csrs = .{},
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

        var tos = self.stack[@subWithOverflow(self.csr.depth, 1)[0] & STACK_MASK];
        var nos = self.stack[@subWithOverflow(self.csr.depth, 2)[0] & STACK_MASK];
        var ros = self.stack[@subWithOverflow(self.csr.depth, 3)[0] & STACK_MASK];

        loop: while (cycle < cycles) : (cycle += 1) {
            // fetch
            const ir = progMem[self.reg.pc];
            self.reg.pc += 1;

            // decode
            const opcode: Opcode = blk: {
                const shi = (ir & 0x80) != 0;
                const psh = (ir & 0xc0) == 0x40;
                break :blk if (shi) .SHI else if (psh) .PUSH else @enumFromInt(ir & 0x3f);
            };

            // execute
            var result: Word = 0;
            var read: u2 = 0;
            var stackop = StackOp.NONE;
            switch (opcode) {
                .SHI => {
                    const value = ir & 0x7f;
                    result = (tos << 7) | value;
                    read = 1;
                    stackop = .REPLACE;

                    std.log.info("{x:0>4}: {x:0>2} SHI {} -> {} ({x:0>4})", .{ self.reg.pc - 1, ir, value, @as(SWord, @bitCast(result)), result });
                },
                .PUSH => {
                    stackop = .PUSH;
                    result = signExtend(ir & 0x3f, 6);
                    std.log.info("{x:0>4}: {x:0>2} PUSH {}", .{ self.reg.pc - 1, ir, @as(SWord, @bitCast(result)) });
                },
                .HALT => {
                    std.log.info("{x:0>4}: {x:0>2} HALT {} ({x:0>4})", .{ self.reg.pc - 1, ir, @as(SWord, @bitCast(tos)), tos });
                    if (self.csr.status & StatusFlags.TH == 0) {
                        break :loop;
                    }
                    return Error.Halt;
                },
                .BEQZ => {
                    read = 2;
                    stackop = .POP2;
                    result = ros;
                    if (nos == 0) {
                        std.log.info("{x:0>4}: {x:0>2} BEQZ {}, {} taken", .{ self.reg.pc - 1, ir, @as(SWord, @bitCast(nos)), @as(SWord, @bitCast(tos)) });
                        self.reg.pc = @addWithOverflow(self.reg.pc, tos)[0];
                    } else {
                        std.log.info("{x:0>4}: {x:0>2} BEQZ {}, {} not taken", .{ self.reg.pc - 1, ir, @as(SWord, @bitCast(nos)), @as(SWord, @bitCast(tos)) });
                    }
                },
                .BNEZ => {
                    read = 2;
                    stackop = .POP2;
                    result = ros;
                    if (nos != 0) {
                        std.log.info("{x:0>4}: {x:0>2} BNEZ {}, {} taken", .{ self.reg.pc - 1, ir, @as(SWord, @bitCast(nos)), @as(SWord, @bitCast(tos)) });
                        self.reg.pc = @addWithOverflow(self.reg.pc, tos)[0];
                    } else {
                        std.log.info("{x:0>4}: {x:0>2} BNEZ {}, {} not taken", .{ self.reg.pc - 1, ir, @as(SWord, @bitCast(nos)), @as(SWord, @bitCast(tos)) });
                    }
                },
                .SWAP => {
                    read = 2;
                    stackop = .SWAP;
                    std.log.info("{x:0>4}: {x:0>2} SWAP {} <-> {}", .{ self.reg.pc - 1, ir, tos, nos });
                },
                .OVER => {
                    read = 2;
                    result = nos;
                    stackop = .PUSH;
                    std.log.info("{x:0>4}: {x:0>2} OVER {}", .{ self.reg.pc - 1, ir, nos });
                },
                .DROP => {
                    read = 1;
                    stackop = .POP1;
                    result = nos;
                    std.log.info("{x:0>4}: {x:0>2} DROP {}", .{ self.reg.pc - 1, ir, tos });
                },
                .DUP => {
                    read = 1;
                    result = tos;
                    stackop = .PUSH;
                    std.log.info("{x:0>4}: {x:0>2} DUP {}", .{ self.reg.pc - 1, ir, tos });
                },
                .LTU => {
                    read = 2;
                    stackop = .POP1;
                    result = if (nos < tos) 1 else 0;
                    std.log.info("{x:0>4}: {x:0>2} LTU {} < {} = {}", .{ self.reg.pc - 1, ir, nos, tos, result });
                },
                .LT => {
                    read = 2;
                    stackop = .POP1;
                    const b: SWord = @bitCast(tos);
                    const a: SWord = @bitCast(nos);
                    result = if (a < b) 1 else 0;
                    std.log.info("{x:0>4}: {x:0>2} LT {} < {} = {}", .{ self.reg.pc - 1, ir, a, b, result });
                },
                .ADD => {
                    read = 2;
                    stackop = .POP1;
                    result = @addWithOverflow(nos, tos)[0];
                    std.log.info("{x:0>4}: {x:0>2} ADD {} + {} = {}", .{ self.reg.pc - 1, ir, nos, tos, result });
                },
                .AND => {
                    read = 2;
                    stackop = .POP1;
                    result = nos & tos;
                    std.log.info("{x:0>4}: {x:0>2} AND {} & {} = {}", .{ self.reg.pc - 1, ir, nos, tos, result });
                },
                .XOR => {
                    read = 2;
                    stackop = .POP1;
                    result = nos ^ tos;
                    std.log.info("{x:0>4}: {x:0>2} XOR {} ^ {} = {}", .{ self.reg.pc - 1, ir, nos, tos, result });
                },
                .FSL => {
                    read = 3;
                    stackop = .POP2;
                    // stack: ros=upper, nos=lower, tos=shift
                    std.log.info("{x:0>4}: {x:0>2} FSL ({x} @ {x} << {}) >> 16", .{ self.reg.pc - 1, ir, ros, nos, tos });
                    const value: u32 = (@as(u32, ros) << 16) | @as(u32, nos);
                    const shifted = value << @truncate(tos & 0x1f);
                    result = @as(Word, @truncate(shifted >> 16));
                },
                .PUSH_PC, .PUSH_FP, .PUSH_RA, .PUSH_AR => {
                    stackop = .PUSH;
                    const reg: RegNum = @enumFromInt(ir & 3);
                    switch (reg) {
                        .PC => result = self.reg.pc,
                        .FP => result = self.framePointer(),
                        .RA => result = self.reg.ra,
                        .AR => result = self.reg.ar,
                    }
                    std.log.info("{x:0>4}: {x:0>2} PUSH {s} = {}", .{ self.reg.pc - 1, ir, @tagName(reg), result });
                },
                .POP_PC, .POP_FP, .POP_RA, .POP_AR => {
                    read = 1;
                    stackop = .POP1;
                    result = nos;
                    const reg: RegNum = @enumFromInt(ir & 3);
                    std.log.info("{x:0>4}: {x:0>2} POP {s} = {}", .{ self.reg.pc - 1, ir, @tagName(reg), tos });
                    switch (reg) {
                        .PC => self.reg.pc = tos,
                        .FP => self.setFramePointer(tos),
                        .RA => self.reg.ra = tos,
                        .AR => self.reg.ar = tos,
                    }
                },
                .ADD_PC, .ADD_FP, .ADD_RA, .ADD_AR => { // ADD <reg>
                    read = 1;
                    stackop = .POP1;
                    result = nos;
                    const reg: RegNum = @enumFromInt(ir & 3);
                    switch (reg) {
                        .PC => { // ADD PC aka JUMP
                            const dest = @addWithOverflow(self.reg.pc, tos)[0];
                            std.log.info("{x:0>4}: {x:0>2} JUMP {} to {x:0>4}", .{ self.reg.pc - 1, ir, @as(SWord, @bitCast(tos)), dest });
                            self.reg.pc = dest;
                        },
                        .FP => { // ADD FP
                            const fp = self.framePointer();
                            const new_fp = @addWithOverflow(fp, tos)[0];
                            self.setFramePointer(new_fp);
                            std.log.info("{x:0>4}: {x:0>2} ADD FP {} + {} = {}", .{ self.reg.pc - 1, ir, fp, tos, new_fp });
                        },
                        .RA => { // ADD RA
                            const ra = self.reg.ra;
                            const new_ra = @addWithOverflow(ra, tos)[0];
                            self.reg.ra = new_ra;
                            std.log.info("{x:0>4}: {x:0>2} ADD RA {} + {} = {}", .{ self.reg.pc - 1, ir, ra, tos, new_ra });
                        },
                        .AR => { // ADD AR
                            const ar = self.reg.ar;
                            const new_ar = @addWithOverflow(ar, tos)[0];
                            self.reg.ar = new_ar;
                            std.log.info("{x:0>4}: {x:0>2} ADD AR {} + {} = {}", .{ self.reg.pc - 1, ir, ar, tos, new_ar });
                        },
                    }
                },
                .PUSH_CSR => {
                    read = 1;
                    stackop = .REPLACE;
                    const csr: CsrNum = @enumFromInt(tos);
                    switch (csr) {
                        .AFP => result = self.alternateFramePointer(),
                        .ECAUSE => result = self.csr.ecause,
                        .EVEC => result = self.csr.evec,
                        _ => {
                            std.log.err("Illegal CSR: {x}", .{csr});
                            return Error.IllegalInstruction;
                        },
                    }
                    std.log.info("{x:0>4}: {x:0>2} PUSH {s} = {}", .{ self.reg.pc - 1, ir, @tagName(csr), result });
                },
                .POP_CSR => {
                    read = 2;
                    stackop = .POP2;
                    result = ros;
                    const csr: CsrNum = @enumFromInt(tos);
                    std.log.info("{x:0>4}: {x:0>2} POP {s} = {}", .{ self.reg.pc - 1, ir, @tagName(csr), nos });
                    switch (csr) {
                        .AFP => self.setAlternateFramePointer(nos),
                        .ECAUSE => self.csr.ecause = nos,
                        .EVEC => self.csr.evec = nos,
                        _ => {
                            std.log.err("Illegal CSR: {}", .{csr});
                            return Error.IllegalInstruction;
                        },
                    }
                },
                .LLW => {
                    read = 1;
                    stackop = .REPLACE;
                    const addr = @addWithOverflow(self.reg.fp, tos)[0];
                    if ((addr) & 1 == 1) {
                        std.log.err("Unaligned LLW from fp+{} = {x}", .{ tos, addr });
                        return Error.UnalignedAccess;
                    }
                    result = self.memory[addr >> 1];
                    std.log.info("{x:0>4}: {x:0>2} LLW from fp+{} = {}", .{ self.reg.pc - 1, ir, tos, result });
                },
                .SLW => {
                    read = 2;
                    stackop = .POP2;
                    result = ros;
                    const addr = @addWithOverflow(self.reg.fp, tos)[0];
                    std.log.info("{x:0>4}: {x:0>2} SLW to fp+{} = {}", .{ self.reg.pc - 1, ir, tos, nos });
                    if ((addr) & 1 == 1) {
                        std.log.err("Unaligned SLW from fp+{} = {x}", .{ tos, addr });
                        return Error.UnalignedAccess;
                    }
                    self.memory[addr >> 1] = nos;
                },
                .DIV => {
                    read = 2;
                    stackop = .POP1;
                    const divisor: SWord = @bitCast(tos);
                    const dividend: SWord = @bitCast(nos);
                    std.log.info("{x:0>4}: {x:0>2} DIV {} / {}", .{ self.reg.pc - 1, ir, dividend, divisor });
                    if (divisor == 0) {
                        return Error.DivideByZero;
                    }
                    result = @bitCast(@divTrunc(dividend, divisor));
                },
                .DIVU => {
                    read = 2;
                    stackop = .POP1;
                    std.log.info("{x:0>4}: {x:0>2} DIVU {} / {}", .{ self.reg.pc - 1, ir, nos, tos });
                    if (tos == 0) {
                        return Error.DivideByZero;
                    }
                    result = @divFloor(nos, tos);
                },
                .MOD => {
                    read = 2;
                    stackop = .POP1;
                    const divisor: SWord = @bitCast(tos);
                    const dividend: SWord = @bitCast(nos);
                    std.log.info("{x:0>4}: {x:0>2} MOD {} % {}", .{ self.reg.pc - 1, ir, dividend, divisor });
                    if (divisor == 0) {
                        return Error.DivideByZero;
                    }
                    result = @bitCast(@rem(dividend, divisor));
                },
                .MODU => {
                    read = 2;
                    stackop = .POP1;
                    std.log.info("{x:0>4}: {x:0>2} MODU {} % {}", .{ self.reg.pc - 1, ir, nos, tos });
                    if (tos == 0) {
                        return Error.DivideByZero;
                    }
                    result = @rem(nos, tos);
                },
                .MUL => {
                    read = 2;
                    stackop = .POP1;
                    const b: SWord = @bitCast(tos);
                    const a: SWord = @bitCast(nos);
                    const res: SWord = @mulWithOverflow(a, b)[0];
                    result = @bitCast(res);
                    std.log.info("{x:0>4}: {x:0>2} MUL {} * {} = {}", .{ self.reg.pc - 1, ir, a, b, res });
                },
                .MULH => {
                    read = 2;
                    stackop = .POP1;
                    const b: i32 = @intCast(tos);
                    const a: i32 = @intCast(nos);
                    const full_result: i32 = @mulWithOverflow(a, b)[0];
                    const res: SWord = @truncate(full_result >> 16);
                    result = @bitCast(res);
                    std.log.info("{x:0>4}: {x:0>2} MULH {} * {} = {}", .{ self.reg.pc - 1, ir, a, b, res });
                },
                .SELECT => {
                    read = 3;
                    stackop = .POP2;
                    // stack: ros=false_val, nos=true_val, tos=cond
                    std.log.info("{x:0>4}: {x:0>2} SELECT {} ? {} : {}", .{ self.reg.pc - 1, ir, tos, nos, ros });
                    result = if (tos != 0) nos else ros;
                },
                .ROT => {
                    read = 3;
                    stackop = .ROT;
                    // a b c -> c a b (ros nos tos -> tos ros nos)
                    std.log.info("{x:0>4}: {x:0>2} ROT {} {} {}", .{ self.reg.pc - 1, ir, ros, nos, tos });
                },
                .SRL => {
                    read = 2;
                    stackop = .POP1;
                    result = nos >> @truncate(tos & 0x0f);
                    std.log.info("{x:0>4}: {x:0>2} SRL {} >> {} = {}", .{ self.reg.pc - 1, ir, nos, tos, result });
                },
                .SRA => {
                    read = 2;
                    stackop = .POP1;
                    const value: SWord = @bitCast(nos);
                    const shifted: SWord = value >> @truncate(tos & 0x0f);
                    result = @bitCast(shifted);
                    std.log.info("{x:0>4}: {x:0>2} SRA {} >> {} = {}", .{ self.reg.pc - 1, ir, value, tos, result });
                },
                .SLL => {
                    read = 2;
                    stackop = .POP1;
                    result = nos << @truncate(tos & 0x0f);
                    std.log.info("{x:0>4}: {x:0>2} SLL {} << {} = {}", .{ self.reg.pc - 1, ir, nos, tos, result });
                },
                .OR => {
                    read = 2;
                    stackop = .POP1;
                    result = nos | tos;
                    std.log.info("{x:0>4}: {x:0>2} OR {} | {} = {}", .{ self.reg.pc - 1, ir, nos, tos, result });
                },
                .SUB => {
                    read = 2;
                    stackop = .POP1;
                    result = @subWithOverflow(nos, tos)[0];
                    std.log.info("{x:0>4}: {x:0>2} SUB {} - {} = {}", .{ self.reg.pc - 1, ir, nos, tos, result });
                },
                .LB => {
                    read = 1;
                    stackop = .REPLACE;
                    std.log.info("{x:0>4}: {x:0>2} LB from {x}", .{ self.reg.pc - 1, ir, tos });
                    const mem_byte: [*]u8 = @ptrCast(self.memory);
                    const byte = mem_byte[tos];
                    result = signExtend(byte, 8);
                },
                .SB => {
                    read = 2;
                    stackop = .POP2;
                    result = ros;
                    std.log.info("{x:0>4}: {x:0>2} SB to {x} = {}", .{ self.reg.pc - 1, ir, tos, nos });
                    const mem_byte: [*]u8 = @ptrCast(self.memory);
                    mem_byte[tos] = @truncate(nos & 0xff);
                },
                .LH, .LW => {
                    read = 1;
                    stackop = .REPLACE;
                    std.log.info("{x:0>4}: {x:0>2} LW from {x}", .{ self.reg.pc - 1, ir, tos });
                    if ((tos & 1) == 1) {
                        std.log.err("Unaligned LW from {x}", .{tos});
                        return Error.UnalignedAccess;
                    }
                    result = self.memory[tos >> 1];
                },
                .SH, .SW => {
                    read = 2;
                    stackop = .POP2;
                    result = ros;
                    std.log.info("{x:0>4}: {x:0>2} SW to {x} = {}", .{ self.reg.pc - 1, ir, tos, nos });
                    if ((tos & 1) == 1) {
                        std.log.err("Unaligned SW to {x}", .{tos});
                        return Error.UnalignedAccess;
                    }
                    self.memory[tos >> 1] = nos;
                },
                .LNW => {
                    stackop = .PUSH;
                    const addr = self.reg.ar;
                    std.log.info("{x:0>4}: {x:0>2} LNW from {x}", .{ self.reg.pc - 1, ir, addr });
                    if ((addr & 1) == 1) {
                        std.log.err("Unaligned LNW from {x}", .{addr});
                        return Error.UnalignedAccess;
                    }
                    self.reg.ar = @addWithOverflow(self.reg.ar, 2)[0];
                    result = self.memory[addr >> 1];
                },
                .SNW => {
                    read = 1;
                    stackop = .POP1;
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
                .CALL => {
                    read = 1;
                    stackop = .POP1;
                    result = nos;
                    std.log.info("{x:0>4}: {x:0>2} CALL to {x}, return address {x}", .{ self.reg.pc - 1, ir, self.reg.pc + tos, self.reg.pc });
                    self.reg.ra = self.reg.pc;
                    self.reg.pc = @addWithOverflow(self.reg.pc, tos)[0];
                },
                .CALLP => {
                    read = 1;
                    stackop = .POP1;
                    result = nos;
                    std.log.info("{x:0>4}: {x:0>2} CALLP to {x}, return address {x}", .{ self.reg.pc - 1, ir, tos, self.reg.pc });
                    self.reg.ra = self.reg.pc;
                    self.reg.pc = tos;
                },
                _ => {
                    std.log.err("Illegal instruction: {x}", .{ir});
                    return Error.IllegalInstruction;
                },
            }

            // check stack underflow
            if (@subWithOverflow(self.csr.depth, read)[1] == 1) {
                return Error.StackUnderflow;
            }

            // update stack
            switch (stackop) {
                .REPLACE => {
                    tos = result;
                },
                .PUSH => {
                    if (self.inKernel()) {
                        if ((self.csr.depth + 1) >= KERNEL_HIGH_WATER) {
                            return Error.StackOverflow;
                        }
                    } else {
                        if ((self.csr.depth + 1) >= USER_HIGH_WATER) {
                            return Error.StackOverflow;
                        }
                    }

                    self.stack[@subWithOverflow(self.csr.depth, 3)[0] & STACK_MASK] = ros;
                    self.csr.depth += 1;

                    ros = nos;
                    nos = tos;
                    tos = result;
                },
                .POP1 => {
                    self.csr.depth -= 1;
                    tos = result;
                    nos = ros;
                    ros = self.stack[@subWithOverflow(self.csr.depth, 3)[0] & STACK_MASK];
                },
                .POP2 => {
                    self.csr.depth -= 2;
                    tos = result;
                    nos = self.stack[@subWithOverflow(self.csr.depth, 2)[0] & STACK_MASK];
                    ros = self.stack[@subWithOverflow(self.csr.depth, 3)[0] & STACK_MASK];
                },
                .SWAP => {
                    const temp = tos;
                    tos = nos;
                    nos = temp;
                },
                .ROT => {
                    // a b c -> c a b (ros tos nos -> tos ros nos)
                    const temp = tos;
                    tos = nos;
                    nos = ros;
                    ros = temp;
                },
                .NONE => {},
            }
        }

        self.stack[@subWithOverflow(self.csr.depth, 1)[0] & STACK_MASK] = tos;
        self.stack[@subWithOverflow(self.csr.depth, 2)[0] & STACK_MASK] = nos;
        self.stack[@subWithOverflow(self.csr.depth, 3)[0] & STACK_MASK] = ros;
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
    const value = try runTest("starj/tests/divu.bin", 200, std.testing.allocator);
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

test "mod instruction" {
    const value = try runTest("starj/tests/mod.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "modu instruction" {
    // std.testing.log_level = .debug;
    const value = try runTest("starj/tests/modu.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "mul instruction" {
    const value = try runTest("starj/tests/mul.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "mulh instruction" {
    const value = try runTest("starj/tests/mulh.bin", 200, std.testing.allocator);
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

test "select instruction" {
    const value = try runTest("starj/tests/select.bin", 200, std.testing.allocator);
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
