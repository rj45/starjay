; Bootstrap test 00: Just push
; Validates: push imm
; Emulator checks: TOS = 7, depth = 1
; No halt mechanism - emulator detects end of code

#bank vector
_start:
    push 7
