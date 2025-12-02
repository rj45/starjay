; Test swap
    ; swap: tos, nos = nos, tos - exchanges top two items

    ; Test 1: Basic swap
    push 10
    push 20
    swap    ; -> 20, 10

    push 10
    sub
    bnez _fail

    push 20
    sub
    bnez _fail

    ; Test 2: Swap with different values
    push 0xAAAA
    push 0xBBBB
    swap        ; -> 0xBBBB, 0xAAAA

    push 0xAAAA
    sub
    bnez _fail

    push 0xBBBB
    sub
    bnez _fail

    ; Test 3: Double swap returns to original
    push 0x1111
    push 0x2222
    swap
    swap        ; back to original

    push 0x2222
    sub
    bnez _fail

    push 0x1111
    sub
    bnez _fail

    ; Test 4: Swap with zero
    push 0
    push 0x5678
    swap

    push 0
    sub
    bnez _fail

    push 0x5678
    sub
    bnez _fail

    ; Test 5: Swap same values (should still work)
    push 99
    push 99
    swap

    push 99
    sub
    bnez _fail

    push 99
    sub
    bnez _fail

    push 1
    syscall

_fail:
    push 0
    syscall
