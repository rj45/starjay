; Test mod instruction
    ; Case 0: 10 mod 3 -> 1
    push 10
    push 3
    mod
    push 1
    sub
    bnez _fail

    ; Case 1: -10 mod 3 -> -1
    push -10
    push 3
    mod
    push -1
    sub
    bnez _fail

    ; Case 2: 10 mod -3 -> 1
    push 10
    push -3
    mod
    push 1
    sub
    bnez _fail

    ; Case 3: -10 mod -3 -> -1
    push -10
    push -3
    mod
    push -1
    sub
    bnez _fail

    ; All passed
    push 1
    syscall

_fail:
    push 0
    syscall
