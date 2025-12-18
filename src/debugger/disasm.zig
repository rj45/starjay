const std = @import("std");

pub const emulator = @import("../emulator/root.zig");

const SWord = emulator.SWord;
const Word = emulator.Word;
const Opcode = emulator.Opcode;
const CsrNum = emulator.CsrNum;

pub const Operand = union(enum) {
    none,
    csr: CsrNum,
    signed: SWord,
    unsigned: Word,
    address: Word,
};

pub const Instr = struct {
    address: usize,
    byte: u8,
    opcode: Opcode,
    operand: Operand,

    pub fn less(offset: usize, instr: Instr) bool {
        if (instr.address < offset) { return true; }
        return false;
    }
};

pub const Group = struct {
    address: usize,
    end_address: usize,
    opcode: Opcode,
    operand: Operand,

    pub fn less(offset: usize, grp: Group) bool {
        if (grp.address < offset) { return true; }
        return false;
    }
};

pub const Block = struct {
    address: usize,
    end_address: usize,
    label: ?[]const u8,

    pub fn less(offset: usize, blk: Block) bool {
        if (blk.address < offset) { return true; }
        return false;
    }
};

pub const AsmListing = struct {
    instructions: []Instr,
    groups: []Group,
    blocks: []Block,
    breakpoints: std.AutoHashMap(usize, bool),

    pub fn getBlockForAddress(self: *const AsmListing, address: usize) ?*const Block {
        const blocks = self.blocks;
        const pos = std.sort.partitionPoint(Block, blocks, address, Block.less);
        if (pos < blocks.len) {
            const blk = &blocks[pos];
            if (blk.address <= address and blk.end_address >= address) {
                return blk;
            }
        }
        return null;
    }
};

pub fn deinit(listing: *AsmListing, alloc: std.mem.Allocator) void {
    for (listing.blocks) |blk| {
        if (blk.label) |lbl| {
            alloc.free(lbl);
        }
    }
    listing.*.breakpoints.deinit();
    alloc.free(listing.*.blocks);
    alloc.free(listing.*.groups);
    alloc.free(listing.*.instructions);
    alloc.destroy(listing);
}

pub fn disassemble(memory: []Word, alloc: std.mem.Allocator) !*AsmListing {
    var arena_alloc = std.heap.ArenaAllocator.init(alloc);
    defer arena_alloc.deinit();

    var instrs = try std.ArrayList(Instr).initCapacity(alloc, 16);
    var groups = try std.ArrayList(Group).initCapacity(alloc, 16);
    var blocks = try std.ArrayList(Block).initCapacity(alloc, 4);

    const arena: std.mem.Allocator = arena_alloc.allocator();

    const progMem: []u8 = @ptrCast(memory);

    var rootsBuf = [_]usize{0} ** 128;
    var roots = std.ArrayList(usize).initBuffer(&rootsBuf);
    try roots.append(arena, 0x0000);

    root: while (roots.pop()) |addr| {
        var offset: usize = addr;
        var immediate: isize = 0;
        var immediateValid: bool = false;

        var prevImmediate: isize = 0;
        var prevImmediateValid: bool = false;

        std.log.debug("Root: {x}", .{addr});

        const blockPos = std.sort.partitionPoint(Block, blocks.items, offset, Block.less);

        if (blockPos < blocks.items.len) {
            if (blockPos > 0 and blocks.items[blockPos-1].address < offset and blocks.items[blockPos-1].end_address >= offset) {
                // split the block here
                try blocks.insert(alloc, blockPos, .{
                    .address = offset,
                    .end_address = blocks.items[blockPos-1].end_address,
                    .label = null,
                });
                blocks.items[blockPos-1].end_address = offset - 1;
                continue :root;
            }
            if (blocks.items[blockPos].address == offset) {
                continue :root; // already disassembled this block
            }
        }

        try blocks.insert(alloc, blockPos, .{
            .address = offset,
            .end_address = offset,
            .label = null,
        });
        var block = &blocks.items[blockPos];

        instr_loop: while (offset < progMem.len) {
            const instrByte = progMem[offset];
            const opcode: Opcode = Opcode.fromByte(instrByte);
            var operand: Operand = .none;
            var done = false;

            switch (opcode) {
                .push => {
                    if (immediateValid) {
                        // There was two consecutive immediates, save the previous one
                        prevImmediate = immediate;
                        prevImmediateValid = true;
                    } else {
                        prevImmediateValid = false;
                    }
                    immediate = @intCast(Opcode.pushImmediate(instrByte));
                    operand = .{.signed = @intCast(Opcode.pushImmediate(instrByte))};
                    immediateValid = true;
                },
                .shi => {
                    const moreBits: SWord = @intCast(Opcode.shiImmediate(instrByte));
                    operand = .{.unsigned = @intCast(Opcode.shiImmediate(instrByte))};
                    immediate = (immediate << 7) | (moreBits & 0x7f);
                    immediateValid = true;
                },
                .beqz, .bnez, .call => {
                    if (immediateValid) {
                        const targetOffset:usize = @intCast(immediate);
                        operand = .{.address = @truncate((offset + 1) +% targetOffset)};
                        try roots.insert(arena, 0, (offset + 1) +% targetOffset);
                    }
                    immediateValid = false;
                },
                .callp => {
                    if (immediateValid) {
                        const absoluteAddr:usize = @intCast(immediate);
                        operand = .{.address = @truncate(absoluteAddr)};
                        try roots.insert(arena, 0, absoluteAddr);
                    }
                    immediateValid = false;
                },
                .pop_pc => { // AKA ret
                    if (immediateValid) {
                        const absoluteAddr:usize = @intCast(immediate);
                        operand = .{.address = @truncate(absoluteAddr)};
                        try roots.insert(arena, 0, absoluteAddr);
                    }
                    done = true;
                },
                .jump => {
                    if (immediateValid) {
                        const targetOffset:usize = @bitCast(immediate);
                        operand = .{.address = @truncate((offset + 1) +% targetOffset)};
                        try roots.insert(arena, 0, (offset + 1) +% targetOffset);
                    }
                    done = true;
                },
                .pushcsr => {
                    operand = .{.csr = @enumFromInt(immediate)};
                    immediateValid = false;
                },
                .popcsr => {
                    const csr: CsrNum = @enumFromInt(immediate);
                    if (prevImmediateValid) {
                        // if popping a constant into evec or epc, assume this is a jump target
                        if (csr == .evec or csr == .epc) {
                            const targetAddr: usize = @bitCast(prevImmediate);
                            try roots.insert(arena, 0, targetAddr);

                            // TODO: somehow add the block address... with a second operand?
                        }
                    }

                    operand = .{.csr = csr};
                    immediateValid = false;
                },
                .halt => {
                    done = true;
                },
                else => {
                    immediateValid = false;
                }
            }

            const pos = std.sort.partitionPoint(Instr, instrs.items, offset, Instr.less);

            std.log.debug("Root: {x} Offset: {x} Opcode: {s} Pos: {any}", .{addr, offset, opcode.toMnemonic(), pos});

            if (pos < instrs.items.len and instrs.items[pos].address == offset) {
                block.end_address = offset-1;
                break :instr_loop; // already disassembled this instruction
            } else{
                try instrs.insert(alloc, pos, .{
                    .address = offset,
                    .byte = instrByte,
                    .opcode = opcode,
                    .operand = operand,
                });
            }

            if (done) {
                block.end_address = offset;
                break :instr_loop;
            }

            offset += 1;
        }
    }

    for (blocks.items, 0..) |*blk, index| {
        blk.*.label = try std.fmt.allocPrint(alloc, ".L{}", .{index});
    }

    const listing = try alloc.create(AsmListing);
    listing.* = AsmListing{
        .instructions = try instrs.toOwnedSlice(alloc),
        .groups = try groups.toOwnedSlice(alloc),
        .blocks = try blocks.toOwnedSlice(alloc),
        .breakpoints = std.AutoHashMap(usize, bool).init(alloc),
    };

    return listing;
}
