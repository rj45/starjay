; Test srl instruction
    ; Case 0: 15 srl 1 -> 7
    push 15
    push 1
    srl
    push 7
    xor
    failnez

    ; Case 1: 65535 srl 4 -> 4095
    push 65535
    push 4
    srl
    push 4095
    xor
    failnez

    ; Case 2: 32768 srl 1 -> 16384
    push 32768
    push 1
    srl
    push 16384
    xor
    failnez

    ; Case 3: 4660 srl 0 -> 4660
    push 4660
    push 0
    srl
    push 4660
    xor
    failnez

    ; Case 4: 65535 srl 15 -> 1
    push 65535
    push 15
    srl
    push 1
    xor
    failnez

    ; Case 5: 4660 srl 16 -> 4660
    push 4660
    push 16
    srl
    push 4660
    xor
    failnez

    ; Case 6: 4660 srl 20 -> 291
    push 4660
    push 20
    srl
    push 291
    xor
    failnez

    ; All passed
    push 1
    halt
