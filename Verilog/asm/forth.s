; ---------------------------------------------------------------------------
; Centurion FORTH - an indirect threaded FORTH for the CPU6.
;
;   make run SRC=asm/forth.s IN=asm/tests_forth.f FOR=400
;
; Register use, which the instruction set rather than taste decides:
;
;   B   the instruction pointer. Only A, B and X can be the destination of a
;       load, and only those three can be stored, so the IP has to be one of
;       them; B is the one left after X is needed as the word pointer.
;   X   the word pointer, and scratch. NEXT loads it and jumps through it.
;   Z   the data stack pointer, growing down.  [--Z] pushes, [Z++] pops.
;   S   the return stack pointer, growing down. JSR pushes here too, so machine
;       code helpers and the threaded return stack share it, which is fine
;       because they nest. >R and R> reach it directly, and have to be balanced
;       within a definition for the same reason: underneath whatever they push
;       is the caller's instruction pointer, which EXIT is going to pop.
;   A   scratch, and the argument to every helper below.
;   Y   free.
;
; The implicit-register arithmetic - SAB, AAB, NAB - leaves the sign flag alone,
; so BM after one of them tests something stale. The register-to-register forms
; SUB B,A, AAB and NAB do the same work and do set it, so this file uses
; those throughout. For an unsigned comparison use BNL, not BL: BL is branch if
; Link, and Link is set when the subtraction did NOT borrow, so BNL is "less
; than". Finding this cost a hang in the number printer, whose loop subtracts
; until the result goes negative, and then a second round when the obvious
; reading of the flag turned out to be backwards.
;
; NEXT is two instructions:  LDX [B++]  fetches the next code field address,
; JMP [[X]] jumps to the machine code whose address that field holds. The extra
; step is what lets a dictionary entry be code, a constant, a variable or a
; colon definition without the interpreter knowing which.
; ---------------------------------------------------------------------------

; ---- the machine ----------------------------------------------------------
CTRL    .equ $f200          ; MUX 0: control on write, status on read
TXDATA  .equ $f201          ; and the data register
RXRDY   .equ $01            ; status bit 0: a byte is waiting
TXIDLE  .equ $02            ; status bit 1: the transmitter is free

; ---- memory map -----------------------------------------------------------
; The dictionary grows up from DICT through the directly addressable RAM. The
; stacks and the kernel's own variables sit in the block RAM at 0xb000, which
; the board answers far faster than the PSRAM.
DICT    .equ $0200          ; the dictionary, growing up
DICTTOP .equ $6f00          ; and where it must stop
BANKWIN .equ $7000          ; the window any physical page can be mapped into
BANKPG  .equ 14             ; which virtual page that is
PROBE1  .equ BANKWIN+$100   ; where in the window to test; not offset 0, which
PROBE2  .equ BANKWIN+$102   ; in physical page 0 is the CPU's register file
VARS    .equ $b000
DSTACK  .equ $bf00          ; data stack, growing down
RSTACK  .equ $bfe0          ; hmm - see below; the two must not meet
TIB     .equ $c000          ; terminal input buffer
TIBSZ   .equ 128

; ---- kernel variables -----------------------------------------------------
scr1    .equ VARS+$00
scr2    .equ VARS+$02
pcsave  .equ VARS+$04
ipsave  .equ VARS+$06
LATEST  .equ VARS+$08       ; newest dictionary entry
HERE    .equ VARS+$0a       ; next free dictionary byte
STATE   .equ VARS+$0c       ; 0 interpreting, 1 compiling
TOIN    .equ VARS+$0e       ; parse position within the input buffer
TIBLEN  .equ VARS+$10       ; how much of the buffer is filled
NPAGES  .equ VARS+$12       ; physical 2K pages found at start up
BASE    .equ VARS+$14       ; the number base, which HEX and DECIMAL set
WORDBUF .equ VARS+$20       ; the word just parsed, length prefixed
EXECTH  .equ VARS+$40       ; a two cell thread used to run one word
MAPIMG  .equ VARS+$60       ; a 32 byte image of map 0

        .org $8000
        .byte $01           ; never executed: the reset vector jumps to 8001

; ---------------------------------------------------------------------------
; Start up
; ---------------------------------------------------------------------------
start:  LDAB #$c4           ; 19200 baud, 7 data bits, no parity
        STAB CTRL
        LDA #RSTACK
        XAS
        LDA #DSTACK
        XAZ

        LDA #DICT           ; an empty user dictionary
        STA HERE
        LDA #lastword
        STA LATEST
        LDA #0
        STA STATE
        STA TIBLEN
        STA TOIN
        LDA #10             ; numbers are decimal until DECIMAL says otherwise
        STA BASE

        LDA #cfa_retmc      ; the thread that runs one word and comes back
        STA EXECTH+2

        JSR sizemem
        JSR banner

interp: LDA #0              ; the outer interpreter, in machine code
        STA STATE
quit:   JSR readline
        STA TIBLEN
        LDA #0
        STA TOIN
run:    JSR parseword
        LDAB WORDBUF
        BNZ rgot
        JMP endline         ; nothing left on this line
rgot:   JSR find
        LDA scr2            ; find leaves the code field address here, or zero
        BNZ rfound
        JMP tonumber
rfound: LDA STATE
        LDB #0
        SUB B,A
        BZ rexec            ; interpreting: just run it
        LDA scr1            ; compiling: is it one of the immediate words?
        LDB #$80
        NAB
        STB rimm
        LDA rimm
        LDB #0
        SUB B,A
        BNZ rexec
        LDA scr2            ; no, so lay its code field address down
        JSR comma
        JMP run
rexec:  LDA scr2
        JSR execute
        JMP run

endline: JSR pr_ok
        JMP quit

tonumber:
        JSR number
        LDA scr2
        BNZ rnum
        JMP notfound
rnum:   LDA STATE
        LDB #0
        SUB B,A
        BZ rpush
        LDA #w_lit          ; compiling: lay down LIT and the value
        JSR comma
        LDA scr1
        JSR comma
        JMP run
rpush:  LDA scr1
        STA [--Z]
        JMP run

notfound:
        JSR pr_word
        LDA #'?'
        JSR putc
        JSR crlf
        LDA STATE           ; if this was in the middle of a definition, take
        LDB #0              ; the half built entry back out again rather than
        SUB B,A             ; leaving something that crashes when it is run
        BZ interp
        LDA newent
        XAY
        LDA [Y]
        STA LATEST
        LDA newent
        STA HERE
        JMP interp

; ---------------------------------------------------------------------------
; The inner interpreter
; ---------------------------------------------------------------------------
NEXT:   LDX [B++]
        JMP [[X]]           ; X, not Y: this is the word pointer NEXT just
                            ; loaded. A bulk rename of the helpers' indirection
                            ; from X to Y caught this line too, and the inner
                            ; interpreter then jumped through whatever the last
                            ; helper had left behind.

DOCOL:  STB [--S]           ; push the caller's instruction pointer
        INX                 ; X points at the code field; the parameters
        INX                 ; start two bytes later
        STX ipsave
        LDB ipsave
        JMP NEXT

; ---------------------------------------------------------------------------
; Running one word from machine code, and getting back.
; EXECTH holds { the code field address, cfa_retmc }, so NEXT runs the word and
; then hits a primitive whose only job is to return to the caller.
; ---------------------------------------------------------------------------
execute: STA EXECTH
        STB ipsave2         ; the machine code caller's instruction pointer
        STX xsave2          ; and its return address, which NEXT destroys
        LDB #EXECTH
        JMP NEXT
retmc:          LDB ipsave2
        LDX xsave2
        RSR

cfa_retmc: .word retmc

; ---------------------------------------------------------------------------
; Console
; ---------------------------------------------------------------------------
putc:   STAB pcsave         ; the low half of A is the character
pc1:    LDAB CTRL
        SLAB                ; bit 1 up to the sign, so a branch can test it
        SLAB
        SLAB
        SLAB
        SLAB
        SLAB
        BP pc1
        LDAB pcsave
        STAB TXDATA
        RSR

getc:   LDAB CTRL           ; wait for a byte and return it in the low half of A
        SLAB                ; bit 0 up to the sign
        SLAB
        SLAB
        SLAB
        SLAB
        SLAB
        SLAB
        BP getc
        LDAB TXDATA
        RSR

crlf:   LDA #13
        JSR putc
        LDA #10
        JMP putc

; Print the NUL terminated string whose address is in A.
puts:   STA scr2
puts1:  LDA scr2
        XAY
        LDAB [Y]
        BZ puts2
        JSR putc
        LDA scr2
        INA
        STA scr2
        JMP puts1
puts2:  RSR

; ---------------------------------------------------------------------------
; Reading a line into the terminal input buffer. Returns its length in A.
; ---------------------------------------------------------------------------
; SUB B,A puts its answer in A, so the character being examined cannot live
; there across a comparison. It goes in a variable and is reloaded each time.
readline:
        LDA #0
        STA TIBLEN
rl1:    JSR getc
        LDB #$7f
        NAB                 ; B = the character, seven bits
        STB rlch
        LDA #13             ; end of line, either way round: a terminal sends
        LDB rlch            ; a carriage return and a file has a newline
        SUB B,A
        BZ rl_done
        LDA #10
        LDB rlch
        SUB B,A
        BZ rl_done
        LDA #8
        LDB rlch
        SUB B,A
        BZ rl_bs
        LDA #TIBSZ-1        ; is there room?
        LDB TIBLEN
        SUB B,A
        BZ rl1
        LDA #TIB
        LDB TIBLEN
        AAB
        STB scr1
        LDA scr1
        XAY
        LDAB rlch+1         ; the low half is where the character is
        STAB [Y]
        LDA TIBLEN
        INA
        STA TIBLEN
        LDA rlch            ; echo it
        JSR putc
        JMP rl1
rl_bs:  LDA TIBLEN
        LDB #0
        SUB B,A
        BZ rl1
        LDA TIBLEN
        DCA
        STA TIBLEN
        LDA #8
        JSR putc
        LDA #' '
        JSR putc
        LDA #8
        JSR putc
        JMP rl1
rl_done: JSR crlf
        LDA TIBLEN
        RSR

; ---------------------------------------------------------------------------
; Parse the next space delimited word out of the buffer into WORDBUF, which
; holds a length byte followed by the characters.
; ---------------------------------------------------------------------------
parseword:
        LDA #0
        STAB WORDBUF
pw_skip: LDA TOIN           ; step over any spaces
        LDB TIBLEN
        SUB B,A
        BZ pw_end
        JSR tibchar
        STA pwch
        LDA #' '
        LDB pwch
        SUB B,A
        BNZ pw_copy
        LDA TOIN
        INA
        STA TOIN
        JMP pw_skip
pw_copy: LDA TOIN           ; then take everything up to the next one
        LDB TIBLEN
        SUB B,A
        BZ pw_end
        JSR tibchar
        STA pwch
        LDA #' '
        LDB pwch
        SUB B,A
        BZ pw_end
        CLA
        LDAB WORDBUF
        LDB #WORDBUF+1
        AAB
        STB scr1
        LDA scr1
        XAY
        LDAB pwch+1
        STAB [Y]
        CLA
        LDAB WORDBUF
        INAB
        STAB WORDBUF
        LDA TOIN
        INA
        STA TOIN
        JMP pw_copy
pw_end: RSR

; The character at TOIN, in the low half of A.
tibchar: LDA #TIB
        LDB TOIN
        AAB
        STB scr1
        LDA scr1
        XAY
        CLA                 ; a byte load leaves the high half alone
        LDAB [Y]
        RSR

; ---------------------------------------------------------------------------
; Look WORDBUF up in the dictionary. Leaves the code field address in scr2, or
; zero, and the flags byte in scr1.
; ---------------------------------------------------------------------------
find:   LDA LATEST
        STA fp
fnext:  LDA fp
        LDB #0
        SUB B,A
        BZ fnone
        LDA fp
        XAY
        CLA
        LDAB [Y+$02]        ; the flags and length byte
        STA flen
        LDB #$1f
        NAB
        STB flen2
        CLA
        LDAB WORDBUF
        LDB flen2
        SUB B,A             ; the same length?
        BZ fcmp
        JMP fskip
fcmp:   LDA #0
        STA fi
fc1:    LDA fi
        LDB flen2
        SUB B,A
        BNZ fc0
        JMP ffound
fc0:    LDA fp              ; the name starts three bytes in
        LDB fi
        AAB
        STB scr1
        LDA scr1
        XAY
        CLA
        LDAB [Y+$03]
        STA fa
        LDA #WORDBUF+1
        LDB fi
        AAB
        STB scr1
        LDA scr1
        XAY
        CLA
        LDAB [Y]
        STA fb
        LDA fa
        LDB fb
        SUB B,A
        BZ fc2
        JMP fskip
fc2:    LDA fi
        INA
        STA fi
        JMP fc1
ffound: LDA fp              ; the code field follows the name
        LDB flen2
        AAB
        STB scr2
        LDA #3
        LDB scr2
        AAB
        STB scr2
        LDA flen
        STA scr1
        RSR
fskip:  LDA fp              ; on to the entry before it
        XAY
        LDA [Y]
        STA fp
        JMP fnext
fnone:  LDA #0
        STA scr2
        RSR

; ---------------------------------------------------------------------------
; Parse WORDBUF as a number in the current base, leaving it in scr1 and a
; found-or-not flag in scr2. A leading minus negates.
number: LDA #0
        STA nval
        STA nneg
        STA fi
        CLA
        LDAB WORDBUF
        LDB #0
        SUB B,A
        BZ nbad             ; an empty word is not a number
        CLA
        LDAB WORDBUF+1
        LDB #'-'
        SUB B,A
        BNZ ndigits
        LDA #1              ; a minus sign, and there must be more after it
        STA nneg
        STA fi
        CLA
        LDAB WORDBUF
        LDB #1
        SUB B,A
        BZ nbad
ndigits: LDA fi
        LDB #0
        LDBB WORDBUF
        SUB B,A             ; B = length - position
        BZ ndone
        LDA #WORDBUF+1      ; the character at that position
        LDB fi
        AAB
        STB scr1
        LDA scr1
        XAY
        CLA
        LDAB [Y]
        STA dch
        JSR digval
        LDA dok
        LDB #0
        SUB B,A
        BZ nbad
        LDA nval            ; value = value * base + digit
        STA dtmp
        LDA #0
        STA nval
        LDA BASE
        STA dcount
nmul:   LDA dtmp
        LDB nval
        AAB
        STB nval
        LDA dcount
        DCA
        STA dcount
        LDB #0
        SUB B,A
        BNZ nmul
        LDA dval
        LDB nval
        AAB
        STB nval
        LDA fi
        INA
        STA fi
        JMP ndigits
ndone:  LDA nneg
        LDB #0
        SUB B,A
        BZ npos
        LDA nval
        IVA
        INA
        STA nval
npos:   LDA nval
        STA scr1
        LDA #1
        STA scr2
        RSR
nbad:   LDA #0
        STA scr2
        RSR

; The value of the digit character in dch, in the current base. dok says
; whether it was one.
digval: LDA #'0'
        LDB dch
        SUB B,A             ; the answer is in A, not in B
        BM dvbad
        STA dval
        LDA #9
        LDB dval
        SUB B,A
        BM dvck
        BZ dvck
        LDA #'A'            ; not a decimal digit, so try the letters
        LDB dch
        SUB B,A
        BM dvbad
        STA dval
        LDA dval
        LDB #10
        AAB
        STB dval
        LDA #15
        LDB dval
        SUB B,A
        BM dvck
        BZ dvck
        JMP dvbad
dvck:   LDA BASE            ; and it has to fit in the base
        LDB dval
        SUB B,A
        BM dvgood
        JMP dvbad
dvgood: LDA #1
        STA dok
        RSR
dvbad:  LDA #0
        STA dok
        RSR

; ---------------------------------------------------------------------------
; Printing
; ---------------------------------------------------------------------------
; Print the signed number in A.
; Print the value in A in the current base, then a space. Repeated subtraction
; from the largest power of the base that fits keeps this to about seventy
; operations whatever the value; taking the base away one at a time instead
; needs six thousand for a large number, which is slow enough to look hung.
prnum:  STA nval
        LDA #0              ; the sign has to come from an arithmetic operation,
        LDB nval            ; and SUB B,A computes B - A, so the value goes in B
        SUB B,A
        BM prneg
        JMP prpos
prneg:  LDA BASE            ; only base ten has negative numbers here
        LDB #10
        SUB B,A
        BNZ prpos
        LDA #'-'
        JSR putc
        LDA nval
        IVA
        INA
        STA nval
prpos:  LDA #1              ; powers[0] = 1
        STA pow
        LDA #0
        STA npow
po1:    LDA npow            ; the power just built
        SLA
        LDB #pow
        AAB
        STB scr1
        LDA scr1
        XAY
        LDA [Y]
        STA pcur
        LDA #0              ; multiply it by the base
        STA pnext
        LDA BASE
        STA pcount
po2:    LDA pcur
        LDB pnext
        AAB
        STB pnext
        LDA pcount
        DCA
        STA pcount
        LDB #0
        SUB B,A
        BNZ po2
        LDA pnext           ; did it wrap round? Unsigned, like the two below.
        LDB pcur            ; These are magnitude tests on values that can have
        SUB B,A             ; bit 15 set, and with the signed BM anything from
        BNL po3             ; 8000 up looked smaller than every power and came
        JMP podone          ; out as "0". Link is set when a subtraction did
                            ; NOT borrow, so BNL is the unsigned "less than".
po3:    LDA nval            ; is it already past the value?
        LDB pnext
        SUB B,A
        BNL po4
        JMP podone
po4:    LDA npow
        INA
        STA npow
        SLA
        LDB #pow
        AAB
        STB scr1
        LDA scr1
        XAY
        LDA pnext
        STA [Y]
        JMP po1
podone: LDA npow            ; now take each power out in turn
        SLA
        LDB #pow
        AAB
        STB scr1
        LDA scr1
        XAY
        LDA [Y]
        STA pcur
        LDA #0
        STA nq
pd1:    LDA pcur
        LDB nval
        SUB B,A             ; the answer lands in A, not in B
        BNL pd2
        STA nval
        LDA nq
        INA
        STA nq
        JMP pd1
pd2:    LDA #digits
        LDB nq
        AAB
        LDAB [B]
        JSR putc
        LDA npow
        LDB #0
        SUB B,A
        BZ pd3
        LDA npow
        DCA
        STA npow
        JMP podone
pd3:    LDA #' '
        JMP putc

digits: .ascii "0123456789ABCDEF"

; Print WORDBUF.
pr_word: LDA #0
        STA fi
pw1:    LDA fi
        LDB #0
        LDBB WORDBUF
        SUB B,A
        BZ pw2
        LDA #WORDBUF+1
        LDB fi
        AAB
        STB scr1
        LDA scr1
        XAY
        LDAB [Y]            ; putc takes the character in the low half of A
        JSR putc
        LDA fi
        INA
        STA fi
        JMP pw1
pw2:    RSR

pr_ok:  LDA #s_ok
        JSR puts
        JMP crlf

; ---------------------------------------------------------------------------
; Dictionary building
; ---------------------------------------------------------------------------
; Append the word in A to the dictionary.
comma:  STA scr2
        LDA HERE
        XAY
        LDA scr2
        STA [Y]
        LDA HERE
        INA
        INA
        STA HERE
        RSR

; ---------------------------------------------------------------------------
; Start a dictionary entry for the next word in the input: the link, the flags
; and length byte, and the name. Leaves the entry's address in newent with HERE
; pointing at the code field, which the caller fills in - that is the only thing
; ":" and CREATE disagree about.
;
; Nothing here may touch X. JSR keeps its return address there, so this walks
; the name with Y, as everything called with JSR in this file has to.
; ---------------------------------------------------------------------------
mkhead: JSR parseword
        LDA HERE
        STA newent
        LDA LATEST          ; the link to the entry before this one
        JSR comma
        CLA
        LDAB WORDBUF
        STA cnt
        LDA HERE            ; the length byte
        XAY
        LDAB WORDBUF
        STAB [Y]
        LDA HERE
        INA
        STA HERE
        LDA #0
        STA ci
cn1:    LDA ci              ; then the name itself
        LDB cnt
        SUB B,A
        BZ cn2
        LDA #WORDBUF+1
        LDB ci
        AAB
        STB scr1
        LDA scr1
        XAY
        CLA
        LDAB [Y]
        STA cch
        LDA HERE
        XAY
        LDAB cch+1
        STAB [Y]
        LDA HERE
        INA
        STA HERE
        LDA ci
        INA
        STA ci
        JMP cn1
cn2:    RSR

; ---------------------------------------------------------------------------
; What a CREATEd word does when it runs. NEXT leaves the code field address in
; X before jumping through it, so a CREATEd word's data starts four bytes on:
; the code field itself, then the cell DOES> fills in. A colon definition has
; no such cell and DOCOL steps over two bytes rather than four - each runtime
; knows the shape of the word it belongs to, and nothing else needs to.
; ---------------------------------------------------------------------------
DOVAR:  STX dvtmp           ; X is this word's code field address
        LDA dvtmp
        INA
        INA
        INA
        INA
        STA [--Z]           ; push the parameter field address
        JMP NEXT

; And what it does once DOES> has been through it: the same push, and then the
; thread DOES> recorded, entered exactly as DOCOL enters a colon definition.
DODOES: STX dvtmp
        LDA dvtmp
        INA
        INA
        INA
        INA
        STA [--Z]
        STB [--S]           ; the caller's instruction pointer
        LDA dvtmp
        INA
        INA
        XAY
        LDB [Y]
        JMP NEXT

; ---------------------------------------------------------------------------
; How much memory is there? Map each physical page into the window in turn and
; see whether it remembers a signature. The page file is only reachable through
; the PAGE instruction, so this keeps a 32 byte image of map 0, edits one entry
; and loads the whole map back.
; ---------------------------------------------------------------------------
sizemem:
        PAGE $1c,$f8,MAPIMG     ; capture the map that is running
        LDA #0
        STA NPAGES
        STA mp
sm1:    LDA mp
        LDB #128                ; 128 pages of 2K is the whole 256K
        SUB B,A
        BNZ sm_go
        JMP smdone
sm_go:  LDA #MAPIMG+BANKPG      ; point the window at physical page mp
        XAY
        LDAB mp+1
        STAB [Y]
        PAGE $0c,$f8,MAPIMG
        ; Probe at an offset of 0x100 into the page, not at 0: the first 256
        ; bytes of physical page 0 are the CPU's own register file, and writing
        ; a signature there stops the machine dead.
        LDA PROBE1              ; keep whatever is there, so that sizing the
        STA sv1                 ; memory does not destroy it - the stacks and
        LDA PROBE2              ; these variables live in pages this walks over
        STA sv2
        LDA #$a5c3
        STA PROBE1
        LDA #$5a3c
        STA PROBE2
        LDA #0
        STA smok
        LDA PROBE1
        LDB #$a5c3
        SUB B,A
        BNZ sm_put
        LDA PROBE2
        LDB #$5a3c
        SUB B,A
        BNZ sm_put
        LDA #1
        STA smok
sm_put: LDA sv1                 ; put the page back as it was
        STA PROBE1
        LDA sv2
        STA PROBE2
        LDA smok
        BZ smnext
        LDA NPAGES
        INA
        STA NPAGES
smnext: LDA mp
        INA
        STA mp
        JMP sm1
smdone: LDA #MAPIMG+BANKPG      ; and put the window back where it was
        XAY
        LDAB #BANKPG
        STAB [Y]
        PAGE $0c,$f8,MAPIMG
        RSR

banner: LDA #s_banner
        JSR puts
        LDA NPAGES              ; each page is 2K
        SLA
        JSR prnum
        LDA #s_kb
        JSR puts
        JMP crlf

s_banner: .asciiz "Centurion FORTH  "
s_kb:     .asciiz "K RAM"
s_ok:     .asciiz "  ok"

; ---------------------------------------------------------------------------
; Scratch that the helpers above use. All in RAM.
; ---------------------------------------------------------------------------
fp      .equ VARS+$80
flen    .equ VARS+$82
flen2   .equ VARS+$84
fi      .equ VARS+$86
fa      .equ VARS+$88
fb      .equ VARS+$8a
fa2     .equ VARS+$8c
nval    .equ VARS+$8e
nneg    .equ VARS+$90
ndig    .equ VARS+$92
nq      .equ VARS+$94
nz      .equ VARS+$96
mp      .equ VARS+$98
sv1     .equ VARS+$9c
sv2     .equ VARS+$9e
smok    .equ VARS+$a0
rlch    .equ VARS+$c4
pwch    .equ VARS+$c6
dch     .equ VARS+$a2
dval    .equ VARS+$a4
dok     .equ VARS+$a6
dtmp    .equ VARS+$a8
dcount  .equ VARS+$aa
pcur    .equ VARS+$ac
pnext   .equ VARS+$ae
pcount  .equ VARS+$b0
npow    .equ VARS+$b2
pow     .equ VARS+$b4       ; six words: the powers of the base that fit
ipsave2 .equ VARS+$9a
xsave2  .equ VARS+$c8
newent  .equ VARS+$ca
cnt     .equ VARS+$cc
ci      .equ VARS+$ce
cch     .equ VARS+$d0
newslot .equ VARS+$d2
dtmp1   .equ VARS+$d4
dtmp2   .equ VARS+$d6
rimm    .equ VARS+$d8
ipsave3 .equ VARS+$da
mula    .equ VARS+$dc       ; the multiplicand * hands to MUL
dvtmp   .equ VARS+$e4       ; the code field address a CREATEd word was entered with
tkcfa   .equ VARS+$e6       ; what ' looked up
pnch    .equ VARS+$e8       ; the character ( is scanning
shcnt   .equ VARS+$ea       ; LSHIFT and RSHIFT
shval   .equ VARS+$ec
dqch    .equ VARS+$ee       ; the character ." is reading
dqn     .equ VARS+$f0       ; how long its string is
dqlen   .equ VARS+$f2       ; and where to write that down
dsn     .equ VARS+$f4       ; the inline string a compiled ." is printing
dsi     .equ VARS+$f6
dsptr   .equ VARS+$f8
dvsr    .equ VARS+$fa       ; the divisor / and /MOD are working with
pktmp   .equ VARS+$fc       ; how far down the stack PICK is reaching
rt1     .equ VARS+$fe       ; ROT holds two of the three here
rt2     .equ VARS+$100


; ---- the runtime halves of the control structures -------------------------
; These have no dictionary entries of their own: the compiling words below lay
; their code field addresses down, and nothing else should reach them.

r_branch: .word rb_code     ; ( -- ) the cell after it is where to go
rb_code: LDA [B]
        STB ipsave3         ; B is the instruction pointer
        STA ipsave
        LDB ipsave
        LDB ipsave3
        JMP NEXT

r_qbranch: .word rq_code    ; ( flag -- ) go there when the flag is zero
rq_code: STB ipsave3        ; the target is read through B, so it has to come
        LDA [Z++]           ; back before either path uses it
        LDB #0
        SUB B,A
        BZ rq_take
        LDB ipsave3         ; not taken: step over the target
        LDA [B++]
        JMP NEXT
rq_take: LDB ipsave3
        LDA [B]
        STA ipsave
        LDB ipsave
        JMP NEXT

r_do:   .word rd_code       ; ( limit start -- ) the loop control goes on the
rd_code: LDA [Z++]          ; return stack, which is where I reads it from
        STA dtmp1
        LDA [Z++]
        STA [--S]           ; the limit underneath
        LDA dtmp1
        STA [--S]           ; and the index on top
        JMP NEXT

r_loop: .word rl_code       ; ( -- ) step the index and go round again
rl_code: STB ipsave3        ; same again: the comparison needs B, and so does
        LDA [S++]           ; reading the address to go back to
        INA
        STA dtmp1
        LDA [S]             ; the limit, without taking it off
        LDB dtmp1
        SUB B,A             ; A = the new index, less the limit
        BM lp_again
        JMP lp_done
lp_again: LDA dtmp1
        STA [--S]
        LDB ipsave3
        LDA [B]
        STA ipsave
        LDB ipsave
        JMP NEXT
lp_done: LDA [S++]          ; drop the limit
        LDB ipsave3
        LDA [B++]           ; and step over the target
        JMP NEXT

; ---------------------------------------------------------------------------
; The dictionary. Each entry is a link to the one before, a length byte with
; the immediate flag in bit 7, the name, and then the code field.
; ---------------------------------------------------------------------------
        .word 0
        .byte 3
        .ascii "DUP"
w_dup:  .code
        LDA [Z]
        STA [--Z]
        JMP NEXT

        .word w_dup-6
        .byte 4
        .ascii "DROP"
w_drop: .code
        LDA [Z++]
        JMP NEXT

        .word w_drop-7
        .byte 4
        .ascii "SWAP"
w_swap: .code
        LDA [Z++]
        STA scr1
        LDA [Z++]
        STA scr2
        LDA scr1
        STA [--Z]
        LDA scr2
        STA [--Z]
        JMP NEXT

        .word w_swap-7
        .byte 4
        .ascii "OVER"
w_over: .code
        LDA [Z+$02]
        STA [--Z]
        JMP NEXT

        .word w_over-7
        .byte 1
        .ascii "+"
w_plus: .code
        STB ipsave3         ; B is the instruction pointer
        LDA [Z++]
        LDB [Z++]
        AAB
        STB [--Z]
        LDB ipsave3
        JMP NEXT

        .word w_plus-4
        .byte 1
        .ascii "*"
w_star: .code
        STB ipsave3         ; B is the instruction pointer
        LDA [Z++]
        STA mula
        LDA [Z++]
        LDB mula
        MUL B,A             ; the machine multiplies: the low word of the
        STB [--Z]           ; product lands in B and the high word in A, which
        LDB ipsave3         ; a sixteen bit * has nowhere to put
        JMP NEXT

        .word w_star-4
        .byte 1
        .ascii "-"
w_minus: .code
        STB ipsave3         ; B is the instruction pointer
        LDA [Z++]           ; ( a b -- a-b ) with b on top
        LDB [Z++]
        SUB B,A             ; the answer is in A
        STA [--Z]
        LDB ipsave3
        JMP NEXT

        .word w_minus-4
        .byte 3
        .ascii "AND"
w_and:  .code
        STB ipsave3         ; B is the instruction pointer
        LDA [Z++]
        LDB [Z++]
        NAB
        STB [--Z]
        LDB ipsave3
        JMP NEXT

        .word w_and-6
        .byte 1
        .ascii "@"
w_fetch: .code
        LDA [Z++]
        XAY
        LDA [Y]
        STA [--Z]
        JMP NEXT

        .word w_fetch-4
        .byte 1
        .ascii "!"
w_store: .code
        LDA [Z++]
        XAY
        LDA [Z++]
        STA [Y]
        JMP NEXT

        .word w_store-4
        .byte 2
        .ascii "C@"
w_cfetch: .code
        LDA [Z++]
        XAY
        LDA #0
        LDAB [Y]
        STA scr1
        LDAB [Y]
        STAB scr1+1
        LDA scr1
        STA [--Z]
        JMP NEXT

        .word w_cfetch-5
        .byte 2
        .ascii "C!"
w_cstore: .code
        LDA [Z++]
        XAY
        LDA [Z++]
        STAB [Y]
        JMP NEXT

        .word w_cstore-5
        .byte 4
        .ascii "EMIT"
w_emit: .code
        STB ipsave3         ; B is the instruction pointer
        LDA [Z++]
        JSR putc
        LDB ipsave3
        JMP NEXT

        .word w_emit-7
        .byte 3
        .ascii "KEY"
w_key:  .code
        STB ipsave3         ; B is the instruction pointer
        JSR getc
        LDB #$7f
        NAB
        STB [--Z]
        LDB ipsave3
        JMP NEXT

        .word w_key-6
        .byte 2
        .ascii "CR"
w_cr:   .code
        STB ipsave3         ; B is the instruction pointer
        JSR crlf
        LDB ipsave3
        JMP NEXT

        .word w_cr-5
        .byte 1
        .ascii "."
w_dot:  .code
        STB ipsave3         ; B is the instruction pointer
        LDA [Z++]
        JSR prnum
        LDA #' '
        JSR putc
        LDB ipsave3
        JMP NEXT

        .word w_dot-4
        .byte 3
        .ascii "LIT"
w_lit:  .code
        LDA [B++]
        STA [--Z]
        JMP NEXT
cfa_lit .equ w_lit

        .word w_lit-6
        .byte 4
        .ascii "EXIT"
w_exit: .code
        LDB [S++]           ; the caller's instruction pointer, pushed by DOCOL.
                            ; EXIT must NOT save and restore B around that pop
                            ; the way the other primitives do - moving B is the
                            ; whole point of it.
        JMP NEXT

        .word w_exit-7
        .byte 5
        .ascii "PAGES"
w_pages: .code
        LDA NPAGES
        STA [--Z]
        JMP NEXT

        .word w_pages-8
        .byte 4
        .ascii "HERE"
w_here: .code
        LDA HERE
        STA [--Z]
        JMP NEXT

        .word w_here-7
        .byte 5
        .ascii "WORDS"
w_words: .code
        STB ipsave3         ; B is the instruction pointer
        LDA LATEST
        STA fp
ww1:    LDA fp
        BZ ww2
        JSR pr_entry
        LDA fp
        XAY
        LDA [Y]
        STA fp
        JMP ww1
ww2:    JSR crlf
        LDB ipsave3
        JMP NEXT

        .word w_words-8
        .byte 5
        .ascii "BANK!"
w_bank: .code
        LDA [Z++]               ; a physical page number
        STA scr1
        LDA #MAPIMG+BANKPG
        XAY
        LDAB scr1+1
        STAB [Y]
        PAGE $0c,$f8,MAPIMG
        JMP NEXT

        .word w_bank-8
        .byte 3
        .ascii "HEX"
w_hex:  .code
        LDA #16
        STA BASE
        JMP NEXT

        .word w_hex-6
        .byte 7
        .ascii "DECIMAL"
w_dec:  .code
        LDA #10
        STA BASE
        JMP NEXT

        .word w_dec-10
        .byte 4
        .ascii "BASE"
w_base: .code
        LDA #BASE
        STA [--Z]
        JMP NEXT

        .word w_base-7
        .byte 7
        .ascii "?BRANCH"
w_qbranch: .word rq_code

        .word w_qbranch-10
        .byte 6
        .ascii "BRANCH"
w_branch: .word rb_code

        .word w_branch-9
        .byte 1
        .ascii "="
w_eq:   .code
        STB ipsave3         ; B is the instruction pointer
        LDA [Z++]
        LDB [Z++]
        SUB B,A
        BZ tru
        JMP fls

        .word w_eq-4
        .byte 1
        .ascii "<"
w_lt:   .code
        STB ipsave3         ; B is the instruction pointer
        LDA [Z++]           ; ( a b -- flag ) with b on top
        LDB [Z++]
        SUB B,A             ; A = a - b
        BM tru
        JMP fls

        .word w_lt-4
        .byte 1
        .ascii ">"
w_gt:   .code
        STB ipsave3         ; B is the instruction pointer
        LDA [Z++]
        LDB [Z++]
        SUB B,A             ; A = a - b
        BM fls
        BZ fls
        JMP tru

        .word w_gt-4
        .byte 2
        .ascii "0="
w_zeq:  .code
        STB ipsave3         ; B is the instruction pointer
        LDA [Z++]
        LDB #0
        SUB B,A
        BZ tru
        JMP fls

        .word w_zeq-5
        .byte 1
        .ascii "I"
w_i:    .code
        LDA [S]
        STA [--Z]
        JMP NEXT

        .word w_i-4
        .byte 1
        .ascii ":"
w_colon: .code
        STB ipsave3         ; B is the instruction pointer
        JSR mkhead
        LDA #DOCOL          ; and the code field
        JSR comma
        LDA newent
        STA LATEST
        LDA #1
        STA STATE
        LDB ipsave3
        JMP NEXT

        .word w_colon-4
        .byte $81
        .ascii ";"
w_semi: .code
        STB ipsave3         ; B is the instruction pointer
        LDA #w_exit
        JSR comma
        LDA #0
        STA STATE
        LDB ipsave3
        JMP NEXT

        .word w_semi-4
        .byte $82
        .ascii "IF"
w_if:   .code
        STB ipsave3         ; B is the instruction pointer
        LDA #w_qbranch
        JSR comma
        LDA HERE            ; remember the slot to fill in later
        STA [--Z]
        LDA #0
        JSR comma
        LDB ipsave3
        JMP NEXT

        .word w_if-5
        .byte $84
        .ascii "THEN"
w_then: .code
        LDA [Z++]
        XAY
        LDA HERE
        STA [Y]
        JMP NEXT

        .word w_then-7
        .byte $84
        .ascii "ELSE"
w_else: .code
        STB ipsave3         ; B is the instruction pointer
        LDA #w_branch
        JSR comma
        LDA HERE
        STA newslot
        LDA #0
        JSR comma
        LDA [Z++]           ; fill in the IF's slot with where we are now
        XAY
        LDA HERE
        STA [Y]
        LDA newslot
        STA [--Z]
        LDB ipsave3
        JMP NEXT

        .word w_else-7
        .byte $85
        .ascii "BEGIN"
w_begin: .code
        LDA HERE
        STA [--Z]
        JMP NEXT

        .word w_begin-8
        .byte $85
        .ascii "UNTIL"
w_until: .code
        STB ipsave3         ; B is the instruction pointer
        LDA #w_qbranch
        JSR comma
        LDA [Z++]
        JSR comma
        LDB ipsave3
        JMP NEXT

        .word w_until-8
        .byte $85
        .ascii "AGAIN"
w_again: .code
        STB ipsave3         ; B is the instruction pointer
        LDA #w_branch
        JSR comma
        LDA [Z++]
        JSR comma
        LDB ipsave3
        JMP NEXT

        .word w_again-8
        .byte $82
        .ascii "DO"
w_do:   .code
        STB ipsave3         ; B is the instruction pointer
        LDA #r_do
        JSR comma
        LDA HERE            ; where LOOP comes back to
        STA [--Z]
        LDB ipsave3
        JMP NEXT

        .word w_do-5
        .byte $84
        .ascii "LOOP"
w_loop: .code
        STB ipsave3         ; B is the instruction pointer
        LDA #r_loop
        JSR comma
        LDA [Z++]
        JSR comma
        LDB ipsave3
        JMP NEXT

        .word w_loop-7
        .byte 9
        .ascii "IMMEDIATE"
w_imm:  .code
        STB ipsave3         ; B is the instruction pointer
        LDA LATEST          ; set the immediate bit on the newest entry. There
        STA newslot         ; is no dependable OR, but the bit is clear until
        XAY                 ; now, so adding it is the same thing.
        CLA
        LDAB [Y+$02]
        LDB #$80
        AAB
        STB cch
        LDA newslot
        XAY
        LDAB cch+1
        STAB [Y+$02]
        LDB ipsave3
        JMP NEXT

; A flag of all ones is true, and zero is false, as everywhere else.
tru:    LDA #$ffff          ; the comparisons above all end here, and they
        STA [--Z]           ; use B, so the instruction pointer comes back
        LDB ipsave3
        JMP NEXT
fls:    LDA #0
        STA [--Z]
        LDB ipsave3
        JMP NEXT

        .word w_imm-12
        .byte 1
        .ascii ","
w_dcomma: .code
        STB ipsave3         ; B is the instruction pointer
        LDA [Z++]
        JSR comma
        LDB ipsave3
        JMP NEXT

        .word w_dcomma-4
        .byte 5
        .ascii "ALLOT"
w_allot: .code
        STB ipsave3         ; B is the instruction pointer
        LDA [Z++]
        LDB HERE
        AAB                 ; AAB leaves its answer in B, not in A
        STB scr1
        LDA scr1
        STA HERE
        LDB ipsave3
        JMP NEXT

        .word w_allot-8
        .byte 6
        .ascii "CREATE"
w_create: .code
        STB ipsave3         ; B is the instruction pointer
        JSR mkhead
        LDA #DOVAR          ; a plain data word for now
        JSR comma
        LDA #0              ; and the empty cell DOES> fills in
        JSR comma
        LDA newent
        STA LATEST
        LDB ipsave3
        JMP NEXT

; DOES> is immediate: it runs while the defining word is being compiled, and
; all it does is compile the runtime below into it.
        .word w_create-9
        .byte $85
        .ascii "DOES>"
w_does: .code
        STB ipsave3         ; B is the instruction pointer
        LDA #r_does
        JSR comma
        LDB ipsave3
        JMP NEXT

; The runtime, which has no dictionary entry of its own because only DOES>
; compiles it. It runs when the *defining* word runs, at which point NEXT has
; already stepped the instruction pointer past this cell - so B is the thread
; that follows DOES>, which from here on belongs to the child rather than to
; the word being run. Hand it to the child, point the child at DODOES, and
; leave the defining word at once, because the rest of it is the child's.
r_does: .word rdoes_code
rdoes_code: STB ipsave3
        LDA LATEST          ; the newest entry's code field: a link and a flags
        XAY                 ; byte, then the name, so three plus its length
        CLA
        LDAB [Y+$02]
        LDB #$1f
        NAB
        STB scr1
        LDA LATEST
        LDB scr1
        AAB
        STB scr1
        LDA #3
        LDB scr1
        AAB
        STB scr1
        LDA scr1
        XAY
        LDA #DODOES         ; the child stops being a plain CREATEd word
        STA [Y]
        LDA scr1
        INA
        INA
        XAY
        LDA ipsave3         ; and remembers the thread to run
        STA [Y]
        LDB [S++]           ; then return from the defining word, as EXIT does
        JMP NEXT

        .word w_does-8
        .byte 1
        .ascii "'"
w_tick: .code
        STB ipsave3         ; B is the instruction pointer
        JSR parseword       ; the name follows in the input, not on the stack
        JSR find
        LDA scr2            ; find leaves the code field address here, or zero
        STA tkcfa           ; a store sets no flags, so the load's still stand
        BNZ tk_got
        JSR pr_word         ; say so rather than pushing a silent zero that
        LDA #'?'            ; only fails later, somewhere else
        JSR putc
        JSR crlf
tk_got: LDA tkcfa
        STA [--Z]
        LDB ipsave3
        JMP NEXT

        .word w_tick-4
        .byte 7
        .ascii "EXECUTE"
w_execute: .code
        LDA [Z++]           ; a code field address, as ' leaves
        XAX                 ; XAX is a move out of A, not an exchange
        JMP [[X]]           ; and this is the second half of NEXT. B is
                            ; untouched, so the word returns to the caller's
                            ; thread by itself.

; [ and ] switch between compiling and interpreting inside a definition. [ has
; to be immediate to run at all while compiling; ] must not be, because it is
; met while interpreting.
        .word w_execute-10
        .byte $81
        .ascii "["
w_lbrack: .code
        LDA #0
        STA STATE
        JMP NEXT

        .word w_lbrack-4
        .byte 1
        .ascii "]"
w_rbrack: .code
        LDA #1
        STA STATE
        JMP NEXT

; What carries a value computed between [ and ] back into the definition being
; compiled: without it the pair can change state but cannot leave anything
; behind. Lays down the same LIT that the interpreter compiles a number as.
        .word w_rbrack-4
        .byte $87
        .ascii "LITERAL"
w_literal: .code
        STB ipsave3         ; B is the instruction pointer
        LDA #w_lit
        JSR comma
        LDA [Z++]
        JSR comma
        LDB ipsave3
        JMP NEXT

; Comments. Both are immediate so that they work while compiling, which is
; where they are wanted most.
        .word w_literal-10
        .byte $81
        .ascii "\\"
w_bslash: .code
        LDA TIBLEN          ; the rest of the line is a comment
        STA TOIN
        JMP NEXT

        .word w_bslash-4
        .byte $81
        .ascii "("
w_paren: .code
        STB ipsave3         ; B is the instruction pointer
pn1:    LDA TOIN            ; up to the next ")", or the end of the line
        LDB TIBLEN
        SUB B,A
        BZ pn2
        JSR tibchar
        STA pnch
        LDA TOIN            ; step over it either way
        INA
        STA TOIN
        LDA pnch
        LDB #$29            ; ")", by value: a bare one here would sit oddly
        SUB B,A             ; in the middle of this file
        BZ pn2
        JMP pn1
pn2:    LDB ipsave3
        JMP NEXT

        .word w_paren-4
        .byte 2
        .ascii ">R"
w_tor:  .code
        LDA [Z++]
        STA [--S]
        JMP NEXT

        .word w_tor-5
        .byte 2
        .ascii "R>"
w_fromr: .code
        LDA [S++]
        STA [--Z]
        JMP NEXT

        .word w_fromr-5
        .byte 2
        .ascii "OR"
w_or:   .code
        STB ipsave3         ; B is the instruction pointer, and the load below
        LDA [Z++]           ; is about to overwrite it
        LDB [Z++]
        ORI B,A             ; like SUB B,A, the answer lands in the second
        STA [--Z]           ; operand rather than in B the way AAB and NAB do
        LDB ipsave3
        JMP NEXT

        .word w_or-5
        .byte 3
        .ascii "XOR"
w_xor:  .code
        STB ipsave3         ; B is the instruction pointer
        LDA [Z++]
        LDB [Z++]
        ORE B,A             ; OR exclusive, and again the answer is in A
        STA [--Z]
        LDB ipsave3
        JMP NEXT

        .word w_xor-6
        .byte 3
        .ascii "NOT"
w_not:  .code
        LDA [Z++]
        IVA
        STA [--Z]
        JMP NEXT

; The shifts are done a bit at a time. SLR and SRR take a count, but it is one
; less than the number of places they shift, and SRR propagates the sign, so
; neither is the plain shift wanted here.
        .word w_not-6
        .byte 6
        .ascii "LSHIFT"
w_lshift: .code
        LDA [Z++]           ; nothing here touches B, so the instruction
        STA shcnt           ; pointer does not have to be parked
        LDA [Z++]
        STA shval
ls1:    LDA shcnt
        BZ ls2
        LDA shval
        SLA
        STA shval
        LDA shcnt
        DCA
        STA shcnt
        JMP ls1
ls2:    LDA shval
        STA [--Z]
        JMP NEXT

        .word w_lshift-9
        .byte 6
        .ascii "RSHIFT"
w_rshift: .code
        STB ipsave3         ; B is the instruction pointer, and the masking
        LDA [Z++]           ; below needs it
        STA shcnt
        LDA [Z++]
        STA shval
rs1:    LDA shcnt
        BZ rs2
        LDA shval
        SRA
        LDB #$7fff          ; SRA carries the sign down with it; RSHIFT is
        NAB                 ; defined as the logical shift, so clear it again
        STB shval
        LDA shcnt
        DCA
        STA shcnt
        JMP rs1
rs2:    LDA shval
        STA [--Z]
        LDB ipsave3
        JMP NEXT

; ." prints the text up to the closing quote. Immediate, because while
; compiling it has to lay the text down inside the definition rather than print
; it there and then.
        .word w_rshift-9
        .byte $82
        .byte $2e, $22      ; the name is ." - a quote inside a quoted string
                            ; is not something this assembler can express
w_dotq: .code
        STB ipsave3         ; B is the instruction pointer
        JSR dqskip          ; the space after ." belongs to the syntax
        LDA STATE
        BZ dq_now
        JMP dq_comp
dq_now: JSR dqnext          ; interpreting: print it as it is read
        LDA dqch
        BZ dq_end
        JSR putc
        JMP dq_now
dq_end: LDB ipsave3
        JMP NEXT

dq_comp: LDA #r_dotstr      ; compiling: the runtime, then the text inline
        JSR comma
        LDA HERE
        STA dqlen           ; the length goes here, once it is known
        LDA #0
        JSR comma
        LDA #0
        STA dqn
dq_c1:  JSR dqnext
        LDA dqch
        BZ dq_c2
        LDA HERE
        XAY
        LDAB dqch+1
        STAB [Y]
        LDA HERE
        INA
        STA HERE
        LDA dqn
        INA
        STA dqn
        JMP dq_c1
dq_c2:  LDA dqn             ; pad to an even length: what follows the text is a
        LDB #$0001          ; code field address, and NEXT reads words
        NAB
        STB scr1
        LDA scr1
        BZ dq_c3
        LDA HERE
        XAY
        LDAB #0
        STAB [Y]
        LDA HERE
        INA
        STA HERE
dq_c3:  LDA dqlen
        XAY
        LDA dqn
        STA [Y]
        LDB ipsave3
        JMP NEXT

; The next character of the string into dqch, or zero at the closing quote or
; at the end of the line.
dqnext: LDA TOIN
        LDB TIBLEN
        SUB B,A
        BZ dqn0
        JSR tibchar
        STA dqch
        LDA TOIN
        INA
        STA TOIN
        LDA dqch
        LDB #$22
        SUB B,A
        BZ dqn0
        RSR
dqn0:   LDA #0
        STA dqch
        RSR

dqskip: LDA TOIN            ; step over one leading space, if there is one
        LDB TIBLEN
        SUB B,A
        BZ dqs0
        JSR tibchar
        LDB #' '
        SUB B,A
        BNZ dqs0
        LDA TOIN
        INA
        STA TOIN
dqs0:   RSR

; What a compiled ." runs. The instruction pointer is sitting on the length
; word, with the text after it, so this prints the text and then leaves the
; pointer on whatever follows.
r_dotstr: .word rds_code
rds_code: STB dsptr
        LDA dsptr
        XAY
        LDA [Y]
        STA dsn
        LDA dsptr
        INA
        INA
        STA dsptr
        LDA #0
        STA dsi
ds1:    LDA dsi
        LDB dsn
        SUB B,A
        BZ ds2
        LDA dsptr
        LDB dsi
        AAB
        STB scr1
        LDA scr1
        XAY
        CLA
        LDAB [Y]
        JSR putc
        LDA dsi
        INA
        STA dsi
        JMP ds1
ds2:    LDA dsn             ; the text was padded to an even length
        LDB #$0001
        NAB
        STB scr1
        LDA scr1
        BZ ds3
        LDA dsn
        INA
        STA dsn
ds3:    LDA dsptr
        LDB dsn
        AAB                 ; AAB leaves the sum in B, which is the pointer
        JMP NEXT

        .word w_dotq-5
        .byte 3
        .ascii "ROT"
w_rot:  .code
        LDA [Z]             ; ( a b c -- b c a ), so the third one comes up
        STA rt1
        LDA [Z+$02]
        STA rt2
        LDA [Z+$04]
        STA [Z]
        LDA rt1
        STA [Z+$02]
        LDA rt2
        STA [Z+$04]
        JMP NEXT

        .word w_rot-6
        .byte 4
        .ascii "PICK"
w_pick: .code
        STB ipsave3         ; B is the instruction pointer
        LDA [Z++]           ; how far down to reach: 0 PICK is DUP
        SLA                 ; the entries are words
        STA pktmp
        CLA                 ; there is no move out of Z, but it can be an
        SUB Z,A             ; operand, and Z minus nothing is Z
        LDB pktmp
        AAB                 ; AAB leaves the sum in B
        STB scr1
        LDA scr1
        XAY
        LDA [Y]
        STA [--Z]
        LDB ipsave3
        JMP NEXT

; DIV takes the dividend in A and the divisor in B, and leaves the remainder in
; A and the quotient in B. Measured in probe19.s: diag never uses it, so there
; was no worked example to copy.
        .word w_pick-7
        .byte 1
        .ascii "/"
w_slash: .code
        STB ipsave3         ; B is the instruction pointer
        LDA [Z++]
        STA dvsr
        LDA [Z++]
        LDB dvsr
        DIV B,A
        STB [--Z]
        LDB ipsave3
        JMP NEXT

        .word w_slash-4
        .byte 4
        .ascii "/MOD"
w_slashmod: .code
        STB ipsave3         ; B is the instruction pointer
        LDA [Z++]
        STA dvsr
        LDA [Z++]
        LDB dvsr
        DIV B,A
        STA [--Z]           ; ( n d -- rem quot ), the quotient on top
        STB [--Z]
        LDB ipsave3
        JMP NEXT

lastword .equ w_slashmod-7

; Print the dictionary entry at fp, followed by a space.
pr_entry:
        LDA fp
        XAY
        LDAB [Y+$02]
        LDB #$1f
        NAB
        STB flen2
        LDA #0
        STA fi
pe1:    LDA fi
        LDB flen2
        SUB B,A
        BZ pe2
        LDA fp
        LDB fi
        AAB
        STB scr1
        LDA scr1
        XAY
        LDAB [Y+$03]
        JSR putc
        LDA fi
        INA
        STA fi
        JMP pe1
pe2:    LDA #' '
        JMP putc
