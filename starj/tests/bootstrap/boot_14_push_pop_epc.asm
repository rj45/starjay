; Bootstrap test 14: Push/Pop epc instructions
; Validates: push / pop epc
; Uses epc to store a value and retrieve it
; Emulator checks: CPU halted with TOS = 3, depth = 1
#bank vector
_start:
    push 2
    pop epc      ; Set FP = 5
    push 5
    push epc     ; Push FP (5)
    add         ; should be 5 + 2 = 7
    xor 7       ; should be 7 ^ 7 = 0
    bnez end     ; Should NOT branch

    push 9
    pop epc
    push 12
    push epc    ; Push FP (9)
    xor         ; should be 12 ^ 9 = 5

end:
    halt
