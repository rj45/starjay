const std = @import("std");

const common = @import("../root.zig");
pub const types = common.types;
pub const utils = common.utils;

pub const WORDSIZE = types.WORDSIZE;
pub const WORDBYTES = types.WORDBYTES;
pub const Word = types.Word;
pub const SWord = types.SWord;
pub const Status = types.Status;
pub const ECause = types.ECause;
pub const CsrNum = types.CsrNum;
pub const Regs = types.Regs;
pub const CpuState = types.CpuState;
pub const Opcode = common.opcode.Opcode;

const STACK_SIZE = types.STACK_SIZE;
const STACK_MASK = types.STACK_MASK;
const USER_HIGH_WATER = types.USER_HIGH_WATER;
const KERNEL_HIGH_WATER = types.KERNEL_HIGH_WATER;

pub const OpASrc = enum(u3) { tos, nos, ros, fp, ra, ar, pc, zero };
pub const OpBSrc = enum(u3) { tos, nos, ros, imm7, zero, wordbytes };
pub const ResultSrc = enum(u3) {
    op_a,
    imm_sext6,
    shl7_or,
    alu,
    shifter,
    mem,
    csr,
};
pub const AluOp = enum(u3) { add, sub, and_op, or_op, xor_op, lt, ltu };
pub const ShiftMode = enum(u2) { sll, srl, sra, fsl };
pub const MemOp = enum(u2) { none, read, write };
pub const MemWidth = enum(u2) { byte, half, word };
pub const MemAddr = enum(u2) { tos, fp_rel, ar };
pub const MemWData = enum(u1) { nos, tos };
pub const Dest = enum(u3) { none, tos, fp, ra, ar, csr };
pub const StackMode = enum(u3) { hold, push, pop, pop2, pop3, swap, rot };
pub const PcSrc = enum(u3) { next, rel, abs, evec, epc, hold, macro };
pub const BranchCond = enum(u2) { always, if_nos_zero, if_nos_nzero };
pub const TrapCheck = enum(u1) { none, th_trap };

pub const MicroOp = packed struct(u43) {
    // OPERAND SELECTION
    op_a: OpASrc = .tos,
    op_b: OpBSrc = .zero,

    // RESULT GENERATION
    result_src: ResultSrc = .op_a,
    alu_op: AluOp = .add,
    shift_mode: ShiftMode = .sll,

    // MULTIPLIER
    mul_enable: bool = false,

    // MEMORY ACCESS
    mem_op: MemOp = .none,
    mem_width: MemWidth = .word,
    mem_addr: MemAddr = .tos,
    mem_wdata: MemWData = .nos,

    // DESTINATION & STACK
    dest: Dest = .none,
    stack_mode: StackMode = .hold,
    ar_increment: bool = false,

    // CONTROL FLOW
    pc_src: PcSrc = .next,
    branch_cond: BranchCond = .always,

    // EXCEPTION & STATUS
    trap_check: TrapCheck = .none,
    ecause: ECause = .none,
    enter_trap: bool = false,
    exit_trap: bool = false,

    // SAFETY
    min_depth: u2 = 0,
    halt: bool = false,
};

fn generateMicrocode(opcode: Opcode) MicroOp {
    const illegal_instr: MicroOp = .{
        .pc_src = .evec,
        .enter_trap = true,
        .ecause = .illegal_instr,
    };

    return switch (opcode) {
        // push (immediate): push sign-extended 6-bit immediate
        .push => .{
            .result_src = .imm_sext6,
            .dest = .tos,
            .stack_mode = .push,
        },

        // shi (shift-high-immediate): TOS = (TOS << 7) | imm7
        .shi => .{
            .op_a = .tos,
            .op_b = .imm7, // imm7 comes from instruction
            .result_src = .shl7_or,
            .dest = .tos,
            .stack_mode = .hold,
            .min_depth = 1,
        },

        // halt: stop execution, trap if TH flag set
        .halt => .{
            .pc_src = .hold,
            .halt = true,
            .trap_check = .th_trap,
            .ecause = .halt_trap,
        },

        // reserved_01: illegal instruction
        .reserved_01 => illegal_instr,

        // syscall: trap to exception handler
        .syscall => .{
            .pc_src = .evec,
            .enter_trap = true,
            .ecause = .syscall,
        },

        // rets: return from exception
        .rets => .{
            .pc_src = .epc,
            .exit_trap = true,
        },

        // beqz: branch if NOS == 0
        .beqz => .{
            .op_a = .tos,
            .pc_src = .rel,
            .branch_cond = .if_nos_zero,
            .stack_mode = .pop2,
            .min_depth = 2,
        },

        // bnez: branch if NOS != 0
        .bnez => .{
            .op_a = .tos,
            .pc_src = .rel,
            .branch_cond = .if_nos_nzero,
            .stack_mode = .pop2,
            .min_depth = 2,
        },

        // swap: exchange TOS and NOS
        .swap => .{
            .stack_mode = .swap,
            .min_depth = 2,
        },

        // over: push NOS (copy second to top)
        .over => .{
            .op_a = .nos,
            .result_src = .op_a,
            .dest = .tos,
            .stack_mode = .push,
            .min_depth = 2,
        },

        // drop: pop and discard TOS
        .drop => .{
            .stack_mode = .pop,
            .min_depth = 1,
        },

        // dup: push TOS (duplicate top)
        .dup => .{
            .op_a = .tos,
            .result_src = .op_a,
            .dest = .tos,
            .stack_mode = .push,
            .min_depth = 1,
        },

        // ltu: unsigned less than
        .ltu => .{
            .op_a = .nos,
            .op_b = .tos,
            .result_src = .alu,
            .alu_op = .ltu,
            .dest = .tos,
            .stack_mode = .pop,
            .min_depth = 2,
        },

        // lt: signed less than
        .lt => .{
            .op_a = .nos,
            .op_b = .tos,
            .result_src = .alu,
            .alu_op = .lt,
            .dest = .tos,
            .stack_mode = .pop,
            .min_depth = 2,
        },

        // add: NOS + TOS
        .add => .{
            .op_a = .nos,
            .op_b = .tos,
            .result_src = .alu,
            .alu_op = .add,
            .dest = .tos,
            .stack_mode = .pop,
            .min_depth = 2,
        },

        // and: NOS & TOS
        .and_op => .{
            .op_a = .nos,
            .op_b = .tos,
            .result_src = .alu,
            .alu_op = .and_op,
            .dest = .tos,
            .stack_mode = .pop,
            .min_depth = 2,
        },

        // xor: NOS ^ TOS
        .xor_op => .{
            .op_a = .nos,
            .op_b = .tos,
            .result_src = .alu,
            .alu_op = .xor_op,
            .dest = .tos,
            .stack_mode = .pop,
            .min_depth = 2,
        },

        // fsl: funnel shift left ({ROS, NOS} << TOS) >> 16
        .fsl => .{
            .op_a = .nos,
            .op_b = .tos,
            .result_src = .shifter,
            .shift_mode = .fsl,
            .dest = .tos,
            .stack_mode = .pop2,
            .min_depth = 3,
        },

        // push_pc: push program counter
        .push_pc => .{
            .op_a = .pc,
            .result_src = .op_a,
            .dest = .tos,
            .stack_mode = .push,
        },

        // push_fp: push frame pointer
        .push_fp => .{
            .op_a = .fp,
            .result_src = .op_a,
            .dest = .tos,
            .stack_mode = .push,
        },

        // push_ra: push return address
        .push_ra => .{
            .op_a = .ra,
            .result_src = .op_a,
            .dest = .tos,
            .stack_mode = .push,
        },

        // push_ar: push address register
        .push_ar => .{
            .op_a = .ar,
            .result_src = .op_a,
            .dest = .tos,
            .stack_mode = .push,
        },

        // pop_pc: pop to program counter (return)
        .pop_pc => .{
            .op_a = .tos,
            .pc_src = .abs,
            .stack_mode = .pop,
            .min_depth = 1,
        },

        // pop_fp: pop to frame pointer
        .pop_fp => .{
            .op_a = .tos,
            .result_src = .op_a,
            .dest = .fp,
            .stack_mode = .pop,
            .min_depth = 1,
        },

        // pop_ra: pop to return address
        .pop_ra => .{
            .op_a = .tos,
            .result_src = .op_a,
            .dest = .ra,
            .stack_mode = .pop,
            .min_depth = 1,
        },

        // pop_ar: pop to address register
        .pop_ar => .{
            .op_a = .tos,
            .result_src = .op_a,
            .dest = .ar,
            .stack_mode = .pop,
            .min_depth = 1,
        },

        // jump: relative jump by TOS
        .jump => .{
            .op_a = .tos,
            .pc_src = .rel,
            .stack_mode = .pop,
            .min_depth = 1,
        },

        // add_fp: FP += TOS
        .add_fp => .{
            .op_a = .fp,
            .op_b = .tos,
            .result_src = .alu,
            .alu_op = .add,
            .dest = .fp,
            .stack_mode = .pop,
            .min_depth = 1,
        },

        // add_ra: RA += TOS
        .add_ra => .{
            .op_a = .ra,
            .op_b = .tos,
            .result_src = .alu,
            .alu_op = .add,
            .dest = .ra,
            .stack_mode = .pop,
            .min_depth = 1,
        },

        // add_ar: AR += TOS
        .add_ar => .{
            .op_a = .ar,
            .op_b = .tos,
            .result_src = .alu,
            .alu_op = .add,
            .dest = .ar,
            .stack_mode = .pop,
            .min_depth = 1,
        },

        // pushcsr: read CSR[TOS] into TOS
        .pushcsr => .{
            .result_src = .csr,
            .dest = .tos,
            .stack_mode = .hold,
            .min_depth = 1,
        },

        // popcsr: write NOS to CSR[TOS]
        .popcsr => .{
            .dest = .csr,
            .stack_mode = .pop2,
            .min_depth = 2,
        },

        // llw: load local word (fp-relative)
        .llw => .{
            .result_src = .mem,
            .mem_op = .read,
            .mem_width = .word,
            .mem_addr = .fp_rel,
            .dest = .tos,
            .stack_mode = .hold,
            .min_depth = 1,
        },

        // slw: store local word (fp-relative)
        .slw => .{
            .mem_op = .write,
            .mem_width = .word,
            .mem_addr = .fp_rel,
            .stack_mode = .pop2,
            .min_depth = 2,
        },

        // div: macro-vectored to software implementation
        .div => .{
            .pc_src = .macro,
            .enter_trap = true,
            .min_depth = 2,
        },

        // divu: macro-vectored to software implementation
        .divu => .{
            .pc_src = .macro,
            .enter_trap = true,
            .min_depth = 2,
        },

        .ext_reserved_22, .ext_reserved_23, .ext_reserved_25, .ext_reserved_26 => illegal_instr,

        // mul: multiply, produces TOS=high, NOS=low
        .mul => .{
            .op_a = .nos,
            .op_b = .tos,
            .mul_enable = true,
            .min_depth = 2,
        },

        // rot: rotate stack (TOS=NOS, NOS=ROS, ROS=TOS)
        .rot => .{
            .stack_mode = .rot,
            .min_depth = 3,
        },

        // srl: shift right logical
        .srl => .{
            .op_a = .nos,
            .op_b = .tos,
            .result_src = .shifter,
            .shift_mode = .srl,
            .dest = .tos,
            .stack_mode = .pop,
            .min_depth = 2,
        },

        // sra: shift right arithmetic
        .sra => .{
            .op_a = .nos,
            .op_b = .tos,
            .result_src = .shifter,
            .shift_mode = .sra,
            .dest = .tos,
            .stack_mode = .pop,
            .min_depth = 2,
        },

        // sll: shift left logical
        .sll => .{
            .op_a = .nos,
            .op_b = .tos,
            .result_src = .shifter,
            .shift_mode = .sll,
            .dest = .tos,
            .stack_mode = .pop,
            .min_depth = 2,
        },

        // or: NOS | TOS
        .or_op => .{
            .op_a = .nos,
            .op_b = .tos,
            .result_src = .alu,
            .alu_op = .or_op,
            .dest = .tos,
            .stack_mode = .pop,
            .min_depth = 2,
        },

        // sub: NOS - TOS
        .sub => .{
            .op_a = .nos,
            .op_b = .tos,
            .result_src = .alu,
            .alu_op = .sub,
            .dest = .tos,
            .stack_mode = .pop,
            .min_depth = 2,
        },

        .ext_reserved_2D, .ext_reserved_2E, .ext_reserved_2F => illegal_instr,

        // lb: load byte (sign-extended)
        .lb => .{
            .result_src = .mem,
            .mem_op = .read,
            .mem_width = .byte,
            .mem_addr = .tos,
            .dest = .tos,
            .stack_mode = .hold,
            .min_depth = 1,
        },

        // sb: store byte
        .sb => .{
            .mem_op = .write,
            .mem_width = .byte,
            .mem_addr = .tos,
            .stack_mode = .pop2,
            .min_depth = 2,
        },

        // lh: load half (sign-extended)
        .lh => .{
            .result_src = .mem,
            .mem_op = .read,
            .mem_width = .half,
            .mem_addr = .tos,
            .dest = .tos,
            .stack_mode = .hold,
            .min_depth = 1,
        },

        // sh: store half
        .sh => .{
            .mem_op = .write,
            .mem_width = .half,
            .mem_addr = .tos,
            .stack_mode = .pop2,
            .min_depth = 2,
        },

        // lw: load word
        .lw => .{
            .result_src = .mem,
            .mem_op = .read,
            .mem_width = .word,
            .mem_addr = .tos,
            .dest = .tos,
            .stack_mode = .hold,
            .min_depth = 1,
        },

        // sw: store word
        .sw => .{
            .mem_op = .write,
            .mem_width = .word,
            .mem_addr = .tos,
            .stack_mode = .pop2,
            .min_depth = 2,
        },

        // lnw: load next word via AR, then AR += WORDBYTES
        .lnw => .{
            .result_src = .mem,
            .mem_op = .read,
            .mem_width = .word,
            .mem_addr = .ar,
            .dest = .tos,
            .stack_mode = .push,
            .ar_increment = true,
        },

        // snw: store next word via AR, then AR += WORDBYTES
        .snw => .{
            .mem_op = .write,
            .mem_width = .word,
            .mem_addr = .ar,
            .mem_wdata = .tos,
            .stack_mode = .pop,
            .ar_increment = true,
            .min_depth = 1,
        },

        // call: relative call, saves PC to RA
        .call => .{
            .op_a = .pc,
            .result_src = .op_a,
            .dest = .ra,
            .pc_src = .rel,
            .stack_mode = .pop,
            .min_depth = 1,
        },

        // callp: absolute call (function pointer), saves PC to RA
        .callp => .{
            .op_a = .pc,
            .result_src = .op_a,
            .dest = .ra,
            .pc_src = .abs,
            .stack_mode = .pop,
            .min_depth = 1,
        },

        .ext_reserved_3A, .ext_reserved_3B, .ext_reserved_3C, .ext_reserved_3D, .ext_reserved_3E, .ext_reserved_3F => illegal_instr,
    };
}

pub const MICROCODE_ROM_SIZE = 66;

pub fn generateMicrocodeRom() [MICROCODE_ROM_SIZE]MicroOp {
    var rom: [MICROCODE_ROM_SIZE]MicroOp = undefined;
    for (0..63) |i| {
        const opcode: Opcode = @enumFromInt(i);
        rom[i] = generateMicrocode(opcode);
    }
    rom[64] = generateMicrocode(.push);
    rom[65] = generateMicrocode(.shi);
    return rom;
}

pub const microcode_rom = generateMicrocodeRom();

pub inline fn executeMicroOp(cpu: *CpuState, uop: MicroOp, instr: u8, trap: bool, trap_cause: u8) void {
    const r = cpu.reg;

    const op_a: Word = switch (uop.op_a) {
        .tos => r.tos,
        .nos => r.nos,
        .ros => r.ros,
        .fp => r.fp(),
        .ra => r.ra,
        .ar => r.ar,
        .pc => r.pc,
        .zero => 0,
    };

    const op_b: Word = switch (uop.op_b) {
        .tos => r.tos,
        .nos => r.nos,
        .ros => r.ros,
        .imm7 => instr & 0x7F,
        .zero => 0,
        .wordbytes => WORDBYTES,
    };

    const mem_addr: Word = if (uop.mem_op != .none) switch (uop.mem_addr) {
        .tos => r.tos,
        .fp_rel => r.fp() +% r.tos,
        .ar => r.ar,
    } else 0;

    const alu_out: Word = executeAlu(uop.alu_op, op_a, op_b);

    const shifter_out: Word = executeShifter(uop.shift_mode, op_a, op_b, r.ros);

    const result: Word = switch (uop.result_src) {
        .op_a => op_a,
        .imm_sext6 => signExtend6(@truncate(instr & 0x3F)),
        .shl7_or => (op_a << 7) | (op_b & 0x7F),
        .alu => alu_out,
        .shifter => shifter_out,
        .mem => switch (uop.mem_width) {
            .byte => signExtend8(cpu.readByte(mem_addr)),
            .half => cpu.readHalf(mem_addr),
            .word => cpu.readWord(mem_addr),
        },
        .csr => cpu.reg.readCsr(r.tos),
    };

    if (uop.mem_op == .write) {
        const mem_write_data = switch (uop.mem_wdata) {
            .nos => r.nos,
            .tos => r.tos,
        };
        switch (uop.mem_width) {
            .byte => cpu.writeByte(mem_addr, @truncate(mem_write_data)),
            .half => cpu.writeHalf(mem_addr, mem_write_data),
            .word => cpu.writeWord(mem_addr, mem_write_data),
        }
    }

    switch (uop.stack_mode) {
        .hold => {
            // mul_enable overrides normal dest routing - always writes both TOS and NOS
            if (uop.mul_enable) {
                const full_product = @as(u32, op_a) * @as(u32, op_b);
                const mul_high: Word = @truncate(full_product >> WORDSIZE);
                const mul_low: Word = @truncate(full_product);
                cpu.reg.tos = mul_high;
                cpu.reg.nos = mul_low;
            }
        },
        .push => {
            cpu.reg.ros = r.nos;
            cpu.reg.nos = r.tos;
            cpu.reg.tos = result;
            cpu.reg.depth = r.depth +% 1;
            if (r.depth >= 3) {
                cpu.writeStackMem(@intCast(r.depth -% 3), r.ros);
            }
        },
        .pop => {
            if (uop.dest == .tos) {
                cpu.reg.tos = result;
            } else {
                cpu.reg.tos = r.nos;
            }
            cpu.reg.nos = r.ros;
            cpu.reg.ros = cpu.readStackMem(@intCast(r.depth -% 4));
            cpu.reg.depth = if (r.depth > 0) r.depth -% 1 else 0;
        },
        .pop2 => {
            if (uop.dest == .tos) {
                cpu.reg.tos = result;
            } else {
                cpu.reg.tos = r.ros;
            }
            cpu.reg.nos = cpu.readStackMem(@intCast(r.depth -% 4));
            cpu.reg.ros = cpu.readStackMem(@intCast(r.depth -% 5));
            cpu.reg.depth = if (r.depth >= 2) r.depth -% 2 else 0;
        },
        .pop3 => {
            cpu.reg.tos = cpu.readStackMem(@intCast(r.depth -% 4));
            cpu.reg.nos = cpu.readStackMem(@intCast(r.depth -% 5));
            cpu.reg.ros = cpu.readStackMem(@intCast(r.depth -% 6));
            cpu.reg.depth = if (r.depth >= 3) r.depth -% 3 else 0;
        },
        .swap => {
            cpu.reg.tos = r.nos;
            cpu.reg.nos = r.tos;
        },
        .rot => {
            cpu.reg.tos = r.nos;
            cpu.reg.nos = r.ros;
            cpu.reg.ros = r.tos;
        },
    }

    switch (uop.dest) {
        .none => {},
        .tos => cpu.reg.tos = result,
        .fp => {
            if (r.status.km) {
                cpu.reg.kfp = result;
            } else {
                cpu.reg.ufp = result;
            }
        },
        .ra => cpu.reg.ra = result,
        .ar => cpu.reg.ar = result,
        .csr => cpu.reg.writeCsr(r.tos, r.nos),
    }

    if (uop.ar_increment) {
        cpu.reg.ar = r.ar +% WORDBYTES;
    }

    const branch_taken: bool = switch (uop.branch_cond) {
        .always => true,
        .if_nos_zero => r.nos == 0,
        .if_nos_nzero => r.nos != 0,
    };

    cpu.reg.pc = switch (uop.pc_src) {
        .next => r.pc,
        .rel => if (branch_taken) r.pc +% r.tos else r.pc,
        .abs => if (branch_taken) r.tos else r.pc,
        .evec => r.evec,
        .epc => r.epc,
        .hold => r.pc,
        .macro => 0x100 +% ((@as(Word, instr) & 0x1F) << 3),
    };

    // Enter trap: save epc, estatus, ecause, set KM, clear IE
    if (uop.enter_trap) {
        cpu.reg.epc = r.pc;
        cpu.reg.estatus = r.status;
        cpu.reg.ecause = if (trap) trap_cause else uop.ecause.toU8();
        cpu.reg.status.km = true;
        cpu.reg.status.ie = false;
    }

    if (uop.exit_trap) {
        cpu.reg.status = r.estatus;
    }

    if (uop.halt) {
        cpu.halted = true;
    }
}

inline fn executeAlu(op: AluOp, a: Word, b: Word) Word {
    const sa: SWord = @bitCast(a);
    const sb: SWord = @bitCast(b);

    return switch (op) {
        .add => a +% b,
        .sub => a -% b,
        .and_op => a & b,
        .or_op => a | b,
        .xor_op => a ^ b,
        .lt => if (sa < sb) 1 else 0,
        .ltu => if (a < b) 1 else 0,
    };
}

inline fn executeShifter(mode: ShiftMode, value: Word, shift_amount: Word, ros: Word) Word {
    const masked_shift = shift_amount & (WORDSIZE - 1);
    const double_mask = shift_amount & (2 * WORDSIZE - 1);

    return switch (mode) {
        .sll => value << @truncate(masked_shift),
        .srl => value >> @truncate(masked_shift),
        .sra => blk: {
            const sval: SWord = @bitCast(value);
            break :blk @bitCast(sval >> @truncate(masked_shift));
        },
        .fsl => blk: {
            // Funnel shift: ({ros, value} << shift) >> WORDSIZE
            if (WORDSIZE == 16) {
                const dword: u32 = (@as(u32, ros) << 16) | value;
                break :blk @truncate((dword << @truncate(double_mask)) >> 16);
            } else {
                const dword: u64 = (@as(u64, ros) << 32) | value;
                break :blk @truncate((dword << @truncate(double_mask)) >> 32);
            }
        },
    };
}

const signExtend6 = utils.signExtend6;
const signExtend8 = utils.signExtend8;

fn getInstrMnemonic(instr: u8) []const u8 {
    return Opcode.fromByte(instr).toMnemonic();
}

fn formatImmediate(instr: u8, buf: *[32]u8) []const u8 {
    if (instr & 0x80 != 0) {
        const imm7 = instr & 0x7F;
        return std.fmt.bufPrint(buf, "0x{x:0>2}", .{imm7}) catch "???";
    } else if (instr & 0xC0 == 0x40) {
        const imm6: i6 = @bitCast(@as(u6, @truncate(instr & 0x3F)));
        const extended: i16 = imm6;
        return std.fmt.bufPrint(buf, "{d}", .{extended}) catch "???";
    } else {
        return "";
    }
}

fn logInstruction(cpu: *const CpuState, pc_before: Word, instr: u8, uop: MicroOp, trap: bool, trap_cause: u8) void {
    var imm_buf: [32]u8 = undefined;
    const mnemonic = getInstrMnemonic(instr);
    const imm_str = formatImmediate(instr, &imm_buf);

    var instr_buf: [128]u8 = undefined;
    const instr_str = std.fmt.bufPrint(instr_buf[0..], "{s} {s}", .{mnemonic, imm_str}) catch "";

    var summary_buf: [128]u8 = undefined;
    var summary_len: usize = 0;

    const stack_info = std.fmt.bufPrint(summary_buf[summary_len..], "stk:[{x:0>4},{x:0>4},{x:0>4}]d={d}", .{
        cpu.reg.tos,
        cpu.reg.nos,
        cpu.reg.ros,
        cpu.reg.depth,
    }) catch "";
    summary_len += stack_info.len;

    if (trap) {
        const trap_info = std.fmt.bufPrint(summary_buf[summary_len..], " TRAP:{x:0>2}", .{trap_cause}) catch "";
        summary_len += trap_info.len;
    }

    if (uop.pc_src != .next and uop.pc_src != .hold) {
        const pc_info = std.fmt.bufPrint(summary_buf[summary_len..], " pc:{s}", .{@tagName(uop.pc_src)}) catch "";
        summary_len += pc_info.len;
    }

    if (uop.stack_mode != .hold) {
        const stack_mode_info = std.fmt.bufPrint(summary_buf[summary_len..], " stk:{s}", .{@tagName(uop.stack_mode)}) catch "";
        summary_len += stack_mode_info.len;
    }

    if (uop.mem_op != .none) {
        const mem_info = std.fmt.bufPrint(summary_buf[summary_len..], " mem:{s}", .{@tagName(uop.mem_op)}) catch "";
        summary_len += mem_info.len;
    }

    std.debug.print("{x:0>4}: {x:0>2} {s:<12} {s}\n", .{
        pc_before,
        instr,
        instr_str,
        summary_buf[0..summary_len],
    });
}

pub fn runForCycles(cpu: *CpuState, max_cycles: usize) usize {
    var cycles: usize = 0;
    while (!cpu.halted and cycles < max_cycles) {
        step(cpu, false, 0);
        cycles += 1;
    }
    cpu.cycles += cycles;

    cpu.stack[@subWithOverflow(cpu.reg.depth, 1)[0] & STACK_MASK] = cpu.reg.tos;
    cpu.stack[@subWithOverflow(cpu.reg.depth, 2)[0] & STACK_MASK] = cpu.reg.nos;
    cpu.stack[@subWithOverflow(cpu.reg.depth, 3)[0] & STACK_MASK] = cpu.reg.ros;
    return cycles;
}

inline fn step(cpu: *CpuState, irq: bool, irq_num: u4) void {
    if (cpu.halted) return;

    const pc_before = cpu.reg.pc;
    const fetched_instr = cpu.readByte(cpu.reg.pc);
    cpu.reg.pc +%= 1;

    const fetched_uop = if ((fetched_instr & 0x80) != 0)
        microcode_rom[65]
    else if ((fetched_instr & 0xC0) == 0x40)
        microcode_rom[64]
    else
        microcode_rom[fetched_instr & 0x3F];

    const interrupt: bool = irq and cpu.reg.status.ie;
    const underflow: bool = cpu.reg.depth < fetched_uop.min_depth;
    // Check post-instruction km (e.g. rets restores estatus.km) to apply correct depth limit
    const dest_km: bool = if (fetched_uop.exit_trap) cpu.reg.estatus.km else cpu.reg.status.km;
    const max_depth: Word = if (dest_km) KERNEL_HIGH_WATER else USER_HIGH_WATER;
    const overflow: bool = cpu.reg.depth > max_depth;

    const instr_exception: bool = switch (fetched_uop.trap_check) {
        .none => false,
        .th_trap => cpu.reg.status.th,
    };

    const trap: bool = interrupt or underflow or overflow or instr_exception;

    const trap_cause: u8 = if (underflow)
        ECause.stack_underflow.toU8()
    else if (overflow)
        ECause.stack_overflow.toU8()
    else if (instr_exception)
        fetched_uop.ecause.toU8()
    else
        ECause.interrupt(irq_num);

    // All traps reuse syscall's microcode: saves state, sets km, clears ie, jumps to evec
    const uop = if (trap) microcode_rom[@intFromEnum(Opcode.syscall)] else fetched_uop;

    if (cpu.log_enabled) {
        logInstruction(cpu, pc_before, fetched_instr, uop, trap, trap_cause);
    }

    executeMicroOp(cpu, uop, fetched_instr, trap, trap_cause);
}

pub fn run(rom_file: []const u8, max_cycles: usize, quiet: bool, gpa: std.mem.Allocator) !Word {
    const memory = try gpa.alloc(u16, 128 * 1024);
    defer gpa.free(memory);

    var cpu: *CpuState = try gpa.create(CpuState);
    defer gpa.destroy(cpu);
    cpu.* = .{
        .memory = @ptrCast(memory),
        .log_enabled = !quiet,
    };

    try cpu.loadRom(rom_file);

    const start = try std.time.Instant.now();
    const cycles = runForCycles(cpu, max_cycles);
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

pub const Error = error{
    InvalidStackDepth,
    TooManyCycles,
};

fn runTest(rom_file: []const u8, max_cycles: usize, gpa: std.mem.Allocator) !Word {
    const memory = try gpa.alloc(u16, 128 * 1024);
    defer gpa.free(memory);

    var cpu: *CpuState = try gpa.create(CpuState);
    defer gpa.destroy(cpu);
    cpu.* = .{
        .log_enabled = false,
        .memory = @ptrCast(memory),
    };

    try cpu.loadRom(rom_file);
    const cycles = runForCycles(cpu, max_cycles);

    if (cycles == max_cycles) {
        std.log.err("Execution did not halt within {} cycles", .{max_cycles});
        return Error.TooManyCycles;
    }

    if (cpu.reg.depth != 1) {
        std.log.err("Expected exactly one value on stack after execution, found {}", .{cpu.reg.depth});
        return Error.InvalidStackDepth;
    }

    return cpu.reg.tos;
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

test "bootstrap div macro vector" {
    const value = try runTest("starj/tests/bootstrap/boot_14_div_vector.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 1);
}

test "bootstrap divu macro vector" {
    const value = try runTest("starj/tests/bootstrap/boot_15_divu_vector.bin", 40, std.testing.allocator);
    try std.testing.expect(value == 1);
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
