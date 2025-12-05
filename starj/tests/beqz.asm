; Test beqz instruction
    ; Tests: forward branch taken, forward branch not taken,
    ;        backward branch taken, backward branch not taken,
    ;        no branch shadow (instruction after branch not executed when taken)
    ;
    ; Strategy: Push sentinel values to detect branch shadows.
    ; If a shadow occurs, an extra value will be on the stack.

    ; Start with a known stack state
    push 0xAAAA     ; sentinel - should remain on stack

    ; Test 1: Forward branch taken (value == 0)
    push 0
    beqz _forward_taken
    push 0x1111     ; shadow marker - should NOT be pushed

_forward_taken:
    ; Test 2: Forward branch not taken (value != 0)
    push 1
    beqz _forward_not_taken_fail
    jump _test_backward
    push 0x2222     ; jump shadow marker - should NOT be pushed

_forward_not_taken_fail:
    push 0
    halt

_test_backward:
    jump _backward_setup
    push 0x3333     ; jump shadow marker - should NOT be pushed

_backward_target:
    jump _test_backward_not_taken
    push 0x4444     ; jump shadow marker - should NOT be pushed

_backward_setup:
    ; Test 3: Backward branch taken (value == 0)
    push 0
    beqz _backward_target
    push 0x5555     ; shadow marker - should NOT be pushed

_test_backward_not_taken:
    ; Test 4: Backward branch not taken (value != 0)
    push 1
    beqz _backward_not_taken_fail
    jump _check_stack
    push 0x6666     ; jump shadow marker - should NOT be pushed

_backward_not_taken_fail:
    push 0
    halt

_check_stack:
    ; Stack should only have our sentinel 0xAAAA
    ; If any shadow occurred, there will be extra values

    ; Check that top of stack is our sentinel
    push 0xAAAA
    xor
    failnez
    ; All passed
    push 1
    halt
