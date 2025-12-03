; Bootstrap test 03: Branch not taken (value is zero)
; Validates: push imm, sub, bnez (not taken path)
; Emulator checks: TOS = 99, depth = 1
; The branch should NOT be taken because sub result is 0

#bank vector
_start:
    push 0        ; TOS = 0
    bnez _bad     ; Should NOT branch
    push 99       ; Should execute
    push 1
    bnez _end
_bad:
    push 0        ; Should NOT execute
_end:
