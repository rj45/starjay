; Bootstrap test 12: Push/Pop evec instructions
; Validates: push / pop evec
; Uses evec to store a value and retrieve it
; Emulator checks: CPU halted with TOS = 3, depth = 1
#bank vector
_start:
    push 2
    pop evec
    push 5
    push evec
    add         ; should be 5 + 2 = 7
    xor 7       ; should be 7 ^ 7 = 0
    bnez end     ; Should NOT branch

    push 9
    pop evec
    push 12
    push evec
    xor         ; should be 12 ^ 9 = 5

end:
    halt
