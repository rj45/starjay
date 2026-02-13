/**
 * Copyright (c) 2026 Ryan "rj45" Sanche, MIT License
 *
 * SYSCON Single Header Library.
 *
 * Do this:
 *     #define SDK_IMPL_SYSCON
 * before you include this file in *one* C or C++ file to create the implementation.
 *
 * To implement all libs in this folder:
 *     #define SDK_IMPL_ALL
 */
#ifndef SDK_SYSCON_H
#define SDK_SYSCON_H

/** Shutdown the system. Does not return. */
void syscon_shutdown(void) __attribute__((noreturn));

#ifdef SDK_IMPL_ALL
#define SDK_IMPL_SYSCON
#endif

#ifdef SDK_IMPL_SYSCON

void syscon_shutdown(void) {
    volatile unsigned int* reg = (volatile unsigned int*)0x11100000;
    *reg = 0xffff;
    while (1) {}
}

#endif

#endif
