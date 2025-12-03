; Bootstrap test 02: Subtraction
; Validates: push imm, sub
; Emulator checks: TOS = 0 (10 - 8 = 2), depth = 1

#bank vector
_start:
    push 10
    push 8
    sub
