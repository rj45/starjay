; Bootstrap test 04: Branch taken (value is non-zero)
; Validates: push imm, sub, bnez (taken path), jump (push_pcrel + add pc)
; Emulator checks: TOS = 99, depth = 1

#bank vector
_start:
    push 5        ; TOS = 5 (non-zero)
    bnez _good    ; Should branch
    push 0        ; Should NOT execute
    push 1
    bnez _end
_good:
    push 99       ; Should execute
_end:
