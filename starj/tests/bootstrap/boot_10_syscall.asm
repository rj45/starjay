; Bootstrap test 10: Full syscall/halt mechanism
; Validates: syscall instruction with ecause/evec exception mechanism
; This uses the full kernel (compiled with test_kernel.asm)
; syscall sets ecause=0x00 and jumps to evec (which points to _exception_handler)
; _exception_handler checks ecause, sees syscall, halts with TOS as exit code
; Emulator checks: CPU halted with TOS = 1, depth = 1

; NOTE: This test requires the kernel, unlike boot_00-08
    push 1        ; Success code
    syscall       ; Sets ecause=0x00, jumps to evec -> _exception_handler -> _halt
