; Does reading the data register clear the "a byte is waiting" bit? If it does
; not, getc returns the same byte over and over and the line reader fills its
; buffer without ever seeing an end of line.
TXDATA  .equ $f201
CTRL    .equ $f200
pcsave  .equ $b004
scr1    .equ $b006
        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$bfe0
        XAS
        LDA #'?'
        JSR putc

w1:     LDAB CTRL           ; wait for a byte the long way round
        LDB #$0001
        NAB
        STB scr1
        LDA scr1
        LDB #0
        SUB B,A
        BZ w1

        LDAB CTRL           ; the status with a byte waiting
        JSR puthex
        LDAB TXDATA         ; read it
        JSR puthex
        LDAB CTRL           ; and the status straight afterwards
        JSR puthex
        LDAB TXDATA         ; read again: the same byte, or the next one?
        JSR puthex
        LDAB CTRL
        JSR puthex

        LDA #$0001
        STA $f900
halt:   JMP halt

puthex: STAB scr1+2
        SRAB
        SRAB
        SRAB
        SRAB
        LDB #$000f
        NAB
        JSR putnib
        LDAB scr1+2
        LDB #$000f
        NAB
        JSR putnib
        LDA #' '
        JMP putc
putnib: LDA #digits
        AAB
        LDAB [B]
        JMP putc
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
digits: .ascii "0123456789ABCDEF"
