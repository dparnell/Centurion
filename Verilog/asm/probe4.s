; Does SAB set the sign flag that BM tests? The number printer's loop subtracts
; until the result goes negative, so if it does not, that loop never ends.
TXDATA  .equ $f201
CTRL    .equ $f200
pcsave  .equ $b004
        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$c000
        XAS

        LDA #5              ; B = 3 - 5, which is negative
        LDB #3
        SAB
        BM ok1
        LDA #'n'
        JSR putc
        JMP t2
ok1:    LDA #'y'
        JSR putc

t2:     LDA #3              ; B = 5 - 3, which is positive
        LDB #5
        SAB
        BM bad2
        LDA #'y'
        JSR putc
        JMP t3
bad2:   LDA #'n'
        JSR putc

t3:     LDA #5              ; B = 5 - 5, which is zero
        LDB #5
        SAB
        BZ ok3
        LDA #'n'
        JSR putc
        JMP t4
ok3:    LDA #'y'
        JSR putc

t4:     LDA #$0001
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
