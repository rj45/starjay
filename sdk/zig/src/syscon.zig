const std = @import("std");

pub const syscon = @This();

const SYSCON_REG_ADDR:usize = 0x11100000;

const reg: * volatile u32 = @ptrFromInt(SYSCON_REG_ADDR);

pub fn shutdown() noreturn {
    reg.* = 0xffff;

    while(true) {} // won't reach here
}
