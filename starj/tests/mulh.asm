; Test mulh instruction
    ; Case 0: 10 mulh 10 -> 0
    push 10
    push 10
    mulh
    push 0
    sub
    bnez _fail

    ; Case 1: 256 mulh 256 -> 1
    push 256
    push 256
    mulh
    push 1
    sub
    bnez _fail

    ; Case 2: 65535 mulh 2 -> 1
    push 65535
    push 2
    mulh
    push 1
    sub
    bnez _fail

    ; Case 3: 65535 mulh 65535 -> 65534
    push 65535
    push 65535
    mulh
    push 65534
    sub
    bnez _fail

    ; Case 4: 32768 mulh 2 -> 1
    push 32768
    push 2
    mulh
    push 1
    sub
    bnez _fail

    ; All passed
    push 1
    syscall

_fail:
    push 0
    syscall
