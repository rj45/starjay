; Bootstrap test 01: Push with shi (large immediate)
; Validates: push imm, shi
; Emulator checks: TOS = 0xABCD, depth = 1

#bank code
_start:
    push 0xABCD   ; Assembler generates: push + shi + shi
