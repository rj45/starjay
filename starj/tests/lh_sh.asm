; Test lh and sh instructions
    ; For 16-bit machine, lh/sh behave same as lw/sw
    ;
    ; sh: mem:half[tos] = nos, pops both
    ; lh: push(sign_extend(mem:half[tos])), pops addr, pushes value

    ; Test 1: Store and load 0x5678
    push 0x5678
    push fp
    push -4
    add
    sh

    push fp
    push -4
    add
    lh

    push 0x5678
    xor
    failnez

    ; Test 2: Store and load negative value
    push -1234
    push fp
    push -4
    add
    sh

    push fp
    push -4
    add
    lh

    push -1234
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
