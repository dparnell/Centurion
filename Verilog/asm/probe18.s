; Where do ORI, ORE, IVA, SLR and SRR put their answers, and how much do the
; shifts shift? The register to register ADD and AND do not put theirs anywhere
; useful, and SUB B,A leaves its answer in A rather than B, so none of it can
; be assumed. What this found:
;
;   ORI X,Y and ORE X,Y put the result in Y, the second operand, as SUB does.
;   ORE is the exclusive one. IVA inverts A.
;   SRR is an ARITHMETIC right shift - it carries the sign down with it.
;   Both shifts move one more place than the count field holds, which is why
;   Assemble.py now biases SLR and SRR the way it always has INR and DCR.
;
; Lines f and g below are written in the assembler's terms, so f shifts one
; place and g four.
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

        LDA #'a'                ; ORI B,A
        JSR putc
        LDA #$0f00
        LDB #$00f0
        ORI B,A
        STA r1
        STB r2
        JSR show

        LDA #'b'                ; ORI A,B
        JSR putc
        LDA #$0f00
        LDB #$00f0
        ORI A,B
        STA r1
        STB r2
        JSR show

        LDA #'c'                ; ORE B,A
        JSR putc
        LDA #$0ff0
        LDB #$00ff
        ORE B,A
        STA r1
        STB r2
        JSR show

        LDA #'d'                ; ORE A,B
        JSR putc
        LDA #$0ff0
        LDB #$00ff
        ORE A,B
        STA r1
        STB r2
        JSR show

        LDA #'e'                ; IVA
        JSR putc
        LDA #$0f0f
        IVA
        STA r1
        STB r2
        JSR show

        LDA #'f'                ; SRR A,1: one place, sign propagated
        JSR putc
        LDA #$8001
        SRR A,1
        STA r1
        STB r2
        JSR show

        LDA #'g'                ; SLR A,4: four places
        JSR putc
        LDA #$0001
        SLR A,4
        STA r1
        STB r2
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
