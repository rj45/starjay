// (C) 2026 Ryan "rj45" Sanche, MIT License
//
// Audio.Thread: Runs PSG emulation in a separate thread.

const std = @import("std");

const chan = @import("../../lib/chan.zig");

pub const Ay38910 = @import("Ay38910.zig");
pub const Bus = @import("../device/Bus.zig");
const ui = @import("../ui.zig");

pub const Thread = @This();

// Timing constants
pub const BUS_CYCLES_PER_FRAME: u64 = 1440 * 741; // 741 scanlines, 1440 cycles per scanline
const FRAME_TIME_NS: u64 = 16_627_502; // ~60 FPS

pub const SOUND_SAMPLE_HZ: comptime_int = 48000;

// Command from UI to Audio thread
pub const Command = union(enum) {
    // Run a full frame
    full_frame,

    // Run a fast frame, skipping as much work as possible
    fast_frame,
};

pub const CommandChannel = chan.Channel(Command);

// Communication
command_channel: CommandChannel,
ui_channel: *ui.chan.Channel,
psg1_queue: *Bus.Queue,
psg2_queue: *Bus.Queue,

// PSG State
psg1: Ay38910,
psg2: Ay38910,

// Thread state
thread: ?std.Thread,
bus_cycles: Bus.Cycle,
frame_number: u64,
timer: std.time.Timer,
allocator: std.mem.Allocator,

pub fn init(
    allocator: std.mem.Allocator,
    ui_channel: *ui.chan.Channel,
    psg1_queue: *Bus.Queue,
    psg2_queue: *Bus.Queue,
) !*Thread {
    const self = try allocator.create(Thread);
    errdefer allocator.destroy(self);

    // Initialize basic state
    self.thread = null;
    self.bus_cycles = 0;
    self.frame_number = 0;
    self.allocator = allocator;
    self.ui_channel = ui_channel;
    self.psg1_queue = psg1_queue;
    self.psg2_queue = psg2_queue;
    self.timer = try std.time.Timer.start();

    // Initialize command/completion queues
    self.command_channel = CommandChannel.init(allocator);
    errdefer self.command_channel.deinit();

    self.psg1 = Ay38910.init(.{.sound_hz = SOUND_SAMPLE_HZ}, allocator) catch {
        std.debug.print("Error: Failed to initialize PSG1\r\n", .{});
        return error.PsgInitFailed;
    };
    errdefer self.psg1.deinit(allocator);

    self.psg2 = Ay38910.init(.{.sound_hz = SOUND_SAMPLE_HZ}, allocator) catch {
        std.debug.print("Error: Failed to initialize PSG2\r\n", .{});
        return error.PsgInitFailed;
    };
    errdefer self.psg2.deinit(allocator);

    return self;
}

pub fn deinit(self: *Thread) void {
    self.stop();

    self.command_channel.deinit();
    self.psg1.deinit(self.allocator);
    self.psg2.deinit(self.allocator);

    self.allocator.destroy(self);
}

pub fn start(self: *Thread) !void {
    if (self.thread != null) return; // Already running

    self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    self.thread.?.setName("starjay/PSG") catch {}; // doesn't work on mac, don't care
}

pub fn stop(self: *Thread) void {
    if (self.thread) |thread| {
        // Send stop command
        self.command_channel.close();
        thread.join();
        self.thread = null;
    }
}

/// Returns true if the command was queued, false if queue is full.
pub fn submitCommand(self: *Thread, command: Command) !void {
    try self.command_channel.send(command);
}

fn drainShadowQueue(self: *Thread) void {
    while (self.psg1_queue.front()) |transaction| {
        _ = self.psg1.access(transaction.*);
        self.psg1_queue.pop();
    }

    while (self.psg2_queue.front()) |transaction| {
        _ = self.psg2.access(transaction.*);
        self.psg2_queue.pop();
    }
}

fn threadMain(self: *Thread) void {
    while (self.command_channel.receive()) |cmd| {
        switch (cmd) {
            .full_frame, .fast_frame => {
                self.drainShadowQueue();

                self.bus_cycles += BUS_CYCLES_PER_FRAME;

                const psg_start_time = self.timer.read();
                self.psg1.runUntil(self.bus_cycles);
                self.psg2.runUntil(self.bus_cycles);
                const psg_elapsed_ns = self.timer.read() - psg_start_time;
                if ((self.frame_number % (60*30)) == 0) {
                    std.debug.print("Frame {} PSGs completed in {} us\r\n", .{self.frame_number, psg_elapsed_ns/1000});
                }

                // Signal frame completion
                self.ui_channel.send(.{ .audio_frame = .{
                    .frame_number = self.frame_number,
                    .cycles = self.bus_cycles,
                }}) catch {
                    std.debug.print("Error: Failed to send audio_frame message to UI channel\r\n", .{});
                    return;
                };

                self.frame_number += 1;
            },
        }
    }
}
