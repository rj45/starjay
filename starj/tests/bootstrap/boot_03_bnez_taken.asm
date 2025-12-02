; Bootstrap test 03: Branch not taken (value is zero)
; Validates: push imm, sub, bnez (not taken path)
; Emulator checks: TOS = 99, depth = 1
; The branch should NOT be taken because sub result is 0

#bank code
_start:
    push 5
    push 5
    sub           ; TOS = 0
    bnez _bad     ; Should NOT branch
    push 99       ; Should execute
    jump _end
_bad:
    push 0        ; Should NOT execute
_end:
