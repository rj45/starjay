; Test clz instruction
    ; Case 0: clz 0 -> 16
    push 0
    clz
    push 16
    xor
    failnez

    ; Case 1: clz 1 -> 15
    push 1
    clz
    push 15
    xor
    failnez

    ; Case 2: clz 2 -> 14
    push 2
    clz
    push 14
    xor
    failnez

    ; Case 3: clz 4 -> 13
    push 4
    clz
    push 13
    xor
    failnez

    ; Case 4: clz 8 -> 12
    push 8
    clz
    push 12
    xor
    failnez

    ; Case 5: clz 16 -> 11
    push 16
    clz
    push 11
    xor
    failnez

    ; Case 6: clz 32 -> 10
    push 32
    clz
    push 10
    xor
    failnez

    ; Case 7: clz 64 -> 9
    push 64
    clz
    push 9
    xor
    failnez

    ; Case 8: clz 128 -> 8
    push 128
    clz
    push 8
    xor
    failnez

    ; Case 9: clz 256 -> 7
    push 256
    clz
    push 7
    xor
    failnez

    ; Case 10: clz 512 -> 6
    push 512
    clz
    push 6
    xor
    failnez

    ; Case 11: clz 1024 -> 5
    push 1024
    clz
    push 5
    xor
    failnez

    ; Case 12: clz 2048 -> 4
    push 2048
    clz
    push 4
    xor
    failnez

    ; Case 13: clz 4096 -> 3
    push 4096
    clz
    push 3
    xor
    failnez

    ; Case 14: clz 8192 -> 2
    push 8192
    clz
    push 2
    xor
    failnez

    ; Case 15: clz 16384 -> 1
    push 16384
    clz
    push 1
    xor
    failnez

    ; Case 16: clz 32768 -> 0
    push 32768
    clz
    push 0
    xor
    failnez

    ; Case 17: clz 65535 -> 0
    push 65535
    clz
    push 0
    xor
    failnez

    ; Case 18: clz 255 -> 8
    push 255
    clz
    push 8
    xor
    failnez

    ; Case 19: clz 65280 -> 0
    push 65280
    clz
    push 0
    xor
    failnez

    ; Case 20: clz 3840 -> 4
    push 3840
    clz
    push 4
    xor
    failnez

    ; Case 21: clz 240 -> 8
    push 240
    clz
    push 8
    xor
    failnez

    ; Case 22: clz 21845 -> 1
    push 21845
    clz
    push 1
    xor
    failnez

    ; Case 23: clz 43690 -> 0
    push 43690
    clz
    push 0
    xor
    failnez

    ; Case 24: clz 3 -> 14
    push 3
    clz
    push 14
    xor
    failnez

    ; Case 25: clz 32767 -> 1
    push 32767
    clz
    push 1
    xor
    failnez

    ; All passed
    push 1
    halt
