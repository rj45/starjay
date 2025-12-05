; Kernel mode test shim

#bank vector

; Reset vector at 0x0000
_reset_handler:
  li fp, 0xffff        ; initialize kernel frame pointer
  li afp, 0xdfff       ; initialize alternate (user) frame pointer

  ; Set up exception vector to point to our handler
  li evec, _exception_handler

  jump _start

_exception_handler:
  push ecause

  ; negate ecause for error code, avoiding `sub` because it's an extended instruction
  xor -1
  add 1

  halt

_start:
