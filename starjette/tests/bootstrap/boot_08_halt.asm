; Bootstrap test 08: Halt mechanism
; Validates: halt bit in status register
; Sets halt bit directly via popcsr, no syscall/vectors needed
; Emulator checks: CPU halted with TOS = 1, depth = 1

#bank vector
_start:
    push 1        ; success code, stack: [1], depth = 1
    halt
