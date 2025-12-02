pub const Word = u16;

pub const WORDSIZE: comptime_int = 16;
pub const WORDBYTES: comptime_int = WORDSIZE / 2;
pub const WORDMASK: Word = (1<<WORDSIZE) - 1;
