; SUB B,A sets the flags correctly, but where does it put the answer? Every
; loop that subtracts and stores the result depends on this.
TXDATA  .equ $f201
CTRL    .equ $f200
pcsave  .equ $b004
        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$c000
        XAS

        LDA #3              ; 10 - 3 = 7: which register ends up holding 7?
        LDB #10
        SUB B,A
        STA $b100           ; A afterwards
        STB $b102           ; B afterwards
        LDA $b102
        LDB #7
        SUB B,A
        BZ inb
        LDA #'-'
        JSR putc
        JMP c2
inb:    LDA #'B'
        JSR putc
c2:     LDA $b100
        LDB #7
        SUB B,A
        BZ ina
        LDA #'-'
        JSR putc
        JMP c3
ina:    LDA #'A'
        JSR putc

c3:     LDA #3              ; and the same for SAB, the implicit form
        LDB #10
        SAB
        STA $b100
        STB $b102
        LDA $b102
        LDB #7
        SUB B,A
        BZ sinb
        LDA #'-'
        JSR putc
        JMP c4
sinb:   LDA #'b'
        JSR putc
c4:     LDA $b100
        LDB #7
        SUB B,A
        BZ sina
        LDA #'-'
        JSR putc
        JMP done
sina:   LDA #'a'
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
