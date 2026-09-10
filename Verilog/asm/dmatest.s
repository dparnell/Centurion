; Drive the DMA test device end to end.
;
; DmaTest generates or checks pattern(N) = N ^ 0x5a, so a byte that lands at the
; wrong offset is unambiguous rather than merely wrong: that catches a dropped
; byte, a doubled one, stepping the wrong way, and stopping in the wrong place,
; where a fixed fill would catch none of them.
;
; The DMA registers are reached through the 0x2f instruction family: sub-op 4
; sets the map from the register nibble, 0 loads the address, 2 loads the count,
; 6 enables and 7 disables. Which of the core's two address counters each of
; those lands in is part of what this program is here to establish.
;
;   pass 1  device to memory, then read the buffer back and check it here
;   pass 2  memory to device, and let the device do the checking
;
; Each line printed is: status position badcount badoffset want got.

CTRL    .equ $f200
TXDATA  .equ $f201
LEDS    .equ $5c00          ; write only, one byte, physical 0x5c00
DMACMD  .equ $f300          ; command on write, status on read
DMABADL .equ $f301
DMABADH .equ $f302
DMAOFFL .equ $f303
DMAOFFH .equ $f304
DMAWANT .equ $f305
DMAGOT  .equ $f306
DMAPOSL .equ $f307
DMAPOSH .equ $f308

BUF     .equ $1000          ; virtual, and map 0 makes that physical too
LEN     .equ 64

; The print helpers below use scr and scr2, and each of them uses the word two
; bytes past its own: puts walks a pointer in scr2+2 and puthex saves its byte in
; scr+2, which is scr2. So everything this program keeps across a call to one of
; them has to live clear of $b006 to $b00b entirely - putting a loop counter at
; scr2+2 makes puts reset it, and the loop never ends.
pcsave  .equ $b004
scr     .equ $b006
scr2    .equ $b008
i       .equ $b010
tmp     .equ $b012
bad     .equ $b014
exp     .equ $b016
got     .equ $b018
round   .equ $b01a

        .org $8000
        .byte $01
start:  LDAB #$c4           ; 19200 7N1, the settings diag leaves behind
        STAB CTRL
        LDA #$bfe0
        XAS
        LDA #banner
        JSR puts
        LDA #0
        STA round

; The whole thing runs in a loop rather than once, so that the board is doing
; something watchable and a fault that only shows up occasionally has a chance
; to. The round number goes to the LED panel, which is the only sign of life
; while the serial line is busy.
again:  LDA round
        INA
        STA round
        LDAB round+1
        STAB LEDS

; ------------------------------------------------- pass 1: device to memory
        LDAB #$ff           ; a fill nothing would produce, so a byte that never
        JSR fill            ; arrived reads as ff rather than as a plausible value
        JSR setup
        LDAB #2             ; the device generates
        STAB DMACMD
        DMA $06             ; enable
        JSR waitdone
        DMA $07             ; disable
        LDA #m1
        JSR puts
        JSR report
        JSR verify          ; check the buffer ourselves

; ------------------------------------------------- pass 2: memory to device
        JSR setup
        LDAB #1             ; the device checks
        STAB DMACMD
        DMA $06
        JSR waitdone
        DMA $07
        LDA #m2
        JSR puts
        JSR report

        JMP again

; ------------------------------------------------------------- subroutines
; Called with JSR, so none of these may touch X: JSR puts the return address
; there and RSR jumps to it. Y and B are the pointer registers.

; Point the DMA at BUF and set the count. The counter steps up and the transfer
; stops when it reaches 0xffff without moving that byte, so LEN bytes need a
; starting value of 0xffff - LEN.
setup:  DMA $04             ; map 0
        LDA #BUF
        DMA $00             ; address <- A
        LDA #$ffff-LEN
        DMA $02             ; count <- A
        RSR

; Wait for the device to drop busy. Give up rather than hang, so a DMA that
; never starts prints something instead of looking like a crash.
waitdone:
        LDA #$4000
        STA tmp
wd1:    LDAB DMACMD
        LDB #$0001
        NAB
        BZ wd2              ; busy clear: finished
        LDA tmp
        DCA
        STA tmp
        BZ wd2              ; ran out of patience
        JMP wd1
wd2:    RSR

; status position badcount badoffset want got
report: LDAB DMACMD
        JSR puthex
        JSR space
        LDAB DMAPOSH
        JSR puthex
        LDAB DMAPOSL
        JSR puthex
        JSR space
        LDAB DMABADH
        JSR puthex
        LDAB DMABADL
        JSR puthex
        JSR space
        LDAB DMAOFFH
        JSR puthex
        LDAB DMAOFFL
        JSR puthex
        JSR space
        LDAB DMAWANT
        JSR puthex
        LDAB DMAGOT
        JSR puthex
        JMP crlf

; Fill the buffer with the byte in B.
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

; Read the buffer back and compare each byte against pattern(N) = N ^ 0x5a.
verify: LDA #0
        STA i
        STA bad
vf1:    LDA i
        LDB #LEN
        SUB B,A
        BZ vf3
        LDA #BUF
        LDB i
        AAB
        STB tmp
        LDA tmp
        XAY
        CLA
        LDAB [Y]
        STA got             ; what we read
        LDA i
        LDB #$005a
        ORE B,A             ; exclusive or, and the answer lands in A
        STA exp             ; what the byte should be
        LDB got
        SUB B,A
        BZ vf2
        LDA bad
        INA
        STA bad
        LDA #mbad
        JSR puts
        LDAB i+1
        JSR puthex
        JSR space
        LDAB exp+1
        JSR puthex
        LDAB got+1
        JSR puthex
        JSR crlf
vf2:    LDA i
        INA
        STA i
        JMP vf1
vf3:    LDA bad
        BZ vf4
        RSR
vf4:    LDA #mok
        JSR puts
        RSR

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
banner: .asciiz "\r\nDMA test: status pos badcount badoff want got\r\n"
m1:     .asciiz "to memory: "
m2:     .asciiz "to device: "
mbad:   .asciiz "  bad "
mok:    .asciiz "  buffer ok\r\n"
