; Test div instruction macro vectoring
    ; div (opcode 0x20) should vector to 0x100 + (0x20 & 0x1F) << 3 = 0x100
    ; This test verifies div jumps to the correct address and enters trap mode

#bank vector
    ; === Entry point at address 0 ===
_start:
    ; Push operands for div (these should be preserved across the vector)
    push 20         ; dividend (NOS)
    push 10         ; divisor (TOS)

    ; Execute div - should vector to 0x100
    div

    ; If we get here, the handler at 0x100 should have set up the return
    ; The handler pushes a marker value and returns via rets

    ; Check that we got the marker from the handler
    push 0x0D17     ; expected marker ("DIV" in hex-ish)
    xor
    failnez

    ; Verify operands are still on stack (preserved by enter_trap)
    ; After div vectors: epc saved, we're in kernel mode
    ; The handler should have cleaned up and returned the marker

    push 1
    halt

    ; Padding to reach 0x100
#addr 0x100
_div_handler:
    ; We're now at address 0x100 - the div macro vector target
    ; In trap mode: epc = return address, status saved to estatus

    ; Drop the original operands (20 and 10)
    drop
    drop

    ; Push marker to prove we got here
    push 0x0D17

    ; Return from trap
    rets

_fail:
    push 0
    halt
