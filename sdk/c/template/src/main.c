#define SDK_IMPL_ALL
#include "syscon.h"
#include "term.h"

void kmain(void) {
    term_puts("Hello World!\r\n");
    syscon_shutdown();
}
