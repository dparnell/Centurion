; What does getc actually return? The line reader comes back with ninety
; characters when six were typed, so either the "a byte is waiting" test is
; wrong or reading the data register does not clear it.
TXDATA  .equ $f201
CTRL    .equ $f200
pcsave  .equ $b004
scr1    .equ $b006
n       .equ $b008
        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$bfe0
        XAS
        LDA #'?'            ; so the testbench knows to start typing
        JSR putc
        LDA #0
        STA n
loop:   JSR getc            ; eight characters, printed as hex
        LDB #$7f
        NAB
        STB scr1
        LDA scr1
        JSR puthex
        LDA #' '
        JSR putc
        LDA n
        INA
        STA n
        LDB #8
        SUB B,A
        BZ fin
        JMP loop
fin:    LDA #$0001
        STA $f900
halt:   JMP halt

getc:   LDAB CTRL
        SLAB
        SLAB
        SLAB
        SLAB
        SLAB
        SLAB
        SLAB
        BP getc
        LDAB TXDATA
        RSR

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
