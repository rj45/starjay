; Test fsl instruction
    ; fsl: push((({ros, nos} << (tos & 31)) >> 16) & 0xFFFF)
    ; Forms 32-bit value {ros, nos}, shifts left, returns upper 16 bits
    ;
    ; Stack before: [ros, nos, shift]  (shift = tos)
    ; Stack after:  [result]

    ; Test 1: Shift by 0 - should return ros unchanged
    ; {0xAAAA, 0x5555} << 0 = 0xAAAA5555, upper = 0xAAAA
    push 0xAAAA     ; ros
    push 0x5555     ; nos
    push 0          ; shift
    fsl
    push 0xAAAA
    xor
    failnez

    ; Test 2: Shift by 16 - should return nos (low word moves to high)
    ; {0xAAAA, 0x5555} << 16 = 0x55550000, upper = 0x5555
    push 0xAAAA     ; ros
    push 0x5555     ; nos
    push 16         ; shift
    fsl
    push 0x5555
    xor
    failnez

    ; Test 3: Shift by 4 - partial shift
    ; {0x0000, 0x1234} << 4 = 0x00012340, upper = 0x0001
    push 0x0000     ; ros
    push 0x1234     ; nos
    push 4          ; shift
    fsl
    push 0x0001
    xor
    failnez

    ; Test 4: Shift by 8
    ; {0x0000, 0xFF00} << 8 = 0x00FF0000, upper = 0x00FF
    push 0x0000     ; ros
    push 0xFF00     ; nos
    push 8          ; shift
    fsl
    push 0x00FF
    xor
    failnez

    ; Test 5: Shift by 1
    ; {0x8000, 0x0000} << 1 = 0x00000000, upper = 0x0000 (high bit shifted out)
    push 0x8000     ; ros
    push 0x0000     ; nos
    push 1          ; shift
    fsl
    push 0x0000
    xor
    failnez

    ; Test 6: Shift by 1 with carry from nos to ros position
    ; {0x0000, 0x8000} << 1 = 0x00010000, upper = 0x0001
    push 0x0000     ; ros
    push 0x8000     ; nos
    push 1          ; shift
    fsl
    push 0x0001
    xor
    failnez

    ; Test 7: Shift by 15
    ; {0x0001, 0x0000} << 15 = 0x80000000, upper = 0x8000
    push 0x0001     ; ros
    push 0x0000     ; nos
    push 15         ; shift
    fsl
    push 0x8000
    xor
    failnez

    ; Test 8: Shift by 31 (max shift)
    ; {0x0000, 0x0001} << 31 = 0x80000000, upper = 0x8000
    push 0x0000     ; ros
    push 0x0001     ; nos
    push 31         ; shift
    fsl
    push 0x8000
    xor
    failnez

    ; Test 9: Shift by 32 should wrap to shift by 0 (masked to 31 bits)
    ; {0xAAAA, 0x5555} << 0 = 0xAAAA5555, upper = 0xAAAA
    push 0xAAAA     ; ros
    push 0x5555     ; nos
    push 32         ; shift (masked to 0)
    fsl
    push 0xAAAA
    xor
    failnez

    ; Test 10: All ones
    ; {0xFFFF, 0xFFFF} << 4 = 0xFFFFFFF0, upper = 0xFFFF
    push 0xFFFF     ; ros
    push 0xFFFF     ; nos
    push 4          ; shift
    fsl
    push 0xFFFF
    xor
    failnez

    ; Test 11: Mixed pattern shift by 8
    ; {0x00F0, 0x0F00} << 8 = 0xF00F0000, upper = 0xF00F
    push 0x00F0     ; ros
    push 0x0F00     ; nos
    push 8          ; shift
    fsl
    push 0xF00F
    xor
    failnez

    ; Test 12: Verify shift implements sll correctly
    ; sll can be done as: push 0; swap; push N; fsl
    ; {0, value} << N, take upper = value << N (for N < 16)
    ; Let's verify: 0x0001 << 4 = 0x0010
    push 0x0000     ; ros
    push 0x0001     ; nos
    push 20         ; shift (16 + 4, so nos shifts up 4 into result)
    fsl
    push 0x0010
    xor
    failnez

    ; Test 13: Verify shift implements srl correctly
    ; srl can be done as: push 0; push value; push (16-N); fsl
    ; {0, value} << (16-N), take upper = value >> N
    ; Let's verify: 0x8000 >> 4 = 0x0800
    push 0x0000     ; ros
    push 0x8000     ; nos
    push 12         ; shift (16 - 4)
    fsl
    push 0x0800
    xor
    failnez

    ; === Deep Stack Preservation Test ===
    ; Verify fsl correctly preserves stack_mem values when depth >= 5
    push 0x1111     ; will be stack_mem[0] (deepest)
    push 0x2222     ; will be stack_mem[1] - CRITICAL VALUE
    push 0x3333     ; will be stack_mem[2]
    push 0xAAAA     ; ROS - high word for fsl
    push 0x5555     ; NOS - low word for fsl
    push 0          ; TOS - shift amount (0 = return high word)

    ; depth=6
    fsl             ; result = 0xAAAA (shift by 0, high word)

    ; Expected: TOS=result(0xAAAA), NOS=0x3333, ROS=0x2222
    push 0xAAAA     ; verify result
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

    push 1
    halt

_fail:
    push 0
    halt
