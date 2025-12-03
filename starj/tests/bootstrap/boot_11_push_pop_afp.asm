; Bootstrap test 10: Push/Pop afp instructions
; Validates: push / pop afp
; Uses afp to store a value and retrieve it
; Emulator checks: CPU halted with TOS = 3, depth = 1
#bank vector
_start:
    push 2
    pop afp      ; Set FP = 5
    push 5
    push afp     ; Push FP (5)
    sub          ; should be 5 - 2 = 3
    sub 3        ; should be 3 - 3 = 0
    bnez end     ; Should NOT branch

    push 9
    pop afp
    push 12
    push afp    ; Push FP (9)
    sub         ; should be 12 - 9 = 3

end:
    halt
