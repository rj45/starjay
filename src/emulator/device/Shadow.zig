//! DeviceShadow: An Device whose writes are put into a queue for another thread to read.

const std = @import("std");

const Bus = @import("Bus.zig");
const Sram = @import("Sram.zig");

const spsc_queue = @import("spsc_queue");

const Word = Bus.Word;
const Addr = Bus.Addr;
const Cycle = Bus.Cycle;
const Transaction = Bus.Transaction;
const Queue = Bus.Queue;

/// A Shadow Device that enqueues write transactions to a queue for another thread to process.
pub fn Shadow(Device: anytype) type {
    return struct {
        const DeviceShadow = @This();

        device: Device,
        queue: *Queue,

        pub fn init(device: Device, queue: *Queue) DeviceShadow {
            return .{
                .device = device,
                .queue = queue,
            };
        }

        pub fn access(self: *DeviceShadow, transaction: Transaction) Transaction {
            const result = self.device.access(transaction);

            if (transaction.write) {
                // Enqueue the write transaction for the other thread to process
                self.queue.push(result);
            }

            return result;
        }
    };
}
