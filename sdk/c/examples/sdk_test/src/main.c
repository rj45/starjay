#include <stdint.h>
#include <stdbool.h>

// This will trigger the implementation C code to be put in this file
#define SDK_IMPL_ALL

// Ask for printf -- this will pull in quite a bit of code
#define SDK_TERM_PRINTF

// Reduce the amount of code pulled in for printf by roughly 15 KB
#define STB_SPRINTF_NOFLOAT

#include "clint.h"
#include "syscon.h"
#include "term.h"
#include "keyboard.h"
#include "psg.h"
#include "vdp.h"

void kmain(void) {
    /* Test clint: read mtime */
    volatile uint64_t t = clint_read_mtime();
    (void)t;

    /* Test term: write and read */
    term_puts("Hello World!\r\n");
    term_putc('!');
    term_putc('\r');
    term_putc('\n');
    int ch = term_getch();
    (void)ch;


    long long value = 412357816;

    printf("Testing printf of %lld works!\r\n", value);

    /* Test keyboard */
    volatile bool pressed = keyboard_is_pressed(KEY_A);
    (void)pressed;
    volatile bool rollover = keyboard_is_rollover_error();
    (void)rollover;
    volatile int ascii = keyboard_scancode_to_ascii(KEY_A, 0);
    (void)ascii;
    volatile bool printable = keyboard_scancode_is_printable(KEY_A, 0);
    (void)printable;

    /* Test PSG: init, set tone A, write */
    psg_regs_t psg;
    psg_regs_init(&psg);
    psg.tone_a = 252;
    psg.mixer.tone_a_disable = 0;
    psg.volume_a.level = 15;
    psg.envelope_shape = 0xf;
    psg_regs_write(&psg, PSG_CHIP_PSG1);

    psg_turbosound_regs_t ts;
    psg_turbosound_init(&ts);
    psg_turbosound_write(&ts);

    /* Test VDP: set palette, sprite, VRAM */
    vdp_palette[0] = 0xFF000000;
    vdp_sprite_table->sprite[0].sprite_y_height.screen_y.value = 100 << 4;
    vdp_sprite_table->sprite[0].sprite_x_width.screen_x.value = 50 << 4;
    vdp_vram[0] = 0xAA;
    vdp_vram_u16[0] = 0xBBCC;

    /* Test syscon: shutdown */
    syscon_shutdown();
    while (true) {}
}
