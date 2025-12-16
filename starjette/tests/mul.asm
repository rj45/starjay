; Test mul instruction
    ; mul now produces two results: TOS=high word, NOS=low word
    ; Stack before: [nos, tos] (nos * tos)
    ; Stack after:  [low, high] (high=TOS, low=NOS, same depth)

    ; Test 1: Small multiplication (result fits in low word)
    ; 10 * 10 = 100, high=0, low=100
    push 10         ; nos
    push 10         ; tos
    mul
    ; Stack: [100, 0] (NOS=100, TOS=0)
    push 0          ; expected high
    xor
    failnez
    push 100        ; expected low
    xor
    failnez

    ; Test 2: Multiplication with overflow into high word
    ; 256 * 256 = 65536 = 0x10000, high=1, low=0
    push 256        ; nos
    push 256        ; tos
    mul
    ; Stack: [0, 1] (NOS=0, TOS=1)
    push 1          ; expected high
    xor
    failnez
    push 0          ; expected low
    xor
    failnez

    ; Test 3: Larger multiplication
    ; 1000 * 1000 = 1000000 = 0xF4240, high=0x0F, low=0x4240
    push 1000       ; nos
    push 1000       ; tos
    mul
    ; Stack: [0x4240, 0x0F]
    push 0x0F       ; expected high
    xor
    failnez
    push 0x4240     ; expected low
    xor
    failnez

    ; Test 4: Multiply by zero
    ; 12345 * 0 = 0, high=0, low=0
    push 12345      ; nos
    push 0          ; tos
    mul
    push 0          ; expected high
    xor
    failnez
    push 0          ; expected low
    xor
    failnez

    ; Test 5: Multiply by one
    ; 12345 * 1 = 12345, high=0, low=12345
    push 12345      ; nos
    push 1          ; tos
    mul
    push 0          ; expected high
    xor
    failnez
    push 12345      ; expected low
    xor
    failnez

    ; Test 6: Max values
    ; 0xFFFF * 0xFFFF = 0xFFFE0001, high=0xFFFE, low=0x0001
    push 0xFFFF     ; nos
    push 0xFFFF     ; tos
    mul
    push 0xFFFE     ; expected high
    xor
    failnez
    push 0x0001     ; expected low
    xor
    failnez

    ; Test 7: 0x8000 * 2 = 0x10000, high=1, low=0
    push 0x8000     ; nos (32768)
    push 2          ; tos
    mul
    push 1          ; expected high
    xor
    failnez
    push 0          ; expected low
    xor
    failnez

    ; Test 8: Asymmetric values
    ; 0x1234 * 0x0100 = 0x123400, high=0x12, low=0x3400
    push 0x1234     ; nos
    push 0x0100     ; tos
    mul
    push 0x12       ; expected high
    xor
    failnez
    push 0x3400     ; expected low
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
