; Test mul instruction
    ; Case 0: 10 mul 10 -> 100
    push 10
    push 10
    mul
    push 100
    sub
    bnez _fail

    ; Case 1: 1000 mul 1000 -> 16960
    push 1000
    push 1000
    mul
    push 16960
    sub
    bnez _fail

    ; Case 2: 0 mul 12345 -> 0
    push 0
    push 12345
    mul
    push 0
    sub
    bnez _fail

    ; Case 3: 1 mul 12345 -> 12345
    push 1
    push 12345
    mul
    push 12345
    sub
    bnez _fail

    ; Case 4: 256 mul 256 -> 0
    push 256
    push 256
    mul
    push 0
    sub
    bnez _fail

    ; Case 5: 2 mul 16384 -> 32768
    push 2
    push 16384
    mul
    push 32768
    sub
    bnez _fail

    ; Case 6: -1 mul 2 -> -2
    push -1
    push 2
    mul
    push -2
    sub
    bnez _fail

    ; Case 7: 256 mul 256 -> 0
    push 256
    push 256
    mul
    push 0
    sub
    bnez _fail

    ; All passed
    push 1
    syscall

_fail:
    push 0
    syscall
