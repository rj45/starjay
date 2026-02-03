// (C) 2026 Ryan "rj45" Sanche, MIT License
//
// Vdp.Device: Memory-mapped device interface for the VDP

const std = @import("std");

const Bus = @import("../device/Bus.zig");
const State = @import("State.zig");
const types = @import("types.zig");

const Transaction = Bus.Transaction;
const Addr = Bus.Addr;
const Word = Bus.Word;

pub const Device = @This();

// Memory region constants
pub const SPRITE_ATTR_BASE: Addr = 0x0000;
pub const SPRITE_ATTR_SIZE: Addr = 0x2000;
pub const SPRITE_HIGH_BASE: Addr = 0x2000;
pub const SPRITE_HIGH_SIZE: Addr = 0x0800;
pub const PALETTE_BASE: Addr = 0x3000;
pub const VRAM_BASE: Addr = 0x4000;
pub const TOTAL_SIZE: Addr = VRAM_BASE + State.VRAM_SIZE;

// VDP state (owns the sprite attribute arrays)
vdp: State,

pub fn init() Device {
    return .{
        .vdp = State.init(),
    };
}

/// Device interface: handle memory-mapped access
pub fn access(self: *Device, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1;

    const addr = transaction.address;

    if (addr < SPRITE_ATTR_SIZE) {
        // Sprite attribute table (low 32 bits)
        result = self.accessSpriteAttrLo(transaction);
    } else if (addr < SPRITE_HIGH_BASE + SPRITE_HIGH_SIZE) {
        // Sprite high bits table
        result = self.accessSpriteHigh(transaction);
    } else if (addr >= PALETTE_BASE and addr < PALETTE_BASE + State.PALETTE_SIZE) {
        // Pallette RAM
        result = self.accessPalette(transaction);
    } else if (addr >= VRAM_BASE and addr < VRAM_BASE + State.VRAM_SIZE) {
        // VRAM
        result = self.accessVram(transaction);
    }

    return result;
}

fn accessSpriteAttrLo(self: *Device, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1;

    const addr = transaction.address;
    if (addr >= SPRITE_ATTR_SIZE) return result;

    // Each sprite has 16 bytes (4 attributes × 4 bytes)
    const sprite_index = addr >> 4;
    const attr_offset = (addr & 0xf) >> 2;
    const byte_offset = addr & 3;

    if (sprite_index >= 512) return result;


    if (transaction.write) {
        switch (transaction.bytes) {
            0b1111 => {
                const current_36 = self.getSpriteAttr36(sprite_index, attr_offset);
                // Keep high 4 bits, replace low 32 bits
                const new_36: u36 = (current_36 & 0xF_00000000) | @as(u36, transaction.data);
                self.setSpriteAttr36(sprite_index, attr_offset, new_36);
                result.valid = true;
            },
            0b0011 => {
                const current_36 = self.getSpriteAttr36(sprite_index, attr_offset);
                switch (byte_offset) {
                    0 => {
                        const new_36: u36 = (current_36 & 0xF_FFFF0000) | @as(u36, transaction.data & 0xFFFF);
                        self.setSpriteAttr36(sprite_index, attr_offset, new_36);
                        result.valid = true;
                    },
                    2 => {
                        const new_36: u36 = (current_36 & 0xF_0000FFFF) | (@as(u36, transaction.data & 0xFFFF) << 16);
                        self.setSpriteAttr36(sprite_index, attr_offset, new_36);
                        result.valid = true;
                    },
                    else => return result,
                }

            },
            0b0001 => {
                const current_36 = self.getSpriteAttr36(sprite_index, attr_offset);
                switch (byte_offset) {
                    0 => {
                        const new_36: u36 = (current_36 & 0xF_FFFF_FF00) | @as(u36, transaction.data & 0xFF);
                        self.setSpriteAttr36(sprite_index, attr_offset, new_36);
                        result.valid = true;
                    },
                    1 => {
                        const new_36: u36 = (current_36 & 0xF_FFFF_00FF) | (@as(u36, transaction.data & 0xFF) << 8);
                        self.setSpriteAttr36(sprite_index, attr_offset, new_36);
                        result.valid = true;
                    },
                    2 => {
                        const new_36: u36 = (current_36 & 0xF_FF00_FFFF) | (@as(u36, transaction.data & 0xFF) << 16);
                        self.setSpriteAttr36(sprite_index, attr_offset, new_36);
                        result.valid = true;
                    },
                    3 => {
                        const new_36: u36 = (current_36 & 0xF_00FF_FFFF) | (@as(u36, transaction.data & 0xFF) << 24);
                        self.setSpriteAttr36(sprite_index, attr_offset, new_36);
                        result.valid = true;
                    },
                    else => return result,
                }
            },
            else => return result,
        }


    } else {
        if (byte_offset != 0 or transaction.bytes != 0b1111) {
            // For now, only support aligned 32-bit accesses
            // TODO: Support partial/unaligned accesses
            return result;
        }

        const val = self.getSpriteAttr36(sprite_index, attr_offset);
        result.data = @truncate(val);
        result.valid = true;
    }

    return result;
}

fn accessSpriteHigh(self: *Device, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1;

    const addr = transaction.address - SPRITE_HIGH_BASE;
    if (addr >= SPRITE_HIGH_SIZE) return result;

    const sprite_index = addr >> 2;
    const byte_offset = addr & 3;

    if (sprite_index >= 512) return result;
    if (byte_offset != 0 or transaction.bytes != 0b1111 ) {
        // For now, only support aligned 32-bit accesses
        return result;
    }

    if (transaction.write) {
        // Unpack the high bits and apply to each attribute
        const yh_hi: u36 = @as(u36, (transaction.data >> 0) & 0xF);
        const xw_hi: u36 = @as(u36, (transaction.data >> 4) & 0xF);
        const addr_hi: u36 = @as(u36, (transaction.data >> 8) & 0xF);
        const vel_hi: u36 = @as(u36, (transaction.data >> 12) & 0xF);

        // Update each attribute's high bits
        const yh = self.getSpriteAttr36(sprite_index, 0);
        self.setSpriteAttr36(sprite_index, 0, (yh & 0x0_FFFFFFFF) | (yh_hi << 32));

        const xw = self.getSpriteAttr36(sprite_index, 1);
        self.setSpriteAttr36(sprite_index, 1, (xw & 0x0_FFFFFFFF) | (xw_hi << 32));

        const sa = self.getSpriteAttr36(sprite_index, 2);
        self.setSpriteAttr36(sprite_index, 2, (sa & 0x0_FFFFFFFF) | (addr_hi << 32));

        const vel = self.getSpriteAttr36(sprite_index, 3);
        self.setSpriteAttr36(sprite_index, 3, (vel & 0x0_FFFFFFFF) | (vel_hi << 32));

        result.valid = true;
    } else {
        // Pack the high 4 bits from each attribute
        const yh: u32 = @truncate(self.getSpriteAttr36(sprite_index, 0) >> 32);
        const xw: u32 = @truncate(self.getSpriteAttr36(sprite_index, 1) >> 32);
        const sa: u32 = @truncate(self.getSpriteAttr36(sprite_index, 2) >> 32);
        const vel: u32 = @truncate(self.getSpriteAttr36(sprite_index, 3) >> 32);

        result.data = (yh & 0xF) |
            ((xw & 0xF) << 4) |
            ((sa & 0xF) << 8) |
            ((vel & 0xF) << 12);
        result.valid = true;
    }

    return result;
}

fn accessPalette(self: *Device, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1;

    const addr = transaction.address - PALETTE_BASE;
    if (addr >= State.PALETTE_SIZE) return result;
    const index = addr >> 2;

    if (transaction.write) {
        if (transaction.bytes == 0b1111 and addr & 3 == 0) {
            self.vdp.palette[index] = transaction.data;
            result.valid = true;
        } else if (transaction.bytes == 0b0011 and addr & 1 == 0) {
            var word = self.vdp.palette[index];
            const half: u5 = @truncate((addr >> 1) & 1);
            word = word & ~(@as(u32, 0xFFFF) << (half * 16)) | ((transaction.data & 0xFFFF) << (half * 16));
            self.vdp.palette[index] = word;
            result.valid = true;
        } else if (transaction.bytes == 0b0001) {
            var word = self.vdp.palette[index];
            const byte:u5 = @truncate(addr & 3);
            word = word & ~(@as(u32, 0xFF) << (byte * 8)) | ((transaction.data & 0xFF) << (byte * 8));
            self.vdp.palette[index] = word;
            result.valid = true;
        }
    } else {
        if (transaction.bytes == 0b1111 and addr & 3 == 0) {
            result.data = self.vdp.palette[index];
            result.valid = true;
        } else if (transaction.bytes == 0b0011 and addr & 1 == 0) {
            const word = self.vdp.palette[index];
            const half: u5 = @truncate(addr & 1);
            result.data = (word >> (half << 4)) & 0xFFFF;
            result.valid = true;
        } else if (transaction.bytes == 0b0001) {
            const word = self.vdp.palette[index];
            const byte:u5 = @truncate(addr & 3);
            result.data = (word >> (byte * 8)) & 0xFF;
            result.valid = true;
        }
    }

    return result;
}

// TODO: this is nearly identical to accessPalette - refactor
fn accessVram(self: *Device, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1;

    const addr = transaction.address - VRAM_BASE;
    if (addr >= State.VRAM_SIZE) return result;

    if (transaction.write) {
        if (transaction.bytes == 0b1111 and addr & 3 == 0) {
            self.setVram(addr, transaction.data);
            result.valid = true;
        } else if (transaction.bytes == 0b0011 and addr & 1 == 0) {
            var word = self.getVram(addr);
            const half:u5 = @truncate(addr & 1);
            word = word & ~(@as(u32, 0xFFFF) << (half << 4)) | ((transaction.data & 0xFFFF) << (half << 4));
            self.setVram(addr, word);
            result.valid = true;
        } else if (transaction.bytes == 0b0001) {
            var word = self.getVram(addr);
            const byte: u5 = @truncate(addr & 3);
            word = word & ~(@as(u32, 0xFF) << (byte * 8)) | ((transaction.data & 0xFF) << (byte * 8));
            self.setVram(addr, word);
            result.valid = true;
        }
    } else {
        if (transaction.bytes == 0b1111 and addr & 3 == 0) {
            result.data = self.getVram(addr);
            result.valid = true;
        } else if (transaction.bytes == 0b0011 and addr & 1 == 0) {
            const word = self.getVram(addr);
            const half:u5 = @truncate(addr & 1);
            result.data = (word >> (half << 4)) & 0xFFFF;
            result.valid = true;
        } else if (transaction.bytes == 0b0001) {
            const word = self.getVram(addr);
            const byte: u5 = @truncate(addr & 3);
            result.data = (word >> (byte * 8)) & 0xFF;
            result.valid = true;
        }
    }

    return result;
}

inline fn getVram(self: *Device, addr: usize) u32 {
    const vram: []u32 = std.mem.bytesAsSlice(u32, &self.vdp.vram);
    return vram[addr >> 2];
}

inline fn setVram(self: *Device, addr: usize, value: u32) void {
    const vram: []u32 = std.mem.bytesAsSlice(u32, &self.vdp.vram);
    vram[addr >> 2] = value;
}

/// Get a sprite attribute as u36 by sprite index and attribute index (0-3)
inline fn getSpriteAttr36(self: *Device, sprite_index: usize, attr_index: usize) u36 {
    return switch (attr_index) {
        0 => @bitCast(self.vdp.sprite_y_height[sprite_index]),
        1 => @bitCast(self.vdp.sprite_x_width[sprite_index]),
        2 => @bitCast(self.vdp.sprite_addr[sprite_index]),
        3 => @bitCast(self.vdp.sprite_velocity[sprite_index]),
        else => 0,
    };
}

/// Set a sprite attribute from u36 by sprite index and attribute index (0-3)
inline fn setSpriteAttr36(self: *Device, sprite_index: usize, attr_index: usize, value: u36) void {
    switch (attr_index) {
        0 => self.vdp.sprite_y_height[sprite_index] = @bitCast(value),
        1 => self.vdp.sprite_x_width[sprite_index] = @bitCast(value),
        2 => self.vdp.sprite_addr[sprite_index] = @bitCast(value),
        3 => self.vdp.sprite_velocity[sprite_index] = @bitCast(value),
        else => {},
    }
}
