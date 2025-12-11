const std = @import("std");

pub const WORDSIZE = 16; // or 32
pub const WORDBYTES = WORDSIZE / 8;

// Word type definition
pub const Word = if (WORDSIZE == 16) u16 else u32;
pub const SWord = if (WORDSIZE == 16) i16 else i32;

// ============================================================================
// Stack Limits (for overflow/underflow detection)
// ============================================================================
// The manual specifies "high water marks" - thresholds that leave room for
// exception handlers to operate without immediately triggering nested exceptions.
//
// User mode: at least 8 words before full
// Kernel mode: at least 4 words before full (gives handlers room to save state)

pub const MAX_STACK_DEPTH: Word = 256; // Total stack memory slots + TOS/NOS/ROS
pub const USER_MAX_DEPTH: Word = MAX_STACK_DEPTH - 8; // 248 - max allowed in user mode
pub const KERNEL_MAX_DEPTH: Word = MAX_STACK_DEPTH - 4; // 252 - max allowed in kernel mode

// ============================================================================
// Status Register
// ============================================================================

/// Status register bitfield - represents both status and estatus
pub const Status = packed struct(u16) {
    km: bool = false, // Bit 0: Kernel Mode
    ie: bool = false, // Bit 1: Interrupt Enable
    th: bool = false, // Bit 2: Trap Halt
    _reserved: u13 = 0, // Bits 3-15: Reserved

    pub fn toWord(self: Status) Word {
        return @bitCast(self);
    }

    pub fn fromWord(w: Word) Status {
        return @bitCast(w);
    }
};

// ============================================================================
// Data Path Enums
// ============================================================================

/// Main result bus source selection
pub const ResultSrc = enum(u4) {
    tos = 0,
    nos = 1,
    pc = 2,
    fp = 3,
    ra = 4,
    ar = 5,
    imm_sext6 = 6, // sign-extended 6-bit immediate
    mem_data = 7, // data from memory read
    csr_data = 8, // data from CSR read
    alu_out = 9, // ALU result
    fsl_out = 10, // Funnel shifter result (for all shift ops)
    zero = 11, // useful default
};

/// ALU A operand source
pub const AluASrc = enum(u3) {
    tos = 0,
    nos = 1,
    fp = 2,
    ra = 3,
    ar = 4,
};

/// ALU B operand source
pub const AluBSrc = enum(u3) {
    tos = 0,
    nos = 1,
    imm7 = 2,
    zero = 3,
    wordbytes = 4,
};

/// ALU operation selection
pub const AluOp = enum(u4) {
    // Basic operations
    pass_a = 0, // output = A (pass through)
    add = 1, // A + B
    sub = 2, // A - B
    and_op = 3, // A & B
    or_op = 4, // A | B
    xor_op = 5, // A ^ B
    lt = 6, // signed(A) < signed(B) ? 1 : 0
    ltu = 7, // unsigned(A) < unsigned(B) ? 1 : 0
    shl7_or = 8, // (A << 7) | B  (for shi instruction)

    // Multiply/divide (may be multi-cycle or trapped)
    mul = 9, // (A * B) & WORDMASK
    mulh = 10, // unsigned(A * B) >> WORDSIZE
    div = 11, // signed(A / B)
    divu = 12, // unsigned(A / B)
    mod = 13, // signed(A % B)
    modu = 14, // unsigned(A % B)

    // Conditional select (3-input: A=cond, B=true_val, C=false_val from ROS)
    select = 15, // A != 0 ? B : C
};

// ============================================================================
// Funnel Shifter Unit
// ============================================================================
// Implements: ({hi, lo} << shift) >> WORDSIZE
// All shift operations (sll, srl, sra, fsl) use this single hardware unit.
//
// sll: hi=operand,   lo=0,         shift=amount        -> operand << amount
// srl: hi=0,         lo=operand,   shift=WORDSIZE-amt  -> operand >> amount (logical)
// sra: hi=sign_fill, lo=operand,   shift=WORDSIZE-amt  -> operand >> amount (arithmetic)
// fsl: hi=ros,       lo=nos,       shift=tos           -> ({ros,nos} << tos) >> WORDSIZE

/// Funnel shifter high word (upper bits) source
/// For ({hi, lo} << shift) >> WORDSIZE:
/// - sll uses hi=NOS, lo=0, shift=TOS
/// - srl uses hi=0, lo=NOS, shift=WORDSIZE-TOS
/// - sra uses hi=sign_fill, lo=NOS, shift=WORDSIZE-TOS
/// - fsl uses hi=ROS, lo=NOS, shift=TOS
pub const FslHiSrc = enum(u2) {
    zero = 0, // 0 (for srl)
    nos = 1, // NOS value (for sll)
    ros = 2, // ROS value (for fsl)
    sign_fill = 3, // All 1s if NOS MSB set, else 0 (for sra)
};

/// Funnel shifter low word source
pub const FslLoSrc = enum(u2) {
    zero = 0, // 0 (for sll)
    nos = 1, // NOS value (for srl, sra, fsl)
};

/// Funnel shifter shift amount source
pub const FslShiftSrc = enum(u2) {
    tos = 0, // TOS value directly (for sll, fsl)
    neg_tos = 1, // WORDSIZE - TOS (for srl, sra)
};

/// Funnel shifter shift amount mask
/// Controls whether shift amount is masked to WORDSIZE-1 or 2*WORDSIZE-1
pub const FslShiftMask = enum(u1) {
    single_word = 0, // Mask to WORDSIZE-1 (for sll, srl, sra)
    double_word = 1, // Mask to 2*WORDSIZE-1 (for fsl)
};

// ============================================================================
// Stack Control Enums
// ============================================================================

/// TOS register source mux
pub const TosSrc = enum(u3) {
    hold = 0, // keep current value
    result = 1, // from result bus
    nos = 2, // from NOS (swap, pop effect)
    ros = 3, // from ROS (rot, deep pop)
    stack_mem = 4, // from stack memory (very deep pop)
    mem_data = 5, // direct from memory (bypasses bus, for lnw)
};

/// NOS register source mux
pub const NosSrc = enum(u2) {
    hold = 0, // keep current value
    tos = 1, // from TOS (swap, push effect)
    ros = 2, // from ROS (pop effect)
    stack_mem = 3, // from stack memory
};

/// ROS register source mux
pub const RosSrc = enum(u2) {
    hold = 0, // keep current value
    nos = 1, // from NOS (push effect)
    tos = 2, // from TOS (rot)
    stack_mem = 3, // from stack memory
};

/// Stack depth modification
pub const DepthOp = enum(u3) {
    none = 0, // no change
    inc = 1, // depth += 1 (push)
    dec = 2, // depth -= 1 (pop one)
    dec2 = 3, // depth -= 2 (pop two)
    dec3 = 4, // depth -= 3 (select: pop 3, push 1 = net -2)
};

// ============================================================================
// Memory Control Enums
// ============================================================================

/// Memory operation type
pub const MemOp = enum(u3) {
    none = 0,
    read_byte = 1, // load byte, sign-extend
    read_half = 2, // load half-word, sign-extend
    read_word = 3, // load word
    write_byte = 4, // store byte
    write_half = 5, // store half-word
    write_word = 6, // store word
};

/// Memory address source
pub const MemAddrSrc = enum(u2) {
    tos = 0, // address from TOS
    fp_plus_tos = 1, // address = FP + TOS (local variables)
    ar = 2, // address from AR (lnw/snw)
};

/// Memory write data source (for store operations)
pub const MemDataSrc = enum(u1) {
    nos = 0, // write data from NOS (default for sw, sh, sb, slw)
    tos = 1, // write data from TOS (for snw)
};

// ============================================================================
// Control Flow Enums
// ============================================================================

/// PC source selection
pub const PcSrc = enum(u3) {
    next = 0, // PC + 1 (sequential)
    rel_tos = 1, // PC + TOS (relative branch/jump)
    abs_tos = 2, // TOS (absolute jump)
    evec = 3, // EVEC (exception vector)
    epc = 4, // EPC (return from exception)
    hold = 5, // don't update (multi-cycle stall)
    // macro_vec removed: extended ops are hardware-implemented in this design
};

/// Branch condition
pub const BranchCond = enum(u2) {
    always = 0, // always take the branch/jump
    if_nos_zero = 1, // branch if NOS == 0 (for beqz)
    if_nos_nzero = 2, // branch if NOS != 0 (for bnez)
};

// ============================================================================
// CSR Control
// ============================================================================

/// CSR operation
pub const CsrOp = enum(u2) {
    none = 0,
    read = 1, // read CSR[TOS] -> csr_data on bus
    write = 2, // write NOS -> CSR[TOS]
};

// ============================================================================
// Status Bit Control
// ============================================================================

/// Source for the KM (kernel mode) bit
pub const KmSrc = enum(u2) {
    hold = 0, // keep current value
    set = 1, // set to 1 (enter kernel mode)
    estatus = 2, // restore from estatus.km (for rets)
};

/// Source for the IE (interrupt enable) bit
pub const IeSrc = enum(u2) {
    hold = 0, // keep current value
    clear = 1, // set to 0 (disable interrupts)
    estatus = 2, // restore from estatus.ie (for rets)
};

/// Source for the TH (trap halt) bit - rarely changed
pub const ThSrc = enum(u1) {
    hold = 0,
    estatus = 1, // restore from estatus.th (for rets)
};

// ============================================================================
// Exception Detection Control
// ============================================================================

/// What condition to check for exceptions
/// Note: Underflow and overflow are checked automatically based on min_depth_required
/// and depth_op fields - they don't need explicit exception_check values.
pub const ExceptionCheck = enum(u2) {
    none = 0, // no exception check
    div_zero = 1, // check if TOS == 0 (for div/mod)
    halt_trap = 2, // check if th bit is set (for halt)
};

// ============================================================================
// Register Write Enables
// ============================================================================

/// Which registers to write this cycle
pub const WriteEnables = packed struct(u9) {
    fp: bool = false, // for pop fp, add fp - input is result bus
    ra: bool = false, // for pop ra, add ra, call/callp - input is result bus
    ar: bool = false, // for pop ar, add ar - input is result bus
    csr: bool = false, // for popcsr - input is nos, index is tos
    epc: bool = false, // exception entry - input is pc
    estatus: bool = false, // exception entry - input is status
    ecause: bool = false, // exception entry - input is ecause_value (from microcode or trap)
    halt: bool = false, // halt instruction - sets halted flip-flop
    th: bool = false, // for setting th bit (not commonly changed)
};

// ============================================================================
// Complete Microcode Word
// ============================================================================

/// Complete micro-operation specification
/// This controls all datapaths for one clock cycle.
///
/// ## Hardware Exception Model
///
/// Exceptions are handled using a hardware-realistic IR mux approach:
///
/// 1. **Exception/Interrupt Detection** (combinational logic in step()):
///    - External interrupt: `irq AND status.ie` (maskable)
///    - Underflow: `depth < min_depth_required`
///    - Overflow: `depth > max_depth` (mode-appropriate threshold)
///    - Instruction-specific: `exception_check` field (div-zero, halt-trap)
///
/// 2. **Trap Signal**: OR of all exception/interrupt conditions
///
/// 3. **Priority Encoder** (produces trap_cause):
///    - Underflow: 0x30 (highest priority)
///    - Overflow: 0x31
///    - Instruction-specific: from `ecause` field
///    - External interrupt: 0xF0 | irq_num (lowest priority)
///
/// 4. **IR Mux**: When trap is asserted, forces the `syscall` opcode (0x02).
///    The syscall instruction already performs the exception entry sequence
///    (save status/pc, set km/ie, jump to evec).
///
/// 5. **Ecause Value**: When trap=1, ecause_value uses trap_cause from priority
///    encoder. Otherwise it uses the microcode's ecause field. This allows
///    syscall to serve dual purposes:
///    - User-executed: ecause = 0x00
///    - Hardware trap: ecause = trap_cause (underflow/overflow/div-zero/etc)
///
/// 6. **Intentional Traps** (illegal instructions): Use their own microcode
///    with writes.ecause = true. The trap signal won't be set for these since
///    they don't trigger exception_check conditions, so their immediate ecause
///    is used directly.
///
/// This design ensures all operations happen through mux selection with no
/// conditional early returns - matching real hardware behavior.
pub const MicroOp = struct {
    // Result bus source (what value to put on the result bus)
    result_src: ResultSrc = .zero,

    // ALU control
    alu_op: AluOp = .pass_a,
    alu_a: AluASrc = .nos,
    alu_b: AluBSrc = .zero,

    // Funnel shifter control (separate from ALU)
    // Computes: ({fsl_hi, fsl_lo} << fsl_shift) >> WORDSIZE
    fsl_hi: FslHiSrc = .zero,
    fsl_lo: FslLoSrc = .zero,
    fsl_shift: FslShiftSrc = .tos,
    fsl_mask: FslShiftMask = .single_word, // default to single word mask for safety

    // Stack register sources
    tos_src: TosSrc = .hold,
    nos_src: NosSrc = .hold,
    ros_src: RosSrc = .hold,
    depth_op: DepthOp = .none,

    // Memory control
    mem_op: MemOp = .none,
    mem_addr: MemAddrSrc = .tos,
    mem_data: MemDataSrc = .nos, // source for store data

    // PC control
    pc_src: PcSrc = .next,
    branch_cond: BranchCond = .always,

    // CSR control
    csr_op: CsrOp = .none,

    // Register write enables
    writes: WriteEnables = .{},

    // Status register bit controls (active when no exception)
    km_src: KmSrc = .hold,
    ie_src: IeSrc = .hold,

    // Exception detection
    exception_check: ExceptionCheck = .none,

    // Exception cause value (used when writes.ecause is true)
    ecause: u8 = 0,

    // Stack safety: minimum depth required to execute without underflow
    // Hardware comparator checks: if (depth < min_depth_required) raise underflow
    // 0 = no stack access needed
    // 1 = needs valid TOS
    // 2 = needs valid TOS and NOS
    // 3 = needs valid TOS, NOS, and ROS
    min_depth: u2 = 0,
};

// ============================================================================
// Microcode ROM Generator
// ============================================================================

/// Opcode extraction from instruction byte
pub const Opcode = enum(u7) {
    // Basic ops (0x00-0x0F)
    halt = 0x00,
    reserved_01 = 0x01,
    syscall = 0x02, // Also used by IR mux for hardware exceptions
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

    // Register ops (0x10-0x1F)
    push_pc = 0x10,
    push_fp = 0x11,
    push_ra = 0x12,
    push_ar = 0x13,
    pop_pc = 0x14, // aka ret, jumpp
    pop_fp = 0x15,
    pop_ra = 0x16,
    pop_ar = 0x17,
    jump = 0x18, // aka add_pc
    add_fp = 0x19,
    add_ra = 0x1A,
    add_ar = 0x1B,
    pushcsr = 0x1C,
    popcsr = 0x1D,
    llw = 0x1E,
    slw = 0x1F,

    // Extended ALU (0x20-0x2F) - may trap to macro handler
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

    // Extended memory (0x30-0x37)
    lb = 0x30,
    sb = 0x31,
    lh = 0x32,
    sh = 0x33,
    lw = 0x34,
    sw = 0x35,
    lnw = 0x36,
    snw = 0x37,

    // Extended control (0x38-0x3F)
    call = 0x38,
    callp = 0x39,
    ext_reserved_3A = 0x3A,
    ext_reserved_3B = 0x3B,
    ext_reserved_3C = 0x3C,
    ext_reserved_3D = 0x3D,
    ext_reserved_3E = 0x3E,
    ext_reserved_3F = 0x3F,

    push = 0x40, // push immediate (special case, not in 6-bit opcode space)
    shi = 0x41, // shift immediate (special case, not in 6-bit opcode space)
};

/// Generate microcode for a single instruction
fn generateMicrocode(opcode: Opcode) MicroOp {
    return switch (opcode) {
        // ================================================================
        // Basic Instructions (must be in hardware)
        // ================================================================

        .push => .{
            .result_src = .imm_sext6,
            .tos_src = .result,
            .nos_src = .tos,
            .ros_src = .nos,
            .depth_op = .inc,
            .min_depth = 0, // Just pushes immediate, no stack read
        },

        .shi => .{
            .result_src = .alu_out,
            .alu_op = .shl7_or,
            .alu_a = .tos,
            .alu_b = .imm7,
            .tos_src = .result,
            .min_depth = 1, // Reads TOS to shift
        },

        .halt => .{
            // Halt CPU (when th=0), or trap (when th=1)
            //
            // Hardware behavior:
            // - exception_check = .halt_trap produces trap signal when th=1
            // - When trap=1: IR mux forces trap instruction, this microcode ignored
            // - When trap=0: This microcode runs, CPU halts
            //
            // This microcode only handles the non-trapping case.
            // The ecause field feeds the priority encoder for the trapping case.
            .pc_src = .hold,
            .writes = .{ .halt = true },
            .exception_check = .halt_trap,
            .ecause = 0x12, // For priority encoder when trap is taken
            .min_depth = 0, // No stack access
        },

        .reserved_01 => .{
            // Illegal instruction - unconditional exception
            .pc_src = .evec,
            .km_src = .set,
            .ie_src = .clear,
            .writes = .{ .epc = true, .estatus = true, .ecause = true },
            .ecause = 0x10,
            .min_depth = 0, // No stack access
        },

        .syscall => .{
            // System call exception entry.
            //
            // This instruction serves dual purposes:
            // 1. User-executed syscall: ecause = 0x00 (from microcode)
            // 2. Hardware exception: IR mux forces this opcode, trap signal
            //    overrides ecause to use trap_cause from priority encoder
            //
            // The trap signal controls the ecause value in commitRegisters().
            // Stack is unchanged - exceptions must preserve stack state.
            .pc_src = .evec,
            .km_src = .set,
            .ie_src = .clear,
            .writes = .{ .epc = true, .estatus = true, .ecause = true },
            .ecause = 0x00, // Used when trap=0 (normal syscall)
            .min_depth = 0, // No stack access
        },

        .rets => .{
            // Return from exception - restore status from estatus
            // Overflow is automatically checked against destination mode (estatus.km)
            // because km_src == .estatus
            .pc_src = .epc,
            .km_src = .estatus,
            .ie_src = .estatus,
            .writes = .{.th = true},
            .min_depth = 0, // No stack access
        },

        .beqz => .{
            // Branch if NOS == 0, target = PC + TOS, pop both
            .pc_src = .rel_tos,
            .branch_cond = .if_nos_zero,
            .tos_src = .ros,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 2, // Reads TOS (offset) and NOS (condition)
        },

        .bnez => .{
            // Branch if NOS != 0, target = PC + TOS, pop both
            .pc_src = .rel_tos,
            .branch_cond = .if_nos_nzero,
            .tos_src = .ros,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 2, // Reads TOS (offset) and NOS (condition)
        },

        .swap => .{
            // TOS <-> NOS
            .tos_src = .nos,
            .nos_src = .tos,
            .min_depth = 2, // Reads both TOS and NOS
        },

        .over => .{
            // Push NOS (duplicate second element to top)
            .result_src = .nos,
            .tos_src = .result,
            .nos_src = .tos,
            .ros_src = .nos,
            .depth_op = .inc,
            .min_depth = 2, // Reads NOS to duplicate it
        },

        .drop => .{
            // Pop and discard TOS
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1, // Need at least one item to drop
        },

        .dup => .{
            // Duplicate TOS
            .tos_src = .hold, // TOS keeps same value
            .nos_src = .tos, // NOS gets old TOS
            .ros_src = .nos, // ROS gets old NOS
            .depth_op = .inc,
            .min_depth = 1, // Reads TOS to duplicate it
        },

        .ltu => .{
            // Unsigned less than: push(NOS < TOS ? 1 : 0), pop both
            .result_src = .alu_out,
            .alu_op = .ltu,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2, // Binary op on TOS and NOS
        },

        .lt => .{
            // Signed less than
            .result_src = .alu_out,
            .alu_op = .lt,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2, // Binary op on TOS and NOS
        },

        .add => .{
            // Addition: push(NOS + TOS), pop both
            .result_src = .alu_out,
            .alu_op = .add,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2, // Binary op on TOS and NOS
        },

        .and_op => .{
            // Bitwise AND
            .result_src = .alu_out,
            .alu_op = .and_op,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2, // Binary op on TOS and NOS
        },

        .xor_op => .{
            // Bitwise XOR
            .result_src = .alu_out,
            .alu_op = .xor_op,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2, // Binary op on TOS and NOS
        },

        .fsl => .{
            // Funnel shift left: ({ROS, NOS} << TOS) >> WORDSIZE
            // hi=ROS, lo=NOS, shift=TOS
            .result_src = .fsl_out,
            .fsl_hi = .ros,
            .fsl_lo = .nos,
            .fsl_shift = .tos,
            .fsl_mask = .double_word, // fsl uses full 2*WORDSIZE shift range
            .tos_src = .result,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 3, // Uses TOS, NOS, and ROS
        },

        // ================================================================
        // Register Operations
        // ================================================================

        .push_pc => .{
            .result_src = .pc,
            .tos_src = .result,
            .nos_src = .tos,
            .ros_src = .nos,
            .depth_op = .inc,
            .min_depth = 0, // Pushes from register, no stack read
        },

        .push_fp => .{
            .result_src = .fp,
            .tos_src = .result,
            .nos_src = .tos,
            .ros_src = .nos,
            .depth_op = .inc,
            .min_depth = 0, // Pushes from register, no stack read
        },

        .push_ra => .{
            .result_src = .ra,
            .tos_src = .result,
            .nos_src = .tos,
            .ros_src = .nos,
            .depth_op = .inc,
            .min_depth = 0, // Pushes from register, no stack read
        },

        .push_ar => .{
            .result_src = .ar,
            .tos_src = .result,
            .nos_src = .tos,
            .ros_src = .nos,
            .depth_op = .inc,
            .min_depth = 0, // Pushes from register, no stack read
        },

        .pop_pc => .{
            // ret / jumpp - absolute jump to TOS
            .pc_src = .abs_tos,
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1, // Reads TOS for jump target
        },

        .pop_fp => .{
            .result_src = .tos,
            .writes = .{ .fp = true },
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1, // Reads TOS
        },

        .pop_ra => .{
            .result_src = .tos,
            .writes = .{ .ra = true },
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1, // Reads TOS
        },

        .pop_ar => .{
            .result_src = .tos,
            .writes = .{ .ar = true },
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1, // Reads TOS
        },

        .jump => .{
            // jump - relative: PC = PC + TOS
            .pc_src = .rel_tos,
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1, // Reads TOS for offset
        },

        .add_fp => .{
            // FP = FP + TOS
            .result_src = .alu_out,
            .alu_op = .add,
            .alu_a = .fp,
            .alu_b = .tos,
            .writes = .{ .fp = true },
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1, // Reads TOS
        },

        .add_ra => .{
            // RA = RA + TOS
            .result_src = .alu_out,
            .alu_op = .add,
            .alu_a = .ra,
            .alu_b = .tos,
            .writes = .{ .ra = true },
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1, // Reads TOS
        },

        .add_ar => .{
            // AR = AR + TOS
            .result_src = .alu_out,
            .alu_op = .add,
            .alu_a = .ar,
            .alu_b = .tos,
            .writes = .{ .ar = true },
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1, // Reads TOS
        },

        .pushcsr => .{
            // Push CSR[TOS] onto stack (replaces TOS)
            .result_src = .csr_data,
            .csr_op = .read,
            .tos_src = .result,
            // No depth change - TOS is replaced, not pushed
            .min_depth = 1, // Reads TOS for CSR index
        },

        .popcsr => .{
            // CSR[TOS] = NOS, pop both
            .csr_op = .write,
            .writes = .{ .csr = true },
            .tos_src = .ros,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 2, // Reads TOS (index) and NOS (value)
        },

        .llw => .{
            // Load local word: push(mem[FP + TOS]), replaces TOS
            .mem_op = .read_word,
            .mem_addr = .fp_plus_tos,
            .result_src = .mem_data,
            .tos_src = .result,
            // TOS replaced, no depth change
            .min_depth = 1, // Reads TOS for offset
        },

        .slw => .{
            // Store local word: mem[FP + TOS] = NOS, pop both
            .mem_op = .write_word,
            .mem_addr = .fp_plus_tos,
            .result_src = .nos, // data to write
            .tos_src = .ros,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 2, // Reads TOS (offset) and NOS (value)
        },

        // ================================================================
        // Extended ALU Operations (may trap to software)
        // ================================================================

        .div => .{
            // Signed division with divide-by-zero check
            //
            // Hardware behavior:
            // - exception_check = .div_zero produces trap signal when TOS==0
            // - When trap=1: IR mux forces trap instruction, this microcode ignored
            // - When trap=0: This microcode runs, division executed
            //
            // The ecause field feeds the priority encoder for the trapping case.
            .result_src = .alu_out,
            .alu_op = .div,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .exception_check = .div_zero,
            .ecause = 0x40, // For priority encoder when trap is taken
            .min_depth = 2, // Binary op on TOS and NOS
        },

        .divu => .{
            // Unsigned division with divide-by-zero check
            // (Same trap mechanism as div - see div for detailed comments)
            .result_src = .alu_out,
            .alu_op = .divu,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .exception_check = .div_zero,
            .ecause = 0x40, // For priority encoder when trap is taken
            .min_depth = 2, // Binary op on TOS and NOS
        },

        .mod => .{
            // Signed modulus with divide-by-zero check
            // (Same trap mechanism as div - see div for detailed comments)
            .result_src = .alu_out,
            .alu_op = .mod,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .exception_check = .div_zero,
            .ecause = 0x40, // For priority encoder when trap is taken
            .min_depth = 2, // Binary op on TOS and NOS
        },

        .modu => .{
            // Unsigned modulus with divide-by-zero check
            // (Same trap mechanism as div - see div for detailed comments)
            .result_src = .alu_out,
            .alu_op = .modu,
            .alu_a = .nos,
            .alu_b = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .exception_check = .div_zero,
            .ecause = 0x40, // For priority encoder when trap is taken
            .min_depth = 2, // Binary op on TOS and NOS
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
            .min_depth = 2, // Binary op on TOS and NOS
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
            .min_depth = 2, // Binary op on TOS and NOS
        },

        .select => .{
            // if TOS then NOS else ROS
            .result_src = .alu_out,
            .alu_op = .select,
            .alu_a = .tos, // condition
            .alu_b = .nos, // true value
            .tos_src = .result,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 3, // Uses TOS (cond), NOS (true), ROS (false)
        },

        .rot => .{
            // Rotate: TOS->ROS, NOS->TOS, ROS->NOS
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .tos,
            .min_depth = 3, // Accesses all three: TOS, NOS, ROS
        },

        .srl => .{
            // Shift right logical: NOS >> TOS
            // Implemented as: ({0, NOS} << (WORDSIZE - TOS)) >> WORDSIZE
            .result_src = .fsl_out,
            .fsl_hi = .zero,
            .fsl_lo = .nos,
            .fsl_shift = .neg_tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2, // Binary shift: NOS >> TOS
        },

        .sra => .{
            // Shift right arithmetic: NOS >> TOS (signed)
            // Implemented as: ({sign_fill, NOS} << (WORDSIZE - TOS)) >> WORDSIZE
            .result_src = .fsl_out,
            .fsl_hi = .sign_fill,
            .fsl_lo = .nos,
            .fsl_shift = .neg_tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2, // Binary shift: NOS >> TOS
        },

        .sll => .{
            // Shift left logical: NOS << TOS
            // Implemented as: ({NOS, 0} << TOS) >> WORDSIZE
            .result_src = .fsl_out,
            .fsl_hi = .nos,
            .fsl_lo = .zero,
            .fsl_shift = .tos,
            .tos_src = .result,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 2, // Binary shift: NOS << TOS
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
            .min_depth = 2, // Binary op on TOS and NOS
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
            .min_depth = 2, // Binary op on TOS and NOS
        },

        // Reserved extended ALU ops - trap as illegal instruction
        .ext_reserved_2D, .ext_reserved_2E, .ext_reserved_2F => .{
            .pc_src = .evec,
            .km_src = .set,
            .ie_src = .clear,
            .writes = .{ .epc = true, .estatus = true, .ecause = true },
            .ecause = 0x10,
            .min_depth = 0, // Illegal instruction, no stack access
        },

        // ================================================================
        // Extended Memory Operations
        // ================================================================

        .lb => .{
            // Load byte, sign-extend (sign extension done in mem_data path)
            .mem_op = .read_byte,
            .mem_addr = .tos,
            .result_src = .mem_data,
            .tos_src = .result,
            .min_depth = 1, // Reads TOS for address
        },

        .sb => .{
            // Store byte
            .mem_op = .write_byte,
            .mem_addr = .tos,
            .result_src = .nos,
            .tos_src = .ros,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 2, // Reads TOS (addr) and NOS (value)
        },

        .lh => .{
            // Load half-word, sign-extend
            .mem_op = .read_half,
            .mem_addr = .tos,
            .result_src = .mem_data,
            .tos_src = .result,
            .min_depth = 1, // Reads TOS for address
        },

        .sh => .{
            // Store half-word
            .mem_op = .write_half,
            .mem_addr = .tos,
            .result_src = .nos,
            .tos_src = .ros,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 2, // Reads TOS (addr) and NOS (value)
        },

        .lw => .{
            // Load word
            .mem_op = .read_word,
            .mem_addr = .tos,
            .result_src = .mem_data,
            .tos_src = .result,
            .min_depth = 1, // Reads TOS for address
        },

        .sw => .{
            // Store word
            .mem_op = .write_word,
            .mem_addr = .tos,
            .result_src = .nos,
            .tos_src = .ros,
            .nos_src = .stack_mem,
            .ros_src = .stack_mem,
            .depth_op = .dec2,
            .min_depth = 2, // Reads TOS (addr) and NOS (value)
        },

        .lnw => .{
            // Load next word from AR, auto-increment AR
            // Memory data goes direct to TOS (bypassing bus)
            // Bus/ALU used for AR = AR + WORDBYTES
            .mem_op = .read_word,
            .mem_addr = .ar,
            .result_src = .alu_out,
            .alu_op = .add,
            .alu_a = .ar,
            .alu_b = .wordbytes,
            .writes = .{ .ar = true },
            .tos_src = .mem_data, // direct path from memory
            .nos_src = .tos,
            .ros_src = .nos,
            .depth_op = .inc,
            .min_depth = 0, // Reads from AR register, no stack read
        },

        .snw => .{
            // Store TOS to AR, auto-increment AR, pop
            // Memory write data comes from TOS directly (via mem_data mux)
            // Bus/ALU used for AR = AR + WORDBYTES
            .mem_op = .write_word,
            .mem_addr = .ar,
            .mem_data = .tos, // write TOS to memory
            .result_src = .alu_out,
            .alu_op = .add,
            .alu_a = .ar,
            .alu_b = .wordbytes,
            .writes = .{ .ar = true },
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1, // Reads TOS for value to store
        },

        // ================================================================
        // Extended Control Flow
        // ================================================================

        .call => .{
            // RA = PC, PC = PC + TOS, pop TOS
            .result_src = .pc,
            .writes = .{ .ra = true },
            .pc_src = .rel_tos,
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1, // Reads TOS for target offset
        },

        .callp => .{
            // RA = PC, PC = TOS, pop TOS
            .result_src = .pc,
            .writes = .{ .ra = true },
            .pc_src = .abs_tos,
            .tos_src = .nos,
            .nos_src = .ros,
            .ros_src = .stack_mem,
            .depth_op = .dec,
            .min_depth = 1, // Reads TOS for absolute target
        },

        // Reserved control ops - trap as illegal instruction
        .ext_reserved_3A, .ext_reserved_3B, .ext_reserved_3C, .ext_reserved_3D, .ext_reserved_3E, .ext_reserved_3F => .{
            .pc_src = .evec,
            .km_src = .set,
            .ie_src = .clear,
            .writes = .{ .epc = true, .estatus = true, .ecause = true },
            .ecause = 0x10,
            .min_depth = 0, // Illegal instruction, no stack access
        },
    };
}

/// ROM has 256 entries (one per possible instruction byte)
pub const MICROCODE_ROM_SIZE = 66;

/// Generate the complete microcode ROM at compile time
pub fn generateMicrocodeRom() [MICROCODE_ROM_SIZE]MicroOp {
    var rom: [MICROCODE_ROM_SIZE]MicroOp = undefined;

    for (0..63) |i| {
        // O-format instruction (00xxxxxx)
        const opcode: Opcode = @enumFromInt(i & 0x3F);
        rom[i] = generateMicrocode(opcode);
    }
    rom[64] = generateMicrocode(.push); // push immediate (0x40)
    rom[65] = generateMicrocode(.shi);  // shift immediate (0x41)

    return rom;
}

/// Compile-time generated ROM
pub const microcode_rom = generateMicrocodeRom();

// ============================================================================
// Emulator Execution Engine
// ============================================================================

/// Core registers that are frequently accessed during instruction execution.
/// Separating these into a struct improves cache locality and makes it easier
/// to snapshot/restore register state.
pub const Regs = struct {
    // Program counter
    pc: Word = 0,

    // General purpose registers
    ra: Word = 0, // Return address
    ar: Word = 0, // Address register

    // Frame pointer registers (physical)
    // The "fp" and "afp" seen by software are mux outputs based on km bit
    ufp: Word = 0, // User frame pointer
    kfp: Word = 0, // Kernel frame pointer

    // Data stack top registers
    tos: Word = 0, // Top of stack
    nos: Word = 0, // Next on stack
    ros: Word = 0, // Rest of stack (third element)

    // Stack depth
    depth: Word = 0,

    // Status registers (packed bitfields)
    status: Status = .{ .km = true }, // Boot in kernel mode
    estatus: Status = .{},

    // Exception-related registers (frequently accessed)
    epc: Word = 0,
    evec: Word = 0,

    // FP/AFP are mux outputs based on status.km bit - not actual registers
    pub fn fp(self: *const Regs) Word {
        return if (self.status.km) self.kfp else self.ufp;
    }

    pub fn afp(self: *const Regs) Word {
        return if (self.status.km) self.ufp else self.kfp;
    }
};

pub const CpuState = struct {
    // Core registers (frequently accessed during execution)
    reg: Regs = .{},

    // Stack memory backing (for depth > 3)
    stack_mem: [256]Word = [_]Word{0} ** 256,

    // Exception cause (written but rarely read in execution path)
    ecause: Word = 0,

    // Memory protection CSRs (only accessed during address translation)
    udmask: Word = 0,
    udset: Word = 0,
    upmask: Word = 0,
    upset: Word = 0,
    kdmask: Word = 0,
    kdset: Word = 0,
    kpmask: Word = 0,
    kpset: Word = 0,

    // Main memory
    memory: []u8,

    // Halt flip-flop
    halted: bool = false,

    // Logging control
    log_enabled: bool = true,

    pub fn init(memory: []u8) CpuState {
        return .{ .memory = memory };
    }

    // Convenience accessors that delegate to reg
    pub fn fp(self: *const CpuState) Word {
        return self.reg.fp();
    }

    pub fn afp(self: *const CpuState) Word {
        return self.reg.afp();
    }

    // Stack memory access (for depth > 3)
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

    // Memory access with address translation
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
        // Simplified - full impl would check mask/set registers
        _ = self;
        return @intCast(vaddr);
    }

    // CSR access
    pub fn readCsr(self: *const CpuState, index: Word) Word {
        return switch (index) {
            0 => self.reg.status.toWord(),
            1 => self.reg.estatus.toWord(),
            2 => self.reg.epc,
            3 => self.afp(), // mux output based on km
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
                // Write to afp - writes to the "other" fp register
                if (self.reg.status.km) {
                    self.reg.ufp = value;
                } else {
                    self.reg.kfp = value;
                }
            },
            4 => self.reg.depth = 0, // writes reset to 0
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

    /// Run until halted or max cycles
    pub fn run(self: *CpuState, max_cycles: usize) usize {
        var cycles: usize = 0;
        while (!self.halted and cycles < max_cycles) {
            step(self, false, 0); // TODO: implement interrupts
            cycles += 1;
        }
        return cycles;
    }
};

/// Execute one micro-operation (optimized inline version).
///
/// This executes a single clock cycle, only computing values that are
/// actually needed by the microcode operation.
///
/// Parameters:
/// - cpu: CPU state
/// - uop: Microcode operation to execute (from IR mux output)
/// - instr: Original fetched instruction (for immediate extraction)
/// - trap: True if hardware exception detected (controls ecause mux)
/// - trap_cause: Exception cause from priority encoder (used when trap=true)
pub inline fn executeMicroOp(cpu: *CpuState, uop: MicroOp, instr: u8, trap: bool, trap_cause: u8) void {
    // Snapshot registers for reading - all reads use this copy
    // All writes go directly to cpu.reg, making execution order irrelevant
    const r = cpu.reg;

    // ========================================
    // Result bus computation
    // ========================================
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

    // ========================================
    // Memory operations
    // ========================================
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

    // Stack spill (for push when depth >= 3)
    if (uop.depth_op == .inc and r.depth >= 3) {
        cpu.writeStackMem(@intCast(r.depth -% 3), r.ros);
    }

    // CSR write
    if (uop.writes.csr) {
        cpu.writeCsr(r.tos, r.nos);
    }

    // ========================================
    // Register writes - order doesn't matter since all reads use snapshot
    // ========================================

    // TOS
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

    // NOS
    cpu.reg.nos = switch (uop.nos_src) {
        .hold => r.nos,
        .tos => r.tos,
        .ros => r.ros,
        .stack_mem => cpu.readStackMem(@intCast(r.depth -% 4)),
    };

    // ROS
    cpu.reg.ros = switch (uop.ros_src) {
        .hold => r.ros,
        .nos => r.nos,
        .tos => r.tos,
        .stack_mem => switch (uop.depth_op) {
            .dec2, .dec3 => cpu.readStackMem(@intCast(r.depth -% 5)),
            else => cpu.readStackMem(@intCast(r.depth -% 4)),
        },
    };

    // Depth
    cpu.reg.depth = switch (uop.depth_op) {
        .none => r.depth,
        .inc => r.depth +% 1,
        .dec => if (r.depth > 0) r.depth -% 1 else 0,
        .dec2 => if (r.depth >= 2) r.depth -% 2 else 0,
        .dec3 => if (r.depth >= 3) r.depth -% 3 else 0,
    };

    // PC
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

    // Status
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

    // FP write
    if (uop.writes.fp) {
        if (r.status.km) {
            cpu.reg.kfp = result;
        } else {
            cpu.reg.ufp = result;
        }
    }

    // RA write
    if (uop.writes.ra) {
        cpu.reg.ra = result;
    }

    // AR write
    if (uop.writes.ar) {
        cpu.reg.ar = result;
    }

    // Estatus write (uses snapshot status, not new status)
    if (uop.writes.estatus) {
        cpu.reg.estatus = r.status;
    }

    // EPC write (uses snapshot pc, not new pc)
    if (uop.writes.epc) {
        cpu.reg.epc = r.pc;
    }

    // Ecause write
    if (uop.writes.ecause) {
        cpu.ecause = if (trap) trap_cause else uop.ecause;
    }

    // Halt
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

/// Get mnemonic string for an instruction byte
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

/// Format immediate value for display
fn formatImmediate(instr: u8, buf: *[32]u8) []const u8 {
    if (instr & 0x80 != 0) {
        // shi: 7-bit immediate
        const imm7 = instr & 0x7F;
        return std.fmt.bufPrint(buf, " 0x{x:0>2}", .{imm7}) catch "???";
    } else if (instr & 0xC0 == 0x40) {
        // push: 6-bit sign-extended immediate
        const imm6: i6 = @bitCast(@as(u6, @truncate(instr & 0x3F)));
        const extended: i16 = imm6;
        if (extended < 0) {
            return std.fmt.bufPrint(buf, " {d}", .{extended}) catch "???";
        } else {
            return std.fmt.bufPrint(buf, " {d}", .{extended}) catch "???";
        }
    } else {
        return "";
    }
}

/// Log detailed instruction execution info
fn logInstruction(cpu: *const CpuState, pc_before: Word, instr: u8, uop: MicroOp, trap: bool, trap_cause: u8) void {
    var imm_buf: [32]u8 = undefined;
    const mnemonic = getInstrMnemonic(instr);
    const imm_str = formatImmediate(instr, &imm_buf);

    // Build operation summary
    var summary_buf: [128]u8 = undefined;
    var summary_len: usize = 0;

    // Stack state: TOS NOS ROS [depth]
    const stack_info = std.fmt.bufPrint(summary_buf[summary_len..], "stk:[{x:0>4},{x:0>4},{x:0>4}]d={d}", .{
        cpu.reg.tos,
        cpu.reg.nos,
        cpu.reg.ros,
        cpu.reg.depth,
    }) catch "";
    summary_len += stack_info.len;

    // Add trap info if applicable
    if (trap) {
        const trap_info = std.fmt.bufPrint(summary_buf[summary_len..], " TRAP:{x:0>2}", .{trap_cause}) catch "";
        summary_len += trap_info.len;
    }

    // Add PC change info
    if (uop.pc_src != .next and uop.pc_src != .hold) {
        const pc_info = std.fmt.bufPrint(summary_buf[summary_len..], " pc:{s}", .{@tagName(uop.pc_src)}) catch "";
        summary_len += pc_info.len;
    }

    // Add depth change
    if (uop.depth_op != .none) {
        const depth_info = std.fmt.bufPrint(summary_buf[summary_len..], " dep:{s}", .{@tagName(uop.depth_op)}) catch "";
        summary_len += depth_info.len;
    }

    // Add memory operation
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

/// Execute one instruction using microcode ROM
///
/// This models the hardware behavior:
/// 1. Fetch instruction from memory
/// 2. Advance PC (so PC points to next instruction during execution)
/// 3. Look up fetched instruction's microcode for exception detection
/// 4. Exception/interrupt detection (combinational logic):
///    - Interrupt: irq=true AND status.ie=true (maskable)
///    - Underflow: depth < min_depth_required
///    - Overflow: depth > max_depth (mode-appropriate)
///    - Instruction-specific: div-by-zero, halt-trap
/// 5. Priority encoder produces trap_cause
/// 6. IR mux: if trap, force syscall instruction; else use fetched instruction
/// 7. Execute selected microcode
///
/// Parameters:
/// - cpu: CPU state
/// - irq: External interrupt request (directly from hardware bus)
/// - irq_num: Interrupt number 0-15 (used when irq=true)
pub inline fn step(cpu: *CpuState, irq: bool, irq_num: u4) void {
    if (cpu.halted) return;

    // ========================================
    // Fetch stage
    // ========================================
    const pc_before = cpu.reg.pc; // Save PC for debug logging
    const fetched_instr = cpu.readByte(cpu.reg.pc);
    cpu.reg.pc +%= 1; // Advance PC (now points to next instruction)

    // ========================================
    // Decode stage - get microcode for exception detection
    // ========================================
    const fetched_uop = if ((fetched_instr & 0x80) != 0)
        // shi instruction
        microcode_rom[65]
     else if ((fetched_instr & 0xC0) == 0x40)
        // push instruction
        microcode_rom[64]
     else
        microcode_rom[fetched_instr&0x3F];

    // ========================================
    // Exception/Interrupt detection (combinational logic)
    // ========================================
    // These are parallel comparators in hardware, not sequential checks.

    // External interrupt: masked by IE bit in status register
    // Interrupts are edge-triggered conceptually - the interrupt controller
    // should hold irq high until acknowledged.
    const interrupt: bool = irq and cpu.reg.status.ie;

    // Underflow: instruction needs more stack depth than available
    const underflow: bool = cpu.reg.depth < fetched_uop.min_depth;

    // Overflow threshold depends on destination mode:
    // For rets (km_src == .estatus), we check against estatus.km
    // This ensures rets triggers overflow if returning to user mode with too-deep stack
    const dest_km: bool = if (fetched_uop.km_src == .estatus) cpu.reg.estatus.km else cpu.reg.status.km;
    const max_depth: Word = if (dest_km) KERNEL_MAX_DEPTH else USER_MAX_DEPTH;
    const overflow: bool = cpu.reg.depth > max_depth;

    // Instruction-specific exceptions
    const instr_exception: bool = switch (fetched_uop.exception_check) {
        .none => false,
        .div_zero => cpu.reg.tos == 0,
        .halt_trap => cpu.reg.status.th,
    };

    // Trap signal: OR of all exception/interrupt conditions
    const trap: bool = interrupt or underflow or overflow or instr_exception;

    // ========================================
    // Priority encoder (produces trap_cause)
    // ========================================
    const trap_cause: u8 = if (underflow)
        0x30 // Data stack underflow
    else if (overflow)
        0x31 // Data stack overflow
    else if (instr_exception)
        fetched_uop.ecause // Instruction-specific cause
    else
        0xF0 | @as(u8,irq_num); // External interrupt (category 15, sub-cause = irq number)

    // ========================================
    // IR mux: select instruction based on trap
    // ========================================
    // In hardware, this is a mux on the IR register input.
    // When trap is asserted, the syscall opcode is forced (it performs
    // the same exception entry sequence needed for all exceptions).
    const uop = if (trap) microcode_rom[@intFromEnum(Opcode.syscall)] else fetched_uop;

    // ========================================
    // Debug logging (only when enabled)
    // ========================================
    if (cpu.log_enabled) {
        logInstruction(cpu, pc_before, fetched_instr, uop, trap, trap_cause);
    }

    // ========================================
    // Execute stage
    // ========================================
    // Pass trap flag and trap_cause. When trap=true, the ecause mux uses
    // trap_cause instead of the instruction's immediate ecause field.
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

/// Helper function for tests to run a ROM and return the top of stack value, checking the depth is 1
pub fn runTest(rom_file: []const u8, max_cycles: usize, gpa: std.mem.Allocator) !Word {
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
