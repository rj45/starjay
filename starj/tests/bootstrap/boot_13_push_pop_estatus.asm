; Bootstrap test 13: Push/Pop estatus instructions
; Validates: push / pop estatus
; Uses estatus to store a value and retrieve it
; Emulator checks: CPU halted with TOS = 3, depth = 1
#bank vector
_start:
    push 2
    pop estatus      ; Set FP = 5
    push 5
    push estatus     ; Push FP (5)
    add         ; should be 5 + 2 = 7
    xor 7       ; should be 7 ^ 7 = 0
    bnez end     ; Should NOT branch

    push 9
    pop estatus
    push 12
    push estatus    ; Push FP (9)
    xor         ; should be 12 - 9 = 5

end:
    halt
