; Which condition does a subtraction leave behind? BZ works after SAB and BM
; does not, so "is the result negative" needs a different test - and an
; unsigned comparison wants the borrow anyway.
TXDATA  .equ $f201
CTRL    .equ $f200
pcsave  .equ $b004
        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$c000
        XAS

        ; B = 3 - 5, a borrow
        LDA #5
        LDB #3
        SAB
        BL l1
        LDA #'-'
        JSR putc
        JMP n1
l1:     LDA #'L'
        JSR putc
n1:     LDA #5
        LDB #3
        SAB
        BGZ g1
        LDA #'-'
        JSR putc
        JMP t2
g1:     LDA #'G'
        JSR putc

t2:     LDA #' '
        JSR putc
        ; B = 5 - 3, no borrow
        LDA #3
        LDB #5
        SAB
        BL l2
        LDA #'-'
        JSR putc
        JMP n2
l2:     LDA #'L'
        JSR putc
n2:     LDA #3
        LDB #5
        SAB
        BGZ g2
        LDA #'-'
        JSR putc
        JMP t3
g2:     LDA #'G'
        JSR putc

t3:     LDA #' '
        JSR putc
        ; and a plain word compare: is the sign visible after SUB dst,src?
        LDA #5
        LDB #3
        SUB B,A
        BM m3
        LDA #'-'
        JSR putc
        JMP done
m3:     LDA #'M'
        JSR putc

done:   LDA #$0001
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
