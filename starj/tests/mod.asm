; Test mod instruction
    ; Case 0: 10 mod 3 -> 1
    push 10
    push 3
    mod
    push 1
    xor
    failnez

    ; Case 1: -10 mod 3 -> -1
    push -10
    push 3
    mod
    push -1
    xor
    failnez

    ; Case 2: 10 mod -3 -> 1
    push 10
    push -3
    mod
    push 1
    xor
    failnez

    ; Case 3: -10 mod -3 -> -1
    push -10
    push -3
    mod
    push -1
    xor
    failnez

    ; All passed
    push 1
    halt
