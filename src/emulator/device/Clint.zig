//! CLINT: Core Local Interrupt
//!
//! Memory-mapped device that provides timer and software interrupt functionality.
//!
//! See: https://chromitem-soc.readthedocs.io/en/latest/clint.html

const std = @import("std");

const Bus = @import("Bus.zig");

const Word = Bus.Word;
const Addr = Bus.Addr;
const Cycle = Bus.Cycle;
const Transaction = Bus.Transaction;

msip: bool,
mtimecmp: u64,
mtime: u64,

pub const Clint = @This();

pub fn init() Clint {
    return .{
        .msip = false,
        .mtimecmp = 0,
        .mtime = 0,
    };
}

pub fn access(self: *Clint, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1; // Presume it takes a cycle to access CLINT
    if (transaction.write) {
        if (transaction.address == 0) {
            self.msip = transaction.data != 0;
            result.valid = true;
        } else if (transaction.address == 0x4000) {
            const val64: u64 = @intCast(transaction.data);
            self.mtimecmp = (self.mtimecmp & 0xFFFFFFFF00000000) | val64;
            result.valid = true;
        } else if (transaction.address == 0x4004) {
            const val64: u64 = @intCast(transaction.data);
            self.mtimecmp = (self.mtimecmp & 0x00000000FFFFFFFF) | (val64 << 32);
            result.valid = true;
        }
    } else {
        if (transaction.address == 0) {
            result.data = if (self.msip) 1 else 0;
            result.valid = true;
        } else if (transaction.address == 0x4000) {
            result.data = @intCast(self.mtimecmp & 0xFFFFFFFF);
            result.valid = true;
        } else if (transaction.address == 0x4004) {
            result.data = @intCast(self.mtimecmp >> 32);
            result.valid = true;
        } else if (transaction.address == 0xBFF8) {
            result.data = @intCast(self.mtime & 0xFFFFFFFF);
            result.valid = true;
        } else if (transaction.address == 0xBFFC) {
            result.data = @intCast(self.mtime >> 32);
            result.valid = true;
        }
    }

    return result;
}
