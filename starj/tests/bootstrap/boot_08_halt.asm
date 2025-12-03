; Bootstrap test 08: Halt mechanism
; Validates: halt bit in status register
; Sets halt bit directly via popcsr, no syscall/vectors needed
; Emulator checks: CPU halted with TOS = 1, depth = 1

#bank vector
_start:
    push 1        ; success code, stack: [1], depth = 1
    push status   ; read status register (expands to: push 0; pushcsr)
                  ; stack: [1, status_value], depth = 2
    or 0b100      ; set halt bit (bit 2), expands to: push 4; or
                  ; stack: [1, status_value | 4], depth = 2
    pop status    ; write status register (expands to: push 0; popcsr)
                  ; popcsr pops CSR number (0) and value, writes to status
                  ; stack: [1], depth = 1
    ; CPU should halt here due to halt bit being set
    ; Emulator verifies: TOS = 1, depth = 1
    push 99       ; Should NOT execute
