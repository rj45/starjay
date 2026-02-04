// Copied from: https://codeberg.org/kaimanhub/zchan
// Copyright (c) 2025 kaimanhub, Apache 2.0 License

//! Channel Library
//!
//! Provides thread-safe communication channels for Zig applications,
//! enabling safe message passing between threads with FIFO ordering
//! and blocking semantics.
//!
//! Exposed Functions:
//! - `Channel(T).init(allocator)`: Creates a buffered channel for type T.
//! - `Channel(T).init(null)`: Creates an unbuffered channel for type T.
//! - `send(item)`: Sends an item to the channel (blocking for unbuffered, non-blocking for buffered).
//! - `receive()`: Receives an item from the channel (blocking until available or closed).
//! - `close()`: Closes the channel, waking all waiting receivers.
//! - `deinit()`: Cleans up allocated resources.
//!
//! These utilities are particularly useful for concurrent programming,
//! supporting multiple producers and consumers with guaranteed thread safety
//! and proper resource cleanup.

const std = @import("std");
const testing = std.testing;
const thread = std.Thread;

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        queue: std.ArrayList(T), // TODO: replace with Dequeue
        mutex: thread.Mutex,
        condition: thread.Condition,
        closed: bool,
        ai: ?std.mem.Allocator,
        buffered: bool,

        transfer_item: ?T,
        sender_waiting: bool,
        receiver_waiting: bool,

        pub fn init(ai: ?std.mem.Allocator) Self {
            const is_buffered = ai != null;

            return Self{
                .queue = std.ArrayList(T).empty,
                .mutex = thread.Mutex{},
                .condition = thread.Condition{},
                .closed = false,
                .ai = ai,
                .buffered = is_buffered,
                .transfer_item = null,
                .sender_waiting = false,
                .receiver_waiting = false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.buffered and self.ai != null) {
                self.queue.deinit(self.ai.?);
            }
        }

        pub fn send(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) return error.ChannelClosed;

            if (self.buffered) {
                try self.queue.append(self.ai.?, item);
                self.condition.signal();
            } else {
                while (!self.closed) {
                    if (self.receiver_waiting) {
                        self.transfer_item = item;
                        self.receiver_waiting = false;
                        self.condition.broadcast();
                        return;
                    } else {
                        self.sender_waiting = true;
                        self.transfer_item = item;

                        while (self.sender_waiting and !self.closed) {
                            self.condition.wait(&self.mutex);
                        }

                        if (self.closed) return error.ChannelClosed;
                        return;
                    }
                }
                return error.ChannelClosed;
            }
        }

        pub fn receive(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.buffered) {
                while (self.queue.items.len == 0 and !self.closed) {
                    self.condition.wait(&self.mutex);
                }

                if (self.queue.items.len == 0) return null;
                return self.queue.orderedRemove(0);
            } else {
                while (!self.closed) {
                    if (self.sender_waiting) {
                        const item = self.transfer_item.?;
                        self.transfer_item = null;
                        self.sender_waiting = false;
                        self.condition.broadcast();
                        return item;
                    } else {
                        self.receiver_waiting = true;

                        while (self.receiver_waiting and !self.closed) {
                            self.condition.wait(&self.mutex);
                        }

                        if (self.closed) return null;

                        const item = self.transfer_item.?;
                        self.transfer_item = null;
                        return item;
                    }
                }
                return null;
            }
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.sender_waiting = false;
            self.receiver_waiting = false;
            self.condition.broadcast();
        }
    };
}

test "Channel: buffered basic send and receive" {
    var channel = Channel(i32).init(testing.allocator);
    defer channel.deinit();

    try channel.send(42);
    try channel.send(100);

    const value1 = channel.receive();
    const value2 = channel.receive();

    try testing.expect(value1 != null);
    try testing.expect(value2 != null);
    try testing.expectEqual(@as(i32, 42), value1.?);
    try testing.expectEqual(@as(i32, 100), value2.?);
}

test "Channel: unbuffered basic send and receive" {
    var channel = Channel(i32).init(null);
    defer channel.deinit();

    const TestContext = struct {
        channel: *Channel(i32),
        sent_value: i32 = 0,
        received_value: ?i32 = null,
    };

    const senderFn = struct {
        fn run(ctx: *TestContext) void {
            ctx.channel.send(42) catch return;
            ctx.sent_value = 42;
        }
    }.run;

    const receiverFn = struct {
        fn run(ctx: *TestContext) void {
            ctx.received_value = ctx.channel.receive();
        }
    }.run;

    var ctx = TestContext{ .channel = &channel };

    const sender = try thread.spawn(.{}, senderFn, .{&ctx});
    const receiver = try thread.spawn(.{}, receiverFn, .{&ctx});

    sender.join();
    receiver.join();

    try testing.expectEqual(@as(i32, 42), ctx.sent_value);
    try testing.expectEqual(@as(i32, 42), ctx.received_value.?);
}

test "Channel: unbuffered synchronization" {
    var channel = Channel(i32).init(null);
    defer channel.deinit();

    const TestContext = struct {
        channel: *Channel(i32),
        sender_finished: bool = false,
        receiver_started: bool = false,
    };

    const senderFn = struct {
        fn run(ctx: *TestContext) void {
            ctx.channel.send(123) catch return;
            ctx.sender_finished = true;
        }
    }.run;

    const receiverFn = struct {
        fn run(ctx: *TestContext) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            ctx.receiver_started = true;
            _ = ctx.channel.receive();
        }
    }.run;

    var ctx = TestContext{ .channel = &channel };

    const sender = try thread.spawn(.{}, senderFn, .{&ctx});
    const receiver = try thread.spawn(.{}, receiverFn, .{&ctx});

    std.Thread.sleep(5 * std.time.ns_per_ms);
    try testing.expect(!ctx.sender_finished);

    receiver.join();
    sender.join();

    try testing.expect(ctx.sender_finished);
    try testing.expect(ctx.receiver_started);
}

test "Channel: send to closed channel returns error" {
    var channel = Channel(i32).init(testing.allocator);
    defer channel.deinit();

    channel.close();

    const result = channel.send(42);
    try testing.expectError(error.ChannelClosed, result);
}

test "Channel: receive from closed empty channel returns null" {
    var channel = Channel(i32).init(testing.allocator);
    defer channel.deinit();

    channel.close();

    const result = channel.receive();
    try testing.expect(result == null);
}

test "Channel: receive from closed channel with items returns items then null" {
    var channel = Channel(i32).init(testing.allocator);
    defer channel.deinit();

    try channel.send(42);
    try channel.send(100);
    channel.close();

    const value1 = channel.receive();
    const value2 = channel.receive();
    const value3 = channel.receive();

    try testing.expectEqual(@as(i32, 42), value1.?);
    try testing.expectEqual(@as(i32, 100), value2.?);
    try testing.expect(value3 == null);
}

test "Channel: works with different types" {
    var str_channel = Channel([]const u8).init(testing.allocator);
    defer str_channel.deinit();

    try str_channel.send("hello");
    try str_channel.send("world");

    try testing.expectEqualStrings("hello", str_channel.receive().?);
    try testing.expectEqualStrings("world", str_channel.receive().?);

    var bool_channel = Channel(bool).init(testing.allocator);
    defer bool_channel.deinit();

    try bool_channel.send(true);
    try bool_channel.send(false);

    try testing.expectEqual(true, bool_channel.receive().?);
    try testing.expectEqual(false, bool_channel.receive().?);
}

test "Channel: FIFO ordering" {
    var channel = Channel(usize).init(testing.allocator);
    defer channel.deinit();

    for (0..10) |i| {
        try channel.send(i);
    }

    for (0..10) |expected| {
        const received = channel.receive();
        try testing.expect(received != null);
        try testing.expectEqual(expected, received.?);
    }
}
