; Sieve of Eratosthenes
; Finds all prime numbers up to SIEVE_SIZE and returns their count
;
; This benchmark exercises:
; - Memory load/store operations (lb, sb)
; - Nested loops
; - Conditional branching
; - Arithmetic operations (add, mul, ltu, lt)
; - Stack manipulation (dup, drop, swap, over)
;
; The sieve array is stored in BSS starting at SIEVE_BASE
; Each byte represents whether that index is composite (1) or prime (0)

#include "../customasm/starj_cpudef.asm"
#include "../customasm/test_shim.asm"

; Configuration - adjust for longer/shorter runs
; SIEVE_SIZE of 1000 gives 168 primes
; SIEVE_SIZE of 10000 gives 1229 primes
; SIEVE_SIZE of 16000 gives 1862 primes (max for 16-bit data region)
#const SIEVE_SIZE = 16000
#const SIEVE_BASE = 0x4000   ; Use data memory region to avoid overwriting code

; Number of iterations for benchmarking
; Each iteration re-runs the entire sieve algorithm
#const ITERATIONS = 1

main:

    jump .iter_done

    ; Outer iteration loop - run sieve ITERATIONS times
    push ITERATIONS          ; iteration counter

.iter_loop:
    ; Stack: [iter]
    dup                      ; [iter, iter]
    beqz .iter_done          ; if iter == 0, done

    sub 1                    ; [iter-1]

    ; Check that the `depth` csr works as expected
    ; Note: the CSR number is pushed on the stack when the depth register is read so there's
    ; two items on the stack not the expected one.
    ; push depth               ; [iter, depth]
    ; sub 2                    ; [iter, depth-2]
    ; failnez                  ; fail here if not 0

    ; Run one iteration of the sieve
    call sieve               ; [iter, count]

    ; Check that the `sieve` function didn't leave garbage on the stack
    ; push depth               ; [iter, count, depth]
    ; sub 3                    ; [iter, count, depth-3]
    ; failnez                  ; fail here if not 0

    drop                     ; [iter] - discard the count
    jump .iter_loop

.iter_done:
    drop                     ; drop iter counter (which is 0)

    ; Run one final time to get and return the result
    call sieve               ; [count]

    drop

    call sieve

    halt

.catch_halt_fail:
    jump .catch_halt_fail

; Sieve subroutine - returns prime count on stack
; This is a leaf function, so we just preserve ra on the data stack
sieve:
    ; Initialize sieve array - mark all as potentially prime (0)
    ; We'll mark composites as 1

    ; First, zero out the entire sieve array
    push SIEVE_BASE          ; current address
    push SIEVE_SIZE          ; remaining count

.zero_loop:
    ; Stack: [addr, count]
    dup                      ; [addr, count, count]
    beqz .zero_done          ; if count == 0, done

    swap                     ; [count, addr]
    dup                      ; [count, addr, addr]
    push 0                   ; [count, addr, addr, 0]
    swap                     ; [count, addr, 0, addr]
    sb                       ; store 0 at addr; [count, addr]

    add 1                    ; addr++; [count, addr]
    swap                     ; [addr, count]
    sub 1                    ; count--; [addr, count]
    jump .zero_loop

.zero_done:
    drop                     ; drop count
    drop                     ; drop addr

    ; Mark 0 and 1 as not prime
    push 1
    push SIEVE_BASE
    sb                       ; sieve[0] = 1 (not prime)

    push 1
    push SIEVE_BASE
    add 1
    sb                       ; sieve[1] = 1 (not prime)

    ; Main sieve algorithm
    ; for i = 2; i * i <= SIEVE_SIZE; i++
    push 2                   ; i = 2

.outer_loop:
    ; Stack: [i]
    dup                      ; [i, i]
    dup                      ; [i, i, i]
    mul                      ; [i, i*i]
    push SIEVE_SIZE          ; [i, i*i, SIEVE_SIZE]
    swap                     ; [i, SIEVE_SIZE, i*i]
    lt                       ; [i, SIEVE_SIZE < i*i] (1 if we should stop)
    bnez .sieve_done         ; if i*i > SIEVE_SIZE, done

    ; Check if sieve[i] is still 0 (prime)
    dup                      ; [i, i]
    push SIEVE_BASE          ; [i, i, base]
    add                      ; [i, addr]
    lb                       ; [i, sieve[i]]
    bnez .next_i             ; if composite, skip to next i
    ; bnez consumed sieve[i], stack is now [i]

    ; Mark all multiples of i as composite
    ; for j = i * i; j < SIEVE_SIZE; j += i
    dup                      ; [i, i]
    dup                      ; [i, i, i]
    mul                      ; [i, j=i*i]

.inner_loop:
    ; Stack: [i, j]
    dup                      ; [i, j, j]
    push SIEVE_SIZE          ; [i, j, j, SIEVE_SIZE]
    ltu                      ; [i, j, j < SIEVE_SIZE]
    beqz .inner_done         ; if j >= SIEVE_SIZE, done with inner loop

    ; sieve[j] = 1 (mark as composite)
    dup                      ; [i, j, j]
    push SIEVE_BASE          ; [i, j, j, base]
    add                      ; [i, j, addr]
    push 1                   ; [i, j, addr, 1]
    swap                     ; [i, j, 1, addr]
    sb                       ; store 1 at sieve[j]; [i, j]

    ; j += i
    over                     ; [i, j, i]
    add                      ; [i, j+i]
    jump .inner_loop

.inner_done:
    drop                     ; drop j; [i]
    ; fall through to .next_i

.next_i:
    add 1                    ; i++
    jump .outer_loop

.sieve_done:
    drop                     ; drop i

    ; Count primes
    ; count = 0
    ; for k = 2; k < SIEVE_SIZE; k++
    ;   if sieve[k] == 0: count++

    push 0                   ; count = 0
    push 2                   ; k = 2

.count_loop:
    ; Stack: [count, k]
    dup                      ; [count, k, k]
    push SIEVE_SIZE          ; [count, k, k, SIEVE_SIZE]
    ltu                      ; [count, k, k < SIEVE_SIZE]
    beqz .count_done         ; if k >= SIEVE_SIZE, done

    ; Check sieve[k]
    dup                      ; [count, k, k]
    push SIEVE_BASE          ; [count, k, k, base]
    add                      ; [count, k, addr]
    lb                       ; [count, k, sieve[k]]
    bnez .count_next         ; if composite, skip

    ; Increment count
    swap                     ; [k, count]
    add 1                    ; [k, count+1]
    swap                     ; [count, k]

.count_next:
    add 1                    ; k++
    jump .count_loop

.count_done:
    drop                     ; drop k
    ; Stack: [count]

    ; Return via ra register
    ret ra
