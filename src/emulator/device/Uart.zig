//! 8250 / 16550 UART for console I/O
//!
//! Reminder: flush the writer periodically.

const std = @import("std");

const Bus = @import("Bus.zig");

const Word = Bus.Word;
const Addr = Bus.Addr;
const Cycle = Bus.Cycle;
const Transaction = Bus.Transaction;

reader: std.fs.File.Reader = undefined,
writer: std.fs.File.Writer = undefined,
readBuffer: [65536]u8 = undefined,
writeBuffer: [65536]u8 = undefined,


pub const Uart = @This();

pub fn init() Uart {
    var self = Uart{};
    self.reader = std.fs.File.stdin().reader(&self.readBuffer);
    self.writer = std.fs.File.stdout().writer(&self.writeBuffer);
    return self;
}

pub fn flush(self: *Uart) void {
    self.writer.interface.flush() catch {};
}

pub fn access(self: *Uart, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1; // Presume it takes one cycle
    if (transaction.write) {
        if (transaction.address == 0) {
            result.valid = true;
            self.writer.interface.writeByte(@truncate(transaction.data)) catch {
                result.valid = false;
            };
            if (transaction.data == '\n' or transaction.data == '\r') {
                self.writer.interface.flush() catch {};
            }
        } else if (transaction.address < 8) {
            // Ignore writes to other registers
            result.valid = true;
        }
    } else {
        result.data = 0;
        if (transaction.address == 0) {
            if (self.reader.interface.peekByte() != error.EndOfStream) {
                result.data = @intCast(self.reader.interface.takeByte() catch 0);
                result.valid = true;
            }
        } else if (transaction.address == 5) {
            if (self.reader.interface.peekByte() != error.EndOfStream) {
                result.data = 0x60 | 1; // Data Ready
            } else {
                result.data = 0x60;
            }
            result.valid = true;
        } else if (transaction.address < 8) {
            // Other registers are valid but return 0
            result.data = 0;
            result.valid = true;
        }
    }

    return result;
}
