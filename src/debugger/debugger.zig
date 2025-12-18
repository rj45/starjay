pub const std = @import("std");


pub const disasm = @import("disasm.zig");
pub const emulator = disasm.emulator;

pub var allocator: std.mem.Allocator = undefined;
pub var cpu: emulator.CpuState = undefined;

pub var listing: ?*disasm.AsmListing = null;

pub const runForCycles = @import("../emulator/microcoded/cpu.zig").runForCycles;
