; Test drop
    ; drop: tos! - pops and discards top of stack

    ; Test 1: Basic drop
    push 10
    push 20
    drop
    ; Stack should have 10
    push 10
    sub
    bnez _fail

    ; Test 2: Multiple drops
    push 1
    push 2
    push 3
    drop        ; remove 3
    push 2
    sub
    bnez _fail
    drop        ; remove 2
    push 1
    sub
    bnez _fail

    ; Test 3: Drop zero
    push 0xABCD
    push 0
    drop
    push 0xABCD
    sub
    bnez _fail

    ; Test 4: Drop negative
    push 0x1234
    push -1
    drop
    push 0x1234
    sub
    bnez _fail

    push 1
    syscall

_fail:
    push 0
    syscall
