//! SRAM: Single cycle access RAM device.

const std = @import("std");

const Bus = @import("Bus.zig");

const Word = Bus.Word;
const Addr = Bus.Addr;
const Cycle = Bus.Cycle;
const Transaction = Bus.Transaction;

mem: []align(4) u8,

pub const Sram = @This();

pub fn init(memory: []align(4) u8) Sram {
    return Sram{
        .mem = memory,
    };
}

pub fn access(self: *Sram, transaction: Transaction) Transaction {
    var result = transaction;
    result.duration += 1; // Presume it takes a cycle to access SRAM
    if (transaction.write) {
        if (transaction.address > self.mem.len) {
            std.debug.print("Out of bounds: {x}\n", .{transaction.address});
            return result; // Out of bounds
        }
        if (transaction.bytes == 0b1111) {
            if (transaction.address & 3 != 0) {
                std.debug.print("Unaligned sw: {x}\n", .{transaction.address});
                return result; // Unaligned access
            }
            const wordPtr: *u32 = @alignCast(@ptrCast(&self.mem[transaction.address]));
            wordPtr.* = transaction.data;
            result.valid = true;
        } else if (transaction.bytes == 0b0011) {
            if (transaction.address & 1 != 0) {
                std.debug.print("Unaligned sh: {x}\n", .{transaction.address});
                return result; // Unaligned access
            }
            const halfPtr: *u16 = @alignCast(@ptrCast(&self.mem[transaction.address]));
            halfPtr.* = @truncate(transaction.data & 0xFFFF);
            result.valid = true;
        } else if (transaction.bytes == 0b0001) {
            self.mem[transaction.address] = @truncate(transaction.data & 0xFF);
            result.valid = true;
        } else { // slow path for arbitrary byte enables
            if (transaction.address & 3 != 0) {
                return result; // Unaligned access
            }
            const wordPtr: *u32 = @alignCast(@ptrCast(&self.mem[transaction.address]));
            var mask: u32 = 0;
            if ((transaction.bytes & 0b0001) != 0) {
                mask |= 0x000000FF;
            }
            if ((transaction.bytes & 0b0010) != 0) {
                mask |= 0x0000FF00;
            }
            if ((transaction.bytes & 0b0100) != 0) {
                mask |= 0x00FF0000;
            }
            if ((transaction.bytes & 0b1000) != 0) {
                mask |= 0xFF000000;
            }
            wordPtr.* = (transaction.data & mask) | (wordPtr.* & ~mask);
            result.valid = true;
        }
    } else {
        if (transaction.address > self.mem.len) {
            std.debug.print("Out of bounds: {x}\n", .{transaction.address});
            return result; // Out of bounds
        }
        if (transaction.bytes == 0b1111) {
            if (transaction.address & 3 != 0) {
                std.debug.print("Load Unaligned: {x}\n", .{transaction.address});
                @panic("wat");
                // return result; // Unaligned access
            }
            const wordPtr: *u32 = @alignCast(@ptrCast(&self.mem[transaction.address]));
            result.data = wordPtr.*;
            result.valid = true;
        } else if (transaction.bytes == 0b0011) {
            if (transaction.address & 1 != 0) {
                std.debug.print("Store Unaligned: {x}\n", .{transaction.address});
                return result; // Unaligned access
            }
            const halfPtr: *u16 = @alignCast(@ptrCast(&self.mem[transaction.address]));
            result.data = @intCast(halfPtr.*);
            result.valid = true;
        } else if (transaction.bytes == 0b0001) {
            result.data = @intCast(self.mem[transaction.address]);
            result.valid = true;
        } else { // slow path for arbitrary byte enables
            if (transaction.address & 3 != 0) {
                return result; // Unaligned access
            }
            const wordPtr: *u32 = @alignCast(@ptrCast(&self.mem[transaction.address]));
            const data: u32 = wordPtr.*;
            if ((transaction.bytes & 0b0001) != 0) {
                result.data |= (data & 0x000000FF);
            }
            if ((transaction.bytes & 0b0010) != 0) {
                result.data |= (data & 0x0000FF00);
            }
            if ((transaction.bytes & 0b0100) != 0) {
                result.data |= (data & 0x00FF0000);
            }
            if ((transaction.bytes & 0b1000) != 0) {
                result.data |= (data & 0xFF000000);
            }
            result.valid = true;
        }
    }

    return result;
}

pub fn loadRom(self: *Sram, rom_file: []const u8) !void {
    var file = try std.fs.cwd().openFile(rom_file, .{});
    defer file.close();

    const file_size = try file.getEndPos();

    std.debug.print("Load {} bytes as rom\r\n", .{file_size});
    _ = try file.readAll(@ptrCast(self.mem));
}

/// Load an ELF executable into SRAM, returning the entry point address.
pub fn loadElf(self: *Sram, rom_file: []const u8, base_addr: u32) !u32 {
    var file = try std.fs.cwd().openFile(rom_file, .{});
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(buffer[0..]);

    var header = try std.elf.Header.read(&reader.interface);

    if (header.machine != .RISCV) return error.NotRiscV;
    if (header.type != .EXEC and header.type != .DYN) return error.NotExecutable;

    var phdr_iter = header.iterateProgramHeaders(&reader);
    while (try phdr_iter.next()) |phdr| {
        if (phdr.p_type != std.elf.PT_LOAD) continue;
        if (phdr.p_memsz == 0 and phdr.p_filesz == 0) continue;

        if (phdr.p_vaddr < base_addr) {
            std.debug.print("Linker script has ELF segment in wrong location: 0x{x} should be >= 0x{x}\r\n", .{phdr.p_vaddr, base_addr});
            return error.SegmentBelowBase;
        }

        const mem_offset = phdr.p_vaddr - base_addr;
        if (mem_offset + phdr.p_memsz > self.mem.len) return error.SegmentOutOfBounds;

        try file.seekTo(phdr.p_offset);
        const dest = self.mem[mem_offset..][0..@intCast(phdr.p_filesz)];
        const bytes_read = try file.readAll(dest);
        if (bytes_read != phdr.p_filesz) return error.UnexpectedEof;

        if (phdr.p_memsz > phdr.p_filesz) {
            const bss_start = mem_offset + phdr.p_filesz;
            const bss_len = phdr.p_memsz - phdr.p_filesz;
            @memset(self.mem[bss_start..][0..@intCast(bss_len)], 0);
        }

        std.debug.print("Loaded ELF segment: vaddr=0x{x} filesz={} memsz={}\r\n", .{
            phdr.p_vaddr, phdr.p_filesz, phdr.p_memsz,
        });
    }

    return @intCast(header.entry);
}
