OUTPUT_ARCH("riscv")

/* Use _start as our entry point to our program */
ENTRY(_start)

MEMORY
{
  /* reserve some space for device table (4 kb is more than sufficient) */
  ram (rwxa): ORIGIN = 0x80000000, LENGTH = 64M - 4096
}

/* We are only loading from the file using PT_LOAD, we are not using dynamic linking */
PHDRS
{
  ram_fakerom PT_LOAD;
  ram_init PT_LOAD;
  ram PT_LOAD;
}

/* We are putting everything into RAM */
SECTIONS
{
  .text : {
    . = ALIGN(4);
    *(.text.init);
    *(.text);
    *(.text.start)
    *(.text)
    *(.text*)
    . = ALIGN(4);
  } >ram :ram_fakerom

  .rodata : {
    . = ALIGN(4);
    *(.rodata)
    *(.rodata*)
    *(.srodata)
    *(.srodata*)
    . = ALIGN(4);
  } >ram :ram_fakerom

  .data : {
    . = ALIGN(4);
    *(.data)
    *(.data*)
    *(.sdata)
    *(.sdata*)
    . = ALIGN(4);
  } >ram :ram_init

  .bss : {
    . = ALIGN(4);
    *(.bss)
    *(.bss*)
    *(.sbss)
    *(.sbss*)
    *(COMMON)
    . = ALIGN(4);
  } >ram :ram

  PROVIDE( _bss_start = ADDR(.bss) );
  PROVIDE( _bss_end = ADDR(.bss) + SIZEOF(.bss) );

  PROVIDE( _global_pointer = ADDR(.rodata) );

  PROVIDE( _stack_start = ORIGIN(ram) + LENGTH(ram) - 0x10000 );
  PROVIDE( _stack_end = ORIGIN(ram) + LENGTH(ram) );
  PROVIDE( _heap_start = _bss_end );
  PROVIDE( _PHYSTOP = ORIGIN(ram) + LENGTH(ram) );
}
