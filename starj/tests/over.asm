; Test over
    ; over: push(nos) - copies second item to top

    ; Test 1: Basic over
    push 10 ; nos
    push 20 ; tos
    over    ; -> 10, 20, 10

    push 10
    xor
    failnez

    push 20
    xor
    failnez

    push 10
    xor
    failnez

    ; Test 2: Over with different values
    push 0xAAAA
    push 0xBBBB
    over        ; -> 0xAAAA, 0xBBBB, 0xAAAA

    push 0xAAAA
    xor
    failnez

    push 0xBBBB
    xor
    failnez

    push 0xAAAA
    xor
    failnez

    ; Test 3: Over with zeros
    push 0
    push 0x1234
    over        ; -> 0, 0x1234, 0

    push 0
    xor
    failnez

    push 0x1234
    xor
    failnez

    push 0
    xor
    failnez

    ; Test 4: Over with same values
    push 42
    push 42
    over        ; -> 42, 42, 42

    push 42
    xor
    failnez

    push 42
    xor
    failnez

    push 42
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
