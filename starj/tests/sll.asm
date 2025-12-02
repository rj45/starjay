; Test sll instruction
    ; Case 0: 1 sll 1 -> 2
    push 1
    push 1
    sll
    push 2
    sub
    bnez _fail

    ; Case 1: 1 sll 4 -> 16
    push 1
    push 4
    sll
    push 16
    sub
    bnez _fail

    ; Case 2: 1 sll 15 -> 32768
    push 1
    push 15
    sll
    push 32768
    sub
    bnez _fail

    ; Case 3: 65535 sll 1 -> 65534
    push 65535
    push 1
    sll
    push 65534
    sub
    bnez _fail

    ; Case 4: 4660 sll 0 -> 4660
    push 4660
    push 0
    sll
    push 4660
    sub
    bnez _fail

    ; All passed
    push 1
    syscall

_fail:
    push 0
    syscall
