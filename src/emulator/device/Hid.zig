const std = @import("std");

const Bus = @import("Bus.zig");

const spsc_queue = @import("spsc_queue");



const Transaction = Bus.Transaction;


/// Modifier key bitmask (first byte of HID report).
pub const Modifiers = packed struct(u8) {
    left_ctrl: bool = false,
    left_shift: bool = false,
    left_alt: bool = false,
    left_gui: bool = false,
    right_ctrl: bool = false,
    right_shift: bool = false,
    right_alt: bool = false,
    right_gui: bool = false,

    pub fn shift(self: Modifiers) bool {
        return self.left_shift or self.right_shift;
    }

    pub fn ctrl(self: Modifiers) bool {
        return self.left_ctrl or self.right_ctrl;
    }

    pub fn alt(self: Modifiers) bool {
        return self.left_alt or self.right_alt;
    }

    pub fn gui(self: Modifiers) bool {
        return self.left_gui or self.right_gui;
    }
};

pub const Hid = @This();

pub const Queue = spsc_queue.SpscQueuePo2Unmanaged(Event);

pub const KeyEvent = packed struct {
    scancode: u8,
    pressed: bool,
};

pub const Event = union(enum) {
    key: KeyEvent,
};

regs: [2]u32 align(8) = .{0} ** 2,
queue: Queue,
down_keys: std.ArrayList(u8),

pub fn init(gpa: std.mem.Allocator) !*Hid {
    const self = try gpa.create(Hid);
    errdefer gpa.destroy(self);
    self.regs = .{0} ** 2;
    self.queue = try Queue.initCapacity(gpa, 4096);
    self.down_keys = try std.ArrayList(u8).initCapacity(gpa, 256);
    return self;
}

pub fn deinit(self: *Hid, gpa: std.mem.Allocator) void {
    self.queue.deinit(gpa);
    self.down_keys.deinit(gpa);
    gpa.destroy(self);
}

pub fn access(self: *Hid, transaction: Transaction) Transaction {
    return transaction.slice_result(1, self.regs[0..]);
}

pub fn process_queue(self: *Hid) void {
    while (self.queue.front()) |event| {
        switch (event.*) {
            Event.key => |key| {
                var report: *[8]u8 = @ptrCast(&self.regs);
                var modifiers: *Modifiers = @ptrCast(&report[0]);
                switch (key.scancode) {
                    224 => modifiers.left_ctrl   = key.pressed,
                    225 => modifiers.left_shift  = key.pressed,
                    226 => modifiers.left_alt    = key.pressed,
                    227 => modifiers.left_gui    = key.pressed,
                    228 => modifiers.right_ctrl  = key.pressed,
                    229 => modifiers.right_shift = key.pressed,
                    230 => modifiers.right_alt   = key.pressed,
                    231 => modifiers.right_gui   = key.pressed,
                    else => {
                        if (key.pressed) {
                            var contains = false;
                            for (self.down_keys.items) |k| {
                                if (k == key.scancode) {
                                    contains = true;
                                    break;
                                }
                            }
                            if (!contains) {
                                self.down_keys.appendAssumeCapacity(key.scancode);
                            }
                            // Add key to report if there's room
                            var added = false;
                            for (report[2..], 2..) |k, i| {
                                if (k == key.scancode) {
                                    added = true; // Key is already in the report
                                    break;
                                } else if (k == 0) {
                                    report[i] = key.scancode;
                                    added = true;
                                    break;
                                }
                            }
                            if (!added) {
                                // Report rollover error
                                report[2] = 0x01;
                                report[3] = 0x01;
                                report[4] = 0x01;
                                report[5] = 0x01;
                                report[6] = 0x01;
                                report[7] = 0x01;
                            }
                        } else {
                            var index: usize = 256;
                            for (self.down_keys.items, 0..) |k, i| {
                                if (k == key.scancode) {
                                    index = i;
                                    break;
                                }
                            }
                            if (index < 256) {
                                _ = self.down_keys.orderedRemove(index);
                            }

                            if (report[2] == 0x01 and self.down_keys.items.len <= 6) {
                                // Clear rollover error and repopulate keys from down_keys
                                for (0..6) |i| {
                                    if (i < self.down_keys.items.len) {
                                        report[i+2] = self.down_keys.items[i];
                                    } else {
                                        report[i+2] = 0;
                                    }
                                }
                            }

                            // Remove key from report
                            for (report[2..], 0..) |k, i| {
                                if (k == key.scancode) {
                                    // Shift remaining keys down
                                    for (i..5) |j| {
                                        report[j + 2] = report[j + 3];
                                    }
                                    report[7] = 0; // Clear last key
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
        self.queue.pop();
    }
}
