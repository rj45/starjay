; Bootstrap test 05: Bitwise OR
; Validates: push imm, or
; Emulator checks: TOS = 0xFF, depth = 1

#bank code
_start:
    push 0xF0
    push 0x0F
    or            ; 0xF0 | 0x0F = 0xFF
