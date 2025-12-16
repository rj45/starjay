; Test llw and slw instructions
    ; These use fp-relative addressing

    ; Allocate some space by adjusting fp
    push fp         ; save original fp
    add fp, -8      ; allocate 8 bytes (4 words for 16-bit)

    ; Store to offset 0 from fp
    push 0x1111
    push 0
    slw

    ; Store to offset 2 from fp
    push 0x2222
    push 2
    slw

    ; Load from offset 0
    push 0
    llw
    push 0x1111
    xor
    failnez

    ; Load from offset 2
    push 2
    llw
    push 0x2222
    xor
    failnez

    ; Restore fp
    push 8
    add fp
    drop            ; drop saved fp (we restored manually)

    ; === Deep Stack Preservation Test ===
    ; Verify slw correctly preserves stack_mem values when depth >= 5
    push 0x1111     ; will be stack_mem[0] (deepest)
    push 0x2222     ; will be stack_mem[1] - CRITICAL VALUE
    push 0x3333     ; will be stack_mem[2]
    push 0x4444     ; will be ROS
    push 0xBEEF     ; NOS - value to store
    push -10        ; TOS - offset for slw (relative to fp)

    ; depth=6
    slw             ; mem[fp-10] = 0xBEEF, dec2

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
    push -10
    llw
    push 0xBEEF
    xor
    failnez
    ; All passed
    push 1
    halt
