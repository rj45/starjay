.section .text.init

# https://github.com/cnlohr/mini-rv32ima/tree/master/baremetal
.align 4
.global _start
_start:
    # Don't do any address translation or protection
    csrw satp, zero

# https://www.sifive.com/blog/all-aboard-part-3-linker-relaxation-in-riscv-toolchain
.option push
.option norelax
    la   gp, _global_pointer
    la   sp, _stack_end
.option pop

  	addi sp,sp,-16
  	sw	 ra,12(sp)
  	jal	 ra, kmain

wait_for_interrupt:
    wfi
    j wait_for_interrupt
