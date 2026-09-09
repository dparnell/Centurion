TXDATA  .equ $f201
CTRL    .equ $f200
VARS    .equ $b000
scr1    .equ VARS+$00
scr2    .equ VARS+$02
pcsave  .equ VARS+$04
ndig    .equ VARS+$92
nq      .equ VARS+$94
nz      .equ VARS+$96
        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$c000
        XAS
        LDA #0
        JSR prnum
        JSR crlf
        LDA #7
        STA scr1
        LDA scr1            ; is a plain store and load of scr1 even working?
        JSR putax
        LDA #7
        JSR prnum
        LDA scr1            ; and what does prnum leave there?
        JSR putax
        JSR crlf
        LDA #256
        JSR prnum
        JSR crlf
        LDA #12345
        JSR prnum
        JSR crlf
        LDA #$0001
        STA $f900
halt:   JMP halt

prnum:  STA scr1
        LDB #0
        ADD B,A
        BM prneg
        JMP prpos
prneg:  LDA #'-'
        JSR putc
        LDA scr1
        IVA                 ; one's complement, then add one
        INA
        STA scr1
prpos:  LDA #0
        STA nz
        LDA #10000
        JSR prdig
        LDA #1000
        JSR prdig
        LDA #100
        JSR prdig
        LDA #10
        JSR prdig
        LDA scr1            ; the units digit always prints
        LDB #'0'
        ADD B,A
        STB scr2
        LDA scr2
        JMP putc

; Print how many times the power of ten in A goes into scr1, and take it out.
prdig:  STA ndig
        LDA #0
        STA nq
pd1:    LDA ndig
        LDB scr1
        SUB B,A             ; B = what is left, minus this power of ten
        BM pd2              ; gone negative: this digit is finished
        STB scr1
        LDA nq
        INA
        STA nq
        JMP pd1
pd2:    LDA nq
        BZ pd3
        LDA #1
        STA nz              ; a non-zero digit, so print the rest as well
pd3:    LDA nz
        BZ pd4
        LDA nq
        LDB #'0'
        ADD B,A
        STB scr2
        LDA scr2
        JSR putc
pd4:    RSR

putax:  STA $b010
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        JSR puthex
        LDA $b010
        JSR puthex
        LDA #' '
        JMP putc
puthex: STAB $b012
        SRAB
        SRAB
        SRAB
        SRAB
        LDB #$000f
        AND B,A
        JSR putnib
        LDAB $b012
        LDB #$000f
        AND B,A
        JMP putnib
putnib: LDA #hexd
        ADD B,A
        LDAB [B]
        JMP putc
hexd:   .ascii "0123456789ABCDEF"

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

