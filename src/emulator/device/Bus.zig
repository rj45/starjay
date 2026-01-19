const std = @import("std");

// TODO: move this elsewhere
pub const Word = u32;
pub const Addr = u32;
pub const Cycle = u64;
pub const Device = @import("Device.zig");

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
};
