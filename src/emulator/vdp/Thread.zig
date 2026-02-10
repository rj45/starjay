// (C) 2026 Ryan "rj45" Sanche, MIT License

const std = @import("std");

const chan = @import("../../lib/chan.zig");

const Bus = @import("../device/Bus.zig");
const Device = @import("Device.zig");
const State = @import("State.zig");
const ui = @import("../ui.zig");

const Transaction = Bus.Transaction;
const ShadowQueue = Bus.Queue;

pub const Thread = @This();

/// Render request sent from UI thread to VDP thread
pub const RenderCommand = struct {
    index: u32,
    buffer: [*]u32,
    width: u32,
    height: u32,
    pitch: u32,
    skip: bool,
};

pub const CommandChannel = chan.Channel(RenderCommand);

// VDP device (owns State)
device: Device,

// Shadow queue to consume memory write transactions from
shadow_queue: *ShadowQueue,

// UI communication channel
ui_channel: *ui.chan.Channel,
frame_count: u64,
timer: std.time.Timer,

// Command channel for rendering
command_chan: CommandChannel,

// Thread control
thread: ?std.Thread,

// Allocator for cleanup
allocator: std.mem.Allocator,

pub fn init(
    allocator: std.mem.Allocator,
    shadow_queue: *ShadowQueue,
    ui_channel: *ui.chan.Channel,
) !*Thread {
    const self = try allocator.create(Thread);
    errdefer allocator.destroy(self);

    self.shadow_queue = shadow_queue;
    self.thread = null;
    self.ui_channel = ui_channel;
    self.allocator = allocator;
    self.frame_count = 0;

    self.command_chan = CommandChannel.init(allocator);

    self.device = Device.init();

    return self;
}

pub fn deinit(self: *Thread) void {
    self.stop();
    self.command_chan.deinit();
    self.allocator.destroy(self);
}

pub fn start(self: *Thread) !void {
    if (self.thread != null) return; // Already running

    self.timer = try std.time.Timer.start();

    self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    self.thread.?.setName("starjay/VDP") catch {}; // doesn't work on mac, don't care
}

pub fn stop(self: *Thread) void {
    if (self.thread) |thread| {
        self.command_chan.close();
        thread.join();
        self.thread = null;
    }
}

/// Submit a render request (called by UI thread).
/// Returns true if the request was queued, false if queue is full.
pub fn submitRenderCommand(self: *Thread, request: RenderCommand) !void {
    try self.command_chan.send(request);
}

fn threadMain(self: *Thread) void {
    while (self.command_chan.receive()) |req| {
        // Set up frame buffer from request
        self.device.vdp.frame_buffer = State.FrameBuffer{
            .width = req.width,
            .height = req.height,
            .pitch = req.pitch,
            .pixels = req.buffer,
        };

        // Render the frame
        const start_time = self.timer.read();
        const vdp = &self.device.vdp;
        vdp.start_frame();
        while (true) {
            self.drainShadowQueue(vdp.cycle);
            if (!vdp.emulate_line(req.skip)) {
                break;
            }
        }
        const elapsed_ns = self.timer.read() - start_time;

        if ((self.frame_count % (60*30)) == 0) {
            std.debug.print("Frame {} VDP completed in {} us\r\n", .{self.frame_count, elapsed_ns/1000});
        }

        // Send result back to UI thread
        self.ui_channel.send(.{ .vdp_frame = .{ .index = req.index, .frame_number = self.frame_count }}) catch {
            std.debug.print("Error: VDP UI channel send failure {}\n", .{req.index});
            return;
        };

        self.frame_count += 1;
    }
}

fn drainShadowQueue(self: *Thread, cycle: Bus.Cycle) void {
    // Drain all pending transactions and apply them to the VDP device
    while (self.shadow_queue.front()) |transaction| {
        if (transaction.start_cycle() > cycle) {
            break; // Not there yet
        }
        _ = self.device.access(transaction.*);
        self.shadow_queue.pop();
    }
}
