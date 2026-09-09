TXDATA  .equ $f201
CTRL    .equ $f200
VARS    .equ $b000
TIB     .equ $c000
TIBSZ   .equ 128
scr1    .equ VARS+$00
scr2    .equ VARS+$02
pcsave  .equ VARS+$04
TOIN    .equ VARS+$0e
TIBLEN  .equ VARS+$10
WORDBUF .equ VARS+$20
fi      .equ VARS+$86
pwch    .equ VARS+$c6
rlch    .equ VARS+$c4
        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$bfe0
        XAS
        LDA #'?'            ; say something so the testbench starts typing
        JSR putc
        JSR crlf
loop:   JSR readline
        LDA #'R'            ; did readline come back at all?
        JSR putc
        STA TIBLEN
        LDA #0
        STA TOIN
w1:     JSR parseword
        LDA #'<'
        JSR putc
        JSR pr_word
        LDA #'>'
        JSR putc
        CLA
        LDAB WORDBUF
        LDB #0
        SUB B,A
        BZ done
        JMP w1
done:   JSR crlf
        LDA #$0001
        STA $f900
halt:   JMP halt

readline:
        LDA #0
        STA TIBLEN
rl1:    JSR getc
        LDB #$7f
        NAB                 ; B = the character, seven bits
        STB rlch
        LDA #13             ; end of line, either way round: a terminal sends
        LDB rlch            ; a carriage return and a file has a newline
        SUB B,A
        BZ rl_done
        LDA #10
        LDB rlch
        SUB B,A
        BZ rl_done
        LDA #8
        LDB rlch
        SUB B,A
        BZ rl_bs
        LDA #TIBSZ-1        ; is there room?
        LDB TIBLEN
        SUB B,A
        BZ rl1
        LDA #TIB
        LDB TIBLEN
        AAB
        STB scr1
        LDA scr1
        XAY
        LDAB rlch+1         ; the low half is where the character is
        STAB [Y]
        LDA TIBLEN
        INA
        STA TIBLEN
        LDA rlch            ; echo it
        JSR putc
        JMP rl1
rl_bs:  LDA TIBLEN
        LDB #0
        SUB B,A
        BZ rl1
        LDA TIBLEN
        DCA
        STA TIBLEN
        LDA #8
        JSR putc
        LDA #' '
        JSR putc
        LDA #8
        JSR putc
        JMP rl1
rl_done: JSR crlf
        LDA TIBLEN
        RSR

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

getc:   LDAB CTRL           ; wait for a byte and return it in the low half of A
        SLAB                ; bit 0 up to the sign
        SLAB
        SLAB
        SLAB
        SLAB
        SLAB
        SLAB
        BP getc
        LDAB TXDATA
        RSR

crlf:   LDA #13
        JSR putc
        LDA #10
        JMP putc

