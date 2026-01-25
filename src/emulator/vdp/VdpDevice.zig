// (C) 2026 Ryan "rj45" Sanche, MIT License
//
// VdpDevice: Memory-mapped device interface for the VDP
// Implements the Device interface and owns VdpState.
// Translates addresses directly to VdpState's sprite attribute arrays.
//
// Address Space (contiguous addressing):
// 0x0000 - 0x1FFF: Sprite attribute table (low 32 bits)
//                  512 sprites × 4 attributes × 4 bytes = 8192 bytes
//                  Per sprite (16 bytes): [y_height_lo, x_width_lo, addr_lo, velocity_lo]
// 0x2000 - 0x27FF: Sprite high bits table
//                  512 sprites × 4 bytes = 2048 bytes
//                  Per sprite word: bits[3:0]=y_height[35:32], [7:4]=x_width[35:32],
//                                   [11:8]=addr[35:32], [15:12]=velocity[35:32]
// 0x4000 - 0x7FFF: VRAM (tilemap and tile bitmap data)
//                  16 KB = 16384 bytes

const std = @import("std");

const Bus = @import("../device/Bus.zig");
const VdpState = @import("VdpState.zig");
const types = @import("types.zig");

const Transaction = Bus.Transaction;
const Addr = Bus.Addr;
const Word = Bus.Word;

pub const VdpDevice = @This();

// Memory region constants
pub const SPRITE_ATTR_BASE: Addr = 0x0000;
pub const SPRITE_ATTR_SIZE: Addr = 0x2000; // 8192 bytes (512 sprites × 4 attrs × 4 bytes)
pub const SPRITE_HIGH_BASE: Addr = 0x2000;
pub const SPRITE_HIGH_SIZE: Addr = 0x0800; // 2048 bytes (512 sprites × 4 bytes)
pub const PALETTE_BASE: Addr = 0x3000;
pub const VRAM_BASE: Addr = 0x4000;
pub const TOTAL_SIZE: Addr = VRAM_BASE + VdpState.VRAM_SIZE;

// VDP state (owns the sprite attribute arrays)
vdp: VdpState,

pub fn init(self: *VdpDevice, allocator: std.mem.Allocator, frame_buffer: VdpState.FrameBuffer) void {
    self.vdp.init(allocator, frame_buffer);
}

/// Device interface: handle memory-mapped access
pub fn access(self: *VdpDevice, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1;

    const addr = transaction.address;

    if (addr < SPRITE_ATTR_SIZE) {
        // Sprite attribute table (low 32 bits)
        result = self.accessSpriteAttrLo(transaction);
    } else if (addr < SPRITE_HIGH_BASE + SPRITE_HIGH_SIZE) {
        // Sprite high bits table
        result = self.accessSpriteHigh(transaction);
    } else if (addr >= PALETTE_BASE and addr < PALETTE_BASE + VdpState.PALETTE_SIZE) {
        // Pallette RAM
        result = self.accessPalette(transaction);
    } else if (addr >= VRAM_BASE and addr < VRAM_BASE + VdpState.VRAM_SIZE) {
        // VRAM
        result = self.accessVram(transaction);
    }
    // Out of range addresses return invalid

    return result;
}

fn accessSpriteAttrLo(self: *VdpDevice, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1;

    const addr = transaction.address;
    if (addr >= SPRITE_ATTR_SIZE) return result;

    // Each sprite has 16 bytes (4 attributes × 4 bytes)
    const sprite_index = addr / 16;
    const attr_offset = (addr % 16) / 4;
    const byte_offset = addr % 4;

    if (sprite_index >= 512) return result;
    if (byte_offset != 0 or transaction.bytes != 0b1111) {
        // For now, only support aligned 32-bit accesses
        // TODO: Support partial/unaligned accesses
        return result;
    }

    if (transaction.write) {
        const current_36 = self.getSpriteAttr36(sprite_index, attr_offset);
        // Keep high 4 bits, replace low 32 bits
        const new_36: u36 = (current_36 & 0xF_00000000) | @as(u36, transaction.data);
        self.setSpriteAttr36(sprite_index, attr_offset, new_36);
        result.valid = true;
    } else {
        const val = self.getSpriteAttr36(sprite_index, attr_offset);
        result.data = @truncate(val);
        result.valid = true;
    }

    return result;
}

fn accessSpriteHigh(self: *VdpDevice, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1;

    const addr = transaction.address - SPRITE_HIGH_BASE;
    if (addr >= SPRITE_HIGH_SIZE) return result;

    const sprite_index = addr / 4;
    const byte_offset = addr % 4;

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

fn accessPalette(self: *VdpDevice, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1;

    const addr = transaction.address - PALETTE_BASE;
    if (addr >= VdpState.PALETTE_SIZE) return result;

    if (transaction.write) {
        if (transaction.bytes == 0b1111 and addr % 4 == 0) {
            self.vdp.palette[addr / 4] = transaction.data;
            result.valid = true;
        } else if (transaction.bytes == 0b0011 and addr % 2 == 0) {
            const half_ptr: [*]u16 = @alignCast(@ptrCast(&self.vdp.palette[addr / 4]));
            half_ptr[addr % 2] = @truncate(transaction.data);
            result.valid = true;
        } else if (transaction.bytes == 0b0001) {
            const byte_ptr: [*]u8 = @alignCast(@ptrCast(&self.vdp.palette[addr / 4]));
            byte_ptr[addr % 4] = @truncate(transaction.data);
            result.valid = true;
        }
    } else {
        if (transaction.bytes == 0b1111 and addr % 4 == 0) {
            result.data = self.vdp.palette[addr/4];
            result.valid = true;
        } else if (transaction.bytes == 0b0011 and addr % 2 == 0) {
            const half_ptr: [*]u16 = @alignCast(@ptrCast(&self.vdp.palette[addr / 4]));
            result.data = half_ptr[addr % 2];
            result.valid = true;
        } else if (transaction.bytes == 0b0001) {
            const byte_ptr: [*]u8 = @alignCast(@ptrCast(&self.vdp.palette[addr / 4]));
            result.data = byte_ptr[addr % 4];
            result.valid = true;
        }
    }

    return result;
}


fn accessVram(self: *VdpDevice, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1;

    const addr = transaction.address - VRAM_BASE;
    if (addr >= VdpState.VRAM_SIZE) return result;

    if (transaction.write) {
        if (transaction.bytes == 0b1111 and addr % 4 == 0) {
            const word_ptr: *u32 = @alignCast(@ptrCast(&self.vdp.vram[addr]));
            word_ptr.* = transaction.data;
            result.valid = true;
        } else if (transaction.bytes == 0b0011 and addr % 2 == 0) {
            const half_ptr: *u16 = @alignCast(@ptrCast(&self.vdp.vram[addr]));
            half_ptr.* = @truncate(transaction.data);
            result.valid = true;
        } else if (transaction.bytes == 0b0001) {
            self.vdp.vram[addr] = @truncate(transaction.data);
            result.valid = true;
        }
    } else {
        if (transaction.bytes == 0b1111 and addr % 4 == 0) {
            const word_ptr: *u32 = @alignCast(@ptrCast(&self.vdp.vram[addr]));
            result.data = word_ptr.*;
            result.valid = true;
        } else if (transaction.bytes == 0b0011 and addr % 2 == 0) {
            const half_ptr: *u16 = @alignCast(@ptrCast(&self.vdp.vram[addr]));
            result.data = half_ptr.*;
            result.valid = true;
        } else if (transaction.bytes == 0b0001) {
            result.data = self.vdp.vram[addr];
            result.valid = true;
        }
    }

    return result;
}

/// Get a sprite attribute as u36 by sprite index and attribute index (0-3)
fn getSpriteAttr36(self: *VdpDevice, sprite_index: usize, attr_index: usize) u36 {
    return switch (attr_index) {
        0 => @bitCast(self.vdp.sprite_y_height[sprite_index]),
        1 => @bitCast(self.vdp.sprite_x_width[sprite_index]),
        2 => @bitCast(self.vdp.sprite_addr[sprite_index]),
        3 => @bitCast(self.vdp.sprite_velocity[sprite_index]),
        else => 0,
    };
}

/// Set a sprite attribute from u36 by sprite index and attribute index (0-3)
fn setSpriteAttr36(self: *VdpDevice, sprite_index: usize, attr_index: usize, value: u36) void {
    switch (attr_index) {
        0 => self.vdp.sprite_y_height[sprite_index] = @bitCast(value),
        1 => self.vdp.sprite_x_width[sprite_index] = @bitCast(value),
        2 => self.vdp.sprite_addr[sprite_index] = @bitCast(value),
        3 => self.vdp.sprite_velocity[sprite_index] = @bitCast(value),
        else => {},
    }
}
