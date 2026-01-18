pub const types = @import("types.zig");
pub const CpuState = @import("CpuState.zig");

// Re-export common types for convenience
pub const Word = types.Word;
pub const SWord = types.SWord;
pub const WORDSIZE = types.WORDSIZE;
pub const WORDBYTES = types.WORDBYTES;


test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
