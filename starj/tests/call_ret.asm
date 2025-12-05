; Test call and ret instructions

    ; Simple call and return
    call _test_func
    ; If we get here, call/ret worked
    push 1
    halt

_test_func:
    ; ra should contain return address
    ; Just return
    push ra
    pop pc      ; ret = pop pc

_fail:
    push 0
    halt
