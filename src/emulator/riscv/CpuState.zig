//! Adapted from https://github.com/ringtailsoftware/zig-minirv32/
//! Which was in turn adapted from https://github.com/cnlohr/mini-rv32ima
//! Original was licensed under MIT License, Copyright (c) 2022 CNLohr.


const std = @import("std");

const root = @import("root.zig");

const Bus = @import("../device/Bus.zig");
const Clint = @import("../device/Clint.zig");

const types = root.types;

pub const Word = types.Word;
pub const SWord = types.SWord;
pub const WORDBYTES = types.WORDBYTES;
pub const Regs = types.Regs;

pub const CpuState = @This();

reg: Regs = .{},
bus: Bus,
cycles: usize = 0,
halted: bool = false,
log_enabled: bool = true,

var console_scratch: [8192]u8 = undefined;
var console_fifo:std.Deque(u8) = std.Deque(u8).initBuffer(&console_scratch);

pub fn init(bus: Bus) CpuState {
    return .{
        .bus = bus,
    };
}

pub fn reset(self: *CpuState) void {
    self.reg = .{};
}

inline fn translateDataAddr(self: *const CpuState, vaddr: Word) usize {
    _ = self;
    return @intCast(vaddr);
}

pub fn run(self: *CpuState, clint: *Clint, max_cycles: usize, fail_on_all_faults: bool) !Word {
    const start = try std.time.Instant.now();
    const initial_cycles = self.cycles;

    var num_cycles: usize = 0;
    var errval: Word = 0;
    while (num_cycles < max_cycles) : (num_cycles += 1000) {
        errval = self.runForCycles(clint, 1000, fail_on_all_faults);

        if (errval != 0 and errval != 1) {
            break;
        }
    }

    const cycles = self.cycles - initial_cycles;
    const elapsed = (try std.time.Instant.now()).since(start);
    const cycles_per_sec = if (elapsed > 0)
        @as(f64, @floatFromInt(cycles)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0)
    else
        0.0;
    std.debug.print("\n\nExecution completed in {d} cycles, elapsed time: {d} ms, {d:.2} cycles/sec\n", .{
        cycles,
        elapsed / 1_000_000,
        cycles_per_sec,
    });

    return errval;//self.reg.regs[10]; // a0
}

pub fn runForCycles(self: *CpuState, clint: *Clint, cycles: u64, fail_on_all_faults: bool) Word {
    // FIXME: This can be quite slow, as it can cause a syscall.
    const t:i64 = std.time.microTimestamp();
    const tu: u64 = @bitCast(t);

    clint.mtime = tu;


    // Handle Timer interrupt.
    if (clint.mtimecmp != 0 and clint.mtime >= clint.mtimecmp) {
        self.reg.extraflags &= ~@as(Word, 4); // Clear WFI
        self.reg.mip |= 1 << 7; //MTIP of MIP // https://stackoverflow.com/a/61916199/2926815  Fire interrupt.
    } else {
        self.reg.mip &= ~(@as(Word, 1) << @as(Word, 7));
    }

    if (self.reg.extraflags & @as(Word, 4) != 0) {
        // In WFI (Wait for interrupt) state.
        const wait_time = @min(
            10_000, // 10ms max
            if (clint.mtimecmp > clint.mtime)
                @as(u64, clint.mtimecmp - clint.mtime) / 1000
            else
                10_000
        );
        std.Thread.sleep(wait_time * 1000);
        return 1;
    }

    var icount: usize = 0;
    while (icount < cycles) : (icount += 1) {
        var ir: Word = 0;
        var trap: Word = 0; // If positive, is a trap or interrupt.  If negative, is fatal error.
        var rval: Word = 0;

        self.cycles += 1;

        var pc: Word = self.reg.pc;

        if (pc & 3 != 0) {
            std.debug.print("PC Misalignment fault: {x}\n", .{pc});
            trap = 1 + 0; //Handle PC-misaligned access
        } else {
            const fetch = self.bus.access(.{
                .cycle = @truncate(self.cycles),
                .address = pc,
                .bytes = 0b1111,
                .write = false,
            });
            self.cycles += fetch.duration-1; // minus 1 because we are presuming a pipelined fetch

            if (!fetch.valid) {
                std.debug.print("Instruction access fault: {x}\n", .{pc});
                trap = 1 + 1; // Instruction access fault.
                ir = 0x13; // NOP
            } else {
                ir = fetch.data;
            }

            var rdid = (ir >> 7) & 0x1f;

            switch (ir & 0x7f) {
                0b0110111 => rval = (ir & 0xfffff000), // LUI
                0b0010111 => rval = pc +% (ir & 0xfffff000), // AUIPC
                0b1101111 => { // JAL
                    const reladdy  = signExtend(((ir & 0x80000000) >> 11) | ((ir & 0x7fe00000) >> 20) | ((ir & 0x00100000) >> 9) | ((ir & 0x000ff000)), 21);
                    rval = pc + 4;
                    pc = pc +% @as(Word, reladdy - 4);
                },
                0b1100111 => { // JALR
                    const imm: Word = signExtend(ir >> 20, 12);
                    rval = pc + 4;
                    const newpc: Word = ((self.reg.regs[(ir >> 15) & 0x1f] +% imm) & ~@as(Word, 1)) - 4;
                    pc = newpc;
                },
                0b1100011 => { // Branch
                    var immm4: Word = signExtend(((ir & 0xf00) >> 7) | ((ir & 0x7e000000) >> 20) | ((ir & 0x80) << 4) | ((ir >> 31) << 12), 13);
                    const rs1u: Word = self.reg.regs[(ir >> 15) & 0x1f];
                    const rs1: SWord = @bitCast(rs1u);
                    const rs2u: Word = self.reg.regs[(ir >> 20) & 0x1f];
                    const rs2: SWord = @bitCast(rs2u);
                    immm4 = pc +% (immm4 -% 4);
                    rdid = 0;

                    switch ((ir >> 12) & 0x7) {
                        // BEQ, BNE, BLT, BGE, BLTU, BGEU
                        0b000 => {
                            if (rs1 == rs2) pc = immm4;
                        },
                        0b001 => {
                            if (rs1 != rs2) pc = immm4;
                        },
                        0b100 => {
                            if (rs1 < rs2) pc = immm4;
                        },
                        0b101 => {
                            if (rs1 >= rs2) pc = immm4;
                        }, //BGE
                        0b110 => {
                            if (rs1u < rs2u) pc = immm4;
                        }, //BLTU
                        0b111 => {
                            if (rs1u >= rs2u) pc = immm4;
                        }, //BGEU
                        else => {
                            trap = (2 + 1);
                        },
                    }
                },
                0b0000011 => { // Load
                    const rs1: Word = self.reg.regs[(ir >> 15) & 0x1f];
                    const imm: Word = signExtend(ir >> 20, 12);
                    const rsval: Word = rs1 +% imm;

                    var bytemask: u4 = 0;
                    switch ((ir >> 12) & 0x7) {
                        //LB, LH, LW, LBU, LHU
                        0b000, 0b100 => bytemask = 0b0001,
                        0b001, 0b101 => bytemask = 0b0011,
                        0b010 => bytemask = 0b1111,
                        else => trap = (2 + 1),
                    }

                    const result: Bus.Transaction = self.bus.access(.{
                        .cycle = @truncate(self.cycles),
                        .address = rsval,
                        .bytes = bytemask,
                        .write = false,
                    });

                    self.cycles += result.duration;

                    if (!result.valid) {
                        std.debug.print("Load access fault: pc: {x}, addy: {x}\n", .{self.reg.pc, rsval});
                        trap = (5 + 1); // Load access fault.
                        rval = rsval;
                    } else {
                        switch ((ir >> 12) & 0x7) {
                            //LB, LH, LW, LBU, LHU
                            0b000 => rval = signExtend(result.data, 8),
                            0b001 => rval = signExtend(result.data, 16),
                            0b010, 0b100, 0b101 => rval = result.data,
                            else => trap = (2 + 1),
                        }
                    }
                },
                0b0100011 => { // Store
                    const rs1: Word = self.reg.regs[(ir >> 15) & 0x1f];
                    const rs2: Word = self.reg.regs[(ir >> 20) & 0x1f];
                    const addy: Word = rs1 +% signExtend(((ir >> 7) & 0x1f) | ((ir & 0xfe000000) >> 20), 12);

                    rdid = 0;

                    if (addy == 0x11100000) { //SYSCON (reboot, poweroff, etc.)
                        self.reg.pc = pc + 4;
                        return rs2; // NOTE: PC will be PC of Syscon.
                    }

                    const bytemask: u4 = switch ((ir >> 12) & 0x7) {
                        //SB, SH, SW
                        0b000 => 0b0001,
                        0b001 => 0b0011,
                        0b010 => 0b1111,
                        else => brk: {
                            trap = (2 + 1);
                            break :brk 0;
                        },
                    };

                    const result = self.bus.access(.{
                        .cycle = @truncate(self.cycles),
                        .address = addy,
                        .bytes = bytemask,
                        .data = rs2,
                        .write = true,
                    });
                    self.cycles += result.duration;

                    if (!result.valid) {
                        std.debug.print("Store access fault: pc: {x}, addy: {x}\n", .{self.reg.pc, addy});
                        trap = (7 + 1); // Store access fault.
                        rval = addy;
                    }
                },
                0b0010011, 0b0110011 => { // Op-immediate, Op
                    var imm: Word = ir >> 20;
                    if (imm & 0x800 != 0) {
                        imm |= 0xfffff000;
                    }

                    const rs1: Word = self.reg.regs[(ir >> 15) & 0x1f];
                    const is_reg = (ir & 0b100000) != 0;
                    var rs2 = imm;
                    if (is_reg) {
                        rs2 = self.reg.regs[imm & 0x1f];
                    }

                    if (is_reg and (ir & 0x02000000 != 0)) {
                        switch ((ir >> 12) & 7) { //0x02000000 = RV32M
                            0b000 => rval = rs1 *% rs2, // MUL
                            0b001 => rval = @as(Word, @truncate(@as(u64, @bitCast((@as(i64, @as(SWord, @bitCast(rs1))) *% @as(i64, @as(SWord, @bitCast(rs2))) >> 32) & 0xFFFFFFFF)))), // MULH
                            0b010 => rval = @as(Word, @truncate(@as(u64, @bitCast(((@as(i64, @as(SWord, @bitCast(rs1))) *% @as(i64, rs2)) >> 32) & 0xFFFFFFFF)))), // MULHSU
                            0b011 => rval = @as(Word, @truncate((@as(u64, rs1) *% @as(u64, rs2)) >> 32)), // MULHU
                            0b100 => { // DIV
                                self.cycles += 31; // DIV takes longer
                                if (rs2 == 0) {
                                    rval = 0xffffffff; // FIXME: Is this right? Should it throw an exception?
                                } else {
                                    rval = @as(Word, @bitCast(@divTrunc(@as(SWord, @bitCast(rs1)), @as(SWord, @bitCast(rs2)))));
                                }
                            },
                            0b101 => { // DIVU
                                self.cycles += 31; // DIV takes longer
                                if (rs2 == 0) {
                                    rval = 0xffffffff; // FIXME: Is this right? Should it throw an exception?
                                } else {
                                    rval = @divFloor(rs1, rs2);
                                }
                            },
                            0b110 => { // REM
                                self.cycles += 31; // DIV takes longer
                                if (rs2 == 0) {
                                    rval = rs1; // FIXME: Is this right? Should it throw an exception?
                                } else {
                                    rval = @as(Word, @bitCast(@mod(@as(SWord, @bitCast(rs1)), @as(SWord, @bitCast(rs2)))));
                                }
                            },
                            0b111 => { // REMU
                                self.cycles += 31; // DIV takes longer
                                if (rs2 == 0) {
                                    rval = rs1; // FIXME: Is this right? Should it throw an exception?
                                } else {
                                    rval = @rem(rs1, rs2);
                                }
                            },
                            else => unreachable,
                        }
                    } else {
                        switch ((ir >> 12) & 7) { // These could be either op-immediate or op commands.  Be careful.
                            0b000 => {
                                if (is_reg and (ir & 0x40000000) != 0) {
                                    rval = rs1 -% rs2;
                                } else {
                                    rval = rs1 +% rs2;
                                }
                            },
                            0b001 => {
                                rval = @shlWithOverflow(rs1, @as(u5, @truncate(rs2 & 31)))[0];
                            },
                            0b010 => {
                                if (@as(SWord, @bitCast(rs1)) < @as(SWord, @bitCast(rs2))) {
                                    rval = 1;
                                } else {
                                    rval = 0;
                                }
                            },
                            0b011 => {
                                if (rs1 < rs2) {
                                    rval = 1;
                                } else {
                                    rval = 0;
                                }
                            },
                            0b100 => rval = rs1 ^ rs2,
                            0b101 => {
                                if (ir & 0x40000000 != 0) {
                                    rval = @as(Word, @bitCast(@as(SWord, @bitCast(rs1)) >> @as(u5, @truncate(rs2 & 31))));
                                } else {
                                    rval = rs1 >> @as(u5, @truncate(rs2 & 31));
                                }
                            },
                            0b110 => rval = rs1 | rs2,
                            0b111 => rval = rs1 & rs2,
                            else => unreachable,
                        }
                    }
                },
                0b0001111 => rdid = 0, // fencetype = (ir >> 12) & 0b111; We ignore fences in this impl.
                0b1110011 => { // Zifencei+Zicsr
                    const csrno: Word = ir >> 20;
                    const microop: Word = (ir >> 12) & 0b111;
                    if ((microop & 3) != 0) { // It's a Zicsr function.
                        const rs1imm: Word = (ir >> 15) & 0x1f;
                        const rs1 = self.reg.regs[rs1imm];
                        var writeval: Word = rs1;

                        // https://raw.githubusercontent.com/riscv/virtual-memory/main/specs/663-Svpbmt.pdf
                        // Generally, support for Zicsr
                        switch (csrno) {
                            0x340 => rval = self.reg.mscratch,
                            0x305 => rval = self.reg.mtvec,
                            0x304 => rval = self.reg.mie,
                            0xC00 => rval = @truncate(self.cycles & 0xffffffff),
                            0x344 => rval = self.reg.mip,
                            0x341 => rval = self.reg.mepc,
                            0x300 => rval = self.reg.mstatus, //mstatus
                            0x342 => rval = self.reg.mcause,
                            0x343 => rval = self.reg.mtval,
                            0xf11 => rval = 0xff0ff0ff, //mvendorid
                            0x301 => rval = 0x40401101, //misa (XLEN=32, IMA+X)
                            //0x3B0 => rval = 0, //pmpaddr0
                            //0x3a0 => rval = 0, //pmpcfg0
                            //0xf12 => rval = 0x00000000, //marchid
                            //0xf13 => rval = 0x00000000, //mimpid
                            //0xf14 => rval = 0x00000000, //mhartid
                            else => {}, //MINIRV32_OTHERCSR_READ( csrno, rval ),
                        }

                        switch (microop) {
                            0b001 => writeval = rs1, //CSRRW
                            0b010 => writeval = rval | rs1, //CSRRS
                            0b011 => writeval = rval & ~rs1, //CSRRC
                            0b101 => writeval = rs1imm, //CSRRWI
                            0b110 => writeval = rval | rs1imm, //CSRRSI
                            0b111 => writeval = rval & ~rs1imm, //CSRRCI
                            else => unreachable,
                        }

                        switch (csrno) {
                            0x340 => self.reg.mscratch = writeval,
                            0x305 => self.reg.mtvec = writeval,
                            0x304 => self.reg.mie = writeval,
                            0x344 => self.reg.mip = writeval,
                            0x341 => self.reg.mepc = writeval,
                            0x300 => self.reg.mstatus = writeval, //mstatus
                            0x342 => self.reg.mcause = writeval,
                            0x343 => self.reg.mtval = writeval,
                            //0x3a0 =>  ; //pmpcfg0
                            //0x3B0 =>  ; //pmpaddr0
                            //0xf11 =>  ; //mvendorid
                            //0xf12 =>  ; //marchid
                            //0xf13 =>  ; //mimpid
                            //0xf14 =>  ; //mhartid
                            //0x301 =>  ; //misa
                            else => {}, //MINIRV32_OTHERCSR_WRITE( csrno, writeval );
                        }
                    } else if (microop == 0b000) { // "SYSTEM"
                        rdid = 0;
                        if (csrno == 0x105) { //WFI (Wait for interrupts)
                            self.reg.mstatus |= 8; //Enable interrupts
                            self.reg.extraflags |= 4; //Infor environment we want to go to sleep.
                            self.reg.pc = pc + 4;
                            return 1;
                        } else if (((csrno & 0xff) == 0x02)) { // MRET
                            //https://raw.githubusercontent.com/riscv/virtual-memory/main/specs/663-Svpbmt.pdf
                            //Table 7.6. MRET then in mstatus/mstatush sets MPV=0, MPP=0, MIE=MPIE, and MPIE=1. La
                            // Should also update mstatus to reflect correct mode.
                            const startmstatus = self.reg.mstatus;
                            const startextraflags = self.reg.extraflags;
                            self.reg.mstatus = ((startmstatus & 0x80) >> 4) | ((startextraflags & 3) << 11) | 0x80;
                            self.reg.extraflags = (startextraflags & ~@as(Word, 3)) | ((startmstatus >> 11) & @as(Word, 3));
                            pc = self.reg.mepc - 4;
                        } else {
                            switch (csrno) {
                                0 => { // ECALL; 8 = "Environment call from U-mode"; 11 = "Environment call from M-mode"
                                    if (self.reg.extraflags & 3 != 0) {
                                        trap = (11 + 1);
                                    } else {
                                        trap = (8 + 1);
                                    }
                                },
                                1 => trap = (3 + 1), // EBREAK 3 = "Breakpoint"
                                else => trap = (2 + 1), // Illegal opcode.
                            }
                        }
                    } else {
                        trap = (2 + 1); // Note micrrop 0b100 == undefined.
                    }
                },
                0b0101111 => { // RV32A
                    const rs1: Word = self.reg.regs[(ir >> 15) & 0x1f];
                    var rs2: Word = self.reg.regs[(ir >> 20) & 0x1f];
                    const irmid: Word = (ir >> 27) & 0x1f;

                    const amoload = self.bus.access(.{
                        .cycle = @truncate(self.cycles),
                        .address = rs1,
                        .bytes = 0b1111,
                        .write = false,
                    });
                    self.cycles += amoload.duration-1; // minus 1 because we already incremented cycles

                    if (!amoload.valid) {
                        trap = (7 + 1); // Store/AMO access fault
                        rval = rs1;
                    }

                    rval = amoload.data;

                    // Referenced a little bit of https://github.com/franzflasch/riscv_em/blob/master/src/core/core.c
                    var dowrite: bool = true;
                    switch (irmid) {
                        0b00010 => {
                            dowrite = false;
                            self.reg.extraflags |= 8; //LR.W
                        },
                        0b00011 => {
                            if (!(self.reg.extraflags & 8 != 0)) { // SC.W (Lie and always say it's good)
                                rval = 1;
                            } else {
                                rval = 0;
                            }
                        },
                        0b00001 => {}, //AMOSWAP.W
                        0b00000 => rs2 +%= rval, //AMOADD.W
                        0b00100 => rs2 ^= rval, //AMOXOR.W
                        0b01100 => rs2 &= rval, //AMOAND.W
                        0b01000 => rs2 |= rval, //AMOOR.W
                        0b10000 => { // AMOMIN.W
                            if (!(@as(SWord, @bitCast(rs2)) < @as(SWord, @bitCast(rval)))) {
                                rs2 = rval;
                            }
                        },
                        0b10100 => { // AMOMAX.W
                            if (!(@as(SWord, @bitCast(rs2)) > @as(SWord, @bitCast(rval)))) {
                                rs2 = rval;
                            }
                        },
                        0b11000 => { // AMOMINU.W
                            if (!(rs2 < rval)) {
                                rs2 = rval;
                            }
                        },
                        0b11100 => { // AMOMAXU.W
                            if (!(rs2 > rval)) {
                                rs2 = rval;
                            }
                        },
                        else => {
                            trap = (2 + 1);
                            dowrite = false; //Not supported.
                        },
                    }
                    if (dowrite) {
                        const amostore = self.bus.access(.{
                            .cycle = @truncate(self.cycles),
                            .address = rs1,
                            .bytes = 0b1111,
                            .write = true,
                            .data = rs2,
                        });
                        self.cycles += amostore.duration-1; // minus 1 because we already incremented cycles

                        if (!amostore.valid) {
                            trap = (7 + 1); // Store/AMO access fault
                            rval = rs1;
                        }
                    }

                },
                else => trap = (2 + 1), // Fault: Invalid opcode.
            }

            if (trap == 0) {
                if (rdid != 0) {
                    self.reg.regs[rdid] = rval;
                } else if ((self.reg.mip & (1 << 7) != 0) and (self.reg.mie & (1 << 7) != 0) and (self.reg.mstatus & 0x8 != 0)) { // Write back register.
                    trap = 0x80000007; // Timer interrupt.
                }
            }
        }

        if (trap > 0 and trap < 0x80000000) {
            if (fail_on_all_faults) {
                //*printf( "FAULT\n" );*/
                std.debug.print("FAULT: {}\n", .{trap});
                return trap;
            } else {
                trap = handle_exception(ir, trap);
            }
        }

        // Handle traps and interrupts.
        if (trap != 0) {
            if (trap & 0x80000000 != 0) { // If prefixed with 1 in MSB, it's an interrupt, not a trap.
                self.reg.extraflags &= ~@as(Word, 8);
                self.reg.mcause = trap;
                self.reg.mtval = 0;
                pc += 4; // PC needs to point to where the PC will return to.
            } else {
                self.reg.mcause = trap - 1;
                if (trap > 5 and trap <= 8) {
                    self.reg.mtval = rval;
                } else {
                    self.reg.mtval = pc;
                }
            }
            self.reg.mepc = pc; //TRICKY: The kernel advances mepc automatically.
            //CSR( mstatus ) & 8 = MIE, & 0x80 = MPIE
            // On an interrupt, the system moves current MIE into MPIE
            self.reg.mstatus = (((self.reg.mstatus) & 0x08) << 4) | (((self.reg.extraflags) & 3) << 11);
            pc = ((self.reg.mtvec) -% 4);

            // XXX TODO: Do we actually want to check here? Is this correct?
            if (!(trap & 0x80000000 != 0)) {
                self.reg.extraflags |= 3;
            }
        }
        self.reg.pc = pc +% 4;
    }
    return 0;
}

fn handle_exception(ir: Word, code: Word) Word {
    //std.debug.print("PROCESSOR EXCEPTION ir:{x} code:{x}\n", .{ir, code});
    _ = ir;
    return code;
}

pub inline fn signExtend(val: Word, bits: comptime_int) Word {
    const mask: Word = 1 << (bits - 1);
    return ((val & ((1 << bits) - 1)) ^ mask) -% mask;
}
