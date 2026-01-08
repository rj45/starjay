pub const std = @import("std");


pub const disasm = @import("disasm.zig");
pub const emulator = disasm.emulator;

pub var allocator: std.mem.Allocator = undefined;
pub var cpu: emulator.cpu.CpuState = undefined;

pub var listing: ?*disasm.AsmListing = null;
pub var running: bool = false;

pub const runForCycles = @import("../emulator/cpu/microcoded/cpu.zig").runForCycles;
