const std = @import("std");

const types = @import("types.zig");
const cpu = @import("cpu.zig");

pub const Word = types.Word;

pub const run = cpu.run;

pub fn main() !void {
    cpu.run();
}
