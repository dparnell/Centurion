; Exactly when does BM branch after SUB B,A? The number printer's loop
; subtracts until the result goes negative, so this one answer decides whether
; that loop terminates. Prints M when it branches and . when it does not, for
; a set of pairs whose signs are known.
TXDATA  .equ $f201
CTRL    .equ $f200
pcsave  .equ $b004
a1      .equ $b006
b1      .equ $b008
        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$c000
        XAS

        LDA #10             ; 7 - 10, negative: expect M
        LDB #7
        JSR t
        LDA #10             ; 56 - 10, positive: expect .
        LDB #56
        JSR t
        LDA #10             ; 6 - 10, negative: expect M
        LDB #6
        JSR t
        LDA #10             ; 10 - 10, zero: expect .
        LDB #10
        JSR t
        LDA #10000          ; 256 - 10000, negative: expect M
        LDB #256
        JSR t
        LDA #100            ; 256 - 100, positive: expect .
        LDB #256
        JSR t
        LDA #$0001
        STA $f900
halt:   JMP halt

t:      SUB B,A
        BM tm
        LDA #'.'
        JMP putc
tm:     LDA #'M'
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
