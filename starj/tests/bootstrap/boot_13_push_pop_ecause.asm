; Bootstrap test 13: Push/Pop ecausenstructions
; Validates: push / pop ecause Uses ecauseo store a value and retrieve it
; Emulator checks: CPU halted with TOS = 3, depth = 1
#bank vector
_start:
    push 2
    pop ecause
    push 5
    push ecause
    add         ; should be 5 + 2 = 7
    xor 7       ; should be 7 ^ 7 = 0
    bnez end     ; Should NOT branch

    push 9
    pop ecause
    push 12
    push ecause
    xor         ; should be 12 - 9 = 5

end:
    halt
