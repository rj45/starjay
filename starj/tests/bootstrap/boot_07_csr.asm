; Bootstrap test 07: CSR access
; Validates: pushcsr, popcsr (via push/pop csr pseudo-ops)
; Tests reading the depth CSR to verify it matches actual stack depth
; Emulator checks: TOS = 1, depth = 2
; No halt mechanism - uses PC-at-zero detection

#bank vector
_start:
    push 10       ; stack: [10], depth = 1
    push depth    ; expands to: push 4; pushcsr
                  ; push 4:  stack: [10, 4], depth = 2
                  ; pushcsr: pops 4 (depth=1), reads depth CSR (1), pushes 1
                  ; stack: [10, 1], depth = 2
    ; Final: TOS = 1, depth = 2
    ; (depth was 1 when read because pushcsr pops before reading)
