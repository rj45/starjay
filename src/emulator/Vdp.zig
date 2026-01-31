pub const Vdp = @This();

pub const Device = @import("vdp/Device.zig");
pub const State = @import("vdp/State.zig");
pub const Thread = @import("vdp/Thread.zig");

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
