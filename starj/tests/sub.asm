; Test sub instruction
    ; Case 0: 20 sub 10 -> 10
    push 20
    push 10
    sub
    push 10
    sub
    bnez _fail

    ; Case 1: 10 sub 20 -> -10
    push 10
    push 20
    sub
    push -10
    sub
    bnez _fail

    ; Case 2: 0 sub 0 -> 0
    push 0
    push 0
    sub
    push 0
    sub
    bnez _fail

    ; Case 3: -5 sub -5 -> 0
    push -5
    push -5
    sub
    push 0
    sub
    bnez _fail

    ; Case 4: 0 sub 1 -> -1
    push 0
    push 1
    sub
    push -1
    sub
    bnez _fail

    ; All passed
    push 1
    syscall

_fail:
    push 0
    syscall
