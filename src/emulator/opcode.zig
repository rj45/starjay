//! Instruction opcodes and decoding logic shared between emulator implementations.

/// Instruction opcodes for the StarJette CPU.
pub const Opcode = enum(u7) {
    halt = 0x00,
    rets = 0x01,
    syscall = 0x02,
    callp = 0x03,
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
    rel_pc = 0x10,
    rel_fp = 0x11,
    rel_rx = 0x12,
    rel_ry = 0x13,
    pop_pc = 0x14,
    pop_fp = 0x15,
    pop_rx = 0x16,
    pop_ry = 0x17,
    jump = 0x18,
    add_fp = 0x19,
    add_rx = 0x1A,
    add_ry = 0x1B,
    pushcsr = 0x1C,
    popcsr = 0x1D,
    lw = 0x1E,
    sw = 0x1F,
    div = 0x20,
    divu = 0x21,
    mul = 0x22,
    rot = 0x23,
    srl = 0x24,
    sra = 0x25,
    sll = 0x26,
    or_op = 0x27,
    sub = 0x28,
    clz = 0x29,
    lb = 0x2A,
    sb = 0x2B,
    lh = 0x2C,
    sh = 0x2D,
    lnw = 0x2E,
    snw = 0x2F,
    reserved_30 = 0x30,
    reserved_31 = 0x31,
    reserved_32 = 0x32,
    reserved_33 = 0x33,
    reserved_34 = 0x34,
    reserved_35 = 0x35,
    reserved_36 = 0x36,
    reserved_37 = 0x37,
    reserved_38 = 0x38,
    reserved_39 = 0x39,
    reserved_3A = 0x3A,
    reserved_3B = 0x3B,
    reserved_3C = 0x3C,
    reserved_3D = 0x3D,
    reserved_3E = 0x3E,
    reserved_3F = 0x3F,
    push = 0x40,
    shi = 0x41,

    /// Returns the assembly mnemonic for this opcode
    pub fn toMnemonic(self: Opcode) []const u8 {
        return switch (self) {
            .halt => "halt",
            .rets => "rets",
            .syscall => "syscall",
            .callp => "callp",
            .beqz => "beqz",
            .bnez => "bnez",
            .swap => "swap",
            .over => "over",
            .drop => "drop",
            .dup => "dup",
            .ltu => "ltu",
            .lt => "lt",
            .add => "add",
            .and_op => "and",
            .xor_op => "xor",
            .fsl => "fsl",
            .rel_pc => "rel pc",
            .rel_fp => "rel fp",
            .rel_rx => "rel rx",
            .rel_ry => "rel ry",
            .pop_pc => "pop pc",
            .pop_fp => "pop fp",
            .pop_rx => "pop rx",
            .pop_ry => "pop ry",
            .jump => "jump",
            .add_fp => "add fp",
            .add_rx => "add rx",
            .add_ry => "add ry",
            .pushcsr => "pushcsr",
            .popcsr => "popcsr",
            .lw => "lw",
            .sw => "sw",
            .div => "div",
            .divu => "divu",
            .mul => "mul",
            .rot => "rot",
            .srl => "srl",
            .sra => "sra",
            .sll => "sll",
            .or_op => "or",
            .sub => "sub",
            .clz => "clz",
            .lb => "lb",
            .sb => "sb",
            .lh => "lh",
            .sh => "sh",
            .lnw => "lnw",
            .snw => "snw",
            .reserved_30, .reserved_31, .reserved_32, .reserved_33,
            .reserved_34, .reserved_35, .reserved_36, .reserved_37,
            .reserved_38, .reserved_39, .reserved_3A, .reserved_3B,
            .reserved_3C, .reserved_3D, .reserved_3E, .reserved_3F => "???",
            .push => "push",
            .shi => "shi",
        };
    }

    /// Decode a byte into an opcode.
    /// Handles the special encoding for shi (0x80-0xFF) and push (0x40-0x7F).
    pub fn fromByte(byte: u8) Opcode {
        // shi: 0x80-0xFF (high bit set)
        if ((byte & 0x80) != 0) {
            return .shi;
        }
        // push: 0x40-0x7F
        if ((byte & 0xC0) == 0x40) {
            return .push;
        }
        // All other opcodes: 0x00-0x3F
        return @enumFromInt(byte);
    }

    /// Extract the 6-bit signed immediate from a push instruction byte.
    pub fn pushImmediate(byte: u8) i6 {
        return @bitCast(@as(u6, @truncate(byte & 0x3F)));
    }

    /// Extract the 7-bit immediate from a shi instruction byte.
    pub fn shiImmediate(byte: u8) u7 {
        return @truncate(byte & 0x7F);
    }
};
