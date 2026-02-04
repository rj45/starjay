pub const Audio = @This();

pub const Ay38910 = @import("audio/Ay38910.zig");
pub const Thread = @import("audio/Thread.zig");

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
