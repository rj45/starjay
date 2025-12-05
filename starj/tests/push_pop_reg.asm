; Test push and pop register operations

    ; Test push fp / pop fp
    push fp     ; save original fp
    push 0x1234
    pop fp      ; set fp to 0x1234
    push fp     ; read it back
    push 0x1234
    xor
    failnez
    pop fp      ; restore original fp

    ; Test push ra / pop ra
    push 0x5678
    pop ra
    push ra
    push 0x5678
    xor
    failnez

    ; Test push ar / pop ar
    push 0xABCD
    pop ar
    push ar
    push 0xABCD
    xor
    failnez

    ; Test push pc (should push current pc value)
    push pc
    drop        ; just verify it doesn't crash

    push 1
    halt

_fail:
    push 0
    halt
