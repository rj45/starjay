const std = @import("std");

pub const WORDSIZE: comptime_int = 32;
pub const WORDBYTES: comptime_int = WORDSIZE / 8;
pub const WORDMASK: comptime_int = (1 << WORDSIZE) - 1;
pub const SHIFTMASK: comptime_int = 0x1f;

pub const RAM_IMAGE_OFFSET: u32 = 0x8000_0000;

pub const Word = u32;
pub const SWord = i32;

pub const Regs = struct {
    regs: [32]Word = [_]Word{0} ** 32,
    pc: u32 = 0,
    mstatus: u32 = 0,
    cyclel: u32 = 0,
    cycleh: u32 = 0,
    timerl: u32 = 0,
    timerh: u32 = 0,
    timermatchl: u32 = 0,
    timermatchh: u32 = 0,
    mscratch: u32 = 0,
    mtvec: u32 = 0,
    mie: u32 = 0,
    mip: u32 = 0,
    mepc: u32 = 0,
    mtval: u32 = 0,
    mcause: u32 = 0,
    // Note: only a few bits are used.  (Machine = 3, User = 0)
    // Bits 0..1 = privilege.
    // Bit 2 = WFI (Wait for interrupt)
    // Bit 3 = Load/Store has a reservation.
    extraflags: u32 = 0,

    pub fn init() Regs {
        return Regs{
            .regs = [_]Word{0} ** 32,
        };
    }

    fn dump(self: *Regs, image1: []align(4) u8 ) !void {
    	const pc = self.pc;
    	const pc_offset = pc - RAM_IMAGE_OFFSET;
    	var ir:u32 = 0;
        const ram_amt = image1.len;

        const image4 = std.mem.bytesAsSlice(u32, image1);
        const wr = std.io.getStdOut().writer();

        _ = try wr.print("PC: {x:0>8} ", .{pc});

    	if( pc_offset >= 0 and pc_offset < ram_amt - 3 ) {
                ir = image4[pc_offset / 4];
                _ = try wr.print("[0x{x:0>8}] ", .{ir});
    	} else {
    		_ = try wr.print("[xxxxxxxxxx] ", .{});
            }
    	const regs = self.regs;
    	_ = try wr.print("Z:{x:0>8} ra:{x:0>8} sp:{x:0>8} gp:{x:0>8} tp:{x:0>8} t0:{x:0>8} t1:{x:0>8} t2:{x:0>8} s0:{x:0>8} s1:{x:0>8} a0:{x:0>8} a1:{x:0>8} a2:{x:0>8} a3:{x:0>8} a4:{x:0>8} a5:{x:0>8} ", .{
    		regs[0], regs[1], regs[2], regs[3], regs[4], regs[5], regs[6], regs[7],
    		regs[8], regs[9], regs[10], regs[11], regs[12], regs[13], regs[14], regs[15] });

    	_ = try wr.print("a6:{x:0>8} a7:{x:0>8} s2:{x:0>8} s3:{x:0>8} s4:{x:0>8} s5:{x:0>8} s6:{x:0>8} s7:{x:0>8} s8:{x:0>8} s9:{x:0>8} s10:{x:0>8} s11:{x:0>8} t3:{x:0>8} t4:{x:0>8} t5:{x:0>8} t6:{x:0>8}\n", .{
    		regs[16], regs[17], regs[18], regs[19], regs[20], regs[21], regs[22], regs[23],
    		regs[24], regs[25], regs[26], regs[27], regs[28], regs[29], regs[30], regs[31] });
    }
};
