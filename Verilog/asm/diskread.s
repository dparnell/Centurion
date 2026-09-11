; Read sectors off the Hawk and print them. Read only: nothing here writes to
; the disk, so a real image on a real card cannot be damaged by running it.
;
; Prints, for each of a few sectors, the sector number, the controller's status,
; and the first sixteen bytes. Compare those against the image file to see
; whether the machine is really reading the disk it thinks it is.

CTRL    .equ $f200
TXDATA  .equ $f201
LEDS    .equ $5c00

HKUNIT  .equ $f140
HKADRH  .equ $f141
HKADRL  .equ $f142
HKWPM   .equ $f143
HKSTAT  .equ $f144
HKDRV   .equ $f145
HKCMD   .equ $f148
CMDREAD .equ 0

BUF     .equ $1000
LEN     .equ 400

pcsave  .equ $b004
scr     .equ $b006
scr2    .equ $b008
i       .equ $b010
tmp     .equ $b012
sec     .equ $b014

        .org $8000
        .byte $01
start:  LDAB #$c4           ; 19200 7N1
        STAB CTRL
        LDA #$bfe0
        XAS
        LDA #banner
        JSR puts
        LDAB #1             ; the image is on unit 1, which is where the drive
        STAB HKUNIT         ; status reports a medium and where "H1" boots from
        LDAB #$00           ; register 3 is a write PERMIT mask, so zero leaves
        STAB HKWPM          ; every unit unwritable: belt and braces on top of
                            ; this program never issuing a write
        LDA #0
        STA sec

again:  LDA sec
        LDB #4              ; four sectors is enough to see the pattern
        SUB B,A
        BZ done
        JSR one
        LDA sec
        INA
        STA sec
        JMP again
done:   LDA #mdone
        JSR puts
halt:   JMP halt

; Read the sector in `sec' and print it.
one:    LDAB sec+1
        STAB LEDS
        LDAB #$ee           ; so a byte that never arrived is visible
        JSR fill
        LDAB sec            ; the packed address is just the sector index
        STAB HKADRH
        LDAB sec+1
        STAB HKADRL
        DMA $04             ; map 0
        LDA #BUF
        DMA $00             ; address
        LDA #$ffff-LEN
        DMA $02             ; count
        LDAB #CMDREAD
        STAB HKCMD
        DMA $06             ; the microcode's wait loop runs the transfer
        JSR waitbusy
        DMA $07
        LDAB sec+1
        JSR puthex
        LDAB #':'
        JSR putcA
        JSR space
        LDAB HKSTAT
        JSR puthex
        JSR space
        LDA #0
        STA i
p1:     LDA i
        LDB #16
        SUB B,A
        BZ p2
        LDA #BUF
        LDB i
        AAB
        STB tmp
        LDA tmp
        XAY
        CLA
        LDAB [Y]
        JSR puthex
        LDA i
        INA
        STA i
        JMP p1
p2:     JMP crlf

waitbusy:
        LDA #$7fff
        STA tmp
wb1:    LDAB HKSTAT
        LDB #$0001
        NAB
        BZ wb2
        LDA tmp
        DCA
        STA tmp
        BZ wb2
        JMP wb1
wb2:    RSR

fill:   STAB scr+2
        LDA #0
        STA i
fl1:    LDA i
        LDB #LEN
        SUB B,A
        BZ fl2
        LDA #BUF
        LDB i
        AAB
        STB tmp
        LDA tmp
        XAY
        LDAB scr+2
        STAB [Y]
        LDA i
        INA
        STA i
        JMP fl1
fl2:    RSR

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

space:  LDA #' '
        JMP putc
putcA:  JMP putc

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

digits: .ascii "0123456789abcdef"
banner: .asciiz "\r\nDISK READ  sector: status data\r\n"
mdone:  .asciiz "done\r\n"
