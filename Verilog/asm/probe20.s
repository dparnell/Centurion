; Walk a page of PSRAM one byte at a time. This is what a block move, a string
; compare or a dictionary search does, and it is the pattern a burst read is
; meant to help: without one, every second byte costs a full HyperBus access.
; The testbench counts the accesses and how long the core was held still.
TXDATA  .equ $f201
CTRL    .equ $f200
pcsave  .equ $b004
ptr     .equ $b010
cnt     .equ $b012
MAPIMG  .equ $b100
BANKPG  .equ 14
        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$bfe0
        XAS
        PAGE $1c,$f8,MAPIMG     ; point the window at physical page 40
        LDA #MAPIMG+BANKPG
        XAY
        LDAB #40
        STAB [Y]
        PAGE $0c,$f8,MAPIMG

again:  LDA #$7000
        STA ptr
        LDA #2048
        STA cnt
loop:   LDA ptr                 ; read every byte of it in order
        XAY
        LDAB [Y]
        LDA ptr
        INA
        STA ptr
        LDA cnt
        DCA
        STA cnt
        BNZ loop

        LDA #'.'                ; a dot per 2K walked: with nothing in this
        STAB pcsave             ; loop but memory, dots per second measures it
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
        JMP again
