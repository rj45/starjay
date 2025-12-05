; Test div instruction
    ; Case 0: 20 div 10 -> 2
    push 20
    push 10
    div
    push 2
    xor
    failnez

    ; Case 1: 20 div -10 -> -2
    push 20
    push -10
    div
    push -2
    xor
    failnez

    ; Case 2: -20 div 10 -> -2
    push -20
    push 10
    div
    push -2
    xor
    failnez

    ; Case 3: -20 div -10 -> 2
    push -20
    push -10
    div
    push 2
    xor
    failnez

    ; All passed
    push 1
    halt
