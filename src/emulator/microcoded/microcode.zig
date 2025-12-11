const std = @import("std");

pub const WORDSIZE = 16;
pub const WORDBYTES = WORDSIZE / 8;

pub const Word = if (WORDSIZE == 16) u16 else u32;
pub const SWord = if (WORDSIZE == 16) i16 else i32;

pub const MAX_STACK_DEPTH: Word = 256;
pub const USER_MAX_DEPTH: Word = MAX_STACK_DEPTH - 8;
pub const KERNEL_MAX_DEPTH: Word = MAX_STACK_DEPTH - 4;

pub const Status = packed struct(u16) {
    km: bool = false,
    ie: bool = false,
    th: bool = false,
    _reserved: u13 = 0,

    pub fn toWord(self: Status) Word {
        return @bitCast(self);
    }

    pub fn fromWord(w: Word) Status {
        return @bitCast(w);
    }
};

pub const ResultSrc = enum(u4) {
    tos = 0,
    nos = 1,
    pc = 2,
    fp = 3,
    ra = 4,
    ar = 5,
    imm_sext6 = 6,
    mem_data = 7,
    csr_data = 8,
    alu_out = 9,
    fsl_out = 10,
    zero = 11,
};

pub const AluASrc = enum(u3) {
    tos = 0,
    nos = 1,
    fp = 2,
    ra = 3,
    ar = 4,
};

pub const AluBSrc = enum(u3) {
    tos = 0,
    nos = 1,
    imm7 = 2,
    zero = 3,
    wordbytes = 4,
};

pub const AluOp = enum(u4) {
    pass_a = 0,
    add = 1,
    sub = 2,
    and_op = 3,
    or_op = 4,
    xor_op = 5,
    lt = 6,
    ltu = 7,
    shl7_or = 8,
    mul = 9,
    mulh = 10,
    div = 11,
    divu = 12,
    mod = 13,
    modu = 14,
    select = 15,
};

// Funnel Shifter: ({hi, lo} << shift) >> WORDSIZE
pub const FslHiSrc = enum(u2) {
    zero = 0,
    nos = 1,
    ros = 2,
    sign_fill = 3,
};

pub const FslLoSrc = enum(u2) {
    zero = 0,
    nos = 1,
};

pub const FslShiftSrc = enum(u2) {
    tos = 0,
    neg_tos = 1,
};

pub const FslShiftMask = enum(u1) {
    single_word = 0,
    double_word = 1,
};

pub const TosSrc = enum(u3) {
    hold = 0,
    result = 1,
    nos = 2,
    ros = 3,
    stack_mem = 4,
    mem_data = 5,
};

pub const NosSrc = enum(u2) {
    hold = 0,
    tos = 1,
    ros = 2,
    stack_mem = 3,
};

pub const RosSrc = enum(u2) {
    hold = 0,
    nos = 1,
    tos = 2,
    stack_mem = 3,
};

pub const DepthOp = enum(u3) {
    none = 0,
    inc = 1,
    dec = 2,
    dec2 = 3,
    dec3 = 4,
};

pub const MemOp = enum(u3) {
    none = 0,
    read_byte = 1,
    read_half = 2,
    read_word = 3,
    write_byte = 4,
    write_half = 5,
    write_word = 6,
};

pub const MemAddrSrc = enum(u2) {
    tos = 0,
    fp_plus_tos = 1,
    ar = 2,
};

pub const MemDataSrc = enum(u1) {
    nos = 0,
    tos = 1,
};

pub const PcSrc = enum(u3) {
    next = 0,
    rel_tos = 1,
    abs_tos = 2,
    evec = 3,
    epc = 4,
    hold = 5,
};

pub const BranchCond = enum(u2) {
    always = 0,
    if_nos_zero = 1,
    if_nos_nzero = 2,
};

pub const CsrOp = enum(u2) {
    none = 0,
    read = 1,
    write = 2,
};

pub const KmSrc = enum(u2) {
    hold = 0,
    set = 1,
    estatus = 2,
};

pub const IeSrc = enum(u2) {
    hold = 0,
    clear = 1,
    estatus = 2,
};

pub const ThSrc = enum(u1) {
    hold = 0,
    estatus = 1,
};

pub const ExceptionCheck = enum(u2) {
    none = 0,
    div_zero = 1,
    halt_trap = 2,
};

pub const ECause = enum(u3) {
    none = 0,
    syscall = 1,
    illegal_instr = 2,
    halt_trap = 3,
    stack_underflow = 4,
    stack_overflow = 5,
    div_by_zero = 6,

    /// Convert to full 8-bit ecause value
    pub fn toU8(self: ECause) u8 {
        return switch (self) {
            .none => 0x00,
            .syscall => 0x00,
            .illegal_instr => 0x10,
            .halt_trap => 0x12,
            .stack_underflow => 0x30,
            .stack_overflow => 0x31,
            .div_by_zero => 0x40,
        };
    }

    pub fn interrupt(irq_num: u4) u8 {
        return 0x50 | @as(u8, irq_num);
    }
};

pub const WriteEnables = packed struct(u9) {
    fp: bool = false,
    ra: bool = false,
    ar: bool = false,
    csr: bool = false,
    epc: bool = false,
    estatus: bool = false,
    ecause: bool = false,
    halt: bool = false,
    th: bool = false,
};

pub const MicroOp = packed struct(u64) {
    result_src: ResultSrc = .zero,
    alu_op: AluOp = .pass_a,
    alu_a: AluASrc = .nos,
    alu_b: AluBSrc = .zero,
    fsl_hi: FslHiSrc = .zero,
    fsl_lo: FslLoSrc = .zero,
    fsl_shift: FslShiftSrc = .tos,
    fsl_mask: FslShiftMask = .single_word,
    tos_src: TosSrc = .hold,
    nos_src: NosSrc = .hold,
    ros_src: RosSrc = .hold,
    depth_op: DepthOp = .none,
    mem_op: MemOp = .none,
    mem_addr: MemAddrSrc = .tos,
    mem_data: MemDataSrc = .nos,
    pc_src: PcSrc = .next,
    branch_cond: BranchCond = .always,
    csr_op: CsrOp = .none,
    writes: WriteEnables = .{},
    km_src: KmSrc = .hold,
    ie_src: IeSrc = .hold,
    exception_check: ExceptionCheck = .none,
    ecause: ECause = .none,
    min_depth: u2 = 0,
};

pub const Opcode = enum(u7) {
    halt = 0x00,
    reserved_01 = 0x01,
    syscall = 0x02,
    rets = 0x03,
    beqz = 0x04,
    bnez = 0x05,
    swap = 0x06,
    over = 0x07,
    drop = 0x08,
    dup = 0x09,
    ltu = 0x0A,
    lt = 0x0B,
    add = 0x0C,
    and_op = 0x0D,
    xor_op = 0x0E,
    fsl = 0x0F,
    push_pc = 0x10,
    push_fp = 0x11,
    push_ra = 0x12,
    push_ar = 0x13,
    pop_pc = 0x14,
    pop_fp = 0x15,
    pop_ra = 0x16,
    pop_ar = 0x17,
    jump = 0x18,
    add_fp = 0x19,
    add_ra = 0x1A,
    add_ar = 0x1B,
    pushcsr = 0x1C,
    popcsr = 0x1D,
    llw = 0x1E,
    slw = 0x1F,
    div = 0x20,
    divu = 0x21,
    mod = 0x22,
    modu = 0x23,
    mul = 0x24,
    mulh = 0x25,
    select = 0x26,
    rot = 0x27,
    srl = 0x28,
    sra = 0x29,
    sll = 0x2A,
    or_op = 0x2B,
    sub = 0x2C,
    ext_reserved_2D = 0x2D,
    ext_reserved_2E = 0x2E,
    ext_reserved_2F = 0x2F,
    lb = 0x30,
    sb = 0x31,
    lh = 0x32,
    sh = 0x33,
    lw = 0x34,
    sw = 0x35,
    lnw = 0x36,
    snw = 0x37,
    call = 0x38,
    callp = 0x39,
    ext_reserved_3A = 0x3A,
    ext_reserved_3B = 0x3B,
    ext_reserved_3C = 0x3C,
    ext_reserved_3D = 0x3D,
    ext_reserved_3E = 0x3E,
    ext_reserved_3F = 0x3F,
    push = 0x40,
    shi = 0x41,
};

fn generateMicrocode(opcode: Opcode) MicroOp {
    return switch (opcode) {
        .push => .{
            .result_src = .imm_sext6,
            .tos_src = .result,
            .nos_src = .tos,
            .ros_src = .nos,
            .depth_op = .inc,
        },
        .shi => .{
            .result_src = .alu_out,
            .alu_op = .shl7_or,
            .alu_a = .tos,
            .alu_b = .imm7,
            .tos_src = .result,
            .min_depth = 1,
        },
        .halt => .{
            .pc_src = .hold,
            .writes = .{ .halt = true },
            .exception_check = .halt_trap,
            .ecause = .halt_trap,
        },
        .reserved_01 => .{
            .pc_src = .evec,
            .km_src = .set,
            .ie_src = .clear,
            .writes = .{ .epc = true, .estatus = true, .ecause = true },
            .ecause = .illegal_instr,
        },
        .syscall => .{
            .pc_src = .evec,
            .km_src = .set,
            .ie_src = .clear,
            .writes = .{ .epc = true, .estatus = true, .ecause = true },
            .ecause = .syscall,
        },
        .rets => .{
            .pc_src = .epc,
            .km_src = .estatus,
            .ie_src = .estatus,
            .writes = .{ .th = true },
        },
        .beqz => .{
            .pc_src = .rel_tos,
            .branch_cond = .if_nos_zero,
            .tos_src = .ros,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 2,
        },
        .bnez => .{
            .pc_src = .rel_tos,
            .branch_cond = .if_nos_nzero,
            .tos_src = .ros,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 2,
        },
        .swap => .{
            .tos_src = .nos,
            .nos_src = .tos,
            .min_depth = 2,
        },
        .over => .{
            .result_src = .nos,
            .tos_src = .result,
            .nos_src = .tos,
            .ros_src = .nos,
            .depth_op = .inc,
            .min_depth = 2,
        },
        .drop => .{
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1,
        },
        .dup => .{
            .nos_src = .tos,
            .ros_src = .nos,
            .depth_op = .inc,
            .min_depth = 1,
        },
        .ltu => .{
            .result_src = .alu_out,
            .alu_op = .ltu,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2,
        },
        .lt => .{
            .result_src = .alu_out,
            .alu_op = .lt,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2,
        },
        .add => .{
            .result_src = .alu_out,
            .alu_op = .add,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2,
        },
        .and_op => .{
            .result_src = .alu_out,
            .alu_op = .and_op,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2,
        },
        .xor_op => .{
            .result_src = .alu_out,
            .alu_op = .xor_op,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2,
        },
        .fsl => .{
            .result_src = .fsl_out,
            .fsl_hi = .ros,
            .fsl_lo = .nos,
            .fsl_shift = .tos,
            .fsl_mask = .double_word,
            .tos_src = .result,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 3,
        },
        .push_pc => .{
            .result_src = .pc,
            .tos_src = .result,
            .nos_src = .tos,
            .ros_src = .nos,
            .depth_op = .inc,
        },
        .push_fp => .{
            .result_src = .fp,
            .tos_src = .result,
            .nos_src = .tos,
            .ros_src = .nos,
            .depth_op = .inc,
        },
        .push_ra => .{
            .result_src = .ra,
            .tos_src = .result,
            .nos_src = .tos,
            .ros_src = .nos,
            .depth_op = .inc,
        },
        .push_ar => .{
            .result_src = .ar,
            .tos_src = .result,
            .nos_src = .tos,
            .ros_src = .nos,
            .depth_op = .inc,
        },
        .pop_pc => .{
            .pc_src = .abs_tos,
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1,
        },
        .pop_fp => .{
            .result_src = .tos,
            .writes = .{ .fp = true },
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1,
        },
        .pop_ra => .{
            .result_src = .tos,
            .writes = .{ .ra = true },
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1,
        },
        .pop_ar => .{
            .result_src = .tos,
            .writes = .{ .ar = true },
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1,
        },
        .jump => .{
            .pc_src = .rel_tos,
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1,
        },
        .add_fp => .{
            .result_src = .alu_out,
            .alu_op = .add,
            .alu_a = .fp,
            .alu_b = .tos,
            .writes = .{ .fp = true },
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1,
        },
        .add_ra => .{
            .result_src = .alu_out,
            .alu_op = .add,
            .alu_a = .ra,
            .alu_b = .tos,
            .writes = .{ .ra = true },
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1,
        },
        .add_ar => .{
            .result_src = .alu_out,
            .alu_op = .add,
            .alu_a = .ar,
            .alu_b = .tos,
            .writes = .{ .ar = true },
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1,
        },
        .pushcsr => .{
            .result_src = .csr_data,
            .csr_op = .read,
            .tos_src = .result,
            .min_depth = 1,
        },
        .popcsr => .{
            .csr_op = .write,
            .writes = .{ .csr = true },
            .tos_src = .ros,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 2,
        },
        .llw => .{
            .mem_op = .read_word,
            .mem_addr = .fp_plus_tos,
            .result_src = .mem_data,
            .tos_src = .result,
            .min_depth = 1,
        },
        .slw => .{
            .mem_op = .write_word,
            .mem_addr = .fp_plus_tos,
            .result_src = .nos,
            .tos_src = .ros,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 2,
        },
        .div => .{
            .result_src = .alu_out,
            .alu_op = .div,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .exception_check = .div_zero,
            .ecause = .div_by_zero,
            .min_depth = 2,
        },
        .divu => .{
            .result_src = .alu_out,
            .alu_op = .divu,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .exception_check = .div_zero,
            .ecause = .div_by_zero,
            .min_depth = 2,
        },
        .mod => .{
            .result_src = .alu_out,
            .alu_op = .mod,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .exception_check = .div_zero,
            .ecause = .div_by_zero,
            .min_depth = 2,
        },
        .modu => .{
            .result_src = .alu_out,
            .alu_op = .modu,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .exception_check = .div_zero,
            .ecause = .div_by_zero,
            .min_depth = 2,
        },
        .mul => .{
            .result_src = .alu_out,
            .alu_op = .mul,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2,
        },
        .mulh => .{
            .result_src = .alu_out,
            .alu_op = .mulh,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2,
        },
        .select => .{
            .result_src = .alu_out,
            .alu_op = .select,
            .alu_a = .tos,
            .alu_b = .nos,
            .tos_src = .result,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 3,
        },
        .rot => .{
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .tos,
            .min_depth = 3,
        },
        .srl => .{
            .result_src = .fsl_out,
            .fsl_hi = .zero,
            .fsl_lo = .nos,
            .fsl_shift = .neg_tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2,
        },
        .sra => .{
            .result_src = .fsl_out,
            .fsl_hi = .sign_fill,
            .fsl_lo = .nos,
            .fsl_shift = .neg_tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2,
        },
        .sll => .{
            .result_src = .fsl_out,
            .fsl_hi = .nos,
            .fsl_lo = .zero,
            .fsl_shift = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2,
        },
        .or_op => .{
            .result_src = .alu_out,
            .alu_op = .or_op,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2,
        },
        .sub => .{
            .result_src = .alu_out,
            .alu_op = .sub,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2,
        },
        .ext_reserved_2D, .ext_reserved_2E, .ext_reserved_2F => .{
            .pc_src = .evec,
            .km_src = .set,
            .ie_src = .clear,
            .writes = .{ .epc = true, .estatus = true, .ecause = true },
            .ecause = .illegal_instr,
        },
        .lb => .{
            .mem_op = .read_byte,
            .mem_addr = .tos,
            .result_src = .mem_data,
            .tos_src = .result,
            .min_depth = 1,
        },
        .sb => .{
            .mem_op = .write_byte,
            .mem_addr = .tos,
            .result_src = .nos,
            .tos_src = .ros,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 2,
        },
        .lh => .{
            .mem_op = .read_half,
            .mem_addr = .tos,
            .result_src = .mem_data,
            .tos_src = .result,
            .min_depth = 1,
        },
        .sh => .{
            .mem_op = .write_half,
            .mem_addr = .tos,
            .result_src = .nos,
            .tos_src = .ros,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 2,
        },
        .lw => .{
            .mem_op = .read_word,
            .mem_addr = .tos,
            .result_src = .mem_data,
            .tos_src = .result,
            .min_depth = 1,
        },
        .sw => .{
            .mem_op = .write_word,
            .mem_addr = .tos,
            .result_src = .nos,
            .tos_src = .ros,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 2,
        },
        .lnw => .{
            .mem_op = .read_word,
            .mem_addr = .ar,
            .result_src = .alu_out,
            .alu_op = .add,
            .alu_a = .ar,
            .alu_b = .wordbytes,
            .writes = .{ .ar = true },
            .tos_src = .mem_data,
            .nos_src = .tos,
            .ros_src = .nos,
            .depth_op = .inc,
        },
        .snw => .{
            .mem_op = .write_word,
            .mem_addr = .ar,
            .mem_data = .tos,
            .result_src = .alu_out,
            .alu_op = .add,
            .alu_a = .ar,
            .alu_b = .wordbytes,
            .writes = .{ .ar = true },
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1,
        },
        .call => .{
            .result_src = .pc,
            .writes = .{ .ra = true },
            .pc_src = .rel_tos,
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1,
        },
        .callp => .{
            .result_src = .pc,
            .writes = .{ .ra = true },
            .pc_src = .abs_tos,
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1,
        },
        .ext_reserved_3A, .ext_reserved_3B, .ext_reserved_3C, .ext_reserved_3D, .ext_reserved_3E, .ext_reserved_3F => .{
            .pc_src = .evec,
            .km_src = .set,
            .ie_src = .clear,
            .writes = .{ .epc = true, .estatus = true, .ecause = true },
            .ecause = .illegal_instr,
        },
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

pub const Regs = struct {
    pc: Word = 0,
    ra: Word = 0,
    ar: Word = 0,
    ufp: Word = 0,
    kfp: Word = 0,
    tos: Word = 0,
    nos: Word = 0,
    ros: Word = 0,
    depth: Word = 0,
    status: Status = .{ .km = true },
    estatus: Status = .{},
    epc: Word = 0,
    evec: Word = 0,

    pub fn fp(self: *const Regs) Word {
        return if (self.status.km) self.kfp else self.ufp;
    }

    pub fn afp(self: *const Regs) Word {
        return if (self.status.km) self.ufp else self.kfp;
    }
};

pub const CpuState = struct {
    reg: Regs = .{},
    stack_mem: [256]Word = [_]Word{0} ** 256,
    ecause: Word = 0,
    udmask: Word = 0,
    udset: Word = 0,
    upmask: Word = 0,
    upset: Word = 0,
    kdmask: Word = 0,
    kdset: Word = 0,
    kpmask: Word = 0,
    kpset: Word = 0,
    memory: []u8,
    halted: bool = false,
    log_enabled: bool = true,

    pub fn init(memory: []u8) CpuState {
        return .{ .memory = memory };
    }

    pub fn fp(self: *const CpuState) Word {
        return self.reg.fp();
    }

    pub fn afp(self: *const CpuState) Word {
        return self.reg.afp();
    }

    pub fn readStackMem(self: *const CpuState, index: usize) Word {
        if (index < self.stack_mem.len) {
            return self.stack_mem[index];
        }
        return 0;
    }

    pub fn writeStackMem(self: *CpuState, index: usize, value: Word) void {
        if (index < self.stack_mem.len) {
            self.stack_mem[index] = value;
        }
    }

    pub fn readByte(self: *const CpuState, addr: Word) u8 {
        const phys = self.translateDataAddr(addr);
        if (phys < self.memory.len) {
            return self.memory[phys];
        }
        return 0;
    }

    pub fn readHalf(self: *const CpuState, addr: Word) Word {
        const phys = self.translateDataAddr(addr);
        if (phys + 1 < self.memory.len) {
            const lo: Word = self.memory[phys];
            const hi: Word = self.memory[phys + 1];
            return lo | (hi << 8);
        }
        return 0;
    }

    pub fn readWord(self: *const CpuState, addr: Word) Word {
        if (WORDSIZE == 16) {
            return self.readHalf(addr);
        } else {
            const phys = self.translateDataAddr(addr);
            if (phys + 3 < self.memory.len) {
                var result: Word = 0;
                for (0..4) |i| {
                    result |= @as(Word, self.memory[phys + i]) << @intCast(i * 8);
                }
                return result;
            }
            return 0;
        }
    }

    pub fn writeByte(self: *CpuState, addr: Word, value: u8) void {
        const phys = self.translateDataAddr(addr);
        if (phys < self.memory.len) {
            self.memory[phys] = value;
        }
    }

    pub fn writeHalf(self: *CpuState, addr: Word, value: Word) void {
        const phys = self.translateDataAddr(addr);
        if (phys + 1 < self.memory.len) {
            self.memory[phys] = @truncate(value);
            self.memory[phys + 1] = @truncate(value >> 8);
        }
    }

    pub fn writeWord(self: *CpuState, addr: Word, value: Word) void {
        if (WORDSIZE == 16) {
            self.writeHalf(addr, value);
        } else {
            const phys = self.translateDataAddr(addr);
            if (phys + 3 < self.memory.len) {
                for (0..4) |i| {
                    self.memory[phys + i] = @truncate(value >> @intCast(i * 8));
                }
            }
        }
    }

    fn translateDataAddr(self: *const CpuState, vaddr: Word) usize {
        _ = self;
        return @intCast(vaddr);
    }

    pub fn readCsr(self: *const CpuState, index: Word) Word {
        return switch (index) {
            0 => self.reg.status.toWord(),
            1 => self.reg.estatus.toWord(),
            2 => self.reg.epc,
            3 => self.afp(),
            4 => self.reg.depth,
            5 => self.ecause,
            6 => self.reg.evec,
            8 => self.udmask,
            9 => self.udset,
            10 => self.upmask,
            11 => self.upset,
            12 => self.kdmask,
            13 => self.kdset,
            14 => self.kpmask,
            15 => self.kpset,
            else => 0,
        };
    }

    pub fn writeCsr(self: *CpuState, index: Word, value: Word) void {
        switch (index) {
            0 => self.reg.status = Status.fromWord(value),
            1 => self.reg.estatus = Status.fromWord(value),
            2 => self.reg.epc = value,
            3 => {
                if (self.reg.status.km) {
                    self.reg.ufp = value;
                } else {
                    self.reg.kfp = value;
                }
            },
            4 => self.reg.depth = 0,
            5 => self.ecause = value,
            6 => self.reg.evec = value,
            8 => self.udmask = value,
            9 => self.udset = value,
            10 => self.upmask = value,
            11 => self.upset = value,
            12 => self.kdmask = value,
            13 => self.kdset = value,
            14 => self.kpmask = value,
            15 => self.kpset = value,
            else => {},
        }
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

    pub fn run(self: *CpuState, max_cycles: usize) usize {
        var cycles: usize = 0;
        while (!self.halted and cycles < max_cycles) {
            step(self, false, 0);
            cycles += 1;
        }
        return cycles;
    }
};

pub inline fn executeMicroOp(cpu: *CpuState, uop: MicroOp, instr: u8, trap: bool, trap_cause: u8) void {
    const r = cpu.reg;

    const result: Word = switch (uop.result_src) {
        .tos => r.tos,
        .nos => r.nos,
        .pc => r.pc,
        .fp => r.fp(),
        .ra => r.ra,
        .ar => r.ar,
        .imm_sext6 => signExtend6(@truncate(instr & 0x3F)),
        .mem_data => blk: {
            const mem_addr = switch (uop.mem_addr) {
                .tos => r.tos,
                .fp_plus_tos => r.fp() +% r.tos,
                .ar => r.ar,
            };
            break :blk switch (uop.mem_op) {
                .read_byte => signExtend8(cpu.readByte(mem_addr)),
                .read_half => cpu.readHalf(mem_addr),
                .read_word => cpu.readWord(mem_addr),
                else => 0,
            };
        },
        .csr_data => cpu.readCsr(r.tos),
        .alu_out => blk: {
            const alu_a = switch (uop.alu_a) {
                .tos => r.tos,
                .nos => r.nos,
                .fp => r.fp(),
                .ra => r.ra,
                .ar => r.ar,
            };
            const alu_b = switch (uop.alu_b) {
                .tos => r.tos,
                .nos => r.nos,
                .imm7 => instr & 0x7F,
                .zero => 0,
                .wordbytes => WORDBYTES,
            };
            break :blk executeAlu(uop.alu_op, alu_a, alu_b, r.ros);
        },
        .fsl_out => blk: {
            const fsl_hi: Word = switch (uop.fsl_hi) {
                .zero => 0,
                .nos => r.nos,
                .ros => r.ros,
                .sign_fill => if (r.nos & (1 << (WORDSIZE - 1)) != 0) @as(Word, @bitCast(@as(SWord, -1))) else 0,
            };
            const fsl_lo: Word = switch (uop.fsl_lo) {
                .zero => 0,
                .nos => r.nos,
            };
            const shift_mask: Word = switch (uop.fsl_mask) {
                .single_word => WORDSIZE - 1,
                .double_word => 2 * WORDSIZE - 1,
            };
            const masked_tos = r.tos & shift_mask;
            const fsl_shift: Word = switch (uop.fsl_shift) {
                .tos => masked_tos,
                .neg_tos => (WORDSIZE -% masked_tos) & (2 * WORDSIZE - 1),
            };
            if (WORDSIZE == 16) {
                const dword: u32 = (@as(u32, fsl_hi) << 16) | fsl_lo;
                break :blk @truncate((dword << @truncate(fsl_shift)) >> 16);
            } else {
                const dword: u64 = (@as(u64, fsl_hi) << 32) | fsl_lo;
                break :blk @truncate((dword << @truncate(fsl_shift)) >> 32);
            }
        },
        .zero => 0,
    };

    if (uop.mem_op == .write_byte or uop.mem_op == .write_half or uop.mem_op == .write_word) {
        const mem_addr = switch (uop.mem_addr) {
            .tos => r.tos,
            .fp_plus_tos => r.fp() +% r.tos,
            .ar => r.ar,
        };
        const mem_write_data = switch (uop.mem_data) {
            .nos => r.nos,
            .tos => r.tos,
        };
        switch (uop.mem_op) {
            .write_byte => cpu.writeByte(mem_addr, @truncate(mem_write_data)),
            .write_half => cpu.writeHalf(mem_addr, mem_write_data),
            .write_word => cpu.writeWord(mem_addr, mem_write_data),
            else => {},
        }
    }

    if (uop.depth_op == .inc and r.depth >= 3) {
        cpu.writeStackMem(@intCast(r.depth -% 3), r.ros);
    }

    if (uop.writes.csr) {
        cpu.writeCsr(r.tos, r.nos);
    }

    cpu.reg.tos = switch (uop.tos_src) {
        .hold => r.tos,
        .result => result,
        .nos => r.nos,
        .ros => r.ros,
        .stack_mem => cpu.readStackMem(@intCast(r.depth -% 4)),
        .mem_data => blk: {
            const mem_addr = switch (uop.mem_addr) {
                .tos => r.tos,
                .fp_plus_tos => r.fp() +% r.tos,
                .ar => r.ar,
            };
            break :blk switch (uop.mem_op) {
                .read_byte => signExtend8(cpu.readByte(mem_addr)),
                .read_half => cpu.readHalf(mem_addr),
                .read_word => cpu.readWord(mem_addr),
                else => 0,
            };
        },
    };

    cpu.reg.nos = switch (uop.nos_src) {
        .hold => r.nos,
        .tos => r.tos,
        .ros => r.ros,
        .stack_mem => cpu.readStackMem(@intCast(r.depth -% 4)),
    };

    cpu.reg.ros = switch (uop.ros_src) {
        .hold => r.ros,
        .nos => r.nos,
        .tos => r.tos,
        .stack_mem => switch (uop.depth_op) {
            .dec2, .dec3 => cpu.readStackMem(@intCast(r.depth -% 5)),
            else => cpu.readStackMem(@intCast(r.depth -% 4)),
        },
    };

    cpu.reg.depth = switch (uop.depth_op) {
        .none => r.depth,
        .inc => r.depth +% 1,
        .dec => if (r.depth > 0) r.depth -% 1 else 0,
        .dec2 => if (r.depth >= 2) r.depth -% 2 else 0,
        .dec3 => if (r.depth >= 3) r.depth -% 3 else 0,
    };

    const branch_taken: bool = switch (uop.branch_cond) {
        .always => true,
        .if_nos_zero => r.nos == 0,
        .if_nos_nzero => r.nos != 0,
    };
    cpu.reg.pc = switch (uop.pc_src) {
        .next => r.pc,
        .rel_tos => if (branch_taken) r.pc +% r.tos else r.pc,
        .abs_tos => if (branch_taken) r.tos else r.pc,
        .evec => r.evec,
        .epc => r.epc,
        .hold => r.pc,
    };

    cpu.reg.status = .{
        .km = switch (uop.km_src) {
            .hold => r.status.km,
            .set => true,
            .estatus => r.estatus.km,
        },
        .ie = switch (uop.ie_src) {
            .hold => r.status.ie,
            .clear => false,
            .estatus => r.estatus.ie,
        },
        .th = if (uop.writes.th) r.estatus.th else r.status.th,
    };

    if (uop.writes.fp) {
        if (r.status.km) {
            cpu.reg.kfp = result;
        } else {
            cpu.reg.ufp = result;
        }
    }

    if (uop.writes.ra) {
        cpu.reg.ra = result;
    }

    if (uop.writes.ar) {
        cpu.reg.ar = result;
    }

    if (uop.writes.estatus) {
        cpu.reg.estatus = r.status;
    }

    if (uop.writes.epc) {
        cpu.reg.epc = r.pc;
    }

    if (uop.writes.ecause) {
        cpu.ecause = if (trap) trap_cause else uop.ecause.toU8();
    }

    if (uop.writes.halt) {
        cpu.halted = true;
    }
}

fn executeAlu(op: AluOp, a: Word, b: Word, c: Word) Word {
    const sa: SWord = @bitCast(a);
    const sb: SWord = @bitCast(b);

    return switch (op) {
        .pass_a => a,
        .add => a +% b,
        .sub => a -% b,
        .and_op => a & b,
        .or_op => a | b,
        .xor_op => a ^ b,
        .lt => if (sa < sb) 1 else 0,
        .ltu => if (a < b) 1 else 0,
        .shl7_or => (a << 7) | (b & 0x7F),
        .mul => @truncate(@as(u64, a) * @as(u64, b)),
        .mulh => @truncate((@as(u64, a) * @as(u64, b)) >> WORDSIZE),
        .div => if (b != 0) @bitCast(@divTrunc(sa, sb)) else 0,
        .divu => if (b != 0) a / b else 0,
        .mod => if (b != 0) @bitCast(@rem(sa, sb)) else 0,
        .modu => if (b != 0) a % b else 0,
        .select => if (a != 0) b else c,
    };
}

inline fn signExtend6(val: u6) Word {
    const sval: i6 = @bitCast(val);
    const extended: SWord = sval;
    return @bitCast(extended);
}

fn signExtend8(val: u8) Word {
    const sval: i8 = @bitCast(val);
    const extended: SWord = sval;
    return @bitCast(extended);
}

fn getInstrMnemonic(instr: u8) []const u8 {
    if (instr & 0x80 != 0) {
        return "shi";
    } else if (instr & 0xC0 == 0x40) {
        return "push";
    } else {
        const opcode: Opcode = @enumFromInt(instr & 0x3F);
        return @tagName(opcode);
    }
}

fn formatImmediate(instr: u8, buf: *[32]u8) []const u8 {
    if (instr & 0x80 != 0) {
        const imm7 = instr & 0x7F;
        return std.fmt.bufPrint(buf, " 0x{x:0>2}", .{imm7}) catch "???";
    } else if (instr & 0xC0 == 0x40) {
        const imm6: i6 = @bitCast(@as(u6, @truncate(instr & 0x3F)));
        const extended: i16 = imm6;
        return std.fmt.bufPrint(buf, " {d}", .{extended}) catch "???";
    } else {
        return "";
    }
}

fn logInstruction(cpu: *const CpuState, pc_before: Word, instr: u8, uop: MicroOp, trap: bool, trap_cause: u8) void {
    var imm_buf: [32]u8 = undefined;
    const mnemonic = getInstrMnemonic(instr);
    const imm_str = formatImmediate(instr, &imm_buf);

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

    if (uop.depth_op != .none) {
        const depth_info = std.fmt.bufPrint(summary_buf[summary_len..], " dep:{s}", .{@tagName(uop.depth_op)}) catch "";
        summary_len += depth_info.len;
    }

    if (uop.mem_op != .none) {
        const mem_info = std.fmt.bufPrint(summary_buf[summary_len..], " mem:{s}", .{@tagName(uop.mem_op)}) catch "";
        summary_len += mem_info.len;
    }

    std.log.info("{x:0>4}: {x:0>2} {s:<7}{s:<8} {s}", .{
        pc_before,
        instr,
        mnemonic,
        imm_str,
        summary_buf[0..summary_len],
    });
}

pub inline fn step(cpu: *CpuState, irq: bool, irq_num: u4) void {
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
    const dest_km: bool = if (fetched_uop.km_src == .estatus) cpu.reg.estatus.km else cpu.reg.status.km;
    const max_depth: Word = if (dest_km) KERNEL_MAX_DEPTH else USER_MAX_DEPTH;
    const overflow: bool = cpu.reg.depth > max_depth;

    const instr_exception: bool = switch (fetched_uop.exception_check) {
        .none => false,
        .div_zero => cpu.reg.tos == 0,
        .halt_trap => cpu.reg.status.th,
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
    const cycles = cpu.run(max_cycles);
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
        .memory = @ptrCast(memory),
    };

    try cpu.loadRom(rom_file);
    const cycles = cpu.run(max_cycles);

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

test "call deep instruction" {
    const value = try runTest("starj/tests/call_deep.bin", 200, std.testing.allocator);
    try std.testing.expect(value == 1);
}
