pub const std = @import("std");

pub const types = @import("types.zig");
pub const CpuState = @import("CpuState.zig");

const Bus = @import("../device/Bus.zig");
const Device = @import("../device/Device.zig");
const Clint = @import("../device/Clint.zig");
const Sram = @import("../device/Sram.zig");
const Uart = @import("../device/Uart.zig");

// Re-export common types for convenience
pub const Word = types.Word;
pub const SWord = types.SWord;
pub const WORDSIZE = types.WORDSIZE;
pub const WORDBYTES = types.WORDBYTES;
pub const RAM_IMAGE_OFFSET = types.RAM_IMAGE_OFFSET;


pub fn main(rom_file: []const u8, max_cycles: usize, quiet: bool, gpa: std.mem.Allocator) !void {
    const memsize:u32 = 64 * 1024 * 1024;
    const memory = try gpa.alloc(u32, memsize/4);
    defer gpa.free(memory);

    var bus: Bus = try Bus.init(gpa);
    defer bus.deinit();

    var clint = Clint.init();
    try bus.attach(Device.init(&clint, 0x11000000, 0x11008000));

    var uart = Uart.init();
    try bus.attach(Device.init(&uart, 0x10000000, 0x10000020));

    var sram = Sram.init(@ptrCast(memory));
    try sram.loadRom(rom_file);
    try bus.attach(Device.init(&sram, RAM_IMAGE_OFFSET, RAM_IMAGE_OFFSET+memsize));

    var cpu = CpuState.init(bus);
    cpu.log_enabled = !quiet;


    var errorLevel = try cpu.run(max_cycles, true);

    if (errorLevel == 9) { // ecall trap
        errorLevel = cpu.reg.regs[10];
    }

    std.debug.print("errorLevel: {}\n", .{errorLevel});
    std.process.exit(@truncate(errorLevel));
}

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
