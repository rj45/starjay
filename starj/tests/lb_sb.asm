; Test lb and sb instructions
    ; Store a byte and load it back
    ;
    ; sb: mem:byte[tos] = nos, pops both
    ; lb: push(sign_extend(mem:byte[tos])), pops addr, pushes value

    ; Test 1: Store and load 0x42 (positive byte)
    push 9          ; sentinel to check no corruption

    push 0x42       ; value (nos)
    push fp
    push -4
    add             ; addr (tos)
    sb

    push fp
    push -4
    add
    lb

    push 0x42
    xor
    failnez

    push 9          ; check sentinel intact
    xor
    failnez

    ; Test 2: Sign extension - 0xFF should load as -1
    push 0xFF
    push fp
    push -4
    add
    sb

    push fp
    push -4
    add
    lb

    push -1         ; 0xFF sign-extended = -1
    xor
    failnez

    ; Test 3: Sign extension boundary - 0x7F should stay positive (127)
    push 0x7F
    push fp
    push -4
    add
    sb

    push fp
    push -4
    add
    lb

    push 0x7F
    xor
    failnez

    ; Test 4: Sign extension boundary - 0x80 should become -128
    push 0x80
    push fp
    push -4
    add
    sb

    push fp
    push -4
    add
    lb

    push -128
    xor
    failnez

    ; === Deep Stack Preservation Test ===
    ; Verify sb correctly preserves stack_mem values when depth >= 5
    push 0x1111     ; will be stack_mem[0] (deepest)
    push 0x2222     ; will be stack_mem[1] - CRITICAL VALUE
    push 0x3333     ; will be stack_mem[2]
    push 0x4444     ; will be ROS
    push 0x55       ; NOS - byte value to store
    push fp
    push -5
    add             ; TOS - address (fp-5)

    ; depth=6
    sb              ; mem[fp-5] = 0x55, dec2

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

    ; Verify the store worked
    push fp
    push -5
    add
    lb
    push 0x55
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
