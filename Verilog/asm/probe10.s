TXDATA  .equ $f201
CTRL    .equ $f200
VARS    .equ $b000
scr1    .equ VARS+$00
pcsave  .equ VARS+$04
BASE    .equ VARS+$14
nval    .equ VARS+$8e
nneg    .equ VARS+$90
nq      .equ VARS+$94
pcur    .equ VARS+$ac
pnext   .equ VARS+$ae
pcount  .equ VARS+$b0
npow    .equ VARS+$b2
pow     .equ VARS+$b4
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
        LDA #250
        JSR prnum
        LDA #12345
        JSR prnum
        JSR crlf
        LDA #16
        STA BASE
        LDA #$beef
        JSR prnum
        JSR crlf
        LDA #$0001
        STA $f900
halt:   JMP halt

prnum:  STA nval
        LDA #0              ; the sign has to come from an arithmetic operation,
        LDB nval            ; and SUB B,A computes B - A, so the value goes in B
        SUB B,A
        BM prneg
        JMP prpos
prneg:  LDA BASE            ; only base ten has negative numbers here
        LDB #10
        SUB B,A
        BNZ prpos
        LDA #'-'
        JSR putc
        LDA nval
        IVA
        INA
        STA nval
prpos:  LDA #1              ; powers[0] = 1
        STA pow
        LDA #0
        STA npow
pw1:    LDA npow            ; the power just built
        SLA
        LDB #pow
        AAB
        STB scr1
        LDA scr1
        XAY
        LDA [Y]
        STA pcur
        LDA #0              ; multiply it by the base
        STA pnext
        LDA BASE
        STA pcount
pw2:    LDA pcur
        LDB pnext
        AAB
        STB pnext
        LDA pcount
        DCA
        STA pcount
        LDB #0
        SUB B,A
        BNZ pw2
        LDA pnext           ; did it wrap round?
        LDB pcur
        SUB B,A
        BM pw3
        JMP pwdone
pw3:    LDA nval            ; is it already past the value?
        LDB pnext
        SUB B,A
        BM pw4
        JMP pwdone
pw4:    LDA npow
        INA
        STA npow
        SLA
        LDB #pow
        AAB
        STB scr1
        LDA scr1
        XAY
        LDA pnext
        STA [Y]
        JMP pw1
pwdone: LDA npow            ; now take each power out in turn
        SLA
        LDB #pow
        AAB
        STB scr1
        LDA scr1
        XAY
        LDA [Y]
        STA pcur
        LDA #0
        STA nq
        LDA pcur            ; show what is being taken out, and from what
        JSR pdbg
        LDA nval
        JSR pdbg
pd1:    LDA pcur
        LDB nval
        SUB B,A
        BM pd2
        STB nval
        LDA nq
        INA
        STA nq
        JMP pd1
pd2:    LDA #digits
        LDB nq
        AAB
        LDAB [B]
        JSR putc
        LDA npow
        LDB #0
        SUB B,A
        BZ pd3
        LDA npow
        DCA
        STA npow
        JMP pwdone
pd3:    LDA #' '
        JMP putc

digits: .ascii "0123456789ABCDEF"

pdbg:   STA $b120
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        JSR pdb2
        LDA $b120
        JSR pdb2
        LDA #'/'
        JMP putc
pdb2:   STAB $b122
        SRAB
        SRAB
        SRAB
        SRAB
        LDB #$000f
        NAB
        JSR pdb3
        LDAB $b122
        LDB #$000f
        NAB
        JMP pdb3
pdb3:   LDA #dg2
        AAB
        LDAB [B]
        JMP putc
dg2:    .ascii "0123456789ABCDEF"

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

crlf:   LDA #13
        JSR putc
        LDA #10
        JMP putc

