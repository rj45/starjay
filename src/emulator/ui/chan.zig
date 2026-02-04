const std = @import("std");

const chan = @import("../../lib/chan.zig");

pub const Bus = @import("../device/Bus.zig");

pub const Channel = chan.Channel(Message);

pub const Message = union(enum) {
    cpu_halt: CpuHalt,
    cpu_frame: CpuFrame,
    vdp_frame: VdpFrame,
    audio_frame: AudioFrame,

    pub const CpuHalt = struct {
        error_level: u32,
    };

    pub const CpuFrame = struct {
        frame_number: u64,
        cycles: Bus.Cycle,
    };

    pub const VdpFrame = struct {
        frame_number: u64,
        index: u32,
    };

    pub const AudioFrame = struct {
        frame_number: u64,
        cycles: Bus.Cycle,
    };
};
