; Test xor instruction
    ; Case 0: 12 xor 10 -> 6
    push 12
    push 10
    xor
    push 6
    xor
    failnez

    ; Case 1: 12345 xor 12345 -> 0
    push 12345
    push 12345
    xor
    push 0
    xor
    failnez

    ; Case 2: 0 xor -1 -> -1
    push 0
    push -1
    xor
    push -1
    xor
    failnez

    ; Case 3: 65535 xor 65535 -> 0
    push 65535
    push 65535
    xor
    push 0
    xor
    failnez

    ; Case 4: 21845 xor 43690 -> 65535
    push 21845
    push 43690
    xor
    push 65535
    xor
    failnez

    ; Case 5: 65280 xor 255 -> 65535
    push 65280
    push 255
    xor
    push 65535
    xor
    failnez

    ; Case 6: 4660 xor 65535 -> 60875
    push 4660
    push 65535
    xor
    push 60875
    xor
    failnez

    ; All passed
    push 1
    halt
