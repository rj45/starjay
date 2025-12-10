; Test call/ret with deep stack preservation
    ; Mimics a corruption pattern where a value pushed before
    ; a call gets corrupted by operations inside the function

    push 0xDEAD     ; sentinel that should survive the call

    call _work_func

    drop            ; drop return value

    push 0xDEAD     ; verify sentinel survived
    xor
    failnez

    push 1
    halt

_work_func:
    ; Do operations that exercise deep stack
    push 0x1111
    push 0x2222
    push 0x3333
    push 0x4444
    push 1          ; condition for bnez (non-zero)

    ; depth is now 6 relative to entry (sentinel + these 6 pushes)
    bnez _wskip
    push 0xBAD
_wskip:

    ; Clean up
    drop
    drop
    drop
    drop

    push 42         ; return value
    ret ra
