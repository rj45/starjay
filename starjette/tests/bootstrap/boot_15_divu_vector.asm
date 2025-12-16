; Test divu instruction macro vectoring
    ; divu (opcode 0x21) should vector to 0x100 + (0x21 & 0x1F) << 3 = 0x108
    ; This test verifies divu jumps to the correct address and enters trap mode

#bank vector
    ; === Entry point at address 0 ===
_start:
    ; Push operands for divu (these should be preserved across the vector)
    push 100        ; dividend (NOS)
    push 25         ; divisor (TOS)

    ; Execute divu - should vector to 0x108
    divu

    ; If we get here, the handler at 0x108 should have set up the return
    ; The handler pushes a marker value and returns via rets

    ; Check that we got the marker from the handler
    push 0x0D10     ; expected marker ("DIVu" marker)
    xor
    failnez

    push 1
    halt

    ; Padding to reach 0x108
#addr 0x108
_divu_handler:
    ; We're now at address 0x108 - the divu macro vector target
    ; In trap mode: epc = return address, status saved to estatus

    ; Drop the original operands (100 and 25)
    drop
    drop

    ; Push marker to prove we got here
    push 0x0D10

    ; Return from trap
    rets

_fail:
    push 0
    halt
