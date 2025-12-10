; Test select
    ; select: if tos != 0 then nos else ros
    ; Stack: [ros, nos, condition] -> [result]

    ; Case 1: True (tos = 1) -> select nos
    push 0xAAAA ; ros
    push 0xBBBB ; nos
    push 1      ; tos (true)
    select
    push 0xBBBB
    xor
    failnez

    ; Case 2: False (tos = 0) -> select ros
    push 0xAAAA ; ros
    push 0xBBBB ; nos
    push 0      ; tos (false)
    select
    push 0xAAAA
    xor
    failnez

    ; Case 3: True with negative condition (-1 is non-zero)
    push 0x1111 ; ros
    push 0x2222 ; nos
    push -1     ; tos (true, -1 != 0)
    select
    push 0x2222
    xor
    failnez

    ; Case 4: True with large positive condition
    push 0x3333 ; ros
    push 0x4444 ; nos
    push 0x7FFF ; tos (true)
    select
    push 0x4444
    xor
    failnez

    ; Case 5: Select between same values
    push 0x5555 ; ros
    push 0x5555 ; nos
    push 1      ; tos
    select
    push 0x5555
    xor
    failnez

    ; Case 6: Select with zeros
    push 0      ; ros
    push 0      ; nos
    push 0      ; tos (false) -> ros
    select
    push 0
    xor
    failnez

    ; === Deep Stack Preservation Test ===
    ; Verify select correctly preserves stack_mem values when depth >= 5
    push 0x1111     ; will be stack_mem[0] (deepest)
    push 0x2222     ; will be stack_mem[1] - CRITICAL VALUE
    push 0x3333     ; will be stack_mem[2]
    push 0xFFFF     ; ROS - false value for select
    push 0xEEEE     ; NOS - true value for select
    push 1          ; TOS - condition (true)

    ; depth=6
    select          ; result = 0xEEEE (true branch)

    ; After depth=4
    ; Expected: TOS=result(0xEEEE), NOS=0x3333, ROS=0x2222
    push 0xEEEE     ; verify result
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

    push 1
    halt

_fail:
    push 0
    halt
