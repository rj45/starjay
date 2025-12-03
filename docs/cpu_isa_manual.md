# StarJette - A 16/32-bit Stack Machine for C-like Languages

## 1.1. Overview

StarJette is the microprocessor in the StarJay console ecosystem. It is a stack machine architecture designed to execute C-like languages, simplifying both the hardware and compiler implementation. In the compiler, register allocation can be avoided, as the register file that would normally be present for holding temporary values is replaced by a stack.

StarJette is designed to be a "progressive complexity" implementation in hardware. There are only 3 instruction formats, all instructions are 8 bits wide, and only a subset of 25 instructions need to be implemented, the rest can be emulated in software (though it will be slow). If more complexity is acceptable, instructions may be fused together to greatly speed up the processor. The processor can be pipelined up to 3 stages, and if the frame stack is stored in a cache, and local load/store with the preceding push immediate is fused to the alu instructions, then one could even potentially get 4 or 5 pipeline stages by treating the frame stack with its locals like another register file. 

The instruction set architecture could be used equally well as a 16 bit machine or 32 bit machine. It is a little-endian architecture where the smallest addressable unit is a byte (8 bits). Multi-byte values are aligned to their size (e.g., 16-bit values are aligned to even addresses, 32-bit values to addresses divisible by 4). All instructions are 8 bits wide, with no alignment requirements (jumping into the middle of a word is legal).

### 1.2. Notation

- `tos` - Top of Stack - The value on the top of the data stack
- `nos` - Next on Stack - The value at the second position of the data stack
- `ros` - Third on Stack - The value at the third position of the data stack
- `pc` - Program Counter - Address of the *currently* executing instruction
- `fp` - Frame Pointer register
- `afp` - Alternate Frame Pointer register
- `mem[addr]` - Memory at address `addr`
- `mem:byte[addr]` - Byte at memory address `addr`
- `mem:half[addr]` - Half-word (16 bits) at memory address `addr`
- `WORDSIZE` - Word size in bits (16 or 32)
- `WORDBYTES` - `WORDSIZE / 8` - Word size in bytes (2 or 4)
- `WORDMASK` - `(1 << WORDSIZE)-1` - Mask for a full word
- `x!` - Pop value from stack (e.g., `tos!` pops the top of stack)
- `x, y = y, x` - Swap values of `x` and `y`
- `push(x)` - Push `x` onto stack, incrementing stack `depth`
- `if (condition) then expr1 else expr2` - Conditional expression
- `sign_extend(imm, bits)` - Sign-extends the `bits` bit wide immediate value to the full word size
- `unsigned(x)` - Treats the expression `x` as using unsigned integers
- `signed(x)` - Treats the expression `x` as using signed integers
- `{high, low}` - `high << WORDSIZE | low` - Concatenates `high` and `low` values to form a double word, with `high` as the upper half and `low` as the lower half
- `^` - Bitwise XOR operation
- `~` - Bitwise NOT operation
- Other standard arithmetic and logical operators (`+`, `-`, `*`, `/`, `&`, `|`, etc.) have their usual meanings.

### 1.3. Stacks

StarJette has two stacks:

1. Data Stack: Used for holding temporary values during computation.
    - Stored in a separate memory from main memory to avoid memory bus congestion.
    - Raises an exception on overflow or underflow (see exception handling section).
    - Function parameters and return values are passed on the data stack.
    - Must be flushed to main memory on task context switches, but not function calls or interrupts.
    - There is a `depth` CSR tracking the number of items pushed onto this stack.

2. Frame Stack: Used for storing local variables and return addresses for function calls.
    - Stored in main memory.
    - Grows toward lower memory addresses (i.e., `fp` is decremented to allocate space).
    - Contains local variables and return addresses.

## 2. Registers

StarJette has a minimal set of registers:

```text
   Num    Name                             Description
  +---+---------+-------------------------------------------------------------------------------+
  | 0 | pc      | Program Counter - Points to the next instruction to execute.                  |
  | 1 | fp      | Frame Pointer - Points to the base of the current stack frame.                |
  | 2 | ra      | Return Address - Holds the return address during function calls.              |
  | 3 | ar      | Address Register - Holds an address for memory copies.                        |
  +---+---------+-------------------------------------------------------------------------------+
```

Note that implementations may store `tos`, `nos`, and `ros` in registers for performance, but the semantics of the architecture treat them as part of the data stack.

Also note that the `pc` register points to the next instruction to execute after the currently executing instruction, so then in an implementation with pipelining it should not be necessary to forward both the current `pc` and the next `pc`. All instructions that reference the `pc` will reference the next instruction to execute.

StarJette does not have a flags register or condition codes. Instead, comparison instructions push their results onto the data stack. Conditional branches then pop the top of the stack to determine the branch direction. There is no add-with-carry or subtract-with-borrow: ltu instructions can be used to read the carry flag and implement multi-precision arithmetic in a manner similar to RISC-V.

`ar` is intended to be used for memory copy operations using the `lnw` and `snw` instructions, allowing efficient copying of data between the data stack and memory. It can also be used for efficient stack spilling and filling during context switches, or in stack overflow/underflow handlers.

Both `ra` and `ar` may be used as temporary registers if they are not otherwise used. They are caller saved.

See the calling convention below to understand better how `fp` and the frame stack work.

### 2.1. Computer Status Registers

There these CSRs:

0. `status` (Status Register): Contains various status flags.
1. `estatus` - A copy of `status` saved on exceptions / interrupts.
2. `epc` - Exception Program Counter - Saved `pc` on exceptions / interrupts.
3. `afp` (Alternate Frame Pointer): Swaps with the `fp` register while in kernel mode.
4. `depth` (Data Stack Depth): Number of items currently on the data stack.
5. `ecause` (Exception Cause): Indicates the cause of the most recent exception or interrupt.
6. `evec` (Exception Vector): Address loaded into `pc` when an exception or interrupt occurs.
7. Reserved
8. `udmask` (User Data Address Mask): Bits of user-mode data addresses forced to zero
9. `udset` (User Data Address Set Bits): Bits of user-mode data addresses forced to one
10. `upmask` (User Program Address Mask): Bits of user-mode program addresses forced to zero
11. `upset` (User Program Address Set Bits): Bits of user-mode program addresses forced to one
12. `kdmask` (Kernel Data Address Mask): Bits of kernel-mode data addresses forced to zero
13. `kdset` (Kernel Data Address Set Bits): Bits of kernel-mode data addresses forced to one
14. `kpmask` (Kernel Program Address Mask): Bits of kernel-mode program addresses forced to zero
15. `kpset` (Kernel Program Address Set Bits): Bits of kernel-mode program addresses forced to one

Note: Undefined or reserved CSRs raise an illegal instruction exception. Attempts to read any CSR in user mode other than `depth` raise an illegal instruction exception. Attempts to write any CSR in user mode raise an illegal instruction exception.

### 2.2. Boot Value of Registers

On boot / reset, the registers are initialized as follows:

```text
   Register   Value
  +---------+-------+
  | status  |   1   |
  | estatus |   0   |
  | pc      |   0   |
  | epc     |   0   |
  | fp      |   0   |
  | afp     |   0   |
  | ra      |   0   |
  | ar      |   0   |
  | ecause  |   0   |
  | evec    |   0   |
  | udmask  |   0   |
  | udset   |   0   |
  | upmask  |   0   |
  | upset   |   0   |
  | kdmask  |   0   |
  | kdset   |   0   |
  | kpmask  |   0   |
  | kpset   |   0   |
  +---------+-------+
```

Note: the first instructions should be to set the initial `fp` and `afp` registers to valid stack frame locations before making any function calls or system calls. You should also set the `evec` register to point to your exception handler before enabling interrupts or executing any instructions that might cause exceptions. You may also want to set up the MMU registers for memory protection and address translation, for example, setting program and data to separate memory regions.

### 2.3. `status` - Computer Status Register

```text
    WORDSIZE-1 .. 3    2     1    0
  +-----------------+-----+----+----+
  |      unused     | hlt | ie | km |
  +-----------------+-----+----+----+
```

Specified bits:
- `0`: `km` - Kernel Mode - specifies whether the processor is in kernel mode or not
- `1`: `ie` - Interrupt Enable - specifies whether interrupts are enabled or not
- `2`: `hlt` - Halted - indicates whether the CPU is halted
- `3..WORDSIZE-1`: unused - reserved for future use

This register may only be accessed in kernel mode, attempts to write it in user mode are ignored, and attempts to read it return zero.

Clearing the `km` bit while in kernel mode will immediately drop to user mode without branching. Note that this will cause the `fp` and `afp` registers to be swapped.

The `ie` bit controls whether interrupts are enabled or disabled. If an interrupt occurs while this bit is clear, the interrupt is deferred until the bit is set again. Interrupts are disabled on boot / reset. When an interrupt is taken, the `ie` bit is cleared, and then the exception sequence is followed as described in the exception section.

Setting the `hlt` bit will cause the CPU to halt execution after the current instruction completes. This can be used by the emulator to exit. The top of stack can be used as the exit code of the emulator for use in end-to-end or integration testing.

On boot / reset, this register is set to `1`, starting the processor with interrupts disabled and in kernel mode.

### 2.4. `epc`, `estatus` - Exception Program Counter and Exception Status

The `epc` register holds the value of the `pc` register at the time an exception or interrupt occurs. This will be the address of the instruction after the one causing the exception. This may have to be adjusted if the instruction should be retried after the exception is handled.

The `estatus` register holds a copy of the `status` register at the time an exception or interrupt occurs. This allows the processor to restore the previous status when returning from the exception.

If re-entrance is wanted, the exception handler must save and restore these registers appropriately before re-enabling interrupts and returning from the exception. Use of extended instructions should be avoided until these are saved, since if they are implemented in software, they will clobber these registers.

### 2.5. `depth` - Data Stack Depth

The `depth` represents the data stack depth, including values in the `tos`, `nos` and `ros` registers, and can be used to save the stack to memory for a context switch. It is incremented for each push, and decremented for each pop. 

The operating system may choose to handle underflow and overflow exceptions by maintaining a spill area in memory to back up the data stack when it grows too large, or to refill the data stack from memory when it shrinks too small.

See the interrupt handling section below for more information on the data stack overflow and underflow exceptions.

The `ar` register and `lnw` / `snw` instructions may be used to efficiently copy the data stack to and from memory.

The `depth` register may be read in user mode, but writes cause an illegal instruction exception. In kernel mode, any writes to this register will write as zero, as the stack only supports being reset.

### 2.6. `ecause` - Exception Cause Register

The `ecause` register indicates the cause of the most recent exception, interrupt, or syscall. It is set by hardware when entering kernel mode and can be read by the exception handler to determine how to respond.

```text
    WORDSIZE-1 .. 8   7   6   5   4   3   2   1   0
  +-----------------+---------------+---------------+
  |     unused      |   category    |   sub-cause   |
  +-----------------+---------------+---------------+
```

The register is divided into two contiguous 4-bit fields:
- **Bits 7:4 (category)**: The general category of the exception (0-15)
- **Bits 3:0 (sub-cause)**: The specific cause within that category (0-15)

This layout is designed for efficient jump table dispatch using the `add pc` instruction:
- For category-level dispatch with 16-byte handler entries: `push ecause; and 0xF0; add pc`
- For sub-cause dispatch with 2-byte entries: `push ecause; and 0x0F; dup; add; add pc`
- For full dispatch with 2-byte entries: `push ecause; dup; add; add pc`

#### Exception Cause Table

```text
  ecause   Category   Sub-cause   Description
  +------+----------+-----------+----------------------------------------+
  | 0x00 |    0     |     0     | Syscall                                |
  +------+----------+-----------+----------------------------------------+
  | 0x10 |    1     |     0     | Invalid instruction (illegal opcode)   |
  | 0x11 |    1     |     1     | Privileged instruction in user mode    |
  +------+----------+-----------+----------------------------------------+
  | 0x20 |    2     |     0     | Unaligned memory access                |
  | 0x21 |    2     |     1     | Memory access fault (unmapped)         |
  | 0x22 |    2     |     2     | Memory protection violation            |
  +------+----------+-----------+----------------------------------------+
  | 0x30 |    3     |     0     | Data stack underflow                   |
  | 0x31 |    3     |     1     | Data stack overflow                    |
  | 0x32 |    3     |     2     | Frame pointer misalignment             |
  | 0x33 |    3     |     3     | Frame pointer wrap                     |
  +------+----------+-----------+----------------------------------------+
  | 0x40 |    4     |     0     | Division by zero                       |
  +------+----------+-----------+----------------------------------------+
  | 0x50-|   5-14   |    0-15   | Reserved for future use                |
  | 0xEF |          |           |                                        |
  +------+----------+-----------+----------------------------------------+
  | 0xF0-|   15     |    0-15   | External interrupt (sub-cause =        |
  | 0xFF |          |           | interrupt number)                      |
  +------+----------+-----------+----------------------------------------+
```

Note: Macro instructions (extended instructions implemented in software) do NOT use the `ecause`/`evec` mechanism. They continue to use their dedicated vector table at addresses 0x0100-0x01FF.

### 2.7. `evec` - Exception Vector Register

The `evec` register holds the address that will be loaded into `pc` when an exception, interrupt, or syscall occurs. This provides a single entry point for all exception handling except macro instructions, with the `ecause` register indicating the specific cause.

On boot/reset, `evec` is initialized to 0. The reset code should set `evec` to point to the exception handler before enabling interrupts or executing instructions that might cause exceptions.

Example exception handler structure:
```
_exception_handler:
  ; Save epc and estatus if re-entrancy is needed
  ; Check ecause to determine cause
  push ecause
  and 0xF0          ; Get category
  jump              ; Jump to category handler
  ; ... 16-byte handler entries for each category ...
```

### 2.8. `udmask`, `upmask`, `kdmask`, `kpmask` - User/Kernel Memory Address Mask

Represents the bits of the memory address that are forced to zero for memory accesses in user or kernel mode. This is used to implement memory protection by restricting the addressable memory range.

There are separate registers for data access (load/store) and program access (instruction fetch), allowing different memory protection configurations for code and data.

For 16 bit machines, this represents bits 27..12 of the physical address, bits 11..0 are never changed. For 32 bit machines, this represents the full word: bits 31..0.

A memory access fault can be raised if the result of masking the address results in a non-zero result.

When `km` is set, the `k` variants are used; otherwise, the `u` variants are used.

On reset these registers are set to zeros, allowing access to the entire memory space.

### 2.9. `udset`, `upset`, `kdset`, `kpset` - User/Kernel Memory Address Set Bits

Represents the bits of the memory address that are forced to one for memory accesses in user or kernel mode. This is used to implement a crude form of address translation.

There are separate registers for data access (load/store) and program access (instruction fetch), allowing code and data to be mapped to different pysical address ranges. 

For 16 bit machines, this represents bits 27..12 of the physical address, bits 11..0 are never changed. For 32 bit machines, this represents the full word: bits 31..0.

When `km` is set, the `k` variants are used; otherwise, the `u` variants are used.

On reset, these registers are set to all zeros, meaning no bits are forced to one. This puts the reset vector at address 0.

## 3. Instruction Set

The instruction set is split into two parts: 25 basic instructions that must be implemented in hardware, and a larger set of extended instructions that may be implemented in software if desired.

### 3.1. Instruction Formats

All instructions are 8 bits wide. There are three instruction formats:

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+---+---------------------------+
  | S | 1 |           7-bit imm       |
  +---+---+---+-----------------------+
  | I | 0   1 |       6-bit imm       |
  +---+-------+-----------------------+
  | O | 0   0 |         opcode        |
  +---+-------+-----------------------+
```

- **S Format** (`1xxxxxxx`): 7 bit immediate for `shi` instruction.
- **I Format** (`01xxxxxx`): 6 bit immediate for `push` instruction.
- **O Format** (`00xxxxxx`): for all other operations.

### 3.2 Instruction Summary

```text
          Instruction Bits           Mnemonic             Description
  +-------+-----------------------+------------+--------------------------------+
  | 7   6   5   4   3   2   1   0 |                  Basic Ops                  |
  +---+---------------------------+------------+--------------------------------+
  | 1 |              imm          | shi <imm>  | Shift 7 more bits into tos     |
  +---+---+-----------------------+------------+--------------------------------+
  | 0   1 |          imm          | push <imm> | Push sign extended immediate   |
  +-------+-------+---------------+------------+--------------------------------+
  | 0   0 | 0   0 | 0   0   0   0 | syscall    | Jump to kernel                 |
  | 0   0 | 0   0 | 0   0   0   1 | rets       | Return from kernel             |
  | 0   0 | 0   0 | 0   0   1   0 | beqz       | Branch if equal zero           |
  | 0   0 | 0   0 | 0   0   1   1 | bnez       | Branch if not equal zero       |
  +-------+-------+---------------+------------+--------------------------------+
  | 0   0 | 0   0 | 0   1   0   0 | dup        | Duplicate top of stack         |
  | 0   0 | 0   0 | 0   1   0   1 | drop       | Drop top of stack              |
  | 0   0 | 0   0 | 0   1   1   0 | over       | Duplicate next on stack        |
  | 0   0 | 0   0 | 0   1   1   1 | swap       | Swap top and next on stack     |
  +-------+-------+---------------+------------+--------------------------------+
  | 0   0 | 0   0 | 1   0   0   0 | add        | Addition                       |
  | 0   0 | 0   0 | 1   0   0   1 | sub        | Subtraction                    |
  | 0   0 | 0   0 | 1   0   1   0 | ltu        | Set unsigned less than         |
  | 0   0 | 0   0 | 1   0   1   1 | lt         | Set signed less than           |
  | 0   0 | 0   0 | 1   1   0   0 | and        | Bitwise AND                    |
  | 0   0 | 0   0 | 1   1   0   1 | or         | Bitwise OR                     |
  | 0   0 | 0   0 | 1   1   1   0 | xor        | Bitwise XOR                    |
  | 0   0 | 0   0 | 1   1   1   1 | fsl        | Double word funnel shift left  |
  +-------+-------+-------+-------+------------+--------------------------------+
  | 0   0 | 0   1 | 0   0 | <reg> | push <reg> | Push register to stack         |
  | 0   0 | 0   1 | 0   1 | <reg> | pop  <reg> | Pop register from stack        |
  | 0   0 | 0   1 | 1   0 | <reg> | add  <reg> | Add tos to register            |
  | 0   0 | 0   1 | 1   1 | 0   0 | pushcsr    | Push CSR to stack              |
  | 0   0 | 0   1 | 1   1 | 0   1 | popcsr     | Pop CSR from stack             |
  +-------+-------+-------+-------+------------+--------------------------------+
  | 0   0 | 0   1 | 1   1 | 1   0 | llw        | Load local (fp-relative) word  |
  | 0   0 | 0   1 | 1   1 | 1   1 | slw        | Store local (fp-relative) word |
  +-------+-------+-------+-------+------------+--------------------------------+
  | 7   6   5   4   3   2   1   0 |              Extended ALU Ops               |
  +-------+-------+---------------+------------+--------------------------------+
  | 0   0 | 1   0 | 0   0   0   0 | div        | Signed division                |
  | 0   0 | 1   0 | 0   0   0   1 | divu       | Unsigned division              |
  | 0   0 | 1   0 | 0   0   1   0 | mod        | Signed remainder / modulus     |
  | 0   0 | 1   0 | 0   0   1   1 | modu       | Unsigned remainder / modulus   |
  | 0   0 | 1   0 | 0   1   0   0 | mul        | Multiply                       |
  | 0   0 | 1   0 | 0   1   0   1 | mulh       | Upper word of multiply         |
  | 0   0 | 1   0 | 0   1   1   0 | select     | If tos then nos else ros       |
  | 0   0 | 1   0 | 0   1   1   1 | rot        | Rotate tos into nos            |
  | 0   0 | 1   0 | 1   0   0   0 | srl        | Shift right logical            |
  | 0   0 | 1   0 | 1   0   0   1 | sra        | Shift right arithmetic         |
  | 0   0 | 1   0 | 1   0   1   0 | sll        | Shift left logical             |
  | 0   0 | 1   0 | 1   0   1   1 |            |                                |
  | 0   0 | 1   0 | 1   1   0   0 |            |                                |
  | 0   0 | 1   0 | 1   1   0   1 |            |                                |
  | 0   0 | 1   0 | 1   1   1   0 |            |                                |
  | 0   0 | 1   0 | 1   1   1   1 |            |                                |
  +-------+-------+---------------+------------+--------------------------------+
  | 7   6   5   4   3   2   1   0 |            Extended Memory Ops              |
  +-------+-----------+-----------+------------+--------------------------------+
  | 0   0 | 1   1   0 | 0   0   0 | lb         | Load sign extended byte        |
  | 0   0 | 1   1   0 | 0   0   1 | sb         | Store byte                     |
  | 0   0 | 1   1   0 | 0   1   0 | lh         | Load sign extended half word   |
  | 0   0 | 1   1   0 | 0   1   1 | sh         | Store half word                |
  | 0   0 | 1   1   0 | 1   0   0 | lw         | Load word from address in tos  |
  | 0   0 | 1   1   0 | 1   0   1 | sw         | Store nos to address in tos    |
  | 0   0 | 1   1   0 | 1   1   0 | lnw        | Load next word at ar           |
  | 0   0 | 1   1   0 | 1   1   1 | snw        | Store next word at ar          |
  +-------+-----------+-----------+------------+--------------------------------+
  | 7   6   5   4   3   2   1   0 |          Extended Control Flow              |
  +-------+-----------+-----------+------------+--------------------------------+
  | 0   0 | 1   1   1 | 0   0   0 | call       | Call pc-relative function      |
  | 0   0 | 1   1   1 | 0   0   1 | callp      | Call function pointer          |
  | 0   0 | 1   1   1 | 0   1   0 |            |                                |
  | 0   0 | 1   1   1 | 0   1   1 |            |                                |
  | 0   0 | 1   1   1 | 1   0   0 |            |                                |
  | 0   0 | 1   1   1 | 1   0   1 |            |                                |
  | 0   0 | 1   1   1 | 1   1   0 |            |                                |
  | 0   0 | 1   1   1 | 1   1   1 |            |                                |
  +-------+-----------+-----------+------------+--------------------------------+
```

### 3.3. Instruction Set Details

#### 3.4. Basic Instructions

##### 3.4.1. `shi imm` - Shift Immediate

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+---+---------------------------+
  | S | 1 |           imm             |
  +---+---+---------------------------+

  tos = (tos << 7) | imm
```

Shifts the `tos` register left by 7 bits and ORs in the 7-bit `imm` value.

This instruction is not often used directly; instead the assembler will use it is as part of a sequence of `push imm` followed by `shi` instructions to load larger immediate values onto the stack.

Implementations may choose to optimise sequences of `push imm` and `shi` instructions by fusing them into a single wider immediate load.

##### 3.4.2. `push <imm>` - Push Immediate

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-----------------------+
  | I | 0   1 |          imm          |
  +---+-------+-----------------------+

  push(sign_extend(imm, 6))
```

Pushes the sign-extended 6-bit `imm` value onto the data stack.

Implementations may choose to optimise `push` (or `push` + `shi` chains) by fusing it with the following instruction. A very good candidate would be to fuse `push` with the following `llw` or `slw` to create a single instruction that loads or stores a local variable onto or from the stack.

##### 3.4.3. `syscall` - System Call

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 0   0 | 0   0   0   0 |
  +---+-------+-------+---------------+

  if (km == 0) then fp, afp = afp, fp; epc = pc; estatus = status; ecause = 0x00; ie = 0; km = 1; pc = evec
```

Causes a system call exception. The following procedure happens:

1. If not already in kernel mode (`km == 0`), swap the `fp` and `afp` registers.
2. Save the address of the next instruction (`pc`) into the `epc` register.
3. Save the current `status` register into the `estatus` register.
4. Set the `ecause` register to `0x00` (syscall).
5. Clear the `ie` bit to disable interrupts.
6. Set the `km` bit in the `status` register to enter kernel mode.
7. Set the `pc` register to the value in the `evec` register.

Care should be taken to avoid this instruction (or anything that may cause an exception) until the `epc` and `estatus` registers have been saved, or they will be clobbered.

##### 3.4.4. `rets` - Return from Kernel

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 0   0 | 0   0   0   1 |
  +---+-------+-------+---------------+

  pc = epc; status = estatus; if (km == 0) then fp, afp = afp, fp
```

Returns from a kernel exception (interrupt, exception, breakpoint or syscall). The following procedure is performed:

1. Set the `pc` register to the value in the `epc` register.
2. Restore the `status` register from the `estatus` register.
3. If now in user mode (`km == 0`), swap the `fp` and `afp` registers.

##### 3.4.5. `beqz` - Branch if Equal to Zero

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 0   0 | 0   0   1   0 |
  +---+-------+-------+---------------+

  next_pc = pc + tos!; if (nos! == 0) then pc = next_pc
```

Branches to a target address if the popped next on stack value is equal to zero. The target address is calculated by adding the address of the next instruction to execute to the top of stack value which is always popped whether the branch is taken or not.

##### 3.4.6. `bnez` - Branch if Not Equal Zero

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 0   0 | 0   0   1   1 |
  +---+-------+-------+---------------+

  next_pc = pc + tos!; if (nos! != 0) then pc = next_pc
```

Branches to a target address if the popped next on stack value is not equal to zero. The target address is calculated by adding the address of the next instruction to execute to the top of stack value which is always popped whether the branch is taken or not.

##### 3.4.7. `dup` - Duplicate

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 0   0 | 0   1   0   0 |
  +---+-------+-------+---------------+

  push(tos)
```

Duplicates the top of stack value and pushes it onto the data stack. The new top of stack value is a copy of the previous top of stack value.

Implementations may choose to fuse this instruction with the following instruction for efficiency.

##### 3.4.8. `drop` - Drop

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 0   0 | 0   1   0   1 |
  +---+-------+-------+---------------+

  tos!
```

Pops the top value off the data stack, discarding it. The next on stack value becomes the new top of stack value.

Implementations may choose to fuse this instruction with the following instruction for efficiency.

##### 3.4.9. `over` - Over

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 0   0 | 0   1   1   0 |
  +---+-------+-------+---------------+

  push(nos)
```

Duplicates the next on stack value and pushes it onto the data stack. The new top of stack value is a copy of the previous next on stack value. In other words, it pulls the next on stack over the top of stack.

Implementations may choose to fuse this instruction with the following instruction for efficiency.

##### 3.4.10. `swap` - Swap

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 0   0 | 0   1   1   1 |
  +---+-------+-------+---------------+

  tos, nos = nos, tos
```

Swaps the top two values on the data stack such that the top of stack value becomes the next on stack value, and the next on stack value becomes the top of stack value.

Implementations may choose to fuse this instruction with the following instruction for efficiency.

##### 3.4.11. `add` - Add

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 0   0 | 1   0   0   0 |
  +---+-------+-------+---------------+

  push(nos! + tos!)
```

Adds the top two values on the data stack which are popped and the result pushed on the top of the stack.

If wanting to add double-words with carry, use the `ltu` instruction to read the carry flag and add to the upper half.

##### 3.4.12. `sub` - Subtract

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 0   0 | 1   0   0   1 |
  +---+-------+-------+---------------+

  push(nos! - tos!)
```

Subtracts the top two values on the data stack which are popped and the result pushed on the top of the stack.

If wanting to subtract double-words with borrow, use the `ltu` instruction to read the borrow flag and subtract from the upper half.

If wanting to negate a value, push zero onto the stack first then subtract. Reverse subtract can be done by `swap` followed by `sub`.

##### 3.4.13. `ltu` - Less Than Unsigned

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 0   0 | 1   0   1   0 |
  +---+-------+-------+---------------+

  push(unsigned(nos! < tos!) ? 1 : 0)
```

Compares the top two values on the data stack as unsigned integers, popping both operands. If the next on stack value is less than the top of stack value, a 1 is pushed onto the stack; otherwise, a 0 is pushed.

The `gtu` pseudo-instruction may be implemented as `swap` followed by `ltu`. `leu` is `gtu` followed by `bnot`. `geu` is `ltu` followed by `bnot`.

This instruction can also be used to read the carry flag for multi-precision arithmetic. Implementations may choose to fuse typical sequences of stack ops, `add`/`sub`, and `ltu` into a single multi-precision add-with-carry or subtract-with-borrow instruction for efficiency. Compilers should ensure they use a canonical sequence of instructions to allow implementations to recognize these patterns.

##### 3.4.14. `lt` - Less Than

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 0   0 | 1   0   1   1 |
  +---+-------+-------+---------------+

  push(signed(nos! < tos!) ? 1 : 0)
```

Compares the top two values on the data stack as signed integers, popping both operands. If the next on stack value is less than the top of stack value, a 1 is pushed onto the stack; otherwise, a 0 is pushed.

The `bnot` pseudo-instruction may be implemented as `push 1` followed by `ltu`. The `gt` pseudo-instruction may be implemented as `swap` followed by `lt`. `le` is `gt` followed by `bnot`. `ge` is `lt` followed by `bnot`.


##### 3.4.15. `and` - Bitwise AND

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 0   0 | 1   1   0   0 |
  +---+-------+-------+---------------+

  push(nos! & tos!)
```

Performs a bitwise AND operation on the top two values on the data stack which are popped and the result pushed on the top of the stack.


##### 3.4.16. `or` - Bitwise OR

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 0   0 | 1   1   0   1 |
  +---+-------+-------+---------------+

  push(nos! | tos!)
```

Performs a bitwise OR operation on the top two values on the data stack which are popped and the result pushed on the top of the stack.

##### 3.4.17. `xor` - Bitwise XOR

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 0   0 | 1   1   1   0 |
  +---+-------+-------+---------------+

  push(nos! ^ tos!)
```

Performs a bitwise XOR operation on the top two values on the data stack which are popped and the result pushed on the top of the stack.

The `not` pseudo-instruction may be implemented as `push -1` followed by `xor`. The `eq` pseudo-instruction may be implemented as `xor` followed by `bnot`. The `ne` pseudo-instruction may be implemented as `xor` followed by `bnot`, `bnot`.


##### 3.4.18. `fsl` - Funnel Shift Left

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 0   0 | 1   1   1   1 |
  +---+-------+-------+---------------+

  push((({ros!, nos!} << (tos! & (2*WORDSIZE - 1))) >> WORDSIZE) & WORDMASK)
```

Shifts the double word formed by concatenating the third on stack and next on stack values left by the number of bits specified in the top of stack value with a funnel shifter. The upper word of the result replaces the top of stack value and pops the next and third on stack.

This operation can be used to implement a left shift, right shift, and arithmetic right shift.

##### 3.4.19. `push <reg>` - Push Register

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+-------+-------+
  | O | 0   0 | 0   1 | 0   0 | <reg> |
  +---+-------+-------+-------+-------+

  push(<reg>)
```

Pushes the specified register to the stack.

See the section 2 for the list of available registers and their numbers.

##### 3.4.20. `pop <reg>` - Pop Register

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+-------+-------+
  | O | 0   0 | 0   1 | 0   1 | <reg> |
  +---+-------+-------+-------+-------+

  <reg> = tos!
```

Pops the top of stack value and stores it into the specified register.

The `pop pc` instruction has an alias of `ret` and `jumpp`.

See the section 2 for the list of available registers and their numbers.

##### 3.4.21. `add <reg>` - Add Register

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+-------+-------+
  | O | 0   0 | 0   1 | 1   0 | <reg> |
  +---+-------+-------+-------+-------+

  <reg> += tos!
```

Pops the top of stack value and increments the specified register by it.

The `add pc` instruction has an alias of `jump`, and note that the `pc` register holds the address of the next instruction to execute (after the `jump`).

See the section 2 for the list of available registers and their numbers.

##### 3.4.22. `pushcsr` - Push Computer Status Register

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+-------+-------+
  | O | 0   0 | 0   1 | 1   1 | 0   0 |
  +---+-------+-------+-------+-------+

  push(csr[tos!])
```

Pushes the CSR specified by the popped top of stack on to the stack.

Only the `depth` CSR may be read in user mode. An illegal instruction exception is expected to be raised if any other CSR is read in user mode.

##### 3.4.23. `popcsr` - Pop Computer Status Register

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+-------+-------+
  | O | 0   0 | 0   1 | 1   1 | 0   1 |
  +---+-------+-------+-------+-------+

  csr[tos!] = nos!
```

Sets the CSR specified by the popped top of stack to the next on stack value (which is then popped).

This instruction is only available in kernel mode. An illegal instruction exception is expected to be raised if executed in user mode.

##### 3.4.24. `llw` - Load Local Word

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+-------+-------+
  | O | 0   0 | 0   1 | 1   1 | 1   0 |
  +---+-------+-------+-------+-------+

  push(mem[fp + tos!])
```

Loads a local variable word from main memory. The address is calculated by adding the frame pointer to the top of stack value (which is then popped). The loaded word replaces the top of stack value.

It is illegal to load a word from an unaligned address (that is, the lower 1 (16-bit) or 2 (32-bit) bits of the address are not zero). Implementations are expected to raise an exception if this occurs.

##### 3.4.25. `slw` - Store Local Word

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+-------+-------+
  | O | 0   0 | 0   1 | 1   1 | 1   1 |
  +---+-------+-------+-------+-------+

  mem[fp + tos!] = nos!
```

Stores a local variable word to main memory. The address is calculated by adding the frame pointer to the top of stack value (which is then popped). The value to be stored is taken from the next on stack value (which is then popped).

It is illegal to store a word to an unaligned address (that is, the lower 1 (16-bit) or 2 (32-bit) bits of the address are not zero). Implementations are expected to raise an exception if this occurs.

#### 3.5. Extended Arithmetic and Logic Instructions

##### 3.5.1. `div` - Signed Divide

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 1   0 | 0   0   0   0 |
  +---+-------+-------+---------------+

  if (tos! == 0) then raise { if (km == 0) then fp, afp = afp, fp; epc = pc; estatus = status; ecause = 0x40; ie = 0; km = 1; pc = evec } else
  push(signed(nos! / tos!))
```

Performs signed integer division on the top two values on the data stack which are popped and the result pushed on the top of the stack.

If a division by zero is attempted, implementations are expected to raise an division by zero exception. If this instruction is emulated, the exception can be simulated by loading `ecause` with `0x40` and jumping to `evec`.

##### 3.5.2. `divu` - Unsigned Divide

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 1   0 | 0   0   0   1 |
  +---+-------+-------+---------------+

  if (tos! == 0) then raise { if (km == 0) then fp, afp = afp, fp; epc = pc; estatus = status; ecause = 0x40; ie = 0; km = 1; pc = evec } else
  push(unsigned(nos! / tos!))
```

Performs unsigned integer division on the top two values on the data stack which are popped and the result pushed on the top of the stack.

If a division by zero is attempted, implementations are expected to raise an division by zero exception. If this instruction is emulated, the exception can be simulated by loading `ecause` with `0x40` and jumping to `evec`.

##### 3.5.3. `mod` - Signed Modulus

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 1   0 | 0   0   1   0 |
  +---+-------+-------+---------------+

  if (tos! == 0) then raise { if (km == 0) then fp, afp = afp, fp; epc = pc; estatus = status; ecause = 0x40; ie = 0; km = 1; pc = evec } else
  push(signed(nos! % tos!))
```

Performs signed integer modulus on the top two values on the data stack which are popped and the result pushed on the top of the stack.

If a modulus by zero is attempted, implementations are expected to raise an division by zero exception. If this instruction is emulated, the exception can be simulated by loading `ecause` with `0x40` and jumping to `evec`.

##### 3.5.4. `modu` - Unsigned Modulus

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 1   0 | 0   0   1   1 |
  +---+-------+-------+---------------+

  if (tos! == 0) then raise { if (km == 0) then fp, afp = afp, fp; epc = pc; estatus = status; ecause = 0x40; ie = 0; km = 1; pc = evec } else
  push(unsigned(nos! % tos!))
```

Performs unsigned integer modulus on the top two values on the data stack which are popped and the result pushed on the top of the stack.

If a modulus by zero is attempted, implementations are expected to raise an division by zero exception. If this instruction is emulated, the exception can be simulated by loading `ecause` with `0x40` and jumping to `evec`.

##### 3.5.5. `mul` - Multiply

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 1   0 | 0   1   0   0 |
  +---+-------+-------+---------------+

  push((nos! * tos!) & WORDMASK)
```

Multiplies the top two values on the data stack which are popped and the result pushed on the top of the stack. Only the least significant `WORDSIZE` bits of the result are kept; the rest are discarded.

If wanting to multiply double-words, use sequences of `mul`, `mulh` and `add` instructions to implement multi-precision multiplication. Implementations may choose to fuse typical sequences of stack ops, `mul`, and `add` into a single multi-precision multiply-and-accumulate instruction for efficiency. Compilers should ensure they use a canonical sequence of instructions to allow implementations to recognize these patterns.

##### 3.5.6. `mulh` - Multiply High

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 1   0 | 0   1   0   1 |
  +---+-------+-------+---------------+

  push(unsigned(nos! * tos!) >> WORDSIZE)
```

Multiplies the top two values on the data stack which are popped. The high `WORDSIZE` bits of the result are then pushed on the data stack. The least significant `WORDSIZE` bits are discarded. The operation is performed treating both operands as unsigned integers.

If wanting to multiply double-words, use sequences of `mul`, `mulh`, and `add` instructions to implement multi-precision multiplication. Implementations may choose to fuse typical sequences of stack ops, `mul`, `mulh`, and `add` into a single multi-precision multiply-and-accumulate instruction for efficiency. Compilers should ensure they use a canonical sequence of instructions to allow implementations to recognize these patterns.

##### 3.5.7. `select` - Select

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 1   0 | 0   1   1   0 |
  +---+-------+-------+---------------+

  push(if tos! then nos! else ros!)
```

Selects between either the next on stack, if the top of stack is non-zero, or the third on stack, if the top of stack is zero. The top three stack values are popped and the selected value is pushed onto the top of the stack.

##### 3.5.8. `rot` - Rotate

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 1   0 | 0   1   1   1 |
  +---+-------+-------+---------------+

  temp = tos; tos = nos; nos = ros; ros = temp
```

Rotates the top three stack items such that the top on stack is rotated into being the third on stack. In other words, if the top three values are `A`, `B`, and `C`, they become `B`, `C`, and `A` after the operation.

##### 3.5.9. `srl` - Shift Right Logical

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 1   0 | 1   0   0   0 |
  +---+-------+-------+---------------+

  push((unsigned(nos!) >> (tos! & (WORDSIZE - 1))) & WORDMASK)
```

Shifts the next on stack value right logically by the number of bits specified in the top of stack value which are popped and the result pushed on the top of the stack. Only the least significant `WORDSIZE` bits of the result are kept; the rest are discarded. The shift amount is masked to be within 0 to `WORDSIZE - 1`.

##### 3.5.10. `sra` - Shift Right Arithmetic

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 1   0 | 1   0   0   1 |
  +---+-------+-------+---------------+

  push((signed(nos!) >> (tos! & (WORDSIZE - 1))) & WORDMASK)
```

Shifts the next on stack value right arithmetically by the number of bits specified in the top of stack value  which are popped and the result pushed on the top of the stack. In other words, the sign bit is copied into the vacated most significant bits which are popped and the result pushed on the top of the stack. The shift amount is masked to be within 0 to `WORDSIZE - 1`.

##### 3.5.11. `sll` - Shift Left Logical

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-------+---------------+
  | O | 0   0 | 1   0 | 1   0   1   0 |
  +---+-------+-------+---------------+

  push((nos! << (tos! & (WORDSIZE - 1))) & WORDMASK)
```

Shifts the next on stack value left logically by the number of bits specified in the top of stack value which are popped and the result pushed on the top of the stack. Only the least significant `WORDSIZE` bits of the result are kept; the rest are discarded. The shift amount is masked to be within 0 to `WORDSIZE - 1`.

#### 3.6. Extended Memory Instructions

##### 3.6.1. `lb` - Load Byte

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-----------+-----------+
  | O | 0   0 | 1   1   0 | 0   0   0 |
  +---+-------+-----------+-----------+

  push(sign_extend(mem:byte[tos!] & 0xFF, 8))
```

Loads a byte from main memory. The address is taken from the top of stack value (which is then popped). The loaded byte is sign-extended and replaces the top of stack value. If zero extension is required, one can AND with 0xFF after loading.

##### 3.6.2. `sb` - Store Byte

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-----------+-----------+
  | O | 0   0 | 1   1   0 | 0   0   1 |
  +---+-------+-----------+-----------+

  mem:byte[tos!] = nos!
```

Stores a byte to main memory. The address is taken from the top of stack value (which is then popped). The value to be stored is taken from the next on stack value (which is then popped). Only the least significant byte of the next on stack value is stored; the rest are ignored.

##### 3.6.3. `lh` - Load Halfword

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-----------+-----------+
  | O | 0   0 | 1   1   0 | 0   1   0 |
  +---+-------+-----------+-----------+

  push(sign_extend(mem:half[tos!] & 0xFFFF, 16))
```

Loads a half-word (16 bits) from main memory. The address is taken from the top of stack value (which is then popped). The loaded half-word is sign-extended and replaces the top of stack value. If zero extension is required, one can and with 0xFFFF after loading.

This instruction is identical to `lw` on a 16-bit machine and implementations can trigger the same implementation for both instructions.

It is illegal to load a half-word from an unaligned address (that is, the least significant bit of the address is not zero). Implementations are expected to raise an exception if this occurs.

##### 3.6.4. `sh` - Store Halfword

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-----------+-----------+
  | O | 0   0 | 1   1   0 | 0   1   1 |
  +---+-------+-----------+-----------+

  mem:half[tos!] = nos!
```

Stores a half-word (16 bits) to main memory. The address is taken from the top of stack value (which is then popped). The value to be stored is taken from the next on stack value (which is then popped). Only the least significant half-word of the next on stack value is stored; the rest are ignored.

This instruction is identical to `sw` on a 16-bit machine and implementations can trigger the same implementation for both instructions.

It is illegal to store a half-word to an unaligned address (that is, the least significant bit of the address is not zero). Implementations are expected to raise an exception if this occurs.

##### 3.6.5. `lw` - Load Word

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-----------+-----------+
  | O | 0   0 | 1   1   0 | 1   0   0 |
  +---+-------+-----------+-----------+

  push(mem[tos!])
```

Loads a word from main memory. The address is taken from the top of stack value which is popped and the result pushed on the top of the stack.

It is illegal to load a word from an unaligned address (that is, the lower 1 (16-bit) or 2 (32-bit) bits of the address are not zero). Implementations are expected to raise an exception if this occurs.

##### 3.6.6. `sw` - Store Word

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-----------+-----------+
  | O | 0   0 | 1   1   0 | 1   0   1 |
  +---+-------+-----------+-----------+

  mem[tos!] = nos!
```

Stores a word to main memory. The address is taken from the top of stack value (which is then popped). The value to be stored is taken from the next on stack value (which is then popped).

It is illegal to store a word to an unaligned address (that is, the lower 1 (16-bit) or 2 (32-bit) bits of the address are not zero). Implementations are expected to raise an exception if this occurs.

##### 3.6.7. `lnw` - Load Next Word

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-----------+-----------+
  | O | 0   0 | 1   1   0 | 1   1   0 |
  +---+-------+-----------+-----------+

  push(mem[ar]); ar += WORDBYTES
```

Pushes a word from main memory onto the data stack from the address in the `ar` register. The `ar` register is then incremented by the number of bytes in a word. This can be used to implement more efficient memory copies or for loops over a block of memory.

It is illegal to load a word from an unaligned address (that is, the lower 1 (16-bit) or 2 (32-bit) bits of the address are not zero). Implementations are expected to raise an exception if this occurs.

##### 3.6.8. `snw` - Store Next Word

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-----------+-----------+
  | O | 0   0 | 1   1   0 | 1   1   1 |
  +---+-------+-----------+-----------+

  mem[ar] = tos!; ar += WORDBYTES
```

Pops a word from the data stack and stores it to main memory at the address in the `ar` register. The `ar` register is then incremented by the number of bytes in a word. This can be used to implement more efficient memory copies or for loops over a block of memory.

It is illegal to store a word to an unaligned address (that is, the lower 1 (16-bit) or 2 (32-bit) bits of the address are not zero). Implementations are expected to raise an exception if this occurs.

#### 3.7. Extended Control Flow Instructions

##### 3.7.1. `call` - Call Function

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-----------+-----------+
  | O | 0   0 | 1   1   1 | 0   0   0 |
  +---+-------+-----------+-----------+

  ra = pc; pc += tos!
```

Calls a function at a pc-relative target address. The return address (the address of the instruction after the `call`) is saved to the `ra` register. The program counter is then set to the target address, which is calculated by adding the address of the next instruction to execute to the top of stack value (which is then popped).

##### 3.7.2. `callp` - Call Function Pointer

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+-----------+-----------+
  | O | 0   0 | 1   1   1 | 0   0   1 |
  +---+-------+-----------+-----------+

  ra = pc; pc = tos!
```

Calls a function at an absolute target address. The return address (the address of the instruction after the `call`) is saved to the `ra` register. The program counter is then set to the top of stack value (which is then popped).

## 4. Calling Convention

By convention, the frame stack grows downwards from the top of memory, and `fp` always points to the bottom of the stack frame, that is, the lowest address. Locals stored at a positive offset from `fp`. The return address and previous frame pointer are stored at the bottom of the stack frame at negative offsets from `fp`.

The following steps happen during a function call:

In the function prologue:

- Function arguments are pushed onto the data stack in reverse order (last argument first). The upper word of multi-word arguments are pushed first.
- The `call` instruction is used to invoke a function, which saves the return address to the `ra` register.
- The callee pushes `ra` and `fp` onto the data stack.
- The callee adjusts the frame pointer downward (subtracts) to allocate space for local variables, `ra` and `fp` using the `add fp` instruction with negative immediate.
- The callee saves the `ra` on the data stack to a negative 1 word offset from the new `fp` using the `slw` instruction.
- The callee saves the `fp` on the data stack to a negative 2 word offset from the new `fp` using the `slw` instruction.
- The callee accesses local variables using the `llw` and `slw` instructions.
- If the callee wants to, it can pop parameters into local variables.

In the function epilogue:

- Any parameters on the data stack must be popped off before returning from the callee.
- The return values are pushed onto the data stack in reverse order before executing the `ret` instruction to return to the caller. The upper word of multi-word return values are pushed first.
- The callee loads the `ra` from the negative 1 word offset from `fp` using the `llw` instruction.
- The callee loads the previous `fp` from the negative 2 word offset from `fp` using the `llw` instruction, popping it to `fp`.
- The callee jumps to the `ra` address to return to the caller.

In leaf functions which do not call any other functions, this can be simplified by skipping the saving and restoring of `fp` and `ra`. If the function needs no local variables, the frame pointer adjustment can also be skipped, or it may opt to store locals at negative 3+ word offsets from `fp`.

Presuming a 16-bit an example layout of stack frames with Fn 2 being a leaf function is as follows:

```text
Address:        Stack elements:
            +----------------------+  |
 0x5004     | Fn 0: Temp 0         |  |
            +----------------------+  |
 0x5002     | Fn 0: Local 1        |   >  Stack frame 0
            +----------------------+  |
 0x5000  +->| Fn 0: Local 0        |  | <-- Fn. 0's FP
         |  +----------------------+  |
 0x4FFE  |  | Fn 0: Ret Addr       |  | 
         |  +----------------------+  |
 0x4FFC  |  | Fn 0: Old FP         | /
         |  +----------------------+  
 0x4FFA  |  | Fn 1: Local 2         | \ 
         |  +----------------------+  |
 0x4FF8  |  | Fn 1: Local 1        |  |
         |  +----------------------+   >  Stack frame 1
 0x4FF6  |  | Fn 1: Local 0        |  | <-- Fn. 1's FP, Current FP
         |  +----------------------+  |
 0x4FF4  |  | Fn 1: Ret Addr       |  | 
         |  +----------------------+  |
 0x4FF2  +--| Fn 1: Old FP         | /  
            +----------------------+
 0x4FF0     | Fn 2: Local 0        | \
            +----------------------+   >  Stack frame 2
 0x4FEE     |                      |  | 
            \/\/\/\/\/\/\/\/\/\/\/\/
```

## 5. Exceptions and Interrupts

### 5.1. Exception and Interrupt Handling

Exceptions, interrupts, and syscalls are handled through a unified mechanism using the `ecause` and `evec` CSRs. When any of these events occur, the processor sets `ecause` to indicate the cause and jumps to the address in `evec`.

Macro instructions (extended instructions implemented in software) use a separate vector table mechanism described in section 5.3.

### 5.2. Exception / Syscall / Interrupt Sequence

Kernel mode can be entered through several mechanisms: system calls, interrupts, exceptions, and macro instruction handling.

Architecturally, interrupts and exceptions appear to occur (from the programmer's perspective) at the beginning of the instruction's execution. If an instruction during the course of execution causes an exception, the state of the processor will be preserved as if the instruction had not started executing yet, and instead the processor will execute the trap sequence.

The `epc` CSR is always set to the address of the next instruction to execute (`pc`), even if the exception occurred during the execution of an instruction. As such, `epc` may need to be adjusted in order to retry a failed instruction.

When entering kernel mode via syscall, exception, or interrupt, the following steps occur:

1. If `km` is not set, the `fp` and `afp` registers are swapped.
   - Note: hardware implementations may simply use muxes to swap them based on the `km` flag rather than actually swapping the values.
2. The current `status` CSR is stored in the `estatus` CSR.
3. The `km` flag is set to `1`.
4. The `ie` flag is cleared to `0`.
5. The `pc` is stored in the `epc` CSR.
6. The `ecause` CSR is set to the appropriate cause code (see section 2.6 for the cause table).
7. `pc` is set to the value in the `evec` CSR.

The exception handler can read `ecause` to determine the cause and dispatch accordingly. For example:

```text
_exception_handler:
  ; Category-level dispatch with 16-byte entries
  push ecause
  and 0xF0          ; Isolate category (0x00, 0x10, 0x20, ...)
  add pc            ; Jump into handler table
  ; Category 0 (syscall): 16 bytes
  jump _syscall_handler
  ; ... padding to 16 bytes ...
  ; Category 1 (invalid instruction): 16 bytes
  jump _invalid_instruction_handler
  ; ... etc ...
```

**Warning**: It is extremely important that the first operation in an interrupt/exception handler is to store the `epc` and `estatus` CSRs to the frame stack, being careful not to use more than four data stack slots in this process. The stack overflow exception will be triggered with at least four stack slots to spare, so this space is guaranteed to be available to an exception handler. This sequence avoids a stack overflow causing the `epc` and `estatus` to be lost or an infinite recursion if a stack overflow occurred. See the next section for more details.

### 5.3. Data Stack Overflow and Underflow

There should be two "high water marks" maintained by the hardware to track the depth of the data stack. One is the maximum depth of the data stack in user mode, and the other is the maximum depth of the data stack in kernel mode. These values are implementation defined, but must be at least 8 words before full for user mode and at least 4 words before full for kernel mode. The high water mark is different in kernel mode to avoid triggering an infinite looping stack overflow during the exception handling sequence.

If the depth exceeds the high water mark, an overflow exception is raised (`ecause` = 0x31). When leaving kernel mode, and the data stack depth exceeds the user mode high water mark, an overflow exception should be raised as soon as possible (that is, before executing the next user mode instruction).

If the depth is about to go below zero, an underflow exception is raised (`ecause` = 0x30). For example, if `depth == 0` and there is an attempt to read `tos`, an underflow exception is raised. If `depth == 1` and there is an attempt to read `nos`, an underflow exception is raised, but reading `tos` is allowed. The hardware must ensure that the underflow exception is raised before the depth variable is decremented such that it does not roll under and cause an infinite loop of underflow exceptions when the interrupt handler attempts to write to the data stack.

### 5.4. Macro Instruction Handling

Macro instructions use a separate vector table mechanism from regular exceptions. This allows extended instructions to be implemented efficiently in software without going through the general exception handler.

```text
   Fmt  7   6   5   4   3   2   1   0
  +---+-------+---+-------------------+
  | O | 0   0 | 1 |       imm         |
  +---+-------+---+-------------------+

  if (km == 0) then fp, afp = afp, fp; estatus = status; km = 1; ie = 0; epc = pc + 1; pc = imm * 8 + 0x100;
```

Any or all of the 32 instructions with binary 0b001XXXXX may be implemented in terms of the 25 basic instructions, or an implementation may choose to implement them in hardware to speed up the processor.

If they are not implemented in hardware, then executing one of these instructions will trigger the macro instruction trap sequence. The processor will enter kernel mode and jump to the appropriate macro instruction handler vector at address `imm * 8 + 0x100`.

The macro instruction vector table is located at addresses 0x0100-0x01FF, with each handler allocated 8 bytes:

```text
  Address   Instruction
  0x0100    div
  0x0108    divu
  0x0110    mod
  0x0118    modu
  0x0120    mul
  0x0128    mulh
  0x0130    select
  0x0138    rot
  0x0140    srl
  0x0148    sra
  0x0150    sll
  0x0158    (reserved)
  0x0160    (reserved)
  0x0168    (reserved)
  0x0170    (reserved)
  0x0178    (reserved)
  0x0180    lb
  0x0188    sb
  0x0190    lh
  0x0198    sh
  0x01A0    lw
  0x01A8    sw
  0x01B0    lnw
  0x01B8    snw
  0x01C0    call
  0x01C8    callp
  0x01D0    (reserved)
  0x01D8    (reserved)
  0x01E0    (reserved)
  0x01E8    (reserved)
  0x01F0    (reserved)
  0x01F8    (reserved)
```

Space should be reserved at 0x02XX for macro instruction handlers to jump to if needed, should they overflow the allotted 8-byte space.

Only 8 bytes are reserved for each macro instruction handler, so if more space is needed, the handler should jump to a different location in memory.

Note: The Invalid Instruction Exception (`ecause` = 0x10) does not include macro instructions (`0b001XXXXX`). Those instead trigger the specific macro instruction handler vector. If a specific instruction is implemented in hardware, it must not trigger an exception.

Note 2: The divide related instructions (`div`, `divu`, `mod`, `modu`) are defined to cause a division by zero exception if the divisor is zero. This can be simulated by writing the `ecause` for division by zero and jumping to the general exception vector at `evec`.

**Warning**: Macro instruction handlers must either use no more than 4 stack slots, or they must first save `epc` and `estatus` to the frame stack before using more than 4 stack slots. See the previous two sections for more details.

## 6. Memory Protection and Translation

This architecture supports memory protection and translation through the use of eight registers. The relevant registers are:

- `udmask`: User data memory mask: The mask for load/store memory addresses in user mode.
- `udset`: User data memory set: The bits to set for load/store memory addresses in user mode.
- `upmask`: User program memory mask: The mask for instruction fetch memory addresses in user mode.
- `upset`: User program memory set: The bits to set for instruction fetch memory addresses in user mode.

- `kdmask`: Kernel data memory mask: The mask for load/store memory addresses in kernel mode.
- `kdset`: Kernel data memory set: The bits to set for load/store memory addresses in kernel mode.
- `kpmask`: Kernel program memory mask: The mask for instruction fetch memory addresses in kernel mode.
- `kpset`: Kernel program memory set: The bits to set for instruction fetch memory addresses in kernel mode.

When accessing memory (either for instruction fetch or data load/store), the processor checks the current mode (user or kernel) and uses the corresponding memory mask and set registers to determine the physical address.

The physical address is calculated as follows for 32-bit machines:

```text
if (virtual_address & memory_mask) != 0 {
    // Memory Access Violation Exception (ecause = 0x22)
    if (km == 0) then fp, afp = afp, fp; estatus = status; km = 1; ie = 0; epc = pc; ecause = 0x22; pc = evec;
} else {
    physical_address = (virtual_address & ~memory_mask) | memory_set
}
```

Where `memory_mask` is one of the above memory mask registers, and `memory_set` is the corresponding memory set register.

And for 16-bit machines:

```text
if (virtual_address & (memory_mask << 12) ) != 0 {
    // Memory Access Violation Exception (ecause = 0x22)
    if (km == 0) then fp, afp = afp, fp; estatus = status; km = 1; ie = 0; epc = pc; ecause = 0x22; pc = evec;
} else {
    physical_address = (virtual_address & ~(memory_mask << 12)) | (memory_set << 12)
}
```

Note that this allows for a 16 bit system to have up to a 28 bit physical address space (16 bits of the `udset`, `upset`, `kdset`, or `kpset` register plus 12 least significant bits of the virtual address). Implementors are not obligated to implement all 28 bits, however, nor does RAM need to be available at all ranges of the 28 bit address bus.

## 7. Copyright

Copyright 2025 (c) Ryan "rj45" Sanche. All rights reserved.
