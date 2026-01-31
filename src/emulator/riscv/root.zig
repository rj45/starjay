pub const std = @import("std");

pub const types = @import("types.zig");
pub const CpuState = @import("CpuState.zig");

pub const DEVICE_TABLE = @embedFile("sixtyfourmb.dtb");
pub const RAM_IMAGE_OFFSET = types.RAM_IMAGE_OFFSET;

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
