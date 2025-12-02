; Test over
    ; over: push(nos) - copies second item to top

    ; Test 1: Basic over
    push 10 ; nos
    push 20 ; tos
    over    ; -> 10, 20, 10

    push 10
    sub
    bnez _fail

    push 20
    sub
    bnez _fail

    push 10
    sub
    bnez _fail

    ; Test 2: Over with different values
    push 0xAAAA
    push 0xBBBB
    over        ; -> 0xAAAA, 0xBBBB, 0xAAAA

    push 0xAAAA
    sub
    bnez _fail

    push 0xBBBB
    sub
    bnez _fail

    push 0xAAAA
    sub
    bnez _fail

    ; Test 3: Over with zeros
    push 0
    push 0x1234
    over        ; -> 0, 0x1234, 0

    push 0
    sub
    bnez _fail

    push 0x1234
    sub
    bnez _fail

    push 0
    sub
    bnez _fail

    ; Test 4: Over with same values
    push 42
    push 42
    over        ; -> 42, 42, 42

    push 42
    sub
    bnez _fail

    push 42
    sub
    bnez _fail

    push 42
    sub
    bnez _fail

    push 1
    syscall

_fail:
    push 0
    syscall
