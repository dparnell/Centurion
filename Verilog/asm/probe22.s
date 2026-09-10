; Run a routine sized loop out of PSRAM. probe21 does this with twelve bytes,
; which four eight byte cache lines hold comfortably; this one is 256 bytes, so
; it fits in a cache of 32 lines and thrashes in one of four. Real code is this
; size or larger, which makes this the benchmark for how many lines are worth
; having.
TXDATA  .equ $f201
CTRL    .equ $f200
pcsave  .equ $b004
src     .equ $b006
dst     .equ $b008
i       .equ $b00a
scr     .equ $b00c
byt     .equ $b00e
cnt     .equ $b010
BODY    .equ $2000
BODYLEN .equ 253
        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$bfe0
        XAS
        LDA #bodysrc
        STA src
        LDA #BODY
        STA dst
        LDA #0
        STA i
cp1:    LDA i
        LDB #BODYLEN
        SUB B,A
        BZ cp2
        LDA src
        LDB i
        AAB
        STB scr
        LDA scr
        XAY
        CLA
        LDAB [Y]
        STA byt
        LDA dst
        LDB i
        AAB
        STB scr
        LDA scr
        XAY
        LDAB byt+1
        STAB [Y]
        LDA i
        INA
        STA i
        JMP cp1
cp2:    LDA #200            ; times round the 256 byte loop
        STA cnt
        JMP BODY

done:   LDA #'.'
        STAB pcsave
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
        JMP cp2

; The body, assembled by hand because it runs at 0x2000 while living here: 241
; NOPs, then the counter and the jump back to the top of them.
bodysrc:
         .byte $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01
         .byte $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01
         .byte $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01
         .byte $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01
         .byte $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01
         .byte $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01
         .byte $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01
         .byte $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01
         .byte $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01
         .byte $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01
         .byte $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01
         .byte $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01
         .byte $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01
         .byte $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01
         .byte $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01
         .byte $01, $91, $b0, $10, $39, $b1, $b0, $10, $14, $03, $71, $20, $00
         .byte $71
         .word done
