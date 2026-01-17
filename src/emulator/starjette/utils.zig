//! Utility functions shared between emulator implementations.

const types = @import("types.zig");
const Word = types.Word;
const SWord = types.SWord;

/// Sign-extend a 6-bit value to Word width.
pub inline fn signExtend6(val: u6) Word {
    const sval: i6 = @bitCast(val);
    const extended: SWord = sval;
    return @bitCast(extended);
}

/// Sign-extend an 8-bit value to Word width.
pub inline fn signExtend8(val: u8) Word {
    const sval: i8 = @bitCast(val);
    const extended: SWord = sval;
    return @bitCast(extended);
}

/// Sign-extend a 16-bit value to Word width.
pub inline fn signExtend16(val: u8) Word {
    const sval: i16 = @bitCast(val);
    const extended: SWord = sval;
    return @bitCast(extended);
}
