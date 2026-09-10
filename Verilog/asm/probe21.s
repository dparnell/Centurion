; Run code out of PSRAM, which is what an operating system does and what none
; of the other benchmarks here do - the ROM is block RAM, so every program so
; far has been fetched for free. This copies a twelve byte loop to virtual
; 0x2000, which the identity map puts in PSRAM, and runs it there. Twelve bytes
; spans two of the bridge's eight byte lines, so a one line cache cannot hold
; the loop and misses on every line crossing: 2 accesses per iteration, where a
; cache of even two lines would fetch the loop once and then hit for ever.
TXDATA  .equ $f201
CTRL    .equ $f200
pcsave  .equ $b004
src     .equ $b006
dst     .equ $b008
i       .equ $b00a
cnt     .equ $b010          ; the loop counter the copied code steps
BODY    .equ $2000
        .org $8000
        .byte $01
start:  LDAB #$c4
        STAB CTRL
        LDA #$bfe0
        XAS

        LDA #bodysrc        ; copy the loop into PSRAM
        STA src
        LDA #BODY
        STA dst
        LDA #0
        STA i
cp1:    LDA i
        LDB #12
        SUB B,A
        BZ cp2
        LDA src             ; one byte at a time
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

cp2:    LDA #2000           ; how many times round the loop
        STA cnt
        JMP BODY            ; and run it from PSRAM

done:   LDA #'.'                ; a dot per run of the loop: here the memory is
        STAB pcsave             ; the bottleneck, because every instruction
                                ; fetched comes out of it
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
        JMP cp2                 ; round again for ever

scr     .equ $b00c
byt     .equ $b00e

; The loop, assembled by hand because it has to run at 0x2000 while living here.
;   2000  91 b0 10   LDA cnt
;   2003  39         DCA
;   2004  b1 b0 10   STA cnt
;   2007  15 f7      BNZ 2000
;   2009  71 xxxx    JMP done
bodysrc: .byte $91, $b0, $10
         .byte $39
         .byte $b1, $b0, $10
         .byte $15, $f7
         .byte $71
         .word done
