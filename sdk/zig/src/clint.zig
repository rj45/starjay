const std = @import("std");

pub const clint = @This();

/// The number of bus clock cycles per second.
pub const BUS_CYCLES_PER_SECOND = 64_000_000;

/// The number of bus clock cycles in one VDP frame (at 60 Hz).
pub const BUS_CYCLES_PER_FRAME = 1440 * 741;

/// The number of bus clock cycles per tick of the CLINT `mtime`.
pub const MTIME_DIVISOR = 512;

/// The number of `mtime` ticks per second.
pub const TICKS_PER_SECOND = BUS_CYCLES_PER_SECOND / MTIME_DIVISOR;

/// The number of `mtime` ticks per frame.
pub const TICKS_PER_FRAME = BUS_CYCLES_PER_FRAME / MTIME_DIVISOR;

const CLINT_BASE: u32 = 0x1100_0000;

/// The `mtime` register's lower 32 bits. Use `mtime()` to read this safely.
pub const mtime_lo: * volatile u32 = @ptrFromInt(CLINT_BASE+0xBFF8);

/// The `mtime` register's high 32 bits. Use `mtime()` to read this safely.
pub const mtime_hi: * volatile u32 = @ptrFromInt(CLINT_BASE+0xBFFC);

/// The `mtimecmp` register. When `mtime >= clint_mtimecmp` and `msip == 1`,
/// the interrupt is triggered. It's expected that this will be updated with
/// the next time the interrupt should occur. To prevent further interrupts,
/// set `msip` to `0`.
pub const mtimecmp: * volatile u64 = @ptrFromInt(CLINT_BASE+0x4000);
pub const msip: *volatile u32 = @ptrFromInt(CLINT_BASE);

/// Atomically read the CLINT mtime register
pub fn mtime() u64 {
    // Read the 64-bit mtime value atomically
    while (true) {
        const hi1 = mtime_hi.*;
        const lo = mtime_lo.*;
        const hi2 = mtime_hi.*;
        if (hi1 == hi2) {
            return (@as(u64, hi1) << 32) | @as(u64, lo);
        }
    }
}
