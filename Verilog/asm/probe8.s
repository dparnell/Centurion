; A number printer and parser that work in any base, built out of only the
; idioms already confirmed on this machine. HEX and DECIMAL just set BASE.

TXDATA  .equ $f201
CTRL    .equ $f200
V       .equ $b100
BASE    .equ V+$00
nval    .equ V+$02
ndig    .equ V+$04
dptr    .equ V+$06
tmp     .equ V+$08
nq      .equ V+$0a
pcsave  .equ V+$0c
nneg    .equ V+$0e
dbuf    .equ V+$20          ; digits are built backwards in here

        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$c000
        XAS

        LDA #10
        STA BASE
        LDA #0
        JSR prnum
        LDA #7
        JSR prnum
        LDA #12345
        JSR prnum
        LDA #65535
        JSR prnum
        JSR crlf
        LDA #16
        STA BASE
        LDA #$beef
        JSR prnum
        LDA #$0010
        JSR prnum
        JSR crlf

        LDA #$0001
        STA $f900
halt:   JMP halt

; ---- print the unsigned value in A in the current base, then a space -------
prnum:  STA nval
        LDA #dbuf+8
        STA dptr
pn1:    JSR divmod          ; nval = nval / BASE, ndig = the remainder
        LDA #digits         ; turn the remainder into a character
        LDB ndig
        AAB
        LDAB [B]
        STAB tmp
        LDA dptr            ; and put it in front of the ones so far
        DCA
        STA dptr
        XAY
        LDAB tmp
        STAB [Y]
        LDA nval
        LDB #0
        AAB             ; ask the ALU whether anything is left
        BNZ pn1
pn2:    LDA dptr            ; print from the front of what was built
        LDB #dbuf+8
        SUB B,A
        BZ pn3
        LDA dptr
        XAY
        CLA                 ; a byte load leaves the high half alone
        LDAB [Y]
        JSR putc
        LDA dptr
        INA
        STA dptr
        JMP pn2
pn3:    LDA #' '
        JMP putc

; ---- nval = nval / BASE, ndig = nval mod BASE -----------------------------
divmod: LDA #0
        STA nq
dm1:    LDA BASE
        LDB nval
        SUB B,A             ; what is left after taking one more base away
        BM dm2
        STB nval
        LDA nq
        INA
        STA nq
        JMP dm1
dm2:    LDA nval
        STA ndig            ; what is left over is the digit
        LDA nq
        STA nval
        RSR

crlf:   LDA #13
        JSR putc
        LDA #10
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
