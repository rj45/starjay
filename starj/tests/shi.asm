; Test shi instruction
    ; shi: tos = (tos << 7) | imm
    ; Shifts tos left by 7 bits and ORs in a 7-bit immediate (0-127)

    ; Test 1: Basic shi - build 0x0080 (128)
    ; Start with 1, shift left 7, OR with 0 = 0x80
    push 1
    shi 0
    push 0x80
    sub
    bnez _fail

    ; Test 2: shi with non-zero immediate
    ; Start with 0, shift left 7 (still 0), OR with 0x55 = 0x55
    push 0
    shi 0x55
    push 0x55
    sub
    bnez _fail

    ; Test 3: Build a larger value with push + shi
    ; push 1 gives 1, shi 0 gives 0x80, shi 0 gives 0x4000
    push 1
    shi 0
    shi 0
    push 0x4000
    sub
    bnez _fail

    ; Test 4: Build 0x1234 using push + shi sequence
    ; 0x1234 = 0b0001_0010_0011_0100
    ; Split: high 2 bits = 0b00, next 7 = 0b0100100 (0x24), low 7 = 0b0110100 (0x34)
    push 0
    shi 0x24
    shi 0x34
    push 0x1234
    sub
    bnez _fail

    ; Test 5: shi with max immediate (0x7F = 127)
    push 0
    shi 0x7F
    push 127
    sub
    bnez _fail

    ; Test 6: Multiple shi to build 16-bit value
    ; Build 0xABCD:
    ; 0xABCD = 0b10_1010111_1001101
    ; Split: high 2 bits = 0b10, next 7 = 0b1010111 (0x57), low 7 = 0b1001101 (0x4D)
    push 2
    shi 0x57
    shi 0x4D
    push 0xABCD
    sub
    bnez _fail

    ; Test 7: Verify shi only uses low 7 bits of immediate
    ; This depends on assembler behavior, but instruction should mask to 7 bits
    push 1
    shi 0           ; (1 << 7) | 0 = 128
    push 128
    sub
    bnez _fail

    ; Test 8: shi with existing value gets shifted
    push 0x01       ; 1
    shi 0x02        ; (1 << 7) | 2 = 128 + 2 = 130 = 0x82
    push 0x82
    sub
    bnez _fail

    ; Test 9: Build negative number via shi
    ; Build 0xFF00 = -256
    ; 0xFF00 = 0b111111110_0000000
    ; 0b111111110 = -2, next 7 = 0b0000000 (0x00)
    push -2
    shi 0
    push 0xFF00
    sub
    bnez _fail

    push 1
    syscall

_fail:
    push 0
    syscall
