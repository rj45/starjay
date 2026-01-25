// (C) 2026 Ryan "rj45" Sanche, MIT License
//
// CpuThread: Runs RISC-V CPU in a separate thread.
// Uses a command/completion model for frame execution:
//   - Coordinator sends run_frame commands via command_queue
//   - CPU thread executes cycles, sends completion via completion_queue
//   - VDP memory writes are shadowed to shadow_queue for VdpThread

const std = @import("std");

const spsc_queue = @import("spsc_queue");

const Bus = @import("../device/Bus.zig");
const Device = @import("../device/Device.zig");
const Clint = @import("../device/Clint.zig");
const Sram = @import("../device/Sram.zig");
const Uart = @import("../device/Uart.zig");
const Shadow = @import("../device/Shadow.zig");
const VdpDevice = @import("../vdp/VdpDevice.zig");
const VdpState = @import("../vdp/VdpState.zig");

const CpuState = @import("CpuState.zig");
const types = @import("types.zig");

const Transaction = Bus.Transaction;
const ShadowQueue = Bus.Queue;

pub const CpuThread = @This();

// Timing constants
pub const CYCLES_PER_FRAME: u64 = 1440 * 741; // 741 scanlines, 1440 cycles per scanline
const FRAME_TIME_NS: u64 = 16_627_502; // ~60 FPS

// Memory map constants
pub const VDP_BASE: u32 = 0x2000_0000;
pub const VDP_SIZE: u32 = VdpDevice.TOTAL_SIZE;

// Device tree blob
const device_table = @embedFile("sixtyfourmb.dtb");

// Command from coordinator to CPU thread
pub const CpuCommand = enum {
    run_frame,
    stop,
};

pub const CpuCompletion = union(enum) {
    frame_complete: FrameComplete,
    cpu_halted: u32,
};

// Frame completion notification sent from CPU thread to coordinator
pub const FrameComplete = struct {
    frame_number: u64,
    // Future: sdram_plan: ?*SdramLatencyPlan,
};

pub const CommandQueue = spsc_queue.SpscQueuePo2Unmanaged(CpuCommand);
pub const CompletionQueue = spsc_queue.SpscQueuePo2Unmanaged(CpuCompletion);

// Owned resources
cpu: CpuState,
bus: Bus,
clint: Clint,
uart: Uart,
sram: Sram,
vdp_shadow: Shadow.Shadow(VdpDevice),
memory: []align(4) u8,

// Communication
shadow_queue: *ShadowQueue,
command_queue: CommandQueue,
completion_queue: CompletionQueue,
frame_futex: *std.atomic.Value(u32),

// Thread state
thread: ?std.Thread,
frame_number: u64,
timer: std.time.Timer,
allocator: std.mem.Allocator,
running: std.atomic.Value(bool),

// Adaptive cycle scaling
// When running too slow, reduce cycles per frame to allow VDP to skip frames
cycle_divisor: u32,

pub fn init(
    allocator: std.mem.Allocator,
    frame_futex: *std.atomic.Value(u32),
    shadow_queue: *ShadowQueue,
    rom_path: ?[]const u8,
) !*CpuThread {
    const self = try allocator.create(CpuThread);
    errdefer allocator.destroy(self);

    // Initialize basic state
    self.shadow_queue = shadow_queue;
    self.thread = null;
    self.frame_number = 0;
    self.allocator = allocator;
    self.frame_futex = frame_futex;

    // Initialize adaptive cycle scaling
    self.cycle_divisor = 1;

    self.timer = try std.time.Timer.start();

    // Initialize command/completion queues
    self.command_queue = CommandQueue.initCapacity(allocator, 4) catch return error.OutOfMemory;
    errdefer self.command_queue.deinit(allocator);

    self.completion_queue = CompletionQueue.initCapacity(allocator, 4) catch return error.OutOfMemory;
    errdefer self.completion_queue.deinit(allocator);

    // Allocate main memory (64 MB)
    const memsize: u32 = 64 * 1024 * 1024;
    self.memory = try allocator.alignedAlloc(u8, .@"4", memsize);
    errdefer allocator.free(self.memory);
    @memset(self.memory, 0x00);

    // Initialize Bus
    self.bus = try Bus.init(allocator);
    errdefer self.bus.deinit();

    // Initialize CLINT (Core Local Interrupt)
    self.clint = Clint.init();
    try self.bus.attach(Device.init(&self.clint, 0x11000000, 0x1100C000));

    // Initialize UART
    self.uart = try Uart.init();
    errdefer self.uart.deinit();
    try self.bus.attach(Device.init(&self.uart, 0x10000000, 0x10000020));

    // Initialize SRAM with main memory
    self.sram = Sram.init(self.memory);

    // Load ROM if provided
    if (rom_path) |path| {
        try self.sram.loadRom(path);
    }

    try self.bus.attach(Device.init(&self.sram, types.RAM_IMAGE_OFFSET, types.RAM_IMAGE_OFFSET + memsize));

    // Initialize VDP shadow device
    // Create a dummy VdpDevice for the shadow - VdpThread owns the real one
    // The shadow only needs to enqueue writes, it doesn't need actual VDP state
    var vdp_device: VdpDevice = undefined;
    vdp_device.init(allocator, VdpState.FrameBuffer{
        .width = 0,
        .height = 0,
        .pitch = 0,
        .pixels = undefined,
    });

    self.vdp_shadow = Shadow.Shadow(VdpDevice).init(vdp_device, shadow_queue);
    try self.bus.attach(Device.init(&self.vdp_shadow, VDP_BASE, VDP_BASE + VDP_SIZE));

    // Initialize CPU state
    self.cpu = CpuState.init(self.bus);
    self.cpu.log_enabled = false; // Disable logging in threaded mode

    // Load DTB into RAM
    const dtb_off = memsize - device_table.len;
    @memcpy(self.memory.ptr + dtb_off, device_table[0..device_table.len]);

    // Update system RAM size in DTB
    const dtb: []u32 = @as([*]u32, @alignCast(@ptrCast(self.memory.ptr + dtb_off)))[0 .. device_table.len / 4];
    if (dtb[0x13c / 4] == 0x00c0ff03) {
        const validram: u32 = dtb_off;
        dtb[0x13c / 4] = (validram >> 24) | (((validram >> 16) & 0xff) << 8) | (((validram >> 8) & 0xff) << 16) | ((validram & 0xff) << 24);
    }

    // Set up initial CPU state
    self.cpu.reg.pc = types.RAM_IMAGE_OFFSET;
    self.cpu.reg.regs[10] = 0x00; // hart ID
    self.cpu.reg.regs[11] = dtb_off + types.RAM_IMAGE_OFFSET;
    self.cpu.reg.extraflags |= 3; // Machine-mode

    return self;
}

pub fn deinit(self: *CpuThread) void {
    self.stop();

    self.uart.deinit();
    self.bus.deinit();
    self.allocator.free(self.memory);
    self.command_queue.deinit(self.allocator);
    self.completion_queue.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn start(self: *CpuThread) !void {
    if (self.thread != null) return; // Already running

    self.running.store(true, .release);

    self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    try self.thread.?.setName("starjay/CPU");
}

pub fn stop(self: *CpuThread) void {
    if (self.thread) |thread| {
        // Send stop command
        self.running.store(false, .release);
        _ = self.command_queue.tryPush(.stop);
        std.Thread.Futex.wake(self.frame_futex, 10);
        thread.join();
        self.thread = null;
    }
}

/// Submit a command to the CPU thread (called by coordinator).
/// Returns true if the command was queued, false if queue is full.
pub fn submitCommand(self: *CpuThread, command: CpuCommand) void {
    self.command_queue.push(command);
}

/// Try to get a frame completion notification (called by coordinator).
/// Returns the completion if available, null otherwise.
pub fn tryGetCompletion(self: *CpuThread) ?CpuCompletion {
    if (self.completion_queue.front()) |completion| {
        const c = completion.*;
        self.completion_queue.pop();
        return c;
    }
    return null;
}

/// Block waiting for a frame completion (called by coordinator).
pub fn waitForCompletion(self: *CpuThread) CpuCompletion {
    while (true) {
        if (self.tryGetCompletion()) |completion| {
            return completion;
        }
        std.Thread.yield() catch {};
    }
}

fn threadMain(self: *CpuThread) void {
    while (self.running.load(.acquire)) {
        // Check for commands
        while (self.command_queue.front()) |command| {
            const cmd = command.*;
            self.command_queue.pop();

            switch (cmd) {
                .run_frame => {
                    const adjusted_cycles = CYCLES_PER_FRAME / @as(u64, self.cycle_divisor);

                    const start_time = self.timer.read();
                    const retval = self.cpu.runForCycles(&self.clint, adjusted_cycles, false);
                    const elapsed_ns = self.timer.read() - start_time;

                    if (elapsed_ns > (FRAME_TIME_NS*2)) {
                        const ratio = std.math.ceilPowerOfTwo(u32,
                            @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(elapsed_ns)) / @as(f32, @floatFromInt(FRAME_TIME_NS))))
                        ) catch 64;
                        if (ratio > self.cycle_divisor) {
                            self.cycle_divisor = ratio;
                            std.debug.print("Frame {} slow ({} ns), increasing cycle_divisor to {}\r\n", .{self.frame_number, elapsed_ns, self.cycle_divisor});
                        }
                    }
                    if ((self.frame_number % (60*30)) == 0) {
                        const fps = @as(f32, 1_000_000_000) / @as(f32, @floatFromInt(elapsed_ns));
                        std.debug.print("Frame {} completed in {} ns ({:.2} FPS), cycle_divisor = {}\r\n", .{self.frame_number, elapsed_ns, fps, self.cycle_divisor});
                    }

                    if (retval != 0 and retval != 1) {
                        var error_level = retval;

                        std.debug.print("original error_level: {}\r\n", .{error_level});

                        if (error_level == 9) { // ecall trap
                            std.debug.print("ecall trap: a0 = {}\r\n", .{self.cpu.reg.regs[10]});
                            error_level = self.cpu.reg.regs[10];
                        }

                        self.completion_queue.push(.{ .cpu_halted = error_level });
                        return;
                    }

                    // Signal frame completion
                    self.completion_queue.push(.{
                        .frame_complete = .{
                            .frame_number = self.frame_number,
                        }
                    });

                    self.frame_number += 1;
                },
                .stop => {
                    return;
                },
            }
        }

        if (self.running.load(.acquire)) {
            // Wait for the next frame
            self.frame_futex.store(1, .release);
            std.Thread.Futex.wait(self.frame_futex, 1);
        }
    }
}
