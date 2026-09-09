; MUL and DIV are in the opcode table but diag never uses them, so there is no
; worked example anywhere to copy. Which register ends up with the quotient,
; which with the remainder, and does the operand order matter? And separately:
; there is no move out of Z, but Z can be an operand of an arithmetic
; instruction, so "CLA / SUB Z,A" should leave the stack pointer in A. PICK
; needs that, because it indexes the stack by a value only known at run time.
TXDATA  .equ $f201
CTRL    .equ $f200
pcsave  .equ $b004
scr1    .equ $b006
scr2    .equ $b00a
r1      .equ $b010
r2      .equ $b012
        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$bfe0
        XAS

        LDA #'a'                ; DIV B,A with 100 over 7
        JSR putc
        LDA #100
        LDB #7
        DIV B,A
        STA r1
        STB r2
        JSR show

        LDA #'b'                ; the other way round
        JSR putc
        LDA #7
        LDB #100
        DIV B,A
        STA r1
        STB r2
        JSR show

        LDA #'c'                ; MUL B,A with 6 by 7
        JSR putc
        LDA #6
        LDB #7
        MUL B,A
        STA r1
        STB r2
        JSR show

        LDA #'d'                ; reading Z without a move
        JSR putc
        LDA #$1234
        XAZ
        CLA
        SUB Z,A
        STA r1
        LDA #0
        STA r2
        JSR show

        LDA #$0001
        STA $f900
halt:   JMP halt

show:   LDA r1
        JSR puthex16
        LDA r2
        JSR puthex16
        LDA #$0d
        JSR putc
        LDA #$0a
        JMP putc
puthex16: STA scr2
        CLA
        LDAB scr2
        JSR puthex
        CLA
        LDAB scr2+1
        JMP puthex
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
