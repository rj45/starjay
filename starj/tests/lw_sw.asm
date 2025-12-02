; Test lw and sw instructions
    ; Store a value and load it back
    ;
    ; sw: mem[tos] = nos, pops both
    ; lw: push(mem[tos]), pops addr, pushes value

    ; Test 1: Store and load 0x1234
    push 0x1234     ; value (will be nos)
    push fp
    push -4
    add             ; addr (will be tos)
    sw              ; mem[fp-4] = 0x1234

    ; Load it back
    push fp
    push -4
    add             ; addr
    lw              ; push(mem[fp-4])

    ; Check result
    push 0x1234
    sub
    bnez _fail

    ; Test 2: Store and load 0xABCD at different offset
    push 0xABCD
    push fp
    push -6
    add
    sw

    push fp
    push -6
    add
    lw

    push 0xABCD
    sub
    bnez _fail

    ; Test 3: Verify first location still has 0x1234
    push fp
    push -4
    add
    lw

    push 0x1234
    sub
    bnez _fail

    push 1
    syscall

_fail:
    push 0
    syscall
