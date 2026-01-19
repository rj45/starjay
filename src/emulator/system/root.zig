
pub const CpuState = @import("CpuState.zig");

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
