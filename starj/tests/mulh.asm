; Test mulh instruction
    ; Case 0: 10 mulh 10 -> 0
    push 10
    push 10
    mulh
    push 0
    xor
    failnez

    ; Case 1: 256 mulh 256 -> 1
    push 256
    push 256
    mulh
    push 1
    xor
    failnez

    ; Case 2: 65535 mulh 2 -> 1
    push 65535
    push 2
    mulh
    push 1
    xor
    failnez

    ; Case 3: 65535 mulh 65535 -> 65534
    push 65535
    push 65535
    mulh
    push 65534
    xor
    failnez

    ; Case 4: 32768 mulh 2 -> 1
    push 32768
    push 2
    mulh
    push 1
    xor
    failnez

    ; All passed
    push 1
    halt
