; Bootstrap test 04: Branch taken (value is non-zero)
; Validates: push imm, sub, bnez (taken path), jump (push_pcrel + add pc)
; Emulator checks: TOS = 99, depth = 1

#bank code
_start:
    push 10
    push 5
    sub           ; TOS = 5 (non-zero)
    bnez _good    ; Should branch
    push 0        ; Should NOT execute
    jump _end
_good:
    push 99       ; Should execute
_end:
