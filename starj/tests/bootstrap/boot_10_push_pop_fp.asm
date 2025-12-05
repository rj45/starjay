; Bootstrap test 10: Push/Pop fp instructions
; Validates: push / pop fp
; Uses fp to store a value and retrieve it
; Emulator checks: CPU halted with TOS = 3, depth = 1
#bank vector
_start:
    push 2
    pop fp      ; Set fp = 5
    push 5
    push fp     ; Push fp (5)
    add         ; should be 5 + 2 = 7
    xor 7       ; should be 7 ^ 7 = 0
    bnez end    ; Should NOT branch

    push 9
    pop fp
    push 12
    push fp     ; Push fp (9)
    xor         ; should be 12 ^ 9 = 3

end:
    halt
