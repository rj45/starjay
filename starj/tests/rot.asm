; Test rot
    ; Stack top-to-bottom: A(tos), B(nos), C(ros)
    ; Manual: temp = tos; tos = nos; nos = ros; ros = temp
    ; Result top-to-bottom: B(tos), C(nos), A(ros)

    ; Test 1: Basic rotation with distinct values
    push 0xCCCC ; C (will be ros)
    push 0xBBBB ; B (will be nos)
    push 0xAAAA ; A (will be tos)
    rot
    ; Stack should be: B(tos), C(nos), A(ros)

    push 0xBBBB ; expect tos = B
    xor
    failnez

    push 0xCCCC ; expect nos = C
    xor
    failnez

    push 0xAAAA ; expect ros = A
    xor
    failnez

    ; Test 2: Rotation with different values
    push 0x1111 ; ros
    push 0x2222 ; nos
    push 0x3333 ; tos
    rot

    push 0x2222 ; expect tos
    xor
    failnez

    push 0x1111 ; expect nos
    xor
    failnez

    push 0x3333 ; expect ros
    xor
    failnez

    ; Test 3: Three rotations should return to original
    push 0x0001 ; ros
    push 0x0002 ; nos
    push 0x0003 ; tos
    rot         ; -> 2, 1, 3
    rot         ; -> 1, 3, 2
    rot         ; -> 3, 2, 1 (back to original)

    push 0x0003 ; expect tos
    xor
    failnez

    push 0x0002 ; expect nos
    xor
    failnez

    push 0x0001 ; expect ros
    xor
    failnez

    ; Test 4: Rotation with zeros
    push 0      ; ros
    push 0      ; nos
    push 0x1234 ; tos
    rot

    push 0      ; expect tos (was nos)
    xor
    failnez

    push 0      ; expect nos (was ros)
    xor
    failnez

    push 0x1234 ; expect ros (was tos)
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
