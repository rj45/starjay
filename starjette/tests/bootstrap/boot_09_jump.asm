; Bootstrap test 09: Jump instruction
; Validates: jump
; Jumps around to verify correct PC-relative addressing
; Emulator checks: CPU halted with TOS = 1, depth = 1
#bank vector
_start:
    push 1
    jump forward
    push 2     ; Should NOT execute
backward:
    push 3
    jump end
    push 4     ; Should NOT execute
forward:
    push 5
    jump backward
    push 6     ; Should NOT execute
end:
    add        ; 5 + 3 = 8
    add        ; 8 + 1 = 9
    halt
