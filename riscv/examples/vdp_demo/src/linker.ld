OUTPUT_ARCH("riscv")

/* Use _start as our entry point to our program */
ENTRY(_start)

MEMORY
{
  ram (rwxa): ORIGIN = 0x80000000, LENGTH = 64M
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
  .text : ALIGN(4K) {
    *(.text.init);
    *(.text);
  } >ram :ram_fakerom

  .rodata : ALIGN(4K) {
    PROVIDE( _global_pointer = . );
    *(.rodata);
  } >ram :ram_fakerom

  .data : ALIGN(4K) {
    *(.data);
  } >ram :ram_init

  .bss : ALIGN(4K) {
    *(.bss);
  } >ram :ram

  /DISCARD/ :
  {
    *(.riscv.attributes)
  }

  PROVIDE( _bss_start = ADDR(.bss) );
  PROVIDE( _bss_end = ADDR(.bss) + SIZEOF(.bss) );

  PROVIDE( _stack_start = _bss_end );
  /* Stack size of 4kB */
  PROVIDE( _stack_end = _stack_start + 0x4000 );
  PROVIDE( _heap_start = _stack_end );
  PROVIDE( _PHYSTOP = ORIGIN(ram) + LENGTH(ram) );
}
