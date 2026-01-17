pub const cpu = @import("starjette/root.zig");

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
