//! 8250 / 16550 UART for console I/O
//!
//! Reminder: flush the writer periodically.

const std = @import("std");

const Bus = @import("Bus.zig");

const Word = Bus.Word;
const Addr = Bus.Addr;
const Cycle = Bus.Cycle;
const Transaction = Bus.Transaction;

reader: std.io.Reader = undefined,
writer: std.io.Writer = undefined,
readBuffer: [65536]u8 = undefined,
writeBuffer: [65536]u8 = undefined,


pub const Uart = @This();

pub fn init() Uart {
    var self = Uart{};
    self.reader = std.fs.File.stdin().reader(&self.readBuffer).interface;
    self.writer = std.fs.File.stdout().writer(&self.writeBuffer).interface;
    return self;
}

pub fn access(self: *Uart, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1; // Presume it takes one cycle
    if (transaction.write) {
        if (transaction.address == 0) {
            result.valid = true;
            self.writer.writeByte(@truncate(transaction.data)) catch {
                result.valid = false;
            };
        }
    } else {
        result.data = 0;
        if (transaction.address == 0) {
            if (self.reader.peekByte() != error.EndOfStream) {
                result.data = @intCast(self.reader.takeByte() catch unreachable);
                result.valid = true;
            }
        } else if (transaction.address == 5) {
            if (self.reader.bufferedLen() > 0) {
                result.data = 0x60 | 1; // Data Ready
            } else {
                result.data = 0x60;
            }
            result.valid = true;
        }
    }

    return result;
}
