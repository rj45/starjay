/**
 * Copyright (c) 2026 Ryan "rj45" Sanche, MIT License
 *
 * Terminal (UART) Single Header Library.
 *
 * To get printf, do this before including this header:
 *     #define SDK_TERM_PRINTF
 *
 * To reduce the amount of code generated when you don't need floats (trims ~15 KB off):
 *     #define STB_SPRINTF_NOFLOAT
 *
 * Do this:
 *     #define SDK_IMPL_TERM
 * before you include this file in *one* C or C++ file to create the implementation.
 *
 * To implement all libs in this folder:
 *     #define SDK_IMPL_ALL
 */
#ifndef SDK_TERM_H
#define SDK_TERM_H

#include <stdint.h>
#include <stddef.h>

#ifdef SDK_IMPL_ALL
#define SDK_IMPL_TERM
#endif

#ifdef SDK_TERM_PRINTF

/* This is extremely important, as this processor doesn't support unaligned word access. */
#define STB_SPRINTF_NOUNALIGNED

#ifdef SDK_IMPL_TERM
#define STB_SPRINTF_IMPLEMENTATION
#endif

#include "stb_sprintf.h"

void printf(const char *format, ...) STBSP__ATTRIBUTE_FORMAT(1,2);
#endif

/**
 * Get a character from the UART.
 * Returns the character, or -1 if no character is available.
 */
int term_getch(void);

/** Write a single character to the UART. */
void term_putc(char c);

/** Write a buffer of len bytes to the UART. */
void term_write(const char* buf, size_t len);

/** Write a null-terminated string to the UART. */
void term_puts(const char* str);



#ifdef SDK_IMPL_TERM

static volatile uint8_t* term_data_reg = (volatile uint8_t*)0x10000000;
static volatile uint8_t* term_status_reg = (volatile uint8_t*)0x10000005;

int term_getch(void) {
    if (*term_status_reg & ~0x60) {
        return *term_data_reg;
    }
    return -1;
}

void term_putc(char c) {
    *term_data_reg = (uint8_t)c;
}

void term_write(const char* buf, size_t len) {
    for (size_t i = 0; i < len; i++) {
        *term_data_reg = (uint8_t)buf[i];
    }
}

void term_puts(const char* str) {
    while (*str) {
        *term_data_reg = (uint8_t)*str++;
    }
}

#ifdef SDK_TERM_PRINTF


void printf(const char *format, ...) STBSP__ATTRIBUTE_FORMAT(1,2) {
    char buffer[4096];
    int len;
    va_list args;
    va_start(args, format);
    len = stbsp_vsnprintf(buffer, 4096, format, args);
    va_end(args);

    term_write(buffer, len);
}
#endif

#endif

#endif
