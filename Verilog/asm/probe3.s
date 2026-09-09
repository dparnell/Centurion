; What does the PAGE store direction actually put in memory? The FORTH kernel's
; memory sizing edits one entry of a 32 byte image of map 0 and loads the whole
; map back, which is only safe if the image it starts from is the map that is
; already running.

TXDATA  .equ $f201
CTRL    .equ $f200
scr1    .equ $b000
scr2    .equ $b002
pcsave  .equ $b004
ipsave  .equ $b006
fi      .equ $b008
MAPIMG  .equ $b060

        .org $8000
        .byte $01

start:  LDAB #$c4
        STAB CTRL
        LDA #$c000
        XAS

        PAGE $1c,$f8,MAPIMG     ; capture the running map first

        ; Does a PAGE block move leave the registers alone? The memory sizing
        ; loop keeps its counter in one and its scratch in others, so if it
        ; does not, that loop can never terminate.
        LDA #$1111
        XAY
        LDA #$2222
        XAX
        LDA #$3333
        XAZ
        LDA #$4444
        PAGE $0c,$f8,MAPIMG
        JSR putax               ; A, if PAGE leaves it alone
        XFR A,Y
        JSR putax
        STX scr2
        LDA scr2
        JSR putax
        JSR crlf
p2:     JSR crlf
        LDA #$0001
        STA $f900
halt:   JMP halt

putax:  STA scr2
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        SRA
        JSR puthex
        LDA scr2
        JSR puthex
        LDA #' '
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

puthex: STAB scr1
        SRAB
        SRAB
        SRAB
        SRAB
        LDB #$000f
        NAB
        JSR putnib
        LDAB scr1
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

digits: .ascii "0123456789ABCDEF"
