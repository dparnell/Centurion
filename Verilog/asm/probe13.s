TXDATA  .equ $f201
CTRL    .equ $f200
VARS    .equ $b000
TIB     .equ $c000
scr1    .equ VARS+$00
scr2    .equ VARS+$02
pcsave  .equ VARS+$04
TOIN    .equ VARS+$0e
TIBLEN  .equ VARS+$10
WORDBUF .equ VARS+$20
fi      .equ VARS+$86
pwch    .equ VARS+$c6
        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$c000
        XAS
        ; put "1 2 +" in the input buffer by hand
        LDA #TIB
        XAY
        LDAB #'1'
        STAB [Y]
        LDA #TIB+1
        XAY
        LDAB #' '
        STAB [Y]
        LDA #TIB+2
        XAY
        LDAB #'2'
        STAB [Y]
        LDA #TIB+3
        XAY
        LDAB #' '
        STAB [Y]
        LDA #TIB+4
        XAY
        LDAB #'+'
        STAB [Y]
        LDA #5
        STA TIBLEN
        LDA #0
        STA TOIN
loop:   JSR parseword
        LDA #'<'
        JSR putc
        JSR pr_word
        LDA #'>'
        JSR putc
        CLA
        LDAB WORDBUF
        LDB #0
        SUB B,A
        BZ fin
        JMP loop
fin:    LDA #$0001
        STA $f900
halt:   JMP halt

parseword:
        LDA #0
        STAB WORDBUF
pw_skip: LDA TOIN           ; step over any spaces
        LDB TIBLEN
        SUB B,A
        BZ pw_end
        JSR tibchar
        STA pwch
        LDA #' '
        LDB pwch
        SUB B,A
        BNZ pw_copy
        LDA TOIN
        INA
        STA TOIN
        JMP pw_skip
pw_copy: LDA TOIN           ; then take everything up to the next one
        LDB TIBLEN
        SUB B,A
        BZ pw_end
        JSR tibchar
        STA pwch
        LDA #' '
        LDB pwch
        SUB B,A
        BZ pw_end
        CLA
        LDAB WORDBUF
        LDB #WORDBUF+1
        AAB
        STB scr1
        LDA scr1
        XAY
        LDAB pwch+1
        STAB [Y]
        CLA
        LDAB WORDBUF
        INAB
        STAB WORDBUF
        LDA TOIN
        INA
        STA TOIN
        JMP pw_copy
pw_end: RSR

; The character at TOIN, in the low half of A.
tibchar: LDA #TIB
        LDB TOIN
        AAB
        STB scr1
        LDA scr1
        XAY
        CLA                 ; a byte load leaves the high half alone
        LDAB [Y]
        RSR

pr_word: LDA #0
        STA fi
pw1:    LDA fi
        LDB #0
        LDBB WORDBUF
        SUB B,A
        BZ pw2
        LDA #WORDBUF+1
        LDB fi
        AAB
        STB scr1
        LDA scr1
        XAY
        LDAB [Y]            ; putc takes the character in the low half of A
        JSR putc
        LDA fi
        INA
        STA fi
        JMP pw1
pw2:    RSR

putc:   STAB pcsave         ; the low half of A is the character
pc1:    LDAB CTRL
        SLAB                ; bit 1 up to the sign, so a branch can test it
        SLAB
        SLAB
        SLAB
        SLAB
        SLAB
        BP pc1
        LDAB pcsave
        STAB TXDATA
        RSR

