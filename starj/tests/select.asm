; Test select
    ; select: if tos != 0 then nos else ros
    ; Stack: [ros, nos, condition] -> [result]

    ; Case 1: True (tos = 1) -> select nos
    push 0xAAAA ; ros
    push 0xBBBB ; nos
    push 1      ; tos (true)
    select
    push 0xBBBB
    sub
    bnez _fail

    ; Case 2: False (tos = 0) -> select ros
    push 0xAAAA ; ros
    push 0xBBBB ; nos
    push 0      ; tos (false)
    select
    push 0xAAAA
    sub
    bnez _fail

    ; Case 3: True with negative condition (-1 is non-zero)
    push 0x1111 ; ros
    push 0x2222 ; nos
    push -1     ; tos (true, -1 != 0)
    select
    push 0x2222
    sub
    bnez _fail

    ; Case 4: True with large positive condition
    push 0x3333 ; ros
    push 0x4444 ; nos
    push 0x7FFF ; tos (true)
    select
    push 0x4444
    sub
    bnez _fail

    ; Case 5: Select between same values
    push 0x5555 ; ros
    push 0x5555 ; nos
    push 1      ; tos
    select
    push 0x5555
    sub
    bnez _fail

    ; Case 6: Select with zeros
    push 0      ; ros
    push 0      ; nos
    push 0      ; tos (false) -> ros
    select
    push 0
    sub
    bnez _fail

    push 1
    syscall

_fail:
    push 0
    syscall
