; Test sra instruction
    ; Case 0: 15 sra 1 -> 7
    push 15
    push 1
    sra
    push 7
    xor
    failnez

    ; Case 1: -4 sra 1 -> -2
    push -4
    push 1
    sra
    push -2
    xor
    failnez

    ; Case 2: -1 sra 4 -> -1
    push -1
    push 4
    sra
    push -1
    xor
    failnez

    ; Case 3: 16384 sra 1 -> 8192
    push 16384
    push 1
    sra
    push 8192
    xor
    failnez

    ; Case 4: -32768 sra 1 -> -16384
    push -32768
    push 1
    sra
    push -16384
    xor
    failnez

    ; Case 5: 100 sra 0 -> 100
    push 100
    push 0
    sra
    push 100
    xor
    failnez

    ; All passed
    push 1
    halt
