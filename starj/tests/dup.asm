; Test dup
    ; dup: push(tos) - duplicates top of stack

    ; Test 1: Basic dup
    push 123
    dup
    ; Stack: 123, 123
    push 123
    sub
    bnez _fail
    ; Stack: 123
    push 123
    sub
    bnez _fail

    ; Test 2: Dup zero
    push 0
    dup
    push 0
    sub
    bnez _fail
    push 0
    sub
    bnez _fail

    ; Test 3: Dup negative
    push -1
    dup
    push -1
    sub
    bnez _fail
    push -1
    sub
    bnez _fail

    ; Test 4: Dup large value
    push 0x7FFF
    dup
    push 0x7FFF
    sub
    bnez _fail
    push 0x7FFF
    sub
    bnez _fail

    ; Test 5: Dup with existing stack values
    push 0xAAAA     ; will be ros after dup
    push 0xBBBB     ; will be nos after dup
    dup             ; -> 0xAAAA, 0xBBBB, 0xBBBB
    push 0xBBBB
    sub
    bnez _fail
    push 0xBBBB
    sub
    bnez _fail
    push 0xAAAA
    sub
    bnez _fail

    push 1
    syscall

_fail:
    push 0
    syscall
