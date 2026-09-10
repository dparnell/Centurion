; Drive the Hawk disk controller: registers, seek, and a sector out and back.
;
; The controller has one sector buffer and no medium yet, so writing a sector and
; reading it back is exactly what can be checked - and it is the interesting
; part, because it exercises the registers, the command handshake, the DMA in
; both directions and the busy bit, which is everything above the medium.
;
;   1  write the sector address and read it back
;   2  seek, and watch busy clear and on-cylinder come up
;   3  DMA 400 bytes of pattern out to the controller
;   4  DMA them back into a different buffer and compare
;
; Each step prints a line. See asm/dmatest.s for the trap about which scratch
; locations the print helpers use.

CTRL    .equ $f200
TXDATA  .equ $f201
LEDS    .equ $5c00

HKUNIT  .equ $f140
HKADRH  .equ $f141
HKADRL  .equ $f142
HKWPM   .equ $f143
HKSTAT  .equ $f144          ; read status: bit 0 busy
HKDRV   .equ $f145          ; drive status: bit 5 on cylinder, bit 0 seek done
HKCMD   .equ $f148

CMDREAD .equ 0
CMDWRIT .equ 1
CMDSEEK .equ 2

OUTBUF  .equ $1000          ; 400 bytes written to the disk
INBUF   .equ $1400          ; 400 bytes read back
LEN     .equ 400
; Cylinder 0x72, head 0, sector 5, packed 00CC CCCC CCCH SSSS as the archive's
; HawkMMIO.txt gives it - which is also 0x0e45 taken as a flat sector number.
SECTORH .equ $0e
SECTORL .equ $45

pcsave  .equ $b004
scr     .equ $b006
scr2    .equ $b008
i       .equ $b010
tmp     .equ $b012
bad     .equ $b014
exp     .equ $b016
got     .equ $b018
ptr     .equ $b01a
lim     .equ $b01c

        .org $8000
        .byte $01
start:  LDAB #$c4           ; 19200 7N1
        STAB CTRL
        LDA #$bfe0
        XAS
        LDA #banner
        JSR puts

; ---------------------------------------------------- 1: the address registers
        LDA #m_reg
        JSR puts
        LDAB #0
        STAB HKUNIT
        LDAB #0
        STAB HKWPM          ; nothing write protected
        LDAB #SECTORH
        STAB HKADRH
        LDAB #SECTORL
        STAB HKADRL
        LDAB HKADRH
        JSR puthex
        LDAB HKADRL
        JSR puthex
        JSR space
        LDAB HKUNIT         ; the archive says this reads back with f on top
        JSR puthex
        JSR crlf

; ------------------------------------------------------------------ 2: a seek
        LDA #m_seek
        JSR puts
        LDAB #CMDSEEK
        STAB HKCMD
        JSR waitbusy
        LDAB HKSTAT
        JSR puthex
        JSR space
        LDAB HKDRV          ; expect on cylinder and seek done
        JSR puthex
        JSR crlf

; ------------------------------------------- 3: fill the buffer and write it out
        JSR fill
        LDA #m_out
        JSR puts
        LDAB #SECTORH    ; the transfer steps the address, so set it each time
        STAB HKADRH
        LDAB #SECTORL
        STAB HKADRL
        LDA #OUTBUF
        JSR setup
        LDAB #CMDWRIT
        STAB HKCMD          ; raises the request
        DMA $06             ; and the microcode's wait loop runs the transfer
        JSR waitbusy
        DMA $07
        LDAB HKSTAT
        JSR puthex
        JSR crlf

; ------------------------------------------------------- 4: read it back and check
        LDA #m_in
        JSR puts
        LDAB #SECTORH
        STAB HKADRH
        LDAB #SECTORL
        STAB HKADRL
        LDA #INBUF
        JSR setup
        LDAB #CMDREAD
        STAB HKCMD
        DMA $06
        JSR waitbusy
        DMA $07
        LDAB HKSTAT
        JSR puthex
        JSR crlf
        JSR compare

        LDA #m_done
        JSR puts
halt:   JMP halt

; ------------------------------------------------------------------ subroutines
; Called with JSR, so none of these may touch X. Y and B are the pointers.

; Point the DMA at the buffer whose address is in A, for LEN bytes. The count
; steps up and stops at 0xffff without moving that byte, so LEN needs 0xffff-LEN.
setup:  STA tmp
        DMA $04             ; map 0
        LDA tmp
        DMA $00             ; address
        LDA #$ffff-LEN
        DMA $02             ; count
        RSR

; Spin until the controller drops busy, with a bound so a controller that never
; finishes prints something instead of looking like a crash.
waitbusy:
        LDA #$4000
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

; OUTBUF[n] = n ^ 0x5a, so a byte at the wrong offset is unambiguous.
fill:   LDA #0
        STA i
fl1:    LDA i
        LDB #LEN
        SUB B,A
        BZ fl2
        LDA i
        LDB #$005a
        ORE B,A
        STA exp
        LDA #OUTBUF
        LDB i
        AAB
        STB tmp
        LDA tmp
        XAY
        LDAB exp+1
        STAB [Y]
        LDA i
        INA
        STA i
        JMP fl1
fl2:    RSR

; Compare INBUF against OUTBUF and report the first four differences.
compare:
        LDA #0
        STA i
        STA bad
cm1:    LDA i
        LDB #LEN
        SUB B,A
        BZ cm4
        LDA #OUTBUF
        LDB i
        AAB
        STB tmp
        LDA tmp
        XAY
        CLA
        LDAB [Y]
        STA exp
        LDA #INBUF
        LDB i
        AAB
        STB tmp
        LDA tmp
        XAY
        CLA
        LDAB [Y]
        STA got
        LDB exp
        SUB B,A
        BZ cm3
        LDA bad
        INA
        STA bad
        LDB #$0005
        SUB B,A
        BP cm3              ; only print the first few
        LDA #m_bad
        JSR puts
        LDAB i+1
        JSR puthex
        JSR space
        LDAB exp+1
        JSR puthex
        LDAB got+1
        JSR puthex
        JSR crlf
cm3:    LDA i
        INA
        STA i
        JMP cm1
cm4:    LDA bad
        BZ cm5
        LDA #m_diff
        JSR puts
        LDAB bad+1
        JSR puthex
        JMP crlf
cm5:    LDA #m_same
        JMP puts

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
banner: .asciiz "\r\nHAWK test\r\n"
m_reg:  .asciiz "addr readback: "
m_seek: .asciiz "seek stat/drv: "
m_out:  .asciiz "write sector:  "
m_in:   .asciiz "read sector:   "
m_bad:  .asciiz "  bad "
m_diff: .asciiz "MISMATCH count "
m_same: .asciiz "sector matches\r\n"
m_done: .asciiz "done\r\n"
