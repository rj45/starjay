pub const chan = @import("ui/chan.zig");

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
