/**
 * Copyright (c) 2026 Ryan "rj45" Sanche, MIT License
 *
 * PSG (AY-3-8910) Single Header Library.
 *
 * Do this:
 *     #define SDK_IMPL_PSG
 * before you include this file in *one* C or C++ file to create the implementation.
 *
 * To implement all libs in this folder:
 *     #define SDK_IMPL_ALL
 */
#ifndef SDK_PSG_H
#define SDK_PSG_H

#include <stdint.h>

/* Chip frequency (Hz) -- Pentagon ZXSpectrum clone */
#define PSG_CHIP_FREQ 1750000

#define PSG_PSG1_BASE 0x13000000
#define PSG_PSG1_SIZE 0x00000010
#define PSG_PSG2_BASE (PSG_PSG1_BASE + PSG_PSG1_SIZE)
#define PSG_PSG2_SIZE PSG_PSG1_SIZE

#define PSG_CHIP_PSG1 0
#define PSG_CHIP_PSG2 1

typedef struct {
    uint8_t tone_a_disable  : 1;
    uint8_t tone_b_disable  : 1;
    uint8_t tone_c_disable  : 1;
    uint8_t noise_a_disable : 1;
    uint8_t noise_b_disable : 1;
    uint8_t noise_c_disable : 1;
    uint8_t _unused         : 2;
} psg_mixer_t;

typedef struct {
    uint8_t level           : 4;
    uint8_t envelope_enable : 1;
    uint8_t _unused         : 3;
} psg_volume_t;

typedef struct {
    uint16_t    tone_a;           /* 12-bit used */
    uint16_t    tone_b;           /* 12-bit used */
    uint16_t    tone_c;           /* 12-bit used */
    uint8_t     noise_period;     /* 5-bit used */
    psg_mixer_t mixer;
    psg_volume_t volume_a;
    psg_volume_t volume_b;
    psg_volume_t volume_c;
    uint16_t    envelope_period;
    uint8_t     envelope_shape;   /* 4-bit used */
} psg_regs_t;

typedef struct {
    psg_regs_t psg1;
    psg_regs_t psg2;
} psg_turbosound_regs_t;

/** Initialize PSG registers to defaults (all tones off, mixer all-disabled). */
void psg_regs_init(psg_regs_t* regs);

/** Write PSG registers to the hardware. chip: PSG_CHIP_PSG1 or PSG_CHIP_PSG2. */
void psg_regs_write(const psg_regs_t* regs, int chip);

/** Initialize TurboSound (dual PSG) registers to defaults. */
void psg_turbosound_init(psg_turbosound_regs_t* ts);

/** Write TurboSound registers to both PSG chips. */
void psg_turbosound_write(const psg_turbosound_regs_t* ts);

#ifdef SDK_IMPL_ALL
#define SDK_IMPL_PSG
#endif

#ifdef SDK_IMPL_PSG

static inline uint8_t psg_mixer_to_u8(psg_mixer_t m) {
    uint8_t v;
    __builtin_memcpy(&v, &m, 1);
    return v;
}

static inline uint8_t psg_volume_to_u8(psg_volume_t vol) {
    uint8_t v;
    __builtin_memcpy(&v, &vol, 1);
    return v;
}

void psg_regs_init(psg_regs_t* regs) {
    regs->tone_a = 0;
    regs->tone_b = 0;
    regs->tone_c = 0;
    regs->noise_period = 0;
    /* Default mixer: all channels disabled */
    psg_mixer_t mixer = {
        .tone_a_disable = 1, .tone_b_disable = 1, .tone_c_disable = 1,
        .noise_a_disable = 1, .noise_b_disable = 1, .noise_c_disable = 1,
        ._unused = 0,
    };
    regs->mixer = mixer;
    psg_volume_t vol_zero = { .level = 0, .envelope_enable = 0, ._unused = 0 };
    regs->volume_a = vol_zero;
    regs->volume_b = vol_zero;
    regs->volume_c = vol_zero;
    regs->envelope_period = 0;
    regs->envelope_shape = 0;
}

void psg_regs_write(const psg_regs_t* regs, int chip) {
    volatile uint32_t* base = (chip == PSG_CHIP_PSG2)
        ? (volatile uint32_t*)PSG_PSG2_BASE
        : (volatile uint32_t*)PSG_PSG1_BASE;

    /* word[0]: tone_a(12) | pad(4) | tone_b(12) | pad(4) */
    base[0] = ((uint32_t)(regs->tone_a & 0xFFF))
            | ((uint32_t)(regs->tone_b & 0xFFF) << 16);

    /* word[1]: tone_c(12) | pad(4) | noise_period(5) | pad(3) | mixer(8) */
    base[1] = ((uint32_t)(regs->tone_c & 0xFFF))
            | ((uint32_t)(regs->noise_period & 0x1F) << 16)
            | ((uint32_t)psg_mixer_to_u8(regs->mixer) << 24);

    /* word[2]: volume_a(8) | volume_b(8) | volume_c(8) | envelope_period_lo(8) */
    base[2] = ((uint32_t)psg_volume_to_u8(regs->volume_a))
            | ((uint32_t)psg_volume_to_u8(regs->volume_b) << 8)
            | ((uint32_t)psg_volume_to_u8(regs->volume_c) << 16)
            | (((uint32_t)regs->envelope_period & 0xFF) << 24);

    /* word[3]: envelope_period_hi(8) | envelope_shape(4) | pad(20) */
    base[3] = (((uint32_t)regs->envelope_period >> 8) & 0xFF)
            | ((uint32_t)(regs->envelope_shape & 0x0F) << 8);
}

void psg_turbosound_init(psg_turbosound_regs_t* ts) {
    psg_regs_init(&ts->psg1);
    psg_regs_init(&ts->psg2);
}

void psg_turbosound_write(const psg_turbosound_regs_t* ts) {
    psg_regs_write(&ts->psg1, PSG_CHIP_PSG1);
    psg_regs_write(&ts->psg2, PSG_CHIP_PSG2);
}

#endif

#endif
