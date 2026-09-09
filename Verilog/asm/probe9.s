; One character per question, so a wrong answer says which primitive is at
; fault rather than that something somewhere is.
TXDATA  .equ $f201
CTRL    .equ $f200
pcsave  .equ $b004
        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$c000
        XAS

        LDA #$1234          ; 1: a word store and load at b100
        STA $b100
        LDA #0
        LDA $b100
        LDB #$1234
        SUB B,A
        BZ y1
        LDA #'a'
        JMP p1
y1:     LDA #'1'
p1:     JSR putc

        LDA #5              ; 2: ADD B,A leaves the sum in B
        LDB #3
        AAB
        STB $b102
        LDA $b102
        LDB #8
        SUB B,A
        BZ y2
        LDA #'b'
        JMP p2
y2:     LDA #'2'
p2:     JSR putc

        LDA #$00ff          ; 3: AND B,A leaves it in B
        LDB #$0f0f
        NAB
        STB $b102
        LDA $b102
        LDB #$000f
        SUB B,A
        BZ y3
        LDA #'c'
        JMP p3
y3:     LDA #'3'
p3:     JSR putc

        LDA #tbl            ; 4: LDAB through B
        LDB #2
        AAB
        LDAB [B]
        STAB $b102
        LDAB $b102
        LDB #'C'
        SUB B,A
        BZ y4
        LDA #'d'
        JMP p4
y4:     LDA #'4'
p4:     JSR putc

        LDA #$b200          ; 5: a byte store through Y
        XAY
        LDA #'Z'
        STAB [Y]
        LDAB $b200
        LDB #'Z'
        SUB B,A
        BZ y5
        LDA #'e'
        JMP p5
y5:     LDA #'5'
p5:     JSR putc

        LDA #9              ; 6: DCA and INA
        DCA
        DCA
        INA
        LDB #8
        SUB B,A
        BZ y6
        LDA #'f'
        JMP p6
y6:     LDA #'6'
p6:     JSR putc

        LDA #$0001
        STA $f900
halt:   JMP halt

tbl:    .ascii "ABCDEF"

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
