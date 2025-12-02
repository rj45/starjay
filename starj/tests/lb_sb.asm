; Test lb and sb instructions
    ; Store a byte and load it back
    ;
    ; sb: mem:byte[tos] = nos, pops both
    ; lb: push(sign_extend(mem:byte[tos])), pops addr, pushes value

    ; Test 1: Store and load 0x42 (positive byte)
    push 0x42       ; value (nos)
    push fp
    push -4
    add             ; addr (tos)
    sb

    push fp
    push -4
    add
    lb

    push 0x42
    sub
    bnez _fail

    ; Test 2: Sign extension - 0xFF should load as -1
    push 0xFF
    push fp
    push -4
    add
    sb

    push fp
    push -4
    add
    lb

    push -1         ; 0xFF sign-extended = -1
    sub
    bnez _fail

    ; Test 3: Sign extension boundary - 0x7F should stay positive (127)
    push 0x7F
    push fp
    push -4
    add
    sb

    push fp
    push -4
    add
    lb

    push 0x7F
    sub
    bnez _fail

    ; Test 4: Sign extension boundary - 0x80 should become -128
    push 0x80
    push fp
    push -4
    add
    sb

    push fp
    push -4
    add
    lb

    push -128
    sub
    bnez _fail

    push 1
    syscall

_fail:
    push 0
    syscall
