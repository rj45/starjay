; Test ltu instruction
    ; Case 0: 10 ltu 20 -> 1
    push 10
    push 20
    ltu
    push 1
    sub
    bnez _fail

    ; Case 1: 20 ltu 10 -> 0
    push 20
    push 10
    ltu
    push 0
    sub
    bnez _fail

    ; Case 2: 10 ltu 10 -> 0
    push 10
    push 10
    ltu
    push 0
    sub
    bnez _fail

    ; Case 3: -1 ltu 10 -> 0
    push -1
    push 10
    ltu
    push 0
    sub
    bnez _fail

    ; Case 4: 0 ltu -1 -> 1
    push 0
    push -1
    ltu
    push 1
    sub
    bnez _fail

    ; All passed
    push 1
    syscall

_fail:
    push 0
    syscall
