//! Adapted from https://github.com/ringtailsoftware/zig-minirv32/
//! Which was in turn adapted from https://github.com/cnlohr/mini-rv32ima
//! Original was licensed under MIT License, Copyright (c) 2022 CNLohr.


const std = @import("std");

const root = @import("root.zig");
const types = root.types;

pub const Word = types.Word;
pub const SWord = types.SWord;
pub const WORDBYTES = types.WORDBYTES;
pub const RAM_IMAGE_OFFSET = types.RAM_IMAGE_OFFSET;
pub const Regs = types.Regs;

pub const CpuState = @This();

reg: Regs = .{},
memory: []Word,
cycles: usize = 0,
halted: bool = false,
log_enabled: bool = true,

var console_scratch: [8192]u8 = undefined;
var console_fifo:std.Deque(u8) = std.Deque(u8).initBuffer(&console_scratch);

pub fn init(memory: []Word) CpuState {
    return .{
        .memory = memory,
    };
}

pub fn reset(self: *CpuState) void {
    self.reg = .{};
    self.reg = .{};
    for (self.stack) |*slot| {
        slot.* = 0;
    }
}

pub inline fn readByte(self: *const CpuState, addr: Word) u8 {
    const mem: []align(4) u8 = @ptrCast(self.memory);
    const phys = self.translateDataAddr(addr);
    if (phys / WORDBYTES < self.memory.len) {
        return mem[phys];
    }
    return 0;
}

pub inline fn readHalf(self: *const CpuState, addr: Word) Word {
    const mem: []align(4) u16 = @ptrCast(self.memory);
    const phys = self.translateDataAddr(addr);
    if (phys / WORDBYTES < self.memory.len) {
        return mem[phys/2];
    }
    return 0;
}

pub inline fn readWord(self: *const CpuState, addr: Word) Word {
    const phys = self.translateDataAddr(addr);
    if (phys / WORDBYTES < self.memory.len) {
        return self.memory[phys / WORDBYTES];
    }
    return 0;
}

pub inline fn writeByte(self: *CpuState, addr: Word, value: Word) void {
    const mem: []align(4) u8 = @ptrCast(self.memory);
    const phys = self.translateDataAddr(addr);
    if (phys / WORDBYTES < self.memory.len) {
        mem[phys] = @truncate(value);
    }
}

pub inline fn writeHalf(self: *CpuState, addr: Word, value: Word) void {
    const mem: []align(4) u16 = @ptrCast(self.memory);
    const phys = self.translateDataAddr(addr);
    if (phys / WORDBYTES < self.memory.len) {
        mem[phys / 2] = @truncate(value);
    }
}

pub inline fn writeWord(self: *CpuState, addr: Word, value: Word) void {
    const phys = self.translateDataAddr(addr);
    if (phys / WORDBYTES < self.memory.len) {
        self.memory[phys / WORDBYTES] = value;
    }
}

inline fn translateDataAddr(self: *const CpuState, vaddr: Word) usize {
    _ = self;
    return @intCast(vaddr);
}

pub fn loadRom(self: *CpuState, rom_file: []const u8) !void {
    var file = try std.fs.cwd().openFile(rom_file, .{});
    defer file.close();

    const file_size = try file.getEndPos();

    for (self.memory) |*word| {
        word.* = 0;
    }

    std.log.info("Load {} bytes as rom", .{file_size});
    _ = try file.readAll(@ptrCast(self.memory));
}

pub fn step(self: *CpuState, cycles: u64, fail_on_all_faults: bool) void {
    const ramSize = @as(Word, self.memory.len*4);

    const t:i64 = std.time.microTimestamp();
    self.reg.timerl = @as(Word, t & 0xFFFFFFFF);
    self.reg.timerh = @as(Word, t >> 32);

    // u8, u16 and u32  access
    var image1 = std.mem.bytesAsSlice(u8, @ptrCast(self.memory));
    var image2 = std.mem.bytesAsSlice(u16, image1);
    var image4 = std.mem.bytesAsSlice(Word, image1);

    // Handle Timer interrupt.
    if ((self.reg.timerh > self.reg.timermatchh or (self.reg.timerh == self.reg.timermatchh and self.reg.timerl > self.reg.timermatchl)) and (self.reg.timermatchh != 0 or self.reg.timermatchl != 0)) {
        self.reg.extraflags &= ~@as(Word, 4); // Clear WFI
        self.reg.mip |= 1 << 7; //MTIP of MIP // https://stackoverflow.com/a/61916199/2926815  Fire interrupt.
    } else {
        self.reg.mip &= ~(@as(Word, 1) << @as(Word, 7));
    }

    if (self.reg.extraflags & @as(Word, 4) != 0) {
        return 1;
    }

    var icount: usize = 0;
    while (icount < cycles) : (icount += 1) {
        var ir: Word = 0;
        var trap: Word = 0; // If positive, is a trap or interrupt.  If negative, is fatal error.
        var rval: Word = 0;

        // Increment both wall-clock and instruction count time.  (NOTE: Not strictly needed to run Linux)
        self.reg.cyclel +%= 1;
        if (self.reg.cyclel == 0) {
            self.reg.cycleh +%= 1;
        }

        var pc: Word = self.reg.pc;
        const ofs_pc = pc -% RAM_IMAGE_OFFSET;

        if (ofs_pc >= ramSize) {
            trap = 1 + 1; // Handle access violation on instruction read.
        } else if (ofs_pc & 3 != 0) {
            trap = 1 + 0; //Handle PC-misaligned access
        } else {
            ir = image4[ofs_pc / 4];
            var rdid = (ir >> 7) & 0x1f;

            switch (ir & 0x7f) {
                0b0110111 => rval = (ir & 0xfffff000), // LUI
                0b0010111 => rval = pc +% (ir & 0xfffff000), // AUIPC
                0b1101111 => { // JAL
                    var reladdy: SWord = @as(SWord, ((ir & 0x80000000) >> 11) | ((ir & 0x7fe00000) >> 20) | ((ir & 0x00100000) >> 9) | ((ir & 0x000ff000)));
                    if ((reladdy & 0x00100000) != 0) {
                        reladdy = @as(SWord, @as(Word, reladdy) | 0xffe00000); // Sign extension.
                    }
                    rval = pc + 4;
                    pc = pc +% @as(Word, reladdy - 4);
                },
                0b1100111 => { // JALR
                    const imm: Word = ir >> 20;
                    var imm_se: SWord = @as(SWord, imm);
                    if (imm & 0x800 != 0) {
                        imm_se = @as(SWord, imm | 0xfffff000);
                    }
                    rval = pc + 4;
                    const newpc: Word = ((self.reg.regs[(ir >> 15) & 0x1f] +% @as(Word, imm_se)) & ~@as(Word, 1)) - 4;
                    pc = newpc;
                },
                0b1100011 => { // Branch
                    var immm4: Word = ((ir & 0xf00) >> 7) | ((ir & 0x7e000000) >> 20) | ((ir & 0x80) << 4) | ((ir >> 31) << 12);
                    if (immm4 & 0x1000 != 0) immm4 |= 0xffffe000;
                    const rs1: SWord = @as(SWord, self.reg.regs[(ir >> 15) & 0x1f]);
                    const rs2: SWord = @as(SWord, self.reg.regs[(ir >> 20) & 0x1f]);
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
                            if (@as(Word, rs1) < @as(Word, rs2)) pc = immm4;
                        }, //BLTU
                        0b111 => {
                            if (@as(Word, rs1) >= @as(Word, rs2)) pc = immm4;
                        }, //BGEU
                        else => {
                            trap = (2 + 1);
                        },
                    }
                },
                0b0000011 => { // Load
                    const rs1: Word = self.reg.regs[(ir >> 15) & 0x1f];
                    const imm: Word = ir >> 20;
                    var imm_se: SWord = @as(SWord, imm);
                    if (imm & 0x800 != 0) {
                        imm_se = @as(SWord, imm | 0xfffff000);
                    }
                    var rsval: Word = @as(Word, @as(SWord, rs1) + imm_se);

                    rsval -%= RAM_IMAGE_OFFSET;

                    if (rsval >= ramSize - 3) {
                        rsval +%= RAM_IMAGE_OFFSET;

                        if (rsval >= 0x10000000 and rsval < 0x12000000) { // UART, CLNT
                            if (rsval == 0x1100bffc) { // https://chromitem-soc.readthedocs.io/en/latest/clint.html
                                rval = self.reg.timerh;
                            } else if (rsval == 0x1100bff8) {
                                rval = self.reg.timerl;
                            } else {
                                rval = handle_control_load(rsval);
                            }
                        } else {
                            trap = (5 + 1);
                            rval = rsval;
                        }
                    } else {

                        switch ((ir >> 12) & 0x7) {
                            //LB, LH, LW, LBU, LHU
                            0b000 => rval = @as(Word, @as(SWord, @as(i8, image1[rsval]))),
                            0b001 => rval = @as(Word, @as(SWord, @as(i16, image2[rsval / 2]))),
                            0b010 => rval = image4[rsval / 4],
                            0b100 => rval = image1[rsval],
                            0b101 => rval = image2[rsval / 2],
                            else => trap = (2 + 1),
                        }
                    }
                },
                0b0100011 => { // Store
                    const rs1: Word = self.reg.regs[(ir >> 15) & 0x1f];
                    const rs2: Word = self.reg.regs[(ir >> 20) & 0x1f];
                    var addy: Word = ((ir >> 7) & 0x1f) | ((ir & 0xfe000000) >> 20);

                    if (addy & 0x800 != 0) {
                        addy |= 0xfffff000;
                    }

                    addy +%= rs1 -% RAM_IMAGE_OFFSET;
                    rdid = 0;

                    if (addy >= ramSize - 3) {
                        addy +%= RAM_IMAGE_OFFSET;
                        if (addy >= 0x10000000 and addy < 0x12000000) {
                            // Should be stuff like SYSCON, 8250, CLNT
                            if (addy == 0x11004004) { //CLNT
                                self.reg.timermatchh = rs2;
                            } else if (addy == 0x11004000) { //CLNT
                                self.reg.timermatchl = rs2;
                            } else if (addy == 0x11100000) { //SYSCON (reboot, poweroff, etc.)
                                self.reg.pc = pc + 4;
                                return @as(SWord, rs2); // NOTE: PC will be PC of Syscon.
                            } else {
                                if (handle_control_store(addy, rs2) > 0) {
                                    return @as(SWord, rs2);
                                }
                            }
                        } else {
                            trap = (7 + 1); // Store access fault.
                            rval = addy;
                        }
                    } else {
                        switch ((ir >> 12) & 0x7) {
                            //SB, SH, SW
                            0b000 => image1[addy] = @as(u8, @truncate(rs2 & 0xFF)),
                            0b001 => image2[addy / 2] = @as(u16, @truncate(rs2)),
                            0b010 => image4[addy / 4] = rs2,
                            else => trap = (2 + 1),
                        }
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
                            0b001 => rval = @as(Word, (@as(i64, @as(SWord, rs1)) *% @as(i64, @as(SWord, rs2)) >> 32) & 0xFFFFFFFF), // MULH
                            0b010 => rval = @as(Word, ((@as(i64, @as(SWord, rs1)) *% @as(i64, rs2)) >> 32) & 0xFFFFFFFF), // MULHSU
                            0b011 => rval = @as(Word, (@as(u64, rs1) *% @as(u64, rs2)) >> 32), // MULHU
                            0b100 => { // DIV
                                if (rs2 == 0) {
                                    rval = @as(Word, @as(SWord, -1));
                                } else {
                                    rval = @as(Word, @divTrunc(@as(SWord, rs1), @as(SWord, rs2)));
                                }
                            },
                            0b101 => { // DIVU
                                if (rs2 == 0) {
                                    rval = 0xffffffff;
                                } else {
                                    rval = @divFloor(rs1, rs2);
                                }
                            },
                            0b110 => { // REM
                                if (rs2 == 0) {
                                    rval = rs1;
                                } else {
                                    rval = @as(Word, @mod(@as(SWord, rs1), @as(SWord, rs2)));
                                }
                            },
                            0b111 => { // REMU
                                if (rs2 == 0) {
                                    rval = rs1;
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
                                rval = @shlWithOverflow(rs1, @as(u5, @mod(rs2, 32)))[0];
                            },
                            0b010 => {
                                if (@as(SWord, rs1) < @as(SWord, rs2)) {
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
                                    rval = @as(Word, @as(SWord, rs1) >> @as(u5, @mod(rs2, 32)));
                                } else {
                                    rval = rs1 >> @as(u5, @mod(rs2, 32));
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
                            0xC00 => rval = self.reg.cyclel,
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
                    var rs1: Word = self.reg.regs[(ir >> 15) & 0x1f];
                    var rs2: Word = self.reg.regs[(ir >> 20) & 0x1f];
                    const irmid: Word = (ir >> 27) & 0x1f;

                    rs1 -= RAM_IMAGE_OFFSET;

                    // We don't implement load/store from UART or CLNT with RV32A here.
                    if (rs1 >= ramSize - 3) {
                        trap = (7 + 1); //Store/AMO access fault
                        rval = rs1 + RAM_IMAGE_OFFSET;
                    } else {
                        rval = image4[rs1 / 4];
                        // Referenced a little bit of https://github.com/franzflasch/riscv_em/blob/master/src/core/core.c
                        var dowrite: Word = 1;
                        switch (irmid) {
                            0b00010 => {
                                dowrite = 0;
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
                                if (!(@as(SWord, rs2) < @as(SWord, rval))) {
                                    rs2 = rval;
                                }
                            },
                            0b10100 => { // AMOMAX.W
                                if (!(@as(SWord, rs2) > @as(SWord, rval))) {
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
                                dowrite = 0; //Not supported.
                            },
                        }
                        if (dowrite != 0) {
                            image4[rs1 / 4] = rs2;
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

        if (trap > 0) {
            if (fail_on_all_faults) {
                //*printf( "FAULT\n" );*/
                return 3;
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

fn handle_control_load(addr: Word) Word {
    // Emulating a 8250 / 16550 UART
    if (addr == 0x10000005) {
        if (console_fifo.len > 0) {
            return 0x60 | 1; //intCastCompat(Word, console_fifo.count);
        } else {
            return 0x60;
        }
    } else if (addr == 0x10000000 and console_fifo.len > 0) {
        const c:u8 = console_fifo.popFront().?;
        return @as(Word, c);
    }
    return 0;
}

fn handle_control_store(addr: Word, val: Word) Word {
    if (addr == 0x10000000) { //UART 8250 / 16550 Data Buffer
        _ = val;
        // var buf: [1]u8 = .{@as(u8, val & 0xFF)};
        // term.write(&buf) catch return 0;    // FIXME handle error
    }
    return 0;
}

fn handle_exception(ir: Word, code: Word) Word {
    //std.log.info("PROCESSOR EXCEPTION ir:{x} code:{x}", .{ir, code});
    _ = ir;
    return code;
}
