; Test bnez instruction
    ; Tests: forward branch taken, forward branch not taken,
    ;        backward branch taken, backward branch not taken,
    ;        no branch shadow (instruction after branch not executed when taken)
    ;
    ; Strategy: Push sentinel values to detect branch shadows.
    ; If a shadow occurs, an extra value will be on the stack.

    ; Start with a known stack state
    push 0xBBBB     ; sentinel - should remain on stack

    ; Test 1: Forward branch taken (value != 0)
    push 1
    bnez _forward_taken
    push 0x1111     ; shadow marker - should NOT be pushed

_forward_taken:
    ; Test 2: Forward branch not taken (value == 0)
    push 0
    bnez _forward_not_taken_fail
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
    ; Test 3: Backward branch taken (value != 0)
    push -1
    bnez _backward_target
    push 0x5555     ; shadow marker - should NOT be pushed

_test_backward_not_taken:
    ; Test 4: Backward branch not taken (value == 0)
    push 0
    bnez _backward_not_taken_fail
    jump _check_stack
    push 0x6666     ; jump shadow marker - should NOT be pushed

_backward_not_taken_fail:
    push 0
    halt

_check_stack:
    ; Stack should only have our sentinel 0xBBBB
    ; If any shadow occurred, there will be extra values

    ; Check that top of stack is our sentinel
    push 0xBBBB
    xor
    failnez

    ; === Deep Stack Preservation Test ===
    push 0x1111     ; will be stack_mem[0] (deepest)
    push 0x2222     ; will be stack_mem[1] - CRITICAL VALUE
    push 0x3333     ; will be stack_mem[2]
    push 0x4444     ; will be ROS
    push 0          ; NOS - condition (zero = branch NOT taken for bnez)

    bnez _deep_bnez_never    ; not taken since NOS=0

    ; After depth=4
    ; Expected: TOS=0x4444, NOS=0x3333, ROS=0x2222
    push 0x4444
    xor
    failnez

    push 0x3333
    xor
    failnez

    push 0x2222     ; CRITICAL check
    xor
    failnez

    push 0x1111
    xor
    failnez

    jump _deep_bnez_done

_deep_bnez_never:
    push 0
    halt

_deep_bnez_done:
    ; All passed
    push 1
    halt
