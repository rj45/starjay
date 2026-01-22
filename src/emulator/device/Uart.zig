//! 8250 / 16550 UART for console I/O
//!
//! Reminder: flush the writer periodically.

const std = @import("std");

const Bus = @import("Bus.zig");

const Tty = @import("tty.zig").Tty;

const Word = Bus.Word;
const Addr = Bus.Addr;
const Cycle = Bus.Cycle;
const Transaction = Bus.Transaction;

tty: Tty = undefined,
read_buffer: [4096]u8 = undefined,
write_buffer: [4096]u8 = undefined,


pub const Uart = @This();

pub fn init() !Uart {
    var uart: Uart = .{};
    uart.tty = try Tty.init(uart.read_buffer[0..], uart.write_buffer[0..]);
    return uart;
}

pub fn deinit(self: *Uart) void {
    self.flush();
    self.tty.deinit();
}

pub fn flush(self: *Uart) void {
    self.tty.writer().flush() catch {};
}

pub fn access(self: *Uart, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1; // Presume it takes one cycle
    if (transaction.write) {
        if (transaction.address == 0) {
            result.valid = true;
            self.tty.writer().writeByte(@truncate(transaction.data)) catch {
                result.valid = false;
            };
            if (transaction.data == '\n' or transaction.data == '\r') {
                self.flush();
            }
        } else if (transaction.address < 8) {
            // Ignore writes to other registers
            result.valid = true;
        }
    } else {
        result.data = 0;
        if (transaction.address == 0) {
            result.data = 0xff;
            if (self.tty.reader().peekByte()) |_| {
                result.data = @intCast(self.tty.reader().takeByte() catch 0);
            } else |_| {}
            result.valid = true;
        } else if (transaction.address == 5) {
            result.data = 0x60;
            if (self.tty.reader().peekByte()) |_| {
                result.data |= 1; // Data Ready
            } else |_| {}
            result.valid = true;
        } else if (transaction.address < 8) {
            // Other registers are valid but return 0
            result.data = 0;
            result.valid = true;
        }
    }

    return result;
}
