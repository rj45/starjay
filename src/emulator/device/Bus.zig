const std = @import("std");

const spsc_queue = @import("spsc_queue");

// TODO: move this elsewhere
pub const Word = u32;
pub const Addr = u32;
pub const Cycle = u64;
pub const Device = @import("Device.zig");
pub const Queue = spsc_queue.SpscQueuePo2Unmanaged(Transaction);

pub const Bus = @This();

devices: std.ArrayList(Device),
gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator) !Bus {
    return Bus{
        .gpa = gpa,
        .devices = try std.ArrayList(Device).initCapacity(gpa, 4),
    };
}

pub fn deinit(self: *Bus) void {
    self.devices.deinit(self.gpa);
}

pub fn attach(self: *Bus, device: Device) !void {
    try self.devices.append(self.gpa, device);
}

pub fn access(self: *Bus, transaction: Transaction) Transaction {
    for (self.devices.items) |*device| {
        if (device.containsAddress(transaction.address)) {
            return device.access(transaction);
        }
    }
    return transaction;
}

pub const Transaction = packed struct(u128) {
    address: Addr,
    data: Word = 0,
    cycle: u48 = 0,
    bytes: u4 = 0b1111,
    write: bool = false,
    valid: bool = false,
    duration: u10 = 0,

    pub fn start_cycle(self: Transaction) Cycle {
        return self.cycle;
    }

    pub fn end_cycle(self: Transaction) Cycle {
        return self.cycle + @as(Cycle, self.duration);
    }

    pub inline fn mask(self: *const Transaction) Word {
        var m: Word = 0;
        if (self.bytes & 0b0001 != 0) {
            m |= 0x000000FF;
        }
        if (self.bytes & 0b0010 != 0) {
            m |= 0x0000FF00;
        }
        if (self.bytes & 0b0100 != 0) {
            m |= 0x00FF0000;
        }
        if (self.bytes & 0b1000 != 0) {
            m |= 0xFF000000;
        }
        return m;
    }

    pub inline fn shift_amount(self: *const Transaction) u5 {
        return @truncate((self.address & 0b11) << 3);
    }

    pub inline fn aligned_mask(self: *const Transaction) Word {
        const shift = self.shift_amount();
        return self.mask() << shift;
    }

    pub inline fn word_address(self: *const Transaction) usize {
        return self.address >> 2;
    }

    pub inline fn is_aligned(self: *const Transaction) bool {
        switch (self.bytes) {
            0b1111 => return (self.address & 0b11) == 0,
            0b0011 => return (self.address & 0b1) == 0,
            0b0001 => return true,
            else => return false,
        }
    }

    /// Helper function to produce a modified word for write transactions
    pub inline fn modify_word(self: *const Transaction, orig: Word) Word {
        const m = self.aligned_mask();
        return (orig & ~m) | (self.data & m);
    }

    /// Helper function to produce a read transaction result from a slice of words
    pub inline fn read_word(self: *const Transaction, duration: Cycle, words: []Word) Transaction {
        var result = self.*;
        result.duration = duration;
        const addr = self.word_address();
        if (addr >= words.len) {
            result.valid = false;
            return result;
        }
        const orig = words[addr];
        result.data = (orig >> self.shift_amount()) & self.mask();
        result.valid = self.is_aligned();
        return result;
    }

    /// Helper function to produce a write transaction result from a slice of words
    pub inline fn write_word(self: *const Transaction, duration: Cycle, words: []Word) Transaction {
        var result = self.*;
        result.duration = duration;
        const addr = self.word_address();
        if (addr >= words.len or !self.is_aligned()) {
            result.valid = false;
            return result;
        }
        const orig = words[addr];
        words[addr] = self.modify_word(orig);
        result.valid = true;
        return result;
    }

    pub inline fn slice_result(self: *const Transaction, duration: Cycle, words: []Word) Transaction {
        if (self.write) {
            return self.write_word(duration, words);
        } else {
            return self.read_word(duration, words);
        }
    }
};
