; Bootstrap test 06: Branch if equal zero
; Validates: push imm, beqz
; Emulator checks: TOS = 99, depth = 1

#bank vector
_start:
    push 0
    beqz _good    ; Should branch (0 == 0)
    push 0        ; Should NOT execute
    beqz _end
_good:
    push 99       ; Should execute
_end:
