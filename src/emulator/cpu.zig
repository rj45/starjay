const std = @import("std");

pub const Word = u16;

pub const WORDSIZE: comptime_int = 16;
pub const WORDBYTES: comptime_int = WORDSIZE / 2;
pub const WORDMASK: Word = (1<<WORDSIZE) - 1;

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
    _,
};

pub const RegNum = enum (u2) {
    PC = 0,
    FP = 1,
    RA = 2,
    AR = 3,
};

pub const CsrNum = enum (u3) {
    AFP = 3,
    ECAUSE = 5,
    EVEC = 6,
    _,
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
                std.log.info("{x:0>4}: {x:0>2} SHI {}", .{self.reg.pc-1, ir, value});
                try self.push((try self.pop() << 7) | value);
            } else if ((ir & 0xc0) == 0x40) {
                const value = signExtend(ir & 0x3f, 6);
                std.log.info("{x:0>4}: {x:0>2} PUSH {}", .{self.reg.pc-1, ir, @as(i16, @bitCast(value))});
                try self.push(value);
            } else {
                const opcode: Opcode = @enumFromInt(ir & 0x3f);
                switch (opcode) {
                    .HALT => {
                        if (self.csr.status & StatusFlags.TH == 0) {
                            std.log.info("{x:0>4}: {x:0>2} HALT - halting execution as requested", .{self.reg.pc-1, ir});
                            return;
                        }
                    },
                    .BEQZ => {
                        const offset = try self.pop();
                        const t = try self.pop();
                        if (t == 0) {
                            std.log.info("{x:0>4}: {x:0>2} BEQZ {}, {} taken", .{self.reg.pc-1, ir, @as(i16, @bitCast(t)), @as(i16, @bitCast(offset))});
                            self.reg.pc = @addWithOverflow(self.reg.pc, @as(Word, @bitCast(offset)))[0];
                        } else {
                            std.log.info("{x:0>4}: {x:0>2} BEQZ {}, {} not taken", .{self.reg.pc-1, ir, @as(i16, @bitCast(t)), @as(i16, @bitCast(offset))});
                        }
                    },
                    .BNEZ => {
                        const offset = try self.pop();
                        const t = try self.pop();
                        if (t != 0) {
                            std.log.info("{x:0>4}: {x:0>2} BNEZ {}, {} taken", .{self.reg.pc-1, ir, @as(i16, @bitCast(t)), @as(i16, @bitCast(offset))});
                            self.reg.pc = @addWithOverflow(self.reg.pc, @as(Word, @bitCast(offset)))[0];
                        } else {
                            std.log.info("{x:0>4}: {x:0>2} BNEZ {}, {} not taken", .{self.reg.pc-1, ir, @as(i16, @bitCast(t)), @as(i16, @bitCast(offset))});
                        }
                    },
                    .SWAP => {
                        const b = try self.pop();
                        const a = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} SWAP {} <-> {}", .{self.reg.pc-1, ir, a, b});
                        try self.push(b);
                        try self.push(a);
                    },
                    .OVER => {
                        const b = try self.pop();
                        const a = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} OVER {}", .{self.reg.pc-1, ir, a});
                        try self.push(a);
                        try self.push(b);
                        try self.push(a);
                    },
                    .DROP => {
                        const a = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} DROP {}", .{self.reg.pc-1, ir, a});
                    },
                    .DUP => {
                        const a = try self.pop();
                        try self.push(a);
                        try self.push(a);
                        std.log.info("{x:0>4}: {x:0>2} DUP {}", .{self.reg.pc-1, ir, a});
                    },
                    .LTU => {
                        const b = try self.pop();
                        const a = try self.pop();
                        const result: Word = if (a < b) 1 else 0;
                        std.log.info("{x:0>4}: {x:0>2} LTU {} < {} = {}", .{self.reg.pc-1, ir, a, b, result});
                        try self.push(result);
                    },
                    .LT => {
                        const b: i16 = @bitCast(try self.pop());
                        const a: i16 = @bitCast(try self.pop());
                        const result: Word = if (a < b) 1 else 0;
                        std.log.info("{x:0>4}: {x:0>2} LT {} < {} = {}", .{self.reg.pc-1, ir, a, b, result});
                        try self.push(result);
                    },
                    .ADD => {
                        const b = try self.pop();
                        const a = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} ADD {} + {}", .{self.reg.pc-1, ir, a, b});
                        try self.push(@addWithOverflow(a, b)[0]);
                    },
                    .AND => {
                        const b = try self.pop();
                        const a = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} AND {} & {}", .{self.reg.pc-1, ir, a, b});
                        try self.push(a & b);
                    },
                    .XOR => {
                        const b = try self.pop();
                        const a = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} XOR {} ^ {}", .{self.reg.pc-1, ir, a, b});
                        try self.push(a ^ b);
                    },
                    .FSL => {
                        const shift = try self.pop();
                        const lower = try self.pop();
                        const upper = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} FSL ({x} @ {x} << {}) >> 16", .{self.reg.pc-1, ir, upper, lower, shift});
                        const value: u32 = (@as(u32, upper) << 16) | @as(u32, lower);
                        const shifted = value << @truncate(shift & 0x1f);
                        const result = @as(Word, @truncate(shifted >> 16));
                        try self.push(result);
                    },
                    .PUSH_PC, .PUSH_FP, .PUSH_RA, .PUSH_AR => {
                        const reg: RegNum = @enumFromInt(ir & 3);
                        var value: Word = 0;
                        switch (reg) {
                            .PC => value = self.reg.pc,
                            .FP => value = self.framePointer(),
                            .RA => value = self.reg.ra,
                            .AR => value = self.reg.ar,
                        }
                        std.log.info("{x:0>4}: {x:0>2} PUSH {s} = {}", .{self.reg.pc-1, ir, @tagName(reg), value});
                        try self.push(value);
                    },
                   .POP_PC, .POP_FP, .POP_RA, .POP_AR => {
                        const reg: RegNum = @enumFromInt(ir & 3);
                        const value = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} POP {s} = {}", .{self.reg.pc-1, ir, @tagName(reg), value});
                        switch (reg) {
                            .PC => self.reg.pc = value,
                            .FP => if (self.inKernel()) {
                                self.csr.afp = value;
                            } else {
                                self.reg.fp = value;
                            },
                            .RA => self.reg.ra = value,
                            .AR => self.reg.ar = value,
                        }
                    },
                    .ADD_PC, .ADD_FP, .ADD_RA, .ADD_AR => { // ADD <reg>
                        const addend = try self.pop();
                        const reg: RegNum = @enumFromInt(ir & 3);
                        switch (reg) {
                            .PC => { // ADD PC aka JUMP
                                self.reg.pc = @addWithOverflow(self.reg.pc, addend)[0];
                                std.log.info("{x:0>4}: {x:0>2} JUMP {} to {x}", .{self.reg.pc-1, ir, addend, self.reg.pc});
                            },
                            .FP => { // ADD FP
                                const fp = self.framePointer();
                                const new_fp = @addWithOverflow(fp, addend)[0];
                                self.setFramePointer(new_fp);
                                std.log.info("{x:0>4}: {x:0>2} ADD FP {} + {} = {}", .{self.reg.pc-1, ir, fp, addend, new_fp});
                            },
                            .RA => { // ADD RA
                                const ra = self.reg.ra;
                                const new_ra = @addWithOverflow(ra, addend)[0];
                                self.reg.ra = new_ra;
                                std.log.info("{x:0>4}: {x:0>2} ADD RA {} + {} = {}", .{self.reg.pc-1, ir, ra, addend, new_ra});
                            },
                            .AR => { // ADD AR
                                const ar = self.reg.ar;
                                const new_ar = @addWithOverflow(ar, addend)[0];
                                self.reg.ar = new_ar;
                                std.log.info("{x:0>4}: {x:0>2} ADD AR {} + {} = {}", .{self.reg.pc-1, ir, ar, addend, new_ar});
                            },
                        }
                    },
                    .PUSH_CSR => {
                        const csr: CsrNum = @enumFromInt(try self.pop());
                        var csr_value: Word = 0;
                        switch (csr) {
                            .AFP => csr_value = self.alternateFramePointer(),
                            .ECAUSE => csr_value = self.csr.ecause,
                            .EVEC => csr_value = self.csr.evec,
                            _ => {
                                std.log.err("Illegal CSR: {x}", .{csr});
                                return Error.IllegalInstruction;
                            },
                        }
                        std.log.info("{x:0>4}: {x:0>2} PUSH {s} = {}", .{self.reg.pc-1, ir, @tagName(csr), csr_value});
                        try self.push(csr_value);
                    },
                    .POP_CSR => {
                        const csr: CsrNum = @enumFromInt(try self.pop());
                        const value = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} POP {s} = {}", .{self.reg.pc-1, ir, @tagName(csr), value});
                        switch (csr) {
                            .AFP => self.setAlternateFramePointer(value),
                            .ECAUSE => self.csr.ecause = value,
                            .EVEC => self.csr.evec = value,

                            _ => {
                                std.log.err("Illegal CSR: {}", .{csr});
                                return Error.IllegalInstruction;
                            }
                        }
                    },
                    .LLW => {
                        const fprel = try self.pop();
                        const value = self.memory[(self.reg.fp + fprel) >> 1];
                        std.log.info("{x:0>4}: {x:0>2} LLW from fp+{} = {}", .{self.reg.pc-1, ir, fprel, value});
                        if ((fprel + self.reg.fp) & 1 == 1) {
                            std.log.err("Unaligned LLW from fp+{} = {x}", .{fprel, self.reg.fp + fprel});
                            return Error.UnalignedAccess;
                        }
                        try self.push(value);
                    },
                    .SLW => {
                        const fprel = try self.pop();
                        const value = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} SLW to fp+{} = {}", .{self.reg.pc-1, ir, fprel, value});
                        if ((fprel + self.reg.fp) & 1 == 1) {
                            std.log.err("Unaligned SLW from fp+{} = {x}", .{fprel, self.reg.fp + fprel});
                            return Error.UnalignedAccess;
                        }
                        self.memory[(self.reg.fp + fprel) >> 1] = value;
                    },
                    .DIV => {
                        const divisor: i16 = @bitCast(try self.pop());
                        const dividend: i16 = @bitCast(try self.pop());
                        std.log.info("{x:0>4}: {x:0>2} DIV {} / {}", .{self.reg.pc-1, ir, dividend, divisor});
                        if (divisor == 0) {
                            return Error.DivideByZero;
                        } else {
                            const signed_result = @divTrunc(dividend, divisor);
                            try self.push(@bitCast(signed_result));
                        }
                    },
                    .DIVU => {
                        const divisor = try self.pop();
                        const dividend = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} DIVU {} / {}", .{self.reg.pc-1, ir, dividend, divisor});
                        if (divisor == 0) {
                            return Error.DivideByZero;
                        } else {
                            try self.push(@divFloor(dividend, divisor));
                        }
                    },
                    .MOD => {
                        const divisor: i16 = @bitCast(try self.pop());
                        const dividend: i16 = @bitCast(try self.pop());
                        std.log.info("{x:0>4}: {x:0>2} MOD {} % {}", .{self.reg.pc-1, ir, dividend, divisor});
                        if (divisor == 0) {
                            return Error.DivideByZero;
                        } else {
                            const signed_result = @rem(dividend, divisor);
                            try self.push(@bitCast(signed_result));
                        }
                    },
                    .MODU => {
                        const divisor = try self.pop();
                        const dividend = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} MODU {} % {}", .{self.reg.pc-1, ir, dividend, divisor});
                        if (divisor == 0) {
                            return Error.DivideByZero;
                        } else {
                            try self.push(@rem(dividend, divisor));
                        }
                    },
                    .MUL => {
                        const b: i16 = @bitCast(try self.pop());
                        const a: i16 = @bitCast(try self.pop());
                        const result: i16 = @mulWithOverflow(a, b)[0];
                        std.log.info("{x:0>4}: {x:0>2} MUL {} * {} = {}", .{self.reg.pc-1, ir, a, b, result});
                        try self.push(@bitCast(result));
                    },
                    .MULH => {
                        const b: i32 = @intCast(try self.pop());
                        const a: i32 = @intCast(try self.pop());
                        const full_result: i32 = @mulWithOverflow(a, b)[0];
                        const result: i16 = @truncate(full_result >> 16);
                        std.log.info("{x:0>4}: {x:0>2} MULH {} * {} = {}", .{self.reg.pc-1, ir, a, b, result});
                        try self.push(@bitCast(result));
                    },
                    .SELECT => {
                        const cond = try self.pop();
                        const a = try self.pop();
                        const b = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} SELECT {} ? {} : {}", .{self.reg.pc-1, ir, cond, a, b});
                        if (cond != 0) {
                            try self.push(a);
                        } else {
                            try self.push(b);
                        }
                    },
                    .ROT => {
                        const c = try self.pop();
                        const b = try self.pop();
                        const a = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} ROT {} {} {}", .{self.reg.pc-1, ir, a, b, c});
                        try self.push(c);
                        try self.push(a);
                        try self.push(b);
                    },
                    .SRL => {
                        const shift = try self.pop();
                        const value = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} SRL {} >> {}", .{self.reg.pc-1, ir, value, shift});
                        try self.push(value >> @truncate(shift & 0x0f));
                    },
                    .SRA => {
                        const shift = try self.pop();
                        const value: i16 = @bitCast(try self.pop());
                        std.log.info("{x:0>4}: {x:0>2} SRA {} >> {}", .{self.reg.pc-1, ir, value, shift});
                        const shifted: i16 = value >> @truncate(shift & 0x0f);
                        try self.push(@bitCast(shifted));
                    },
                    .SLL => {
                        const shift = try self.pop();
                        const value = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} SLL {} << {}", .{self.reg.pc-1, ir, value, shift});
                        try self.push(value << @truncate(shift & 0x0f));
                    },
                    .OR => {
                        const b = try self.pop();
                        const a = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} OR {} | {}", .{self.reg.pc-1, ir, a, b});
                        try self.push(a | b);
                    },
                    .SUB => {
                        const b = try self.pop();
                        const a = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} SUB {} - {}", .{self.reg.pc-1, ir, a, b});
                        try self.push(@subWithOverflow(a, b)[0]);
                    },
                    .LB => {
                        const addr = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} LB from {x}", .{self.reg.pc-1, ir, addr});
                        const mem_byte: []u8 = @ptrCast(self.memory);
                        const byte = mem_byte[addr];
                        const value = signExtend(byte, 8);
                        try self.push(value);
                    },
                    .SB => {
                        const addr = try self.pop();
                        const value:u8 = @truncate(try self.pop() & 0xff);
                        std.log.info("{x:0>4}: {x:0>2} SB to {x} = {}", .{self.reg.pc-1, ir, addr, value});
                        const mem_byte: []u8 = @ptrCast(self.memory);
                        mem_byte[addr] = value;
                    },
                    .LH, .LW => {
                        const addr = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} LW from {x}", .{self.reg.pc-1, ir, addr});
                        if ((addr & 1) == 1) {
                            std.log.err("Unaligned LW from {x}", .{addr});
                            return Error.UnalignedAccess;
                        }
                        const value = self.memory[addr >> 1];
                        try self.push(value);
                    },
                    .SH, .SW => {
                        const addr = try self.pop();
                        const value = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} SW to {x} = {}", .{self.reg.pc-1, ir, addr, value});
                        if ((addr & 1) == 1) {
                            std.log.err("Unaligned SW to {x}", .{addr});
                            return Error.UnalignedAccess;
                        }
                        self.memory[addr >> 1] = value;
                    },
                    .LNW => {
                        const addr = self.reg.ar;
                        std.log.info("{x:0>4}: {x:0>2} LNW from {x}", .{self.reg.pc-1, ir, addr});
                        if ((addr & 1) == 1) {
                            std.log.err("Unaligned LNW from {x}", .{addr});
                            return Error.UnalignedAccess;
                        }
                        self.reg.ar = @addWithOverflow(self.reg.ar, 2)[0];
                        const value = self.memory[addr >> 1];
                        try self.push(value);
                    },
                    .SNW => {
                        const addr = self.reg.ar;
                        const value = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} SNW to {x} = {}", .{self.reg.pc-1, ir, addr, value});
                        if ((addr & 1) == 1) {
                            std.log.err("Unaligned SNW to {x}", .{addr});
                            return Error.UnalignedAccess;
                        }
                        self.reg.ar = @addWithOverflow(self.reg.ar, 2)[0];
                        self.memory[addr >> 1] = value;
                    },
                    .CALL => {
                        const pcrel = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} CALL to {x}, return address {x}", .{self.reg.pc-1, ir, self.reg.pc+pcrel, self.reg.pc});
                        self.reg.ra = self.reg.pc;
                        self.reg.pc += pcrel;
                    },
                    .CALLP => {
                        const addr = try self.pop();
                        std.log.info("{x:0>4}: {x:0>2} CALLP to {x}, return address {x}", .{self.reg.pc-1, ir, addr, self.reg.pc});
                        self.reg.ra = self.reg.pc;
                        self.reg.pc = addr;
                    },
                    _ => {
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
