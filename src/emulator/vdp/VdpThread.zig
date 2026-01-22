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
    buffer: [*]u32,
    width: u32,
    height: u32,
    pitch: u32,
    skip: bool,
};

/// Render result sent from VDP thread back to UI thread
pub const RenderResult = struct {
    buffer: [*]u32,
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

// Timing
frame_time_ns: u64,

// Allocator for cleanup
allocator: std.mem.Allocator,

pub fn init(
    allocator: std.mem.Allocator,
    shadow_queue: *ShadowQueue,
    frame_time_ns: u64,
) !*VdpThread {
    const self = try allocator.create(VdpThread);
    errdefer allocator.destroy(self);

    self.shadow_queue = shadow_queue;
    self.thread = null;
    self.running = std.atomic.Value(bool).init(false);
    self.frame_time_ns = frame_time_ns;
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
}

pub fn stop(self: *VdpThread) void {
    if (self.thread) |thread| {
        self.running.store(false, .release);
        thread.join();
        self.thread = null;
    }
}

/// Submit a render request (called by UI thread).
/// Returns true if the request was queued, false if queue is full.
pub fn submitRenderRequest(self: *VdpThread, request: RenderRequest) bool {
    return self.request_queue.tryPush(request);
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
        std.Thread.yield() catch {};
    }
}

fn threadMain(self: *VdpThread) void {
    // Wake up this early before expected frame to account for sleep inaccuracy
    const early_wakeup_ns: u64 = 4_000_000; // 4ms

    var timer = std.time.Timer.start() catch unreachable;
    var last_frame_time: u64 = 0;

    while (self.running.load(.acquire)) {
        // Always drain shadow queue (memory writes from CPU)
        self.drainShadowQueue();

        // Check for render requests
        if (self.request_queue.front()) |request| {
            const req = request.*;
            self.request_queue.pop();

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
            self.result_queue.push(.{ .buffer = req.buffer });

            // Record when this frame completed
            last_frame_time = timer.read();
        } else {
            // No request pending - sleep intelligently
            const now = timer.read();
            const time_since_last_frame = now - last_frame_time;

            if (time_since_last_frame < self.frame_time_ns) {
                const time_until_next_frame = self.frame_time_ns - time_since_last_frame;

                if (time_until_next_frame > early_wakeup_ns) {
                    // Sleep until early_wakeup_ns before the next expected frame
                    std.Thread.sleep(time_until_next_frame - early_wakeup_ns);
                }
                // Spin wait for the remaining time (or if close to frame time)
            }
            // If past expected frame time, just spin waiting for the request
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
