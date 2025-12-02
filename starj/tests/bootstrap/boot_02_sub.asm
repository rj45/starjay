; Bootstrap test 02: Subtraction
; Validates: push imm, sub
; Emulator checks: TOS = 0 (10 - 10 = 0), depth = 1

#bank code
_start:
    push 10
    push 10
    sub
