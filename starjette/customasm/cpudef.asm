
; StarJ ISA Definition
; Contains instruction encodings, pseudo-ops, and memory bank definitions
; This file is included by both test kernels and standalone tests

; Opcode definitions
#subruledef op {
  ; Basic instruction set
  ; shi       => 0b1_???????
  ; push imm  => 0b01_??????
  halt        => 0b00_00_0000
  illegal     => 0b00_00_0001
  syscall     => 0b00_00_0010
  rets        => 0b00_00_0011
  beqz        => 0b00_00_0100
  bnez        => 0b00_00_0101
  swap        => 0b00_00_0110
  over        => 0b00_00_0111
  drop        => 0b00_00_1000
  dup         => 0b00_00_1001
  ltu         => 0b00_00_1010
  lt          => 0b00_00_1011
  add         => 0b00_00_1100
  and         => 0b00_00_1101
  xor         => 0b00_00_1110
  fsl         => 0b00_00_1111
  ; push reg  => 0b00_01_00??
  ; pop reg   => 0b00_01_01??
  ; add reg   => 0b00_01_10??
  pushcsr     => 0b00_01_1100
  popcsr      => 0b00_01_1101
  llw         => 0b00_01_1110
  slw         => 0b00_01_1111

  ; Extended instruction set
  div         => 0b00_10_0000
  divu        => 0b00_10_0001
  mod         => 0b00_10_0010
  modu        => 0b00_10_0011
  mul         => 0b00_10_0100
  mulh        => 0b00_10_0101
  select      => 0b00_10_0110
  rot         => 0b00_10_0111
  srl         => 0b00_10_1000
  sra         => 0b00_10_1001
  sll         => 0b00_10_1010
  or          => 0b00_10_1011
  sub         => 0b00_10_1100
  res0        => 0b00_10_1101
  res1        => 0b00_10_1110
  res2        => 0b00_10_1111
  lb          => 0b00_110_000
  sb          => 0b00_110_001
  lh          => 0b00_110_010
  sh          => 0b00_110_011
  lw          => 0b00_110_100
  sw          => 0b00_110_101
  lnw         => 0b00_110_110
  snw         => 0b00_110_111
  call        => 0b00_111_000
  callp       => 0b00_111_001
  res5        => 0b00_111_010
  res6        => 0b00_111_011
  res7        => 0b00_111_100
  res8        => 0b00_111_101
  res9        => 0b00_111_110
  res10       => 0b00_111_111
}

#subruledef reg {
  pc => 0b00
  fp => 0b01
  ra => 0b10
  ar => 0b11
}

#subruledef csr {
  status  => 0x0
  estatus => 0x1
  epc     => 0x2
  afp     => 0x3
  depth   => 0x4
  ecause  => 0x5
  evec    => 0x6
  udmask   => 0x8
  udset    => 0x9
  upmask   => 0xa
  upset    => 0xb
  kdmask   => 0xc
  kdset    => 0xd
  kpmask   => 0xe
  kpset    => 0xf
}

; the main instruction rules
#ruledef {
  ;  Fmt  7   6   5   4   3   2   1   0
  ; +---+---+---------------------------+
  ; | S | 1 |              imm          |
  ; +---+---+---+-----------------------+
  ; | I | 0   1 |          imm          |
  ; +---+-------+-----------------------+
  ; | O | 0   0 |         opcode        |
  ; +---+-------+-----------------------+

  {op:op} => 0b00`2 @ op`6

  shi {imm} => 0b1`1 @ imm`7

  push {imm} => {
    imm = ((imm & 0x8000) == 0) ? imm : -((!imm & 0xffff) + 1)
    assert(imm < (1<<5) && imm >= -(1<<5))
    0b01`2 @ imm`6
  }

  push_pcrel {label} => {
    imm = label - ($ + 2)
    imm = ((imm & 0x8000) == 0) ? imm : -((!imm & 0xffff) + 1)
    assert(imm < (1<<5) && imm >= -(1<<5))
    0b01`2 @ imm`6
  }

  push {imm} => {
    imm = ((imm & 0x8000) == 0) ? imm : -((!imm & 0xffff) + 1)
    assert(imm < (1<<(5+7)) && imm >= -(1<<(5+7)))
    0b01`2 @ (imm >> 7)`6 @ 0b1`1 @ (imm & 0x7F)`7
  }

  push_pcrel {label} => {
    imm = label - ($ + 3)
    imm = ((imm & 0x8000) == 0) ? imm : -((!imm & 0xffff) + 1)
    assert(imm < (1<<(5+7)) && imm >= -(1<<(5+7)))
    0b01`2 @ (imm >> 7)`6 @ 0b1`1 @ (imm & 0x7F)`7
  }

  push {imm} => {
    imm = ((imm & 0x8000) == 0) ? imm : -((!imm & 0xffff) + 1)
    assert(imm < (1<<(5+7+7)) && imm >= -(1<<(5+7+7)))
    0b01`2 @ (imm >> 14)`6 @ 0b1`1 @ ((imm >> 7) & 0x7F)`7 @ 0b1`1 @ (imm & 0x7F)`7
  }

  push_pcrel {label} => {
    imm = label - ($ + 4)
    imm = ((imm & 0x8000) == 0) ? imm : -((!imm & 0xffff) + 1)
    assert(imm < (1<<(5+7+7)) && imm >= -(1<<(5+7+7)))
    0b01`2 @ (imm >> 14)`6 @ 0b1`1 @ ((imm >> 7) & 0x7F)`7 @ 0b1`1 @ (imm & 0x7F)`7
  }

  push {reg:reg} => 0b00_01_00`6 @ reg`2
  pop  {reg:reg} => 0b00_01_01`6 @ reg`2
  add  {reg:reg} => 0b00_01_10`6 @ reg`2

  add {reg:reg}, {imm} => asm {
    push {imm}
    add {reg}
  }

  push {csr:csr} => {
    assert(csr < (1<<5) && csr >= -(1<<5))
    0b01`2 @ csr`6 @ 0b00_01_11_00
  }

  pop {csr:csr} => {
    assert(csr < (1<<5) && csr >= -(1<<5))
    0b01`2 @ csr`6 @ 0b00_01_11_01
  }

  beqz {label} => asm {
    push_pcrel {label}
    beqz
  }

  bnez {label} => asm {
    push_pcrel {label}
    bnez
  }

  jump {label} => asm {
    push_pcrel {label}
    add pc
  }

  call {label} => asm {
    push_pcrel {label}
    call
  }

  add {imm} => asm {
    push {imm}
    add
  }

  sub {imm} => asm {
    push {imm}
    sub
  }

  neg => asm {
    push 0
    swap
    sub
  }

  rsub {imm} => asm {
    push {imm}
    swap
    sub
  }

  ltu {imm} => asm {
    push {imm}
    ltu
  }

  geu {imm} => asm {
    push {imm}
    geu
  }

  gtu {imm} => asm {
    push {imm}
    gtu
  }

  leu {imm} => asm {
    push {imm}
    leu
  }

  lt {imm} => asm {
    push {imm}
    lt
  }

  ge {imm} => asm {
    push {imm}
    ge
  }

  gt {imm} => asm {
    push {imm}
    gt
  }

  eq {imm} => asm {
    push {imm}
    eq
  }

  ne {imm} => asm {
    push {imm}
    ne
  }

  le {imm} => asm {
    push {imm}
    le
  }

  geu => asm {
    ltu
    bnot
  }

  gtu => asm {
    swap
    ltu
  }

  leu => asm {
    swap
    geu
  }

  ge => asm {
    lt
    bnot
  }

  gt => asm {
    swap
    lt
  }

  le => asm {
    swap
    ge
  }

  eq => asm {
    xor
    bnot
  }

  ne => asm {
    xor
    push 0
    gtu
  }

  and {imm} => asm {
    push {imm}
    and
  }

  or {imm} => asm {
    push {imm}
    or
  }

  xor {imm} => asm {
    push {imm}
    xor
  }

  not => asm {
    push -1
    xor
  }

  bnot => asm {
    push 1
    ltu
  }

  fsl {imm} => asm {
    push {imm}
    fsl
  }

  llw {imm} => asm {
    push {imm}
    llw
  }

  slw {imm} => asm {
    push {imm}
    slw
  }

  div {imm} => asm {
    push {imm}
    div
  }

  divu {imm} => asm {
    push {imm}
    divu
  }

  mod {imm} => asm {
    push {imm}
    mod
  }

  modu {imm} => asm {
    push {imm}
    modu
  }

  srl {imm} => asm {
    push {imm}
    srl
  }

  sra {imm} => asm {
    push {imm}
    sra
  }

  sll {imm} => asm {
    push {imm}
    sll
  }

  failnez => asm {
    beqz $+4
    push 0
    halt
  }

  faileqz => asm {
    bnez $+4
    push 0
    halt
  }

  li {reg:reg}, {imm} => asm {
    push {imm}
    pop {reg}
  }

  li {csr:csr}, {imm} => asm {
    push {imm}
    pop {csr}
  }

  ret ra => asm {
    push ra
    pop pc
  }

  ret => asm {
    pop pc
  }
}

; ==========================================
; Memory Bank Definitions
; ==========================================

; vector is the interrupt vector table
; Usually located at the start of program memory
#bankdef vector
{
  #bits 8        ; program memory is byte-addressed
  #addr 0x0000   ; vector table starts at address 0x0
  #size 0x0500   ; size can be adjusted as needed
  #outp 0        ; emit to the rom file starting at address 0x0
}

; code bank is the main program memory bank
#bankdef code
{
  #bits 8         ; program memory is byte-addressed
  #addr 0x0500    ; code bank starts after vector table
  #size 0xFB00    ; rest of program memory
  #outp 0x500 * 8 ; emit to the rom file starting at address 0x500
}

; data is the bank where strings, constants and pre-initialized
; values goes.
#bankdef data
{
  #bits 8          ; data memory is byte-addressed
  #addr 0x8000     ; data bank starts here -- can be adjusted
  #size 0x4000     ; some area of data memory reserved for IO
  #outp 0x10000*8  ; emit to the rom file starting at address 0x10000
}

; bss is the main data memory bank for uninitialized variables
#bankdef bss
{
  #bits 8
  #addr 0x0000
  #size 0x8000 ; first half of data memory is for BSS -- can be adjusted
  ; no #outp means won't be emitted to rom
}
