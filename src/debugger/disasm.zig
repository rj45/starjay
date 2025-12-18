const std = @import("std");

pub const emulator = @import("../emulator/root.zig");

const SWord = emulator.SWord;
const Word = emulator.Word;
const Opcode = emulator.Opcode;

pub const Asm = struct {
    address: usize,
    byte: u8,
    instr: Opcode,
    immediate: ?SWord,
    label: ?[]const u8,

    pub fn less(offset: usize, instr: Asm) bool {
        if (instr.address < offset) { return true; }
        return false;
    }
};

pub var disassembly: ?[]Asm = null;


pub fn disassemble(memory: []Word, allocator: std.mem.Allocator) !void {
    var arena_alloc = std.heap.ArenaAllocator.init(allocator);
    defer arena_alloc.deinit();

    if (disassembly) |old| {
        allocator.free(old);
    }

    var dis = try std.ArrayList(Asm).initCapacity(allocator, 16);

    const arena: std.mem.Allocator = arena_alloc.allocator();

    const progMem: []u8 = @ptrCast(memory);

    var rootsBuf = [_]usize{0} ** 128;
    var roots = std.ArrayList(usize).initBuffer(&rootsBuf);
    try roots.append(arena, 0x0000);

    while (roots.pop()) |addr| {
        var offset: usize = addr;
        var immediate: isize = 0;
        var immediateValid: bool = false;

        std.log.debug("Root: {x}", .{addr});

        root: while (offset < progMem.len) {
            const instrByte = progMem[offset];
            const opcode: Opcode = Opcode.fromByte(instrByte);

            const pos = std.sort.partitionPoint(Asm, dis.items, offset, Asm.less);

            std.log.debug("Root: {x} Offset: {x} Opcode: {s} Pos: {any}", .{addr, offset, opcode.toMnemonic(), pos});

            if (pos < dis.items.len and dis.items[pos].address == offset) {
                break :root; // already disassembled this instruction
            } else {
                try dis.insert(allocator, pos, Asm{
                    .address = offset,
                    .byte = instrByte,
                    .immediate = if (immediateValid) @intCast(immediate) else null,
                    .instr = opcode,
                    .label = null,
                });
            }

            switch (opcode) {
                .push => {
                    immediate = @intCast(Opcode.pushImmediate(instrByte));
                    immediateValid = true;
                },
                .shi => {
                    const moreBits: SWord = @intCast(Opcode.shiImmediate(instrByte));
                    immediate = (immediate << 7) | (moreBits & 0x7f);
                    immediateValid = true;
                },
                .beqz, .bnez, .call => {
                    if (immediateValid) {
                        const targetOffset:usize = @intCast(immediate);
                        try roots.insert(arena, 0, (offset + 1) +% targetOffset);
                    }
                    immediateValid = false;
                },
                .callp => {
                    if (immediateValid) {
                        const absoluteAddr:usize = @intCast(immediate);
                        try roots.insert(arena, 0, absoluteAddr);
                    }
                    immediateValid = false;
                },
                .pop_pc => { // AKA ret
                    if (immediateValid) {
                        const absoluteAddr:usize = @intCast(immediate);
                        try roots.insert(arena, 0, absoluteAddr);
                    }
                    break :root;
                },
                .jump => {
                    if (immediateValid) {
                        const targetOffset:usize = @bitCast(immediate);
                        try roots.insert(arena, 0, (offset + 1) +% targetOffset);
                    }
                    break :root;
                },
                .halt => {
                    break :root;
                },
                else => {
                    immediateValid = false;
                }
            }

            offset += 1;

        }
    }

    disassembly = try dis.toOwnedSlice(allocator);
}

pub fn deinit(allocator: std.mem.Allocator) void {
    if (disassembly) |old| {
        allocator.free(old);
        disassembly = null;
    }
}
