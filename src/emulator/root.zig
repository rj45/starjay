const std = @import("std");

const types = @import("types.zig");
const cpu = @import("cpu.zig");

pub const Word = types.Word;

pub const run = cpu.run;

pub fn main(rom_file: []const u8, max_cycles: usize, gpa: std.mem.Allocator) !void {
    const errorLevel = try cpu.run(rom_file, max_cycles, gpa);
    std.process.exit(@intCast(errorLevel));
}
