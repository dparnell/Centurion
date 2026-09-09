; Which way round does XFR move, and does it reach every register? DOCOL has to
; save the instruction pointer, which lives in Y, and there is no STY and no
; move into A in the XAB family - so a threaded interpreter stands or falls on
; this one instruction.

TXDATA  .equ $f201
CTRL    .equ $f200
scr1    .equ $b000
scr2    .equ $b002
pcsave  .equ $b004

        .org $8000
        .byte $01

start:  LDAB #$c4
        STAB CTRL
        LDA #$c000
        XAS

        LDA #$1111          ; put a known value in each register
        XAY
        LDA #$2222
        XAX
        LDA #$3333
        XAZ

        XFR A,Y             ; if this is A = Y, it prints 1111
        JSR putax
        XFR A,X             ; 2222 if so
        JSR putax
        XFR A,Z             ; 3333 if so
        JSR putax
        JSR crlf

        LDA #$4444          ; and the other direction: B = A?
        XFR B,A
        LDA #$0000
        XFR A,B
        JSR putax           ; 4444 if XFR moves dst from src
        JSR crlf

        LDA #$0001
        STA $f900
halt:   JMP halt

putc:   STAB pcsave
pc1:    LDAB CTRL
        SLAB
        SLAB
        SLAB
        SLAB
        SLAB
        SLAB
        BP pc1
        LDAB pcsave
        STAB TXDATA
        RSR

putax:  STA scr2
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        JSR puthex
        LDA scr2
        JSR puthex
        LDA #' '
        JMP putc

puthex: STAB scr1
        SRAB
        SRAB
        SRAB
        SRAB
        LDB #$000f
        NAB
        JSR putnib
        LDAB scr1
        LDB #$000f
        NAB
        JMP putnib

putnib: LDA #digits
        AAB
        LDAB [B]
        JMP putc

crlf:   LDA #13
        JSR putc
        LDA #10
        JMP putc

digits: .ascii "0123456789ABCDEF"
