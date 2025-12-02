; Test modu instruction
    ; Case 0: 10 modu 3 -> 1
    push 10
    push 3
    modu
    push 1
    sub
    bnez _fail

    ; Case 1: 20 modu 6 -> 2
    push 20
    push 6
    modu
    push 2
    sub
    bnez _fail

    ; Case 2: 100 modu 7 -> 2
    push 100
    push 7
    modu
    push 2
    sub
    bnez _fail

    ; Case 3: 65535 modu 256 -> 255
    push 65535
    push 256
    modu
    push 255
    sub
    bnez _fail

    ; Case 4: 1000 modu 1000 -> 0
    push 1000
    push 1000
    modu
    push 0
    sub
    bnez _fail

    ; Case 5: 5 modu 10 -> 5
    push 5
    push 10
    modu
    push 5
    sub
    bnez _fail

    ; Case 6: 0 modu 5 -> 0
    push 0
    push 5
    modu
    push 0
    sub
    bnez _fail

    ; All passed
    push 1
    syscall

_fail:
    push 0
    syscall
