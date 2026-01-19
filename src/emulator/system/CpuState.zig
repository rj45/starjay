const std = @import("std");

const RiscVState = @import("../riscv/root.zig").CpuState;
const StarJetteState = @import("../starjette/root.zig").CpuState;

pub const CpuState = union(enum) {
    riscv: *RiscVState,
    starjette: *StarJetteState,
};
