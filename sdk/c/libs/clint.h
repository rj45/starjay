/**
 * Copyright (c) 2026 Ryan "rj45" Sanche, MIT License
 *
 * CLINT Single Header Library.
 *
 * Do this:
 *     #define SDK_IMPL_CLINT
 * before you include this file in *one* C or C++ file to create the implementation.
 *
 * To implement all libs in this folder:
 *     #define SDK_IMPL_ALL
 */
#ifndef SDK_CLINT_H
#define SDK_CLINT_H

#include <stdint.h>

/** The speed that the system bus runs at (64 MHz). */
#define CLINT_BUS_CYCLES_PER_SECOND (64000000)

/** The number of bus cycles per VDP frame (at 60 Hz). */
#define CLINT_BUS_CYCLES_PER_FRAME (1440 * 741)

/** The number of system bus cycles per mtime increment. */
#define CLINT_MTIME_DIVISOR (512)

/** The number of mtime ticks per second. */
#define CLINT_TICKS_PER_SECOND (CLINT_BUS_CYCLES_PER_SECOND / CLINT_MTIME_DIVISOR)

/** The number of mtime ticks per VDP frame (at 60 Hz). */
#define CLINT_TICKS_PER_FRAME (CLINT_BUS_CYCLES_PER_FRAME / CLINT_MTIME_DIVISOR)

/** Boolean value for whether the CLINT interrupt is enabled or not. */
extern volatile uint32_t* clint_msip;

/** High word of CLINT mtime -- use clint_read_mtime() to safely read this. */
extern volatile uint32_t* clint_mtime_hi;

/** Low word of CLINT mtime -- use clint_read_mtime() to safely read this. */
extern volatile uint32_t* clint_mtime_lo;

/**
 * CLINT mtimecmp register. When mtime >= clint_mtimecmp and msip == 1, the interrupt
 * is triggered. It's expected that this will be updated with the next time the
 * interrupt should occur. To prevent further interrupts, set msip to 0.
 */
extern volatile uint64_t* clint_mtimecmp;

/**
 * Read the CLINT mtime register, ensuring rollover of the high word
 * is handled correctly.
 */
uint64_t clint_read_mtime();

#ifdef SDK_IMPL_ALL
#define SDK_IMPL_CLINT
#endif

#ifdef SDK_IMPL_CLINT
#define CLINT_BASE 0x11000000
#define CLINT_MISP_BASE (CLINT_BASE)
#define CLINT_MTIMECMP_BASE (CLINT_BASE+0x4000)
#define CLINT_MTIME_BASE (CLINT_BASE+0xBFF8)

volatile uint32_t* clint_msip = (uint32_t*)CLINT_MISP_BASE;
volatile uint32_t* clint_mtime_hi = (uint32_t*)(CLINT_MTIME_BASE + 4);
volatile uint32_t* clint_mtime_lo = (uint32_t*)CLINT_MTIME_BASE;
volatile uint64_t* clint_mtimecmp = (uint64_t*)CLINT_MTIMECMP_BASE;

uint64_t clint_read_mtime() {
    // Read the 64-bit mtime value atomically
    for (;;) {
        uint32_t hi1 = *clint_mtime_hi;
        uint32_t lo = *clint_mtime_lo;
        uint32_t hi2 = *clint_mtime_hi;
        if (hi1 == hi2) {
            return ((uint64_t)hi1) << 32 | ((uint64_t)lo);
        }
    }
}

#endif

#endif
