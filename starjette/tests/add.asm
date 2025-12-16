; Test add instruction
    ; Case 0: 10 add 20 -> 30
    push 10
    push 20
    add
    push 30
    xor
    failnez

    ; Case 1: 0 add 0 -> 0
    push 0
    push 0
    add
    push 0
    xor
    failnez

    ; Case 2: -10 add 5 -> -5
    push -10
    push 5
    add
    push -5
    xor
    failnez

    ; Case 3: 32767 add 1 -> -32768
    push 32767
    push 1
    add
    push -32768
    xor
    failnez

    ; Case 4: -1 add 1 -> 0
    push -1
    push 1
    add
    push 0
    xor
    failnez

    ; All passed
    push 1
    halt
