; Test swap
    ; swap: tos, nos = nos, tos - exchanges top two items

    ; Test 1: Basic swap
    push 10
    push 20
    swap    ; -> 20, 10

    push 10
    xor
    failnez

    push 20
    xor
    failnez

    ; Test 2: Swap with different values
    push 0xAAAA
    push 0xBBBB
    swap        ; -> 0xBBBB, 0xAAAA

    push 0xAAAA
    xor
    failnez

    push 0xBBBB
    xor
    failnez

    ; Test 3: Double swap returns to original
    push 0x1111
    push 0x2222
    swap
    swap        ; back to original

    push 0x2222
    xor
    failnez

    push 0x1111
    xor
    failnez

    ; Test 4: Swap with zero
    push 0
    push 0x5678
    swap

    push 0
    xor
    failnez

    push 0x5678
    xor
    failnez

    ; Test 5: Swap same values (should still work)
    push 99
    push 99
    swap

    push 99
    xor
    failnez

    push 99
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
