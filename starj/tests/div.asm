; Test div instruction
    ; Case 0: 20 div 10 -> 2
    push 20
    push 10
    div
    push 2
    sub
    bnez _fail

    ; Case 1: 20 div -10 -> -2
    push 20
    push -10
    div
    push -2
    sub
    bnez _fail

    ; Case 2: -20 div 10 -> -2
    push -20
    push 10
    div
    push -2
    sub
    bnez _fail

    ; Case 3: -20 div -10 -> 2
    push -20
    push -10
    div
    push 2
    sub
    bnez _fail

    ; All passed
    push 1
    syscall

_fail:
    push 0
    syscall
