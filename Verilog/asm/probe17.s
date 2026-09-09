; The FORTH's memory sizing finds only 12K - exactly the six block RAM pages -
; so every PSRAM page fails its signature test. Map physical pages 40 to 47
; into the window one at a time, write the same two words the sizer writes and
; print what reads back.
TXDATA  .equ $f201
CTRL    .equ $f200
pcsave  .equ $b004
scr1    .equ $b006
scr2    .equ $b00a
mp      .equ $b00c
MAPIMG  .equ $b100
WIN     .equ $7000
BANKPG  .equ 14
        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$bfe0
        XAS
        PAGE $1c,$f8,MAPIMG     ; capture the map that is running
        LDA #40
        STA mp

loop:   LDA #MAPIMG+BANKPG      ; point the window at physical page mp
        XAY
        LDAB mp+1
        STAB [Y]
        PAGE $0c,$f8,MAPIMG

        CLA                     ; which page this line is about
        LDAB mp+1
        JSR puthex
        LDA #':'
        JSR putc

        LDA WIN+$100            ; read first, exactly as the sizer does
        JSR puthex16
        LDA #'w'
        JSR putc
        LDA #$a5c3
        STA WIN+$100
        LDA #'1'
        JSR putc
        LDA #$5a3c
        STA WIN+$102
        LDA #'2'
        JSR putc
        LDA WIN+$100
        JSR puthex16
        LDA WIN+$102
        JSR puthex16
        LDA #$0d
        JSR putc
        LDA #$0a
        JSR putc

        LDA mp
        INA
        STA mp
        LDB #43
        SUB B,A
        BNZ loop

        LDA #$0001
        STA $f900
halt:   JMP halt

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
