; Test add register operation

    ; Test add fp
    push fp     ; save original
    push 100
    add fp      ; fp += 100
    push fp
    swap        ; original, new_fp
    push 100
    add         ; original + 100
    sub         ; should be 0
    bnez _fail
    push -100
    add fp      ; restore fp

    ; Test add ra
    push 0
    pop ra      ; ra = 0
    push 50
    add ra      ; ra += 50
    push ra
    push 50
    sub
    bnez _fail

    ; Test add ar
    push 0
    pop ar
    push 200
    add ar
    push ar
    push 200
    sub
    bnez _fail

    push 1
    syscall

_fail:
    push 0
    syscall
