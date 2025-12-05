; Test divu instruction
    ; Case 0: 20 divu 10 -> 2
    push 20
    push 10
    divu
    push 2
    xor
    failnez

    ; Case 1: 65535 divu 1 -> 65535
    push 65535
    push 1
    divu
    push 65535
    xor
    failnez

    ; Case 2: 10 divu 20 -> 0
    push 10
    push 20
    divu
    push 0
    xor
    failnez

    ; All passed
    push 1
    halt
