const std = @import("std");

const Bus = @import("Bus.zig");

const Word = Bus.Word;
const Addr = Bus.Addr;
const Cycle = Bus.Cycle;
const Transaction = Bus.Transaction;

pub const Device = @This();

start_address: Addr,
end_address: Addr,

// VTable
impl: *anyopaque,
v_access: *const fn(*anyopaque, Transaction) Transaction,

pub fn init(impl_obj: anytype, start_address: Addr, end_address: Addr) Device {
    const impl = DeviceImpl(impl_obj);
    return .{
        .start_address = start_address,
        .end_address = end_address,
        .impl = impl_obj,
        .v_access = impl.access,
    };
}

pub inline fn containsAddress(self: *const Device, address: Addr) bool {
    return address >= self.start_address and address < self.end_address;
}

pub inline fn access(self: *Device, transaction: Transaction) Transaction {
    std.debug.assert(self.containsAddress(transaction.address));

    var t = transaction;

    // Adjust address to be relative to device
    t.address -= self.start_address;

    var result = self.v_access(self.impl, t);

    // Adjust address back to system address space
    result.address += self.start_address;

    return result;
}

inline fn DeviceImpl(impl_obj: anytype) type {
    const ImplType = @TypeOf(impl_obj);
    return struct {
        fn access(impl: *anyopaque, transaction: Transaction) Transaction {
            return TPtr(ImplType, impl).access(transaction);
        }
    };
}

fn TPtr(T: type, opaque_ptr: *anyopaque) T {
    return @as(T, @ptrCast(@alignCast(opaque_ptr)));
}
