; Bootstrap test 11: Push/Pop afp instructions
; Validates: push / pop afp
; Uses afp to store a value and retrieve it
; Emulator checks: CPU halted with TOS = 3, depth = 1
#bank vector
_start:
    push 2
    pop afp
    push 5
    push afp
    add         ; should be 5 + 2 = 7
    xor 7       ; should be 7 ^ 7 = 0
    bnez end     ; Should NOT branch

    push 9
    pop afp
    push 12
    push afp
    xor         ; should be 12 ^ 9 = 5

end:
    halt
