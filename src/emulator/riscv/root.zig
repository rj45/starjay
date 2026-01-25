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

const device_table = @embedFile("sixtyfourmb.dtb");

pub fn main(rom_file: []const u8, max_cycles: usize, quiet: bool, gpa: std.mem.Allocator) !void {
    const memsize:u32 = 64 * 1024 * 1024;
    const memory: []align(4) u8 = try gpa.alignedAlloc(u8, .@"4", memsize);
    defer gpa.free(memory);

    @memset(memory, 0x00);

    var bus: Bus = try Bus.init(gpa);
    defer bus.deinit();

    var clint = Clint.init();
    try bus.attach(Device.init(&clint, 0x11000000, 0x1100C000));

    var uart = try Uart.init();
    defer uart.deinit();
    try bus.attach(Device.init(&uart, 0x10000000, 0x10000020));

    var sram = Sram.init(memory);
    try sram.loadRom(rom_file);
    try bus.attach(Device.init(&sram, RAM_IMAGE_OFFSET, RAM_IMAGE_OFFSET+memsize));

    var cpu = CpuState.init(bus);
    cpu.log_enabled = !quiet;

    // load DTB into ram
    const dtb_off = memsize - device_table.len;
    @memcpy(memory.ptr + dtb_off, device_table[0..device_table.len]);

    // Update system ram size in DTB (but if and only if we're using the default DTB)
    // Warning - this will need to be updated if the skeleton DTB is ever modified.
    var dtb: []u32 = @ptrCast(memory[dtb_off..]);
    if (dtb[0x13c / 4] == 0x00c0ff03) {
        const validram: u32 = dtb_off;
        dtb[0x13c / 4] = (validram >> 24) | (((validram >> 16) & 0xff) << 8) | (((validram >> 8) & 0xff) << 16) | ((validram & 0xff) << 24);
    }

    cpu.reg.pc = RAM_IMAGE_OFFSET;
    cpu.reg.regs[10] = 0x00; // hart ID
    cpu.reg.regs[11] = dtb_off + RAM_IMAGE_OFFSET;
    cpu.reg.extraflags |= 3; // Machine-mode.

    var error_level = try cpu.run(&clint, max_cycles, false);

    try uart.tty.writer().print("original error_level: {}\r\n", .{error_level});
    uart.flush();

    if (error_level == 9) { // ecall trap
        try uart.tty.writer().print("ecall trap: a0 = {}\r\n", .{cpu.reg.regs[10]});
        error_level = cpu.reg.regs[10];
    }

    try uart.tty.writer().print("error_level: {}\r\n", .{error_level});
    uart.flush();

    const byte_val: u8 = @truncate(error_level & 0xff);

    std.process.exit(byte_val);
}

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
