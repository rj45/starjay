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
    ; All passed
    push 1
    halt
