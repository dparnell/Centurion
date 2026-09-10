; A mapping and memory test of our own, meant to be watched rather than waited
; on. diag's equivalent is a poor instrument for working on the memory: it
; prints nothing for minutes, only looks for the exit key at the end of a round
; of 65536 passes, reports its verdict through a JSR to virtual 0x07cc which
; lands in low RAM that nothing ever writes, and stops reading the serial port
; so the status dump cannot be asked for one either. A run that fails tells you
; only that it stopped saying nothing.
;
; This one prints a dot per pass, counts the passes on the LED panel so the
; board is visibly alive, and stops on the first wrong byte with the page, the
; offset, and both values. Sixteen bytes per page spans two of the memory
; bridge's eight byte cache lines on purpose: a cache that mixes up its lines
; or fails to patch a written byte shows up here and nowhere else.
;
;   phase 1  write sixteen bytes to a page and read them straight back
;   phase 2  write every page, then read every page - which is the one that
;            catches a cache tag matching the wrong line
CTRL    .equ $f200
TXDATA  .equ $f201
LEDS    .equ $5c00          ; write only, one byte, physical 0x5c00
WIN     .equ $7100          ; virtual page 14, offset 0x100: not offset 0, which
                            ; in physical page 0 is the CPU's own register file
LOPAGE  .equ 32             ; clear of the ROM, the block RAM and the I/O page
HIPAGE  .equ 120
pcsave  .equ $b004
scr     .equ $b006
scr2    .equ $b008
pg      .equ $b010
i       .equ $b012
got     .equ $b014
exp     .equ $b016
pass    .equ $b018
MAPIMG  .equ $b100
        .org $8000
        .byte $01
start:  LDAB #$c4           ; 19200 7N1
        STAB CTRL
        LDA #$bfe0
        XAS
        LDA #banner
        JSR puts
        PAGE $1c,$f8,MAPIMG ; the running map, which we edit one entry of
        LDA #0
        STA pass

main:   LDA #LOPAGE         ; phase 1: write a page and read it straight back
        STA pg
p1:     JSR setpage
        JSR wr16
        JSR rd16
        LDA pg
        INA
        STA pg
        LDB #HIPAGE
        SUB B,A
        BNZ p1

        LDA #LOPAGE         ; phase 2: every page written, then every page read
        STA pg
p2a:    JSR setpage
        JSR wr16
        LDA pg
        INA
        STA pg
        LDB #HIPAGE
        SUB B,A
        BNZ p2a
        LDA #LOPAGE
        STA pg
p2b:    JSR setpage
        JSR rd16
        LDA pg
        INA
        STA pg
        LDB #HIPAGE
        SUB B,A
        BNZ p2b

        LDA pass            ; a dot per pass, and the LEDs count them
        INA
        STA pass
        LDAB pass+1
        STAB LEDS
        LDA #'.'
        JSR putc
        JSR drain           ; and empty the receiver, so a status dump can be
        JMP main            ; asked for while this is running

; The dump request is edge triggered on a byte arriving, so a program that never
; reads the data register can never be asked for one - which is the failing that
; makes diag's own test so hard to work with. Take whatever is waiting and throw
; it away.
drain:  LDAB CTRL
        LDB #$0001
        NAB
        STB scr2+2
        LDA scr2+2
        BZ dr1
        LDAB TXDATA
dr1:    RSR

; Point the window at physical page pg.
setpage: LDA #MAPIMG+14
        XAY
        LDAB pg+1
        STAB [Y]
        PAGE $0c,$f8,MAPIMG
        RSR

; Sixteen bytes of pg+i, which no other page produces at the same offset.
wr16:   LDA #0
        STA i
w1:     LDA i
        LDB #16
        SUB B,A
        BZ w2
        LDA #WIN
        LDB i
        AAB
        STB scr
        LDA scr
        XAY
        LDA pg
        LDB i
        AAB
        STB scr2
        LDAB scr2+1
        STAB [Y]
        LDA i
        INA
        STA i
        JMP w1
w2:     RSR

rd16:   LDA #0
        STA i
r1:     LDA i
        LDB #16
        SUB B,A
        BZ r2
        LDA #WIN
        LDB i
        AAB
        STB scr
        LDA scr
        XAY
        CLA
        LDAB [Y]
        STA got
        LDA pg
        LDB i
        AAB
        STB scr2
        LDA scr2
        LDB #$00ff
        NAB
        STB exp
        LDA got
        LDB exp
        SUB B,A
        BNZ fail
        LDA i
        INA
        STA i
        JMP r1
r2:     RSR

; The first wrong byte stops everything and says where it was and what it held.
fail:   LDA #s_err
        JSR puts
        CLA
        LDAB pg+1
        JSR puthex
        LDA #s_at
        JSR puts
        CLA
        LDAB i+1
        JSR puthex
        LDA #s_want
        JSR puts
        CLA
        LDAB exp+1
        JSR puthex
        LDA #s_got
        JSR puts
        CLA
        LDAB got+1
        JSR puthex
        JSR crlf
fhalt:  LDAB #$ff           ; every LED on, and stay here
        STAB LEDS
        JMP fhalt

puts:   STA scr2+2
ps1:    LDA scr2+2
        XAY
        CLA
        LDAB [Y]
        BZ ps2
        JSR putc
        LDA scr2+2
        INA
        STA scr2+2
        JMP ps1
ps2:    RSR

crlf:   LDA #$0d
        JSR putc
        LDA #$0a
        JMP putc

puthex: STAB scr+2
        SRAB
        SRAB
        SRAB
        SRAB
        LDB #$000f
        NAB
        JSR putnib
        LDAB scr+2
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

digits:   .ascii "0123456789ABCDEF"
banner:   .asciiz "MAPTEST\r\n"
s_err:    .asciiz "\r\nFAIL page "
s_at:     .asciiz " offset "
s_want:   .asciiz " wanted "
s_got:    .asciiz " got "
