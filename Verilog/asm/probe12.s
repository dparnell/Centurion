; Can a physical page be reached through a remapped window at all? The FORTH's
; memory sizing finds only the six pages of block RAM, so either the remap is
; not taking effect or the access through it is not reaching the PSRAM.
TXDATA  .equ $f201
CTRL    .equ $f200
V       .equ $b100
pcsave  .equ V+$00
scr1    .equ V+$02
MAPIMG  .equ V+$40
BANKWIN .equ $7000
BANKPG  .equ 14
PROBE1  .equ BANKWIN+$100
PROBE2  .equ BANKWIN+$102
sv1     .equ V+$06
sv2     .equ V+$08
        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$c000
        XAS
        PAGE $1c,$f8,MAPIMG     ; capture the running map

        ; page 40 is well inside the PSRAM, at physical 0x14000
        LDA #MAPIMG+BANKPG
        XAY
        LDAB #40
        STAB [Y]
        PAGE $0c,$f8,MAPIMG

        ; what does the window's entry read back as?
        LDA #MAPIMG+BANKPG
        XAY
        CLA
        LDAB [Y]
        JSR puthex
        LDA #' '
        JSR putc

        ; the exact sequence the memory sizing uses, with each step shown
        LDA #'a'
        JSR putc
        LDA PROBE1              ; save what is there
        LDA #'b'
        JSR putc
        STA sv1
        LDA PROBE2
        LDA #'c'
        JSR putc
        STA sv2
        LDA #$a5c3
        STA PROBE1
        LDA #'d'
        JSR putc
        LDA #$5a3c
        STA PROBE2
        LDA #'e'
        JSR putc
        LDA PROBE1              ; read the first back
        JSR putax
        LDA PROBE2              ; and the second
        JSR putax
        LDA sv1                 ; put the page back
        STA PROBE1
        LDA sv2
        STA PROBE2

        ; and the same for a page that is definitely block RAM
        LDA #MAPIMG+BANKPG
        XAY
        LDAB #22
        STAB [Y]
        PAGE $0c,$f8,MAPIMG
        LDA #$1234
        STA PROBE1
        LDA PROBE1
        JSR putax

        JSR crlf
        LDA #$0001
        STA $f900
halt:   JMP halt

putax:  STA scr1
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        JSR puthex
        LDA scr1
        JSR puthex
        LDA #' '
        JMP putc
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
        JMP putnib
putnib: LDA #digits
        AAB
        LDAB [B]
        JMP putc
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
