; Probe the addressing modes an indirect threaded FORTH depends on, by running
; them on the real machine and printing the answers, rather than inferring them
; from a manual. What is actually in question is the semantics: whether a
; post-increment steps by one or by two for a word, and whether a jump through
; a register goes to the register or to what it points at.
;
;   make run SRC=probe.s FOR=60

TXDATA  .equ $f201
CTRL    .equ $f200
STACK   .equ $c000          ; block RAM: JSR pushes here, so it must be real
; Scratch lives in RAM, named rather than reserved: an .org into RAM would
; pad the ROM image out to it.
scr1    .equ $b000
scr2    .equ $b002
pcsave  .equ $b004

        .org $8000
        .byte $01           ; never executed; the reset vector jumps to 8001

start:  LDAB #$c4           ; 19200 baud, 7 data bits, no parity
        STAB CTRL
        LDA #STACK          ; JSR pushes the old X here; without this every
        XAS                 ; call returns to nowhere

        ; ---- does a post-increment step by two for a word load? ----
        LDA #table
        XAY
        LDA [Y++]
        JSR putax
        LDA [Y++]
        JSR putax
        JSR crlf

        ; ---- a data stack held in a register ----
        LDA #$c800
        XAZ
        LDA #$1122
        STA [--Z]
        LDA #$3344
        STA [--Z]
        LDA [Z++]
        JSR putax
        LDA [Z++]
        JSR putax
        JSR crlf

        ; ---- the two instructions an indirect threaded inner loop needs ----
        LDA #thread
        XAY
        LDX [Y++]
        JMP [[X]]

done:   JSR crlf
        LDA #$0001
        STA $f900           ; the testbench stops on this
halt:   JMP halt

; Two code field addresses. Each points at a cell holding the address of the
; machine code to run; that extra step is what lets a dictionary entry be code,
; a constant or a variable without the interpreter knowing which.
thread: .word cfa1, cfa2
cfa1:   .word code1
cfa2:   .word code2

code1:  LDA #'1'
        JSR putc
        LDX [Y++]
        JMP [[X]]
code2:  LDA #'2'
        JSR putc
        JMP done

table:  .word $abcd, $1234

; ---- helpers ----
; A carries the argument. JSR nests correctly: it puts the return address in X
; and pushes the old X, and RSR jumps to X and pops the old one back.

; Wait for the transmitter before handing it a byte. Without this the writes
; overwrite each other and almost nothing reaches the wire, which is exactly
; what programs/hellorld.txt gets wrong.
; XAB and friends are moves from A, not exchanges - XAB is B = A - so there is
; no move back the other way in that family. Rather than depend on a transfer
; whose direction is not yet confirmed, park the character in RAM.
putc:   STAB pcsave
pc1:    LDAB CTRL
        SLAB                ; bit 1 is "transmitter idle"; shift it up to the
        SLAB                ; sign so a branch can test it
        SLAB
        SLAB
        SLAB
        SLAB
        BP pc1
        LDAB pcsave
        STAB TXDATA
        RSR

; A carries the value in. The shifts here are arithmetic, so a byte with its
; top bit set sign extends and has to be masked before it can index anything -
; which is what made the first version of this print rubbish.
putax:  STA scr2            ; print A as four hex digits
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        JSR puthex          ; the high byte is now in the low half of A
        LDA scr2
        JSR puthex
        LDA #' '
        JMP putc

puthex: STAB scr1           ; print the low half of A as two hex digits
        SRAB
        SRAB
        SRAB
        SRAB
        LDB #$000f
        NAB                 ; B = B and A, so B is the high nibble, masked
        JSR putnib
        LDAB scr1
        LDB #$000f
        NAB
        JMP putnib

putnib: LDA #digits         ; B is 0..15
        AAB                 ; B = B + A
        LDAB [B]
        JMP putc

crlf:   LDA #13
        JSR putc
        LDA #10
        JMP putc

digits: .ascii "0123456789ABCDEF"

