; Bootstrap test 15: Rets instructions
; Validates: rets
; Returns from kernel mode to user mode
; Emulator checks: CPU halted with TOS = 13, depth = 1, km = 0, fp = 20
#bank vector
_start:
    push 20
    pop afp

    push user_mode
    pop epc
    rets
    push 0 ; fail
    halt

user_mode:
    push 13
    halt
