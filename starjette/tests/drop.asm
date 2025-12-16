; Test drop
    ; drop: tos! - pops and discards top of stack

    ; Test 1: Basic drop
    push 10
    push 20
    drop
    ; Stack should have 10
    push 10
    xor
    failnez

    ; Test 2: Multiple drops
    push 1
    push 2
    push 3
    push 4
    drop        ; remove 4
    push 3
    xor
    failnez
    drop        ; remove 2
    push 1
    xor
    failnez

    ; Test 3: Drop zero
    push 0xABCD
    push 0
    drop
    push 0xABCD
    xor
    failnez

    ; Test 4: Drop negative
    push 0x1234
    push -1
    drop
    push 0x1234
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
