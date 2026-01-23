// (C) 2026 Ryan "rj45" Sanche, MIT License
//
// VdpThread: Runs VdpDevice in a separate thread.
// Uses a request/response model for frame rendering:
//   - UI thread sends render requests via request_queue
//   - VDP thread drains shadow queue, renders, sends result via result_queue
//   - UI thread owns both frame buffers, only lending one at a time

const std = @import("std");

const spsc_queue = @import("spsc_queue");

const Bus = @import("../device/Bus.zig");
const VdpDevice = @import("VdpDevice.zig");
const VdpState = @import("VdpState.zig");

const Transaction = Bus.Transaction;
const ShadowQueue = Bus.Queue;

pub const VdpThread = @This();

const FrameBuffer = VdpState.FrameBuffer;

/// Render request sent from UI thread to VDP thread
pub const RenderRequest = struct {
    index: u32,
    buffer: [*]u32,
    width: u32,
    height: u32,
    pitch: u32,
    skip: bool,
};

/// Render result sent from VDP thread back to UI thread
pub const RenderResult = struct {
    buffer: [*]u32,
    index: u32,
};

pub const RequestQueue = spsc_queue.SpscQueuePo2Unmanaged(RenderRequest);
pub const ResultQueue = spsc_queue.SpscQueuePo2Unmanaged(RenderResult);

// VDP device (owns VdpState)
device: VdpDevice,

// Shadow queue to consume memory write transactions from
shadow_queue: *ShadowQueue,

// Request/result queues for frame rendering (both owned by VdpThread)
request_queue: RequestQueue,
result_queue: ResultQueue,

// Thread control
thread: ?std.Thread,
running: std.atomic.Value(bool),
frame_futex: *std.atomic.Value(u32),

// Allocator for cleanup
allocator: std.mem.Allocator,

pub fn init(
    allocator: std.mem.Allocator,
    shadow_queue: *ShadowQueue,
    frame_futex: *std.atomic.Value(u32),
) !*VdpThread {
    const self = try allocator.create(VdpThread);
    errdefer allocator.destroy(self);

    self.shadow_queue = shadow_queue;
    self.thread = null;
    self.running = std.atomic.Value(bool).init(false);
    self.frame_futex = frame_futex;
    self.allocator = allocator;

    // Initialize queues (small capacity is fine, typically 1-2 in flight)
    self.request_queue = RequestQueue.initCapacity(allocator, 4) catch return error.OutOfMemory;
    self.result_queue = ResultQueue.initCapacity(allocator, 4) catch return error.OutOfMemory;

    // Initialize VDP device with a dummy frame buffer (will be set by render requests)
    self.device.init(allocator, FrameBuffer{
        .width = 0,
        .height = 0,
        .pitch = 0,
        .pixels = undefined,
    });

    return self;
}

pub fn deinit(self: *VdpThread) void {
    self.stop();
    self.request_queue.deinit(self.allocator);
    self.result_queue.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn start(self: *VdpThread) !void {
    if (self.thread != null) return; // Already running

    self.running.store(true, .release);
    self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    try self.thread.?.setName("starjay/VDP");
}

pub fn stop(self: *VdpThread) void {
    if (self.thread) |thread| {
        self.running.store(false, .release);
        std.Thread.Futex.wake(self.frame_futex, 10);
        thread.join();
        self.thread = null;
    }
}

/// Submit a render request (called by UI thread).
/// Returns true if the request was queued, false if queue is full.
pub fn submitRenderRequest(self: *VdpThread, request: RenderRequest) void {
    self.request_queue.push(request);
}

/// Try to get a completed render result (called by UI thread).
/// Returns the result if available, null otherwise.
pub fn tryGetResult(self: *VdpThread) ?RenderResult {
    if (self.result_queue.front()) |result| {
        const r = result.*;
        self.result_queue.pop();
        return r;
    }
    return null;
}

/// Block waiting for a render result (called by UI thread).
/// Spins until a result is available.
pub fn waitForResult(self: *VdpThread) RenderResult {
    while (true) {
        if (self.tryGetResult()) |result| {
            return result;
        }
        std.atomic.spinLoopHint();
    }
}

fn threadMain(self: *VdpThread) void {
    while (self.running.load(.acquire)) {
        // Check for render requests
        while (self.request_queue.front()) |request| {
            const req = request.*;
            self.request_queue.pop();

            // Always drain shadow queue (memory writes from CPU)
            self.drainShadowQueue();

            // Set up frame buffer from request
            self.device.vdp.frame_buffer = FrameBuffer{
                .width = req.width,
                .height = req.height,
                .pitch = req.pitch,
                .pixels = req.buffer,
            };

            // Render the frame
            self.device.vdp.emulate_frame(req.skip);

            // Send result back to UI thread
            self.result_queue.push(.{ .index = req.index, .buffer = req.buffer });
        }

        if (self.running.load(.acquire)) {
            // Wait for the next frame
            self.frame_futex.store(1, .release);
            std.Thread.Futex.wait(self.frame_futex, 1);
        }
    }
}

fn drainShadowQueue(self: *VdpThread) void {
    // Drain all pending transactions and apply them to the VDP device
    while (self.shadow_queue.front()) |transaction| {
        _ = self.device.access(transaction.*);
        self.shadow_queue.pop();
    }
}
