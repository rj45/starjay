; Test lh and sh instructions
    ; For 16-bit machine, lh/sh behave same as lw/sw
    ;
    ; sh: mem:half[tos] = nos, pops both
    ; lh: push(sign_extend(mem:half[tos])), pops addr, pushes value

    ; Test 1: Store and load 0x5678
    push 0x5678
    push fp
    push -4
    add
    sh

    push fp
    push -4
    add
    lh

    push 0x5678
    xor
    failnez

    ; Test 2: Store and load negative value
    push -1234
    push fp
    push -4
    add
    sh

    push fp
    push -4
    add
    lh

    push -1234
    xor
    failnez

    ; === Deep Stack Preservation Test ===
    ; Verify sh correctly preserves stack_mem values when depth >= 5
    push 0x1111     ; will be stack_mem[0] (deepest)
    push 0x2222     ; will be stack_mem[1] - CRITICAL VALUE
    push 0x3333     ; will be stack_mem[2]
    push 0x4444     ; will be ROS
    push 0x5678     ; NOS - halfword value to store
    push fp
    push -6
    add             ; TOS - address (fp-6)

    ; depth=6
    sh              ; mem[fp-6] = 0x5678, dec2

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
    push -6
    add
    lh
    push 0x5678
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
