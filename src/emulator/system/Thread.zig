// (C) 2026 Ryan "rj45" Sanche, MIT License
//
// System.Thread: Runs RISC-V System in a separate thread.

const std = @import("std");

const chan = @import("../../lib/chan.zig");

const System = @import("../System.zig");
const ui = @import("../ui.zig");

pub const Thread = @This();

// Timing constants
pub const BUS_CYCLES_PER_FRAME: u64 = 1440 * 741; // 741 scanlines, 1440 cycles per scanline
const FRAME_TIME_NS: u64 = 16_627_502; // ~60 FPS

// Command from UI to CPU thread
pub const CpuCommand = union(enum) {
    // Run a full frame
    full_frame,

    // Run a fast frame, skipping as much work as possible
    fast_frame,
};

pub const CommandChannel = chan.Channel(CpuCommand);

system: *System,

// Communication
vdp_queue: *System.Bus.Queue,
command_channel: CommandChannel,
ui_channel: *ui.chan.Channel,

// Thread state
thread: ?std.Thread,
bus_cycles: System.Bus.Cycle,
frame_number: u64,
timer: std.time.Timer,
allocator: std.mem.Allocator,

pub fn init(
    allocator: std.mem.Allocator,
    ui_channel: *ui.chan.Channel,
    vdp_queue: *System.Bus.Queue,
    system: *System,
) !*Thread {
    const self = try allocator.create(Thread);
    errdefer allocator.destroy(self);

    // Initialize basic state
    self.vdp_queue = vdp_queue;
    self.thread = null;
    self.bus_cycles = 0;
    self.frame_number = 0;
    self.allocator = allocator;
    self.ui_channel = ui_channel;
    self.timer = try std.time.Timer.start();

    // Initialize command/completion queues
    self.command_channel = CommandChannel.init(allocator);
    errdefer self.command_channel.deinit(allocator);

    self.system = system;

    return self;
}

pub fn deinit(self: *Thread) void {
    self.stop();

    self.command_channel.deinit();
    self.allocator.destroy(self);
}

pub fn start(self: *Thread) !void {
    if (self.thread != null) return; // Already running

    self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    self.thread.?.setName("starjay/CPU") catch {}; // doesn't work on mac, don't care
}

pub fn stop(self: *Thread) void {
    if (self.thread) |thread| {
        // Send stop command
        self.command_channel.close();
        thread.join();
        self.thread = null;
    }
}

/// Submit a command to the CPU thread (called by coordinator).
/// Returns true if the command was queued, false if queue is full.
pub fn submitCommand(self: *Thread, command: CpuCommand) !void {
    try self.command_channel.send(command);
}

fn threadMain(self: *Thread) void {
    var slow_frames: usize = 0;
    while (self.command_channel.receive()) |cmd| {
        switch (cmd) {
            .full_frame, .fast_frame => {
                const adjusted_cycles = BUS_CYCLES_PER_FRAME / @as(u64, self.system.cpu.cycle_divisor);
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
                //std.debug.print("CPU frame took: {} us\r\n", .{elapsed_ns/1000});

                if (elapsed_ns > FRAME_TIME_NS) {
                    slow_frames += 1;
                    if (slow_frames > 8) {
                        const full_frame_time = elapsed_ns * self.system.cpu.cycle_divisor;
                        const ratio = std.math.ceilPowerOfTwo(u32,
                            @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(full_frame_time)) / @as(f32, @floatFromInt(FRAME_TIME_NS))))
                        ) catch 64;
                        if (ratio > self.system.cpu.cycle_divisor) {
                            self.system.cpu.cycle_divisor = ratio;
                            std.debug.print("Frame {} slow ({} us), increasing cycle_divisor to {}\r\n", .{self.frame_number, elapsed_ns/1000, self.system.cpu.cycle_divisor});
                        }
                    }
                } else {
                    slow_frames = 0;
                }
                if ((self.frame_number % (60*30)) == 0) {
                    std.debug.print("Frame {} CPU completed in {} us, cycle_divisor = {}\r\n", .{self.frame_number, elapsed_ns/1000, self.system.cpu.cycle_divisor});
                }

                if (retval != 0 and retval != 1) {
                    var error_level = retval;

                    std.debug.print("original error_level: {}\r\n", .{error_level});

                    if (error_level == 9) { // ecall trap
                        std.debug.print("ecall trap: a0 = {}\r\n", .{self.system.cpu.reg.regs[10]});
                        error_level = self.system.cpu.reg.regs[10];
                    }

                    self.ui_channel.send(.{ .cpu_halt = .{
                        .error_level = error_level,
                    }}) catch {
                        std.debug.print("Failed to send cpu_halt message to UI channel\r\n", .{});
                    };
                    return;
                }

                self.bus_cycles += BUS_CYCLES_PER_FRAME;

                const psg_start_time = self.timer.read();
                self.system.psg1.runUntil(self.bus_cycles);
                self.system.psg2.runUntil(self.bus_cycles);
                const psg_elapsed_ns = self.timer.read() - psg_start_time;
                if ((self.frame_number % (60*30)) == 0) {
                    std.debug.print("Frame {} PSGs completed in {} us\r\n", .{self.frame_number, psg_elapsed_ns/1000});
                }

                const full_elapsed_ns = self.timer.read() - start_time;
                if ((self.frame_number % (60*30)) == 0) {
                    const fps = @as(f32, 1_000_000_000) / @as(f32, @floatFromInt(full_elapsed_ns));
                    std.debug.print("Full Frame {} completed in {} us ({} fps), cycle_divisor = {}\r\n", .{self.frame_number, full_elapsed_ns / 1000, fps, self.system.cpu.cycle_divisor});
                }

                // Signal frame completion
                self.ui_channel.send(.{ .cpu_frame = .{
                    .frame_number = self.frame_number,
                    .cycles = self.bus_cycles,
                }}) catch {
                    std.debug.print("Error: Failed to send cpu_frame message to UI channel\r\n", .{});
                    return;
                };

                self.frame_number += 1;
            },
        }
    }
}
