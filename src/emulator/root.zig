pub const cpu = @import("cpu/root.zig");

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
