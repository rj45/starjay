import os

# Ensure test directory exists once at module load
os.makedirs("tests", exist_ok=True)


def write_test(filename, content):
    with open(filename, "w") as f:
        f.write(content)


def test_epilogue():
    """Generate the pass/fail epilogue for tests."""
    return """    ; All passed
    push 1
    halt
"""


def generate_binary_op_test(opcode_name, cases):
    """
    Generates a test file for a binary operation (pops 2, pushes 1).
    cases: list of tuples (a, b, expected_result)
    """
    filename = f"tests/{opcode_name}.asm"

    code = f"; Test {opcode_name} instruction\n"

    for i, (a, b, expected) in enumerate(cases):
        code += f"    ; Case {i}: {a} {opcode_name} {b} -> {expected}\n"
        code += f"    push {a}\n"
        code += f"    push {b}\n"
        code += f"    {opcode_name}\n"
        code += f"    push {expected}\n"
        code += "    xor\n"
        code += "    failnez\n\n"

    code += test_epilogue()
    write_test(filename, code)


def generate_unary_op_test(opcode_name, cases):
    """
    Generates a test for a unary operation (pops 1, pushes 1).
    cases: list of tuples (input_val, expected_result)
    """
    filename = f"tests/{opcode_name}.asm"

    code = f"; Test {opcode_name} instruction\n"

    for i, (inp, expected) in enumerate(cases):
        code += f"    ; Case {i}: {opcode_name} {inp} -> {expected}\n"
        code += f"    push {inp}\n"
        code += f"    {opcode_name}\n"
        code += f"    push {expected}\n"
        code += "    xor\n"
        code += "    failnez\n\n"

    code += test_epilogue()

    write_test(filename, code)


def generate_control_flow_tests():
    # beqz - comprehensive test
    write_test("tests/beqz.asm", """; Test beqz instruction
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
""" + test_epilogue())

    # bnez - comprehensive test
    write_test("tests/bnez.asm", """; Test bnez instruction
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
""" + test_epilogue())


def generate_stack_manip_tests():
    # dup
    write_test("tests/dup.asm", """; Test dup
    ; dup: push(tos) - duplicates top of stack

    ; Test 1: Basic dup
    push 123
    dup
    ; Stack: 123, 123
    push 123
    xor
    failnez

    ; Stack: 123
    push 123
    xor
    failnez

    ; Test 2: Dup zero
    push 0
    dup
    push 0
    xor
    failnez
    push 0
    xor
    failnez

    ; Test 3: Dup negative
    push -1
    dup
    push -1
    xor
    failnez
    push -1
    xor
    failnez

    ; Test 4: Dup large value
    push 0x7FFF
    dup
    push 0x7FFF
    xor
    failnez
    push 0x7FFF
    xor
    failnez

    ; Test 5: Dup with existing stack values
    push 0xAAAA     ; will be ros after dup
    push 0xBBBB     ; will be nos after dup
    dup             ; -> 0xAAAA, 0xBBBB, 0xBBBB
    push 0xBBBB
    xor
    failnez
    push 0xBBBB
    xor
    failnez
    push 0xAAAA
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
""")

    # drop
    write_test("tests/drop.asm", """; Test drop
    ; drop: tos! - pops and discards top of stack

    ; Test 1: Basic drop
    push 10
    push 20
    drop
    ; Stack should have 10
    push 10
    xor
    failnez

    ; Test 2: Multiple drops
    push 1
    push 2
    push 3
    drop        ; remove 3
    push 2
    xor
    failnez
    drop        ; remove 2
    push 1
    xor
    failnez

    ; Test 3: Drop zero
    push 0xABCD
    push 0
    drop
    push 0xABCD
    xor
    failnez

    ; Test 4: Drop negative
    push 0x1234
    push -1
    drop
    push 0x1234
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
""")

    # over
    write_test("tests/over.asm", """; Test over
    ; over: push(nos) - copies second item to top

    ; Test 1: Basic over
    push 10 ; nos
    push 20 ; tos
    over    ; -> 10, 20, 10

    push 10
    xor
    failnez

    push 20
    xor
    failnez

    push 10
    xor
    failnez

    ; Test 2: Over with different values
    push 0xAAAA
    push 0xBBBB
    over        ; -> 0xAAAA, 0xBBBB, 0xAAAA

    push 0xAAAA
    xor
    failnez

    push 0xBBBB
    xor
    failnez

    push 0xAAAA
    xor
    failnez

    ; Test 3: Over with zeros
    push 0
    push 0x1234
    over        ; -> 0, 0x1234, 0

    push 0
    xor
    failnez

    push 0x1234
    xor
    failnez

    push 0
    xor
    failnez

    ; Test 4: Over with same values
    push 42
    push 42
    over        ; -> 42, 42, 42

    push 42
    xor
    failnez

    push 42
    xor
    failnez

    push 42
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
""")

    # swap
    write_test("tests/swap.asm", """; Test swap
    ; swap: tos, nos = nos, tos - exchanges top two items

    ; Test 1: Basic swap
    push 10
    push 20
    swap    ; -> 20, 10

    push 10
    xor
    failnez

    push 20
    xor
    failnez

    ; Test 2: Swap with different values
    push 0xAAAA
    push 0xBBBB
    swap        ; -> 0xBBBB, 0xAAAA

    push 0xAAAA
    xor
    failnez

    push 0xBBBB
    xor
    failnez

    ; Test 3: Double swap returns to original
    push 0x1111
    push 0x2222
    swap
    swap        ; back to original

    push 0x2222
    xor
    failnez

    push 0x1111
    xor
    failnez

    ; Test 4: Swap with zero
    push 0
    push 0x5678
    swap

    push 0
    xor
    failnez

    push 0x5678
    xor
    failnez

    ; Test 5: Swap same values (should still work)
    push 99
    push 99
    swap

    push 99
    xor
    failnez

    push 99
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
""")


def generate_fsl_test():
    write_test("tests/fsl.asm", """; Test fsl instruction
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

    ; Test 11: Mixed pattern shift by 12
    ; {0x00F0, 0x0F00} << 12 = 0xF00F0000, upper = 0xF00F
    push 0x00F0     ; ros
    push 0x0F00     ; nos
    push 12         ; shift
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

    push 1
    halt

_fail:
    push 0
    halt
""")


def generate_select_test():
    write_test("tests/select.asm", """; Test select
    ; select: if tos != 0 then nos else ros
    ; Stack: [ros, nos, condition] -> [result]

    ; Case 1: True (tos = 1) -> select nos
    push 0xAAAA ; ros
    push 0xBBBB ; nos
    push 1      ; tos (true)
    select
    push 0xBBBB
    xor
    failnez

    ; Case 2: False (tos = 0) -> select ros
    push 0xAAAA ; ros
    push 0xBBBB ; nos
    push 0      ; tos (false)
    select
    push 0xAAAA
    xor
    failnez

    ; Case 3: True with negative condition (-1 is non-zero)
    push 0x1111 ; ros
    push 0x2222 ; nos
    push -1     ; tos (true, -1 != 0)
    select
    push 0x2222
    xor
    failnez

    ; Case 4: True with large positive condition
    push 0x3333 ; ros
    push 0x4444 ; nos
    push 0x7FFF ; tos (true)
    select
    push 0x4444
    xor
    failnez

    ; Case 5: Select between same values
    push 0x5555 ; ros
    push 0x5555 ; nos
    push 1      ; tos
    select
    push 0x5555
    xor
    failnez

    ; Case 6: Select with zeros
    push 0      ; ros
    push 0      ; nos
    push 0      ; tos (false) -> ros
    select
    push 0
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
""")


def generate_rot_test():
    write_test("tests/rot.asm", """; Test rot
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
""")


def generate_memory_tests():
    """Generate tests for lw, sw, lb, sb, lh, sh memory operations."""
    # lw/sw test
    write_test("tests/lw_sw.asm", """; Test lw and sw instructions
    ; Store a value and load it back
    ;
    ; sw: mem[tos] = nos, pops both
    ; lw: push(mem[tos]), pops addr, pushes value

    ; Test 1: Store and load 0x1234
    push 0x1234     ; value (will be nos)
    push fp
    push -4
    add             ; addr (will be tos)
    sw              ; mem[fp-4] = 0x1234

    ; Load it back
    push fp
    push -4
    add             ; addr
    lw              ; push(mem[fp-4])

    ; Check result
    push 0x1234
    xor
    failnez

    ; Test 2: Store and load 0xABCD at different offset
    push 0xABCD
    push fp
    push -6
    add
    sw

    push fp
    push -6
    add
    lw

    push 0xABCD
    xor
    failnez

    ; Test 3: Verify first location still has 0x1234
    push fp
    push -4
    add
    lw

    push 0x1234
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
""")

    # lb/sb test
    write_test("tests/lb_sb.asm", """; Test lb and sb instructions
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
    xor
    failnez

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
    xor
    failnez

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
    xor
    failnez

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
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
""")

    # lh/sh test
    write_test("tests/lh_sh.asm", """; Test lh and sh instructions
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
""")


def generate_register_tests():
    """Generate tests for push reg, pop reg, add reg operations."""
    # push/pop register tests
    write_test("tests/push_pop_reg.asm", """; Test push and pop register operations

    ; Test push fp / pop fp
    push fp     ; save original fp
    push 0x1234
    pop fp      ; set fp to 0x1234
    push fp     ; read it back
    push 0x1234
    xor
    failnez
    pop fp      ; restore original fp

    ; Test push ra / pop ra
    push 0x5678
    pop ra
    push ra
    push 0x5678
    xor
    failnez

    ; Test push ar / pop ar
    push 0xABCD
    pop ar
    push ar
    push 0xABCD
    xor
    failnez

    ; Test push pc (should push current pc value)
    push pc
    drop        ; just verify it doesn't crash

    push 1
    halt

_fail:
    push 0
    halt
""")

    # add reg test
    write_test("tests/add_reg.asm", """; Test add register operation

    ; Test add fp
    push fp     ; save original
    push 100
    add fp      ; fp += 100
    push fp
    swap        ; original, new_fp
    push 100
    add         ; original + 100
    xor         ; should be 0
    failnez
    push -100
    add fp      ; restore fp

    ; Test add ra
    push 0
    pop ra      ; ra = 0
    push 50
    add ra      ; ra += 50
    push ra
    push 50
    xor
    failnez

    ; Test add ar
    push 0
    pop ar
    push 200
    add ar
    push ar
    push 200
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
""")


def generate_call_tests():
    """Generate tests for call and ret (pop pc) operations."""
    write_test("tests/call_ret.asm", """; Test call and ret instructions

    ; Simple call and return
    call _test_func
    ; If we get here, call/ret worked
    push 1
    halt

_test_func:
    ; ra should contain return address
    ; Just return
    push ra
    pop pc      ; ret = pop pc

_fail:
    push 0
    halt
""")

    # Test callp (call function pointer)
    write_test("tests/callp.asm", """; Test callp instruction (call function pointer)

    push _test_func2
    callp
    ; If we get here, callp worked
    push 1
    halt

_test_func2:
    push ra
    pop pc

_fail:
    push 0
    halt
""")


def generate_next_word_tests():
    """Generate tests for lnw and snw (load/store next word via ar) operations."""
    write_test("tests/lnw_snw.asm", """; Test lnw and snw instructions
    ; lnw: push(mem[ar]); ar += 2 (for 16-bit)
    ; snw: mem[ar] = tos!; ar += 2 (for 16-bit)
    ; These use the ar register for sequential memory access

    ; First, store some values using snw
    ; Set ar to point to fp-8
    push fp
    push -8
    add
    pop ar          ; ar = fp - 8

    ; Store 4 words sequentially using snw
    push 0x1111
    snw             ; mem[fp-8] = 0x1111, ar = fp-6

    push 0x2222
    snw             ; mem[fp-6] = 0x2222, ar = fp-4

    push 0x3333
    snw             ; mem[fp-4] = 0x3333, ar = fp-2

    push 0x4444
    snw             ; mem[fp-2] = 0x4444, ar = fp

    ; Verify ar has been incremented correctly (should be fp now)
    push ar
    push fp
    xor
    failnez

    ; Now read them back using lnw
    ; Reset ar to fp-8
    push fp
    push -8
    add
    pop ar

    ; Load 4 words sequentially using lnw
    lnw             ; push(mem[fp-8]) = 0x1111, ar = fp-6
    push 0x1111
    xor
    failnez

    lnw             ; push(mem[fp-6]) = 0x2222, ar = fp-4
    push 0x2222
    xor
    failnez

    lnw             ; push(mem[fp-4]) = 0x3333, ar = fp-2
    push 0x3333
    xor
    failnez

    lnw             ; push(mem[fp-2]) = 0x4444, ar = fp
    push 0x4444
    xor
    failnez

    ; Verify ar has been incremented correctly again
    push ar
    push fp
    xor
    failnez

    ; Test with different values to ensure no aliasing
    push fp
    push -8
    add
    pop ar

    push 0xAAAA
    snw
    push 0xBBBB
    snw

    ; Reset and read back
    push fp
    push -8
    add
    pop ar

    lnw
    push 0xAAAA
    xor
    failnez

    lnw
    push 0xBBBB
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
""")


def generate_shi_tests():
    """Generate tests for shi (shift immediate) instruction."""
    write_test("tests/shi.asm", """; Test shi instruction
    ; shi: tos = (tos << 7) | imm
    ; Shifts tos left by 7 bits and ORs in a 7-bit immediate (0-127)

    ; Test 1: Basic shi - build 0x0080 (128)
    ; Start with 1, shift left 7, OR with 0 = 0x80
    push 1
    shi 0
    push 0x80
    xor
    failnez

    ; Test 2: shi with non-zero immediate
    ; Start with 0, shift left 7 (still 0), OR with 0x55 = 0x55
    push 0
    shi 0x55
    push 0x55
    xor
    failnez

    ; Test 3: Build a larger value with push + shi
    ; push 1 gives 1, shi 0 gives 0x80, shi 0 gives 0x4000
    push 1
    shi 0
    shi 0
    push 0x4000
    xor
    failnez

    ; Test 4: Build 0x1234 using push + shi sequence
    ; 0x1234 = 0b0001_0010_0011_0100
    ; Split: high 2 bits = 0b00, next 7 = 0b0100100 (0x24), low 7 = 0b0110100 (0x34)
    push 0
    shi 0x24
    shi 0x34
    push 0x1234
    xor
    failnez

    ; Test 5: shi with max immediate (0x7F = 127)
    push 0
    shi 0x7F
    push 127
    xor
    failnez

    ; Test 6: Multiple shi to build 16-bit value
    ; Build 0xABCD:
    ; 0xABCD = 0b10_1010111_1001101
    ; Split: high 2 bits = 0b10, next 7 = 0b1010111 (0x57), low 7 = 0b1001101 (0x4D)
    push 2
    shi 0x57
    shi 0x4D
    push 0xABCD
    xor
    failnez

    ; Test 7: Verify shi only uses low 7 bits of immediate
    ; This depends on assembler behavior, but instruction should mask to 7 bits
    push 1
    shi 0           ; (1 << 7) | 0 = 128
    push 128
    xor
    failnez

    ; Test 8: shi with existing value gets shifted
    push 0x01       ; 1
    shi 0x02        ; (1 << 7) | 2 = 128 + 2 = 130 = 0x82
    push 0x82
    xor
    failnez

    ; Test 9: Build negative number via shi
    ; Build 0xFF00 = -256
    ; 0xFF00 = 0b111111110_0000000
    ; 0b111111110 = -2, next 7 = 0b0000000 (0x00)
    push -2
    shi 0
    push 0xFF00
    xor
    failnez

    push 1
    halt

_fail:
    push 0
    halt
""")


def generate_local_tests():
    """Generate tests for llw and slw (local load/store) operations."""
    write_test("tests/llw_slw.asm", """; Test llw and slw instructions
    ; These use fp-relative addressing

    ; Allocate some space by adjusting fp
    push fp         ; save original fp
    add fp, -8      ; allocate 8 bytes (4 words for 16-bit)

    ; Store to offset 0 from fp
    push 0x1111
    push 0
    slw

    ; Store to offset 2 from fp
    push 0x2222
    push 2
    slw

    ; Load from offset 0
    push 0
    llw
    push 0x1111
    xor
    failnez

    ; Load from offset 2
    push 2
    llw
    push 0x2222
    xor
    failnez

    ; Restore fp
    push 8
    add fp
    drop            ; drop saved fp (we restored manually)
"""+test_epilogue())


def main():
    # --- ALU ops ---

    # add
    generate_binary_op_test(
        "add",
        [
            (10, 20, 30),
            (0, 0, 0),
            (-10, 5, -5),
            (32767, 1, -32768),  # Overflow 16-bit signed interpretation
            (-1, 1, 0),
        ],
    )

    # sub
    generate_binary_op_test(
        "sub",
        [(20, 10, 10), (10, 20, -10), (0, 0, 0), (-5, -5, 0), (0, 1, -1)],
    )

    # ltu (unsigned less than)
    generate_binary_op_test(
        "ltu",
        [
            (10, 20, 1),
            (20, 10, 0),
            (10, 10, 0),
            (-1, 10, 0),  # -1 is MAX_UINT, so MAX > 10 -> FALSE (0)
            (0, -1, 1),   # 0 < MAX_UINT -> TRUE (1)
        ],
    )

    # lt (signed less than)
    generate_binary_op_test(
        "lt",
        [
            (10, 20, 1),
            (20, 10, 0),
            (10, 10, 0),
            (-10, 5, 1),
            (5, -10, 0),
            (-20, -10, 1),
        ],
    )

    # and
    generate_binary_op_test(
        "and",
        [
            (0b1100, 0b1010, 0b1000),
            (0, 0xFFFF, 0),
            (0xFFFF, 0xFFFF, -1),       # 0xFFFF is -1 signed
            (0xFF00, 0x0FF0, 0x0F00),
            (0x5555, 0xAAAA, 0),
            (0x1234, 0xFFFF, 0x1234),
            (0x8000, 0x8000, 0x8000),
        ],
    )

    # or
    generate_binary_op_test(
        "or",
        [
            (0b1100, 0b1010, 0b1110),
            (0, 0, 0),
            (0, 1234, 1234),
            (0x5555, 0xAAAA, 0xFFFF),
            (0xFF00, 0x00FF, 0xFFFF),
            (0x1234, 0, 0x1234),
            (0x8000, 0x0001, 0x8001),
        ],
    )

    # xor
    generate_binary_op_test(
        "xor",
        [
            (0b1100, 0b1010, 0b0110),
            (12345, 12345, 0),
            (0, -1, -1),
            (0xFFFF, 0xFFFF, 0),
            (0x5555, 0xAAAA, 0xFFFF),
            (0xFF00, 0x00FF, 0xFFFF),
            (0x1234, 0xFFFF, 0xEDCB),
        ],
    )

    # fsl (funnel shift left)
    generate_fsl_test()

    # --- Stack Manipulation ---
    generate_stack_manip_tests()

    # --- Extended Math ---

    # div (signed)
    generate_binary_op_test(
        "div",
        [(20, 10, 2), (20, -10, -2), (-20, 10, -2), (-20, -10, 2)],
    )

    # divu (unsigned)
    generate_binary_op_test(
        "divu",
        [
            (20, 10, 2),
            (0xFFFF, 1, 0xFFFF),  # 65535 / 1 = 65535
            (10, 20, 0),
        ],
    )

    # mod
    generate_binary_op_test(
        "mod",
        [(10, 3, 1), (-10, 3, -1), (10, -3, 1), (-10, -3, -1)],
    )

    # modu
    generate_binary_op_test(
        "modu",
        [
            (10, 3, 1),
            (20, 6, 2),
            (100, 7, 2),
            (0xFFFF, 256, 255),
            (1000, 1000, 0),
            (5, 10, 5),
            (0, 5, 0),
        ],
    )

    # mul
    generate_binary_op_test(
        "mul",
        [
            (10, 10, 100),
            (1000, 1000, 0x4240),   # 1000000 & 0xFFFF = 16960
            (0, 12345, 0),
            (1, 12345, 12345),
            (256, 256, 0),          # 65536 & 0xFFFF = 0 (overflow)
            (2, 0x4000, 0x8000),
            (-1, 2, -2),
            (0x100, 0x100, 0),
        ],
    )

    # mulh - upper word of unsigned multiply
    generate_binary_op_test(
        "mulh",
        [
            (10, 10, 0),
            (0x100, 0x100, 1),        # 256*256 = 65536, upper = 1
            (0xFFFF, 2, 1),           # 65535*2 = 131070, upper = 1
            (0xFFFF, 0xFFFF, 0xFFFE), # 65535*65535, upper = 0xFFFE
            (0x8000, 2, 1),           # 32768*2 = 65536, upper = 1
        ],
    )

    # select
    generate_select_test()

    # rot
    generate_rot_test()

    # Shifts
    # srl - logical right shift (zero fill)
    generate_binary_op_test(
        "srl",
        [
            (0b1111, 1, 0b0111),
            (0xFFFF, 4, 0x0FFF),
            (0x8000, 1, 0x4000),
            (0x1234, 0, 0x1234),
            (0xFFFF, 15, 1),
            (0x1234, 16, 0x1234),  # Shift by 16 = shift by 0 (masked)
        ],
    )

    # sra - arithmetic right shift (sign extend)
    generate_binary_op_test(
        "sra",
        [
            (0b1111, 1, 0b0111),
            (-4, 1, -2),
            (-1, 4, -1),
            (0x4000, 1, 0x2000),
            (-32768, 1, -16384),
            (100, 0, 100),
        ],
    )

    # sll - logical left shift
    generate_binary_op_test(
        "sll",
        [
            (0b0001, 1, 0b0010),
            (0b0001, 4, 0b00010000),
            (0x0001, 15, 0x8000),
            (0xFFFF, 1, 0xFFFE),
            (0x1234, 0, 0x1234),
        ],
    )

    # Control Flow
    generate_control_flow_tests()

    # Memory operations
    generate_memory_tests()

    # Register operations
    generate_register_tests()

    # Call/ret
    generate_call_tests()

    # Local load/store
    generate_local_tests()

    # Next word (ar-relative) load/store
    generate_next_word_tests()

    # Shift immediate
    generate_shi_tests()

    print("Tests generated successfully.")


if __name__ == "__main__":
    main()
