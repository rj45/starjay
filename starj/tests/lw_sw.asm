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
    xor
    failnez

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
    xor
    failnez

    ; Test 3: Verify first location still has 0x1234
    push fp
    push -4
    add
    lw

    push 0x1234
    xor
    failnez

    ; === Deep Stack Preservation Test ===
    ; Verify sw correctly preserves stack_mem values when depth >= 5
    push 0x1111     ; will be stack_mem[0] (deepest)
    push 0x2222     ; will be stack_mem[1] - CRITICAL VALUE
    push 0x3333     ; will be stack_mem[2]
    push 0x4444     ; will be ROS
    push 0xABCD     ; NOS - value to store
    push fp
    push -8
    add             ; TOS - address (fp-8)

    ; depth=6: after all pushes and computing address
    sw              ; mem[fp-8] = 0xABCD

    ; After depth=4
    ; Expected: TOS=0x4444, NOS=0x3333, ROS=0x2222
    push 0x4444
    xor
    failnez

    push 0x3333
    xor
    failnez

    push 0x2222     ; CRITICAL check
    xor
    failnez

    push 0x1111
    xor
    failnez

    ; Verify the store actually worked
    push fp
    push -8
    add
    lw
    push 0xABCD
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
