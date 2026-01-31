// (C) 2026 Ryan "rj45" Sanche, MIT License
//
// System.Thread: Runs RISC-V System in a separate thread.
// Uses a command/completion model for frame execution:
//   - Coordinator sends run_frame commands via command_queue
//   - CPU thread executes cycles, sends completion via completion_queue
//   - VDP memory writes are shadowed to vdp_queue for VdpThread

const std = @import("std");

const spsc_queue = @import("spsc_queue");

const System = @import("../System.zig");

pub const Thread = @This();

// Timing constants
pub const CYCLES_PER_FRAME: u64 = 1440 * 741 / 2; // 741 scanlines, 1440 cycles per scanline, running at half speed
const FRAME_TIME_NS: u64 = 16_627_502; // ~60 FPS

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

system: *System,

// Communication
vdp_queue: *System.Bus.Queue,
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
    vdp_queue: *System.Bus.Queue,
    system: *System,
) !*Thread {
    const self = try allocator.create(Thread);
    errdefer allocator.destroy(self);

    // Initialize basic state
    self.vdp_queue = vdp_queue;
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

    self.system = system;

    return self;
}

pub fn deinit(self: *Thread) void {
    self.stop();

    self.command_queue.deinit(self.allocator);
    self.completion_queue.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn start(self: *Thread) !void {
    if (self.thread != null) return; // Already running

    self.running.store(true, .release);

    self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    try self.thread.?.setName("starjay/CPU");
}

pub fn stop(self: *Thread) void {
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
pub fn submitCommand(self: *Thread, command: CpuCommand) void {
    self.command_queue.push(command);
}

/// Try to get a frame completion notification (called by coordinator).
/// Returns the completion if available, null otherwise.
pub fn tryGetCompletion(self: *Thread) ?CpuCompletion {
    if (self.completion_queue.front()) |completion| {
        const c = completion.*;
        self.completion_queue.pop();
        return c;
    }
    return null;
}

/// Block waiting for a frame completion (called by coordinator).
pub fn waitForCompletion(self: *Thread) CpuCompletion {
    while (true) {
        if (self.tryGetCompletion()) |completion| {
            return completion;
        }
        std.Thread.yield() catch {};
    }
}

fn threadMain(self: *Thread) void {
    var slow_frames: usize = 0;
    while (self.running.load(.acquire)) {
        // Check for commands
        while (self.command_queue.front()) |command| {
            const cmd = command.*;
            self.command_queue.pop();

            switch (cmd) {
                .run_frame => {
                    const adjusted_cycles = CYCLES_PER_FRAME / @as(u64, self.cycle_divisor);
                    const cycle_goal = self.system.cpu.cycles +% adjusted_cycles;

                    const start_time = self.timer.read();
                    var retval: System.Word = 0;
                    while (self.system.cpu.cycles < cycle_goal) {
                        const remaining_cycles = cycle_goal - self.system.cpu.cycles;
                        const ret = self.system.cpu.runForCycles(&self.system.clint, self.system.memory, remaining_cycles, false);
                        if (ret != 0 and ret != 1) {
                            retval = ret;
                            break;
                        }
                    }

                    const elapsed_ns = self.timer.read() - start_time;

                    if (elapsed_ns > (FRAME_TIME_NS*2/self.cycle_divisor)) {
                        slow_frames += 1;
                        if (slow_frames > 8) {
                            const ratio = std.math.ceilPowerOfTwo(u32,
                                @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(elapsed_ns)) / @as(f32, @floatFromInt(FRAME_TIME_NS))))
                            ) catch 64;
                            if (ratio > self.cycle_divisor) {
                                self.cycle_divisor = ratio;
                                std.debug.print("Frame {} slow ({} ns), increasing cycle_divisor to {}\r\n", .{self.frame_number, elapsed_ns, self.cycle_divisor});
                            }
                        }
                    } else {
                        slow_frames = 0;
                    }
                    if ((self.frame_number % (60*30)) == 0) {
                        const fps = @as(f32, 1_000_000_000) / @as(f32, @floatFromInt(elapsed_ns));
                        std.debug.print("Frame {} completed in {} ns ({:.2} FPS), cycle_divisor = {}\r\n", .{self.frame_number, elapsed_ns, fps, self.cycle_divisor});
                    }

                    if (retval != 0 and retval != 1) {
                        var error_level = retval;

                        std.debug.print("original error_level: {}\r\n", .{error_level});

                        if (error_level == 9) { // ecall trap
                            std.debug.print("ecall trap: a0 = {}\r\n", .{self.system.cpu.reg.regs[10]});
                            error_level = self.system.cpu.reg.regs[10];
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
