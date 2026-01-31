const std = @import("std");

pub const TileLink = @This();

pub const DATA_WIDTH: comptime_int = 32;
pub const ADDR_WIDTH: comptime_int = 32;
pub const SIZE_WIDTH: comptime_int = 2;
pub const SRC_WIDTH:  comptime_int = 4;
pub const SINK_WIDTH: comptime_int = 4;

pub const Word = std.meta.Int(.unsigned, DATA_WIDTH);
pub const SWord = std.meta.Int(.signed, DATA_WIDTH);
pub const ByteMask = std.meta.Int(.unsigned, DATA_WIDTH / 8);
pub const Addr = std.meta.Int(.unsigned, ADDR_WIDTH);
pub const Size = std.meta.Int(.unsigned, SIZE_WIDTH);
pub const SrcId = std.meta.Int(.unsigned, SRC_WIDTH);
pub const SinkId = std.meta.Int(.unsigned, SINK_WIDTH);

pub const ACycle = std.meta.Int(.unsigned, 64 - (3+3+SIZE_WIDTH+SRC_WIDTH+(DATA_WIDTH / 8)));
pub const DCycle = u64;

pub const ChannelA = packed struct(u128) {
    cycle: ACycle,

    code: Opcode,
    param: Param,
    size: Size,
    source: SrcId,
    mask: ByteMask,

    address: Addr,
    data: Word,


    pub const Opcode = enum(u3) {
        PutFullData = 0,
        PutPartialData = 1,
        ArithmeticData = 2,
        LogicalData = 3,
        Get = 4,
        Intent = 5,
        AcquireBlock = 6,
        AcquirePerm = 7,
    };

    pub const Param = union(u3) {
        Arithmetic: ArithmeticDataParam,
        Logical: LogicalDataParam,
        Intent: IntentParam,
    };

    pub const ArithmeticDataParam = enum(u3) {
        Min = 0,
        Max = 1,
        MinU = 2,
        MaxU = 3,
        Add = 4,
    };

    pub const LogicalDataParam = enum(u3) {
        Xor = 0,
        Or = 1,
        And = 2,
        Swap = 3,
    };

    pub const IntentParam = enum(u3) {
        PrefetchRead = 0,
        PrefetchWrite = 1,
    };
};

pub const ChannelD = packed struct(u128) {
    cycle: DCycle,
    data: Word,

    code: Opcode,
    param: u2,
    size: Size,
    source: SrcId,
    sink: SinkId,
    denied: bool,

    _padding: u16,

    pub const Opcode = enum(u3) {
        AccessAck = 0,
        AccessAckData = 1,
        HintAck = 2,
        Grant = 4,
        GrantData = 5,
        ReleaseAck = 6,
    };
};
