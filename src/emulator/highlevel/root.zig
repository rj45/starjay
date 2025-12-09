const std = @import("std");

const cpu = @import("cpu.zig");

pub const Word = cpu.Word;

pub const run = cpu.run;

pub fn main(rom_file: []const u8, max_cycles: usize, gpa: std.mem.Allocator) !void {
    const errorLevel = try cpu.run(rom_file, max_cycles, gpa);
    std.debug.print("errorLevel: {}\n", .{errorLevel});
    std.process.exit(@truncate(errorLevel));
}
