; Test Kernel for StarJ
; Provides reset handler, exception handler using ecause/evec,
; and software implementations of extended instructions.
;
; This kernel is designed for running tests where:
; - syscall halts the processor with TOS as the exit code
; - Extended instructions are implemented via macro instruction vectors
; - All exceptions halt with the negated ecause as error code
;
; Usage: customasm -f binary -o test.bin starj_isa.asm test_kernel.asm test.asm

; ==========================================
; Vector Table (0x0000 - 0x00FF)
; Reset vector and exception handler
; ==========================================

#bank vector

; Reset vector at 0x0000
_reset_handler:
  push 0xffff
  pop fp        ; initialize kernel frame pointer
  push 0xdfff
  pop afp       ; initialize alternate (user) frame pointer

  ; Set up exception vector to point to our handler
  push _exception_handler
  pop evec

  jump _kernel_start

; Exception handler - uses ecause to determine cause
; Located after reset code, before macro instruction vectors
#addr 0x0020
_exception_handler:
  ; Check if this is a syscall (ecause == 0x00)
  ; For syscall: TOS is already the exit code, just halt
  ; For other exceptions: push negated ecause and halt
  push ecause
  bnez _exception_not_syscall
  ; It's a syscall - TOS is already the exit code
  drop          ; drop the ecause we pushed
  jump _halt

_exception_not_syscall:
  ; Not a syscall - negate ecause for error code
  ; ecause is already on stack from the bnez check
  neg           ; negate to get negative error code
  jump _halt

; ==========================================
; Extended Instruction Vectors (0x0100 - 0x01FF)
; Each vector is 8 bytes
; These use the macro instruction trap mechanism,
; NOT the ecause/evec mechanism.
; ==========================================

#addr 0x0100
_vector_div:
  jump _div
#addr 0x0108
_vector_divu:
  jump _divu
#addr 0x0110
_vector_mod:
  jump _mod
#addr 0x0118
_vector_modu:
  jump _modu
#addr 0x0120
_vector_mul:
  jump _mul
#addr 0x0128
_vector_mulh:
  jump _mulh
#addr 0x0130
_vector_select:
  beqz _select_false
  swap
  drop
  rets
_select_false:
  drop
  rets
#addr 0x0138
_vector_rot:
  ; Rotate: A, B, C -> B, C, A (TOS=A)
  swap    ;   -- B A C
  slw -6  ; B -- A C
  swap    ;   -- C A
  llw -6  ;   -- B C A
  rets
#addr 0x0140
_vector_srl:
  jump _srl
#addr 0x0148
_vector_sra:
  jump _sra
#addr 0x0150
_vector_sll:
  ; V << S === ( {V, 0} << S ) >> 16
  push 0
  swap
  fsl
  rets
#addr 0x0158
_vector_res0:
  ; Reserved - trigger invalid instruction via ecause
  push 0x10     ; Invalid instruction ecause
  neg
  jump _halt
#addr 0x0160
_vector_res1:
  push 0x10
  neg
  jump _halt
#addr 0x0168
_vector_res2:
  push 0x10
  neg
  jump _halt
#addr 0x0170
_vector_res3:
  push 0x10
  neg
  jump _halt
#addr 0x0178
_vector_res4:
  push 0x10
  neg
  jump _halt
#addr 0x0180
_vector_lb:
  jump _lb
#addr 0x0188
_vector_sb:
  jump _sb
#addr 0x0190
_vector_lh:
  jump _vector_lw
#addr 0x0198
_vector_sh:
  jump _vector_sw
#addr 0x01A0
_vector_lw:
  push fp
  sub
  llw
  rets
#addr 0x01A8
_vector_sw:
  push fp
  sub
  slw
  rets
#addr 0x01B0
_vector_lnw:
  push ar
  push fp
  sub
  llw
  add ar, 2
  rets
#addr 0x01B8
_vector_snw:
  push ar
  push fp
  sub
  slw
  add ar, 2
  rets
#addr 0x01C0
_vector_call:
  push epc
  push 1
  sub
  add
  jump _vector_callp
#addr 0x01C8
_vector_callp:
  push epc
  pop ra
  pop epc
  rets
#addr 0x01D0
_vector_res5:
  push 0x10
  neg
  jump _halt
#addr 0x01D8
_vector_res6:
  push 0x10
  neg
  jump _halt
#addr 0x01E0
_vector_res7:
  push 0x10
  neg
  jump _halt
#addr 0x01E8
_vector_res8:
  push 0x10
  neg
  jump _halt
#addr 0x01F0
_vector_res9:
  push 0x10
  neg
  jump _halt
#addr 0x01F8
_vector_res10:
  push 0x10
  neg
  jump _halt

; ==========================================
; Halt Implementation (0x0200)
; ==========================================

#addr 0x0200
_halt:
  push status
  or 0b100   ; set halt flag
  pop status
  _halt_loop: ; loop in case halt fails
    push 0
    beqz _halt_loop

; ==========================================
; Extended Instruction Implementations
; ==========================================

_srl:
  ; V >> S === ( {0, V} << (16-S) ) >> 16
  ; Input: Stack: S, V
  push 16
  swap
  sub     ; T = 16-S
  slw -6
  push 0
  swap
  llw -6
  fsl
  rets

_sra:
  ; Input: Stack: S, V
  push 16
  swap
  sub     ; T = 16-S
  over    ; Check V (nos)
  push 0
  lt      ; V < 0 ?
  neg     ; Mask (0 or -1)
  slw -6
  push 0
  swap
  llw -6
  fsl
  rets

; ==========================================
; Memory Ops
; ==========================================

_lb:
  dup
  and 1      ; Offset
  swap
  and 0xFFFE ; Aligned
  call _vector_lw
  swap       ; Offset, Word
  push 3
  call _vector_sll
  call _srl
  push 0xFF
  and
  dup
  push 0x80
  and
  push 0
  bnez _lb_neg
  rets
_lb_neg:
  or 0xFF00
  rets

_sb:
  push fp
  push -4
  add fp
  swap    ; Val, Addr
  push 0
  slw     ; Addr
  push 2
  slw     ; Val

  push 0
  llw
  push 0xFFFE
  and
  call _vector_lw ; Existing

  push 0
  llw
  push 1
  and
  push 3
  call _vector_sll
  push 0xFF
  over
  call _vector_sll
  not
  swap    ; ~Mask, Existing
  and

  push 2
  llw
  push 0xFF
  and
  ; Need Shift again. Using temp reg or recalc? Recalc safe.
  push 0
  llw
  push 1
  and
  push 3
  call _vector_sll
  or      ; NewWord

  push 0
  llw
  push 0xFFFE
  and
  call _vector_sw

  push 4
  add fp
  pop fp
  rets

; ==========================================
; Arithmetic
; ==========================================

_mul:
  push fp
  add fp, -8
  push 0
  slw     ; B
  push 2
  slw     ; A
  push 0
  push 4
  slw     ; Res=0
  push 16
  push 6
  slw     ; Count=16

_mul_loop:
  push 6
  llw
  beqz _mul_done

  push 0
  llw
  push 1
  and
  beqz _mul_skip
    push 2
    llw
    push 4
    llw
    add
    push 4
    slw
_mul_skip:
  push 2
  llw
  dup
  add
  push 2
  slw
  push 0
  llw
  push 1
  call _srl
  push 0
  slw
  push 6
  llw
  push -1
  add
  push 6
  slw
  jump _mul_loop

_mul_done:
  push 4
  llw
  add fp, 8
  swap
  pop fp
  rets

_mulh:
  push 0
  rets

_div_mod_u:
  ; Stack: D(tos), N(nos). Returns R, Q(tos)
  push fp
  add fp, -10
  ; 0:D, 2:N, 4:Q, 6:R, 8:Count
  push 0
  slw ; D
  push 2
  slw ; N
  push 0
  push 4
  slw ; Q=0
  push 0
  push 6
  slw ; R=0

  push 0
  llw ; D
  bnez _dmu_ok
    ; Div by zero
    push -1 ; Q
    push 0  ; R
    jump _dmu_ret_vals

_dmu_ok:
  push 16
  push 8
  slw ; Count=16

_dmu_loop:
  push 8
  llw
  beqz _dmu_done
  push -1
  add
  push 8
  slw

  ; R <<= 1
  push 6
  llw
  dup
  add
  push 6
  slw

  ; Bit = (N >> count) & 1
  push 2
  llw
  push 8
  llw
  call _srl
  push 1
  and

  ; R |= Bit
  push 6
  llw
  or
  push 6
  slw

  ; if R >= D
  push 0
  llw
  push 6
  llw
  geu
  beqz _dmu_loop
    ; R -= D
    push 0
    llw
    push 6
    llw
    sub
    push 6
    slw
    ; Q |= 1 << Count
    push 4
    llw
    push 1
    push 8
    llw
    call _vector_sll
    or
    push 4
    slw
    jump _dmu_loop

_dmu_done:
  push 6
  llw ; R
  push 4
  llw ; Q

_dmu_ret_vals:
  add fp, 10
  ; Stack: R, Q, OldFP
  swap ; R, OldFP, Q
  pop fp ; Stack: R, Q
  rets

_divu:
  call _div_mod_u
  swap
  drop
  rets

_modu:
  call _div_mod_u
  drop
  rets

_div:
  call _divu ; Signed support todo
  rets
_mod:
  call _modu
  rets

_kernel_start:
  ; Initialize kernel and user data segments to be at 0x10000
  push 0x10
  dup
  dup
  pop udset
  pop kdset

  push 0b10     ; usermode with interrupts enabled
  pop estatus   ; set initial status register
  push _start
  pop epc       ; set initial pc to start of code
  rets          ; return to epc to start execution

; ==========================================
; Code Bank - Test code goes here
; ==========================================

#bank code
_start:
