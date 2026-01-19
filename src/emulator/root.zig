pub const cpu = @import("starjette/root.zig");
pub const riscv = @import("riscv/root.zig");
pub const vdp = @import("vdp/root.zig");
pub const device = @import("device/root.zig");
pub const system = @import("system/root.zig");

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
