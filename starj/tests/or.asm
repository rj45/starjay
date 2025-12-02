; Test or instruction
    ; Case 0: 12 or 10 -> 14
    push 12
    push 10
    or
    push 14
    sub
    bnez _fail

    ; Case 1: 0 or 0 -> 0
    push 0
    push 0
    or
    push 0
    sub
    bnez _fail

    ; Case 2: 0 or 1234 -> 1234
    push 0
    push 1234
    or
    push 1234
    sub
    bnez _fail

    ; Case 3: 21845 or 43690 -> 65535
    push 21845
    push 43690
    or
    push 65535
    sub
    bnez _fail

    ; Case 4: 65280 or 255 -> 65535
    push 65280
    push 255
    or
    push 65535
    sub
    bnez _fail

    ; Case 5: 4660 or 0 -> 4660
    push 4660
    push 0
    or
    push 4660
    sub
    bnez _fail

    ; Case 6: 32768 or 1 -> 32769
    push 32768
    push 1
    or
    push 32769
    sub
    bnez _fail

    ; All passed
    push 1
    syscall

_fail:
    push 0
    syscall
