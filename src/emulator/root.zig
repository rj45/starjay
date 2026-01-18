pub const cpu = @import("starjette/root.zig");
pub const riscv = @import("riscv/root.zig");

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
