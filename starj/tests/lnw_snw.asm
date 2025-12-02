; Test lnw and snw instructions
    ; lnw: push(mem[ar]); ar += 2 (for 16-bit)
    ; snw: mem[ar] = tos!; ar += 2 (for 16-bit)
    ; These use the ar register for sequential memory access

    ; First, store some values using snw
    ; Set ar to point to fp-8
    push fp
    push -8
    add
    pop ar          ; ar = fp - 8

    ; Store 4 words sequentially using snw
    push 0x1111
    snw             ; mem[fp-8] = 0x1111, ar = fp-6

    push 0x2222
    snw             ; mem[fp-6] = 0x2222, ar = fp-4

    push 0x3333
    snw             ; mem[fp-4] = 0x3333, ar = fp-2

    push 0x4444
    snw             ; mem[fp-2] = 0x4444, ar = fp

    ; Verify ar has been incremented correctly (should be fp now)
    push ar
    push fp
    sub
    bnez _fail

    ; Now read them back using lnw
    ; Reset ar to fp-8
    push fp
    push -8
    add
    pop ar

    ; Load 4 words sequentially using lnw
    lnw             ; push(mem[fp-8]) = 0x1111, ar = fp-6
    push 0x1111
    sub
    bnez _fail

    lnw             ; push(mem[fp-6]) = 0x2222, ar = fp-4
    push 0x2222
    sub
    bnez _fail

    lnw             ; push(mem[fp-4]) = 0x3333, ar = fp-2
    push 0x3333
    sub
    bnez _fail

    lnw             ; push(mem[fp-2]) = 0x4444, ar = fp
    push 0x4444
    sub
    bnez _fail

    ; Verify ar has been incremented correctly again
    push ar
    push fp
    sub
    bnez _fail

    ; Test with different values to ensure no aliasing
    push fp
    push -8
    add
    pop ar

    push 0xAAAA
    snw
    push 0xBBBB
    snw

    ; Reset and read back
    push fp
    push -8
    add
    pop ar

    lnw
    push 0xAAAA
    sub
    bnez _fail

    lnw
    push 0xBBBB
    sub
    bnez _fail

    push 1
    syscall

_fail:
    push 0
    syscall
