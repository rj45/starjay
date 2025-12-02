; Test callp instruction (call function pointer)

    push _test_func2
    callp
    ; If we get here, callp worked
    push 1
    syscall

_test_func2:
    push ra
    pop pc

_fail:
    push 0
    syscall
