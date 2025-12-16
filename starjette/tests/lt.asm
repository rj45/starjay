; Test lt instruction
    ; Case 0: 10 lt 20 -> 1
    push 10
    push 20
    lt
    push 1
    xor
    failnez

    ; Case 1: 20 lt 10 -> 0
    push 20
    push 10
    lt
    push 0
    xor
    failnez

    ; Case 2: 10 lt 10 -> 0
    push 10
    push 10
    lt
    push 0
    xor
    failnez

    ; Case 3: -10 lt 5 -> 1
    push -10
    push 5
    lt
    push 1
    xor
    failnez

    ; Case 4: 5 lt -10 -> 0
    push 5
    push -10
    lt
    push 0
    xor
    failnez

    ; Case 5: -20 lt -10 -> 1
    push -20
    push -10
    lt
    push 1
    xor
    failnez

    ; All passed
    push 1
    halt
