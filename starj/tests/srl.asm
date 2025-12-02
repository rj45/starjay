; Test srl instruction
    ; Case 0: 15 srl 1 -> 7
    push 15
    push 1
    srl
    push 7
    sub
    bnez _fail

    ; Case 1: 65535 srl 4 -> 4095
    push 65535
    push 4
    srl
    push 4095
    sub
    bnez _fail

    ; Case 2: 32768 srl 1 -> 16384
    push 32768
    push 1
    srl
    push 16384
    sub
    bnez _fail

    ; Case 3: 4660 srl 0 -> 4660
    push 4660
    push 0
    srl
    push 4660
    sub
    bnez _fail

    ; Case 4: 65535 srl 15 -> 1
    push 65535
    push 15
    srl
    push 1
    sub
    bnez _fail

    ; Case 5: 4660 srl 16 -> 4660
    push 4660
    push 16
    srl
    push 4660
    sub
    bnez _fail

    ; All passed
    push 1
    syscall

_fail:
    push 0
    syscall
