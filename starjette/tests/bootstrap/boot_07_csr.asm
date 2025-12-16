; Bootstrap test 07: CSR access
; Validates: pushcsr
; Tests reading the status CSR
; Emulator checks: TOS = 1, depth = 1
; No halt mechanism - uses PC-at-zero detection

#bank vector
_start:
    push status   ; should be 1
    ; Final: TOS = 1, depth = 1
