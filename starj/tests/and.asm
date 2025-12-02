; Test and instruction
    ; Case 0: 12 and 10 -> 8
    push 12
    push 10
    and
    push 8
    sub
    bnez _fail

    ; Case 1: 0 and 65535 -> 0
    push 0
    push 65535
    and
    push 0
    sub
    bnez _fail

    ; Case 2: 65535 and 65535 -> -1
    push 65535
    push 65535
    and
    push -1
    sub
    bnez _fail

    ; Case 3: 65280 and 4080 -> 3840
    push 65280
    push 4080
    and
    push 3840
    sub
    bnez _fail

    ; Case 4: 21845 and 43690 -> 0
    push 21845
    push 43690
    and
    push 0
    sub
    bnez _fail

    ; Case 5: 4660 and 65535 -> 4660
    push 4660
    push 65535
    and
    push 4660
    sub
    bnez _fail

    ; Case 6: 32768 and 32768 -> 32768
    push 32768
    push 32768
    and
    push 32768
    sub
    bnez _fail

    ; All passed
    push 1
    syscall

_fail:
    push 0
    syscall
