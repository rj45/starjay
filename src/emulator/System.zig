pub const std = @import("std");

const spsc_queue = @import("spsc_queue");

pub const riscv = @import("riscv/root.zig");

pub const Bus = @import("device/Bus.zig");
pub const Device = @import("device/Device.zig");
pub const Clint = @import("device/Clint.zig");
pub const Sram = @import("device/Sram.zig");
pub const Uart = @import("device/Uart.zig");
pub const Hid = @import("device/Hid.zig");
pub const Shadow = @import("device/shadow.zig").Shadow;
pub const Vdp = @import("Vdp.zig");
pub const Memory = riscv.CpuState.Memory;

pub const Thread = @import("system/Thread.zig");

pub const Word = Bus.Word;
pub const RAM_IMAGE_OFFSET = riscv.RAM_IMAGE_OFFSET;
pub const DEVICE_TABLE = riscv.DEVICE_TABLE;

// Timing constants
pub const CYCLES_PER_FRAME: u64 = 1440 * 741; // 741 scanlines, 1440 cycles per scanline
const FRAME_TIME_NS: u64 = 16_627_502; // ~60 FPS

// Memory map constants
pub const CLINT_BASE: u32 = 0x1100_0000;
pub const CLINT_SIZE: u32 = 0x0000_C000;
pub const UART_BASE: u32 = 0x1000_0000;
pub const UART_SIZE: u32 = 0x0000_0020;
pub const HID_BASE: u32 = 0x1000_0100;
pub const HID_SIZE: u32 = 0x0000_0008;
pub const PSG_SIZE: u32 = 0x0000_0010;
pub const PSG1_BASE: u32 = 0x1300_0000;
pub const PSG2_BASE: u32 = PSG1_BASE + PSG_SIZE;
pub const SRAM_BASE: u32 = RAM_IMAGE_OFFSET;
pub const VDP_BASE: u32 = 0x2000_0000;
pub const VDP_SIZE: u32 = Vdp.Device.TOTAL_SIZE;

pub const System = @This();

memory: Memory,
bus: Bus,
clint: Clint,
uart: *Uart,
hid: *Hid,
sram: Sram,
psg_buffer: [2][PSG_SIZE/4]u32,
psg1: Shadow(Sram), // using Sram to stand in for PSG registers
psg2: Shadow(Sram),
cpu: riscv.CpuState,
vdp_shadow: Shadow(Vdp.Device),

pub fn init(rom_file: ?[]const u8, quiet: bool, vdp_queue: ?*Bus.Queue, psg1_queue: ?*Bus.Queue, psg2_queue: ?*Bus.Queue, gpa: std.mem.Allocator) !*System {
    var self = try gpa.create(System);
    errdefer gpa.destroy(self);

    const memsize:u32 = 64 * 1024 * 1024;
    self.memory = .{
       .data = try gpa.alignedAlloc(u8, .@"4", memsize),
       .start_address = RAM_IMAGE_OFFSET,
       .end_address = RAM_IMAGE_OFFSET + memsize,
    };
    errdefer gpa.free(self.memory.data);

    @memset(self.memory.data, 0x00);

    self.bus = try Bus.init(gpa);
    errdefer self.bus.deinit();

    self.clint = Clint.init();
    try self.bus.attach(Device.init(&self.clint, CLINT_BASE, CLINT_BASE + CLINT_SIZE));

    self.uart = try Uart.init(gpa);
    errdefer self.uart.deinit(gpa);
    try self.bus.attach(Device.init(self.uart, UART_BASE, UART_BASE + UART_SIZE));

    self.hid = try Hid.init(gpa);
    errdefer self.hid.deinit(gpa);
    try self.bus.attach(Device.init(self.hid, HID_BASE, HID_BASE + HID_SIZE));

    const psg1_buffer: []align(4) u8 = @ptrCast(self.psg_buffer[0][0..]);
    self.psg1 = Shadow(Sram).init(Sram.init(psg1_buffer), psg1_queue);
    try self.bus.attach(Device.init(&self.psg1, PSG1_BASE, PSG1_BASE + PSG_SIZE));

    const psg2_buffer: []align(4) u8 = @ptrCast(self.psg_buffer[1][0..]);
    self.psg2 = Shadow(Sram).init(Sram.init(psg2_buffer), psg2_queue);
    try self.bus.attach(Device.init(&self.psg2, PSG2_BASE, PSG2_BASE + PSG_SIZE));

    self.sram = Sram.init(self.memory.data);
    if (rom_file) |path| {
        try self.sram.loadRom(path);
    } else {
        // TODO: some sort of default WFI loop?
    }
    try self.bus.attach(Device.init(&self.sram, self.memory.start_address, self.memory.end_address));

    self.vdp_shadow = Shadow(Vdp.Device).init(Vdp.Device.init(), vdp_queue);
    try self.bus.attach(Device.init(&self.vdp_shadow, VDP_BASE, VDP_BASE + VDP_SIZE));

    self.cpu = riscv.CpuState.init(&self.bus);
    self.cpu.log_enabled = !quiet;

    // load DTB into ram
    const dtb_off = memsize - DEVICE_TABLE.len;
    @memcpy(self.memory.data.ptr + dtb_off, DEVICE_TABLE[0..DEVICE_TABLE.len]);

    // Update system ram size in DTB (but if and only if we're using the default DTB)
    // Warning - this will need to be updated if the skeleton DTB is ever modified.
    var dtb: []u32 = @ptrCast(self.memory.data[dtb_off..]);
    if (dtb[0x13c / 4] == 0x00c0ff03) {
        const validram: u32 = dtb_off;
        dtb[0x13c / 4] = (validram >> 24) | (((validram >> 16) & 0xff) << 8) | (((validram >> 8) & 0xff) << 16) | ((validram & 0xff) << 24);
    }

    self.cpu.reg.pc = RAM_IMAGE_OFFSET;
    self.cpu.reg.regs[10] = 0x00; // hart ID
    self.cpu.reg.regs[11] = dtb_off + RAM_IMAGE_OFFSET;
    self.cpu.reg.extraflags |= 3; // Machine-mode.

    return self;
}

pub fn deinit(self: *System, gpa: std.mem.Allocator) void {
    self.bus.deinit();
    self.uart.deinit(gpa);
    self.hid.deinit(gpa);
    gpa.free(self.memory.data);
    gpa.destroy(self);
}

pub fn run(self: *System, max_cycles: usize) !void {
    var error_level = try self.cpu.run(&self.clint, self.memory, max_cycles, false);

    try self.uart.tty.writer().print("original error_level: {}\r\n", .{error_level});
    self.uart.flush();

    if (error_level == 9) { // ecall trap
        try self.uart.tty.writer().print("ecall trap: a0 = {}\r\n", .{self.cpu.reg.regs[10]});
        error_level = self.cpu.reg.regs[10];
    }

    try self.uart.tty.writer().print("error_level: {}\r\n", .{error_level});
    self.uart.flush();

    const byte_val: u8 = @truncate(error_level & 0xff);

    std.process.exit(byte_val);
}

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
