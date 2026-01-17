//! CPU emulator module - shared types and utilities for CPU emulation.

pub const types = @import("types.zig");
pub const opcode = @import("opcode.zig");
pub const utils = @import("utils.zig");

// Re-export common types for convenience
pub const Word = types.Word;
pub const SWord = types.SWord;
pub const WORDSIZE = types.WORDSIZE;
pub const WORDBYTES = types.WORDBYTES;
pub const Status = types.Status;
pub const ECause = types.ECause;
pub const CsrNum = types.CsrNum;
pub const Opcode = opcode.Opcode;
pub const CpuState = types.CpuState;

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
