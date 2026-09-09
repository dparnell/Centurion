; ---------------------------------------------------------------------------
; Centurion FORTH - an indirect threaded FORTH for the CPU6.
;
;   make run SRC=forth.s IN=tests/forth_core.f FOR=400
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
;       because they nest.
;   A   scratch, and the argument to every helper below.
;   Y   free.
;
; The implicit-register arithmetic - SAB, AAB, NAB - leaves the sign flag alone,
; so BM after one of them tests something stale. The register-to-register forms
; SUB B,A, AAB and NAB do the same work and do set it, so this file uses
; those throughout. BL after a subtraction is the borrow, which is the unsigned
; comparison. Finding this cost a hang in the number printer, whose loop
; subtracts until the result goes negative.
;
; NEXT is two instructions:  LDX [B++]  fetches the next code field address,
; JMP [[Y]] jumps to the machine code whose address that field holds. The extra
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
        JMP interp

; ---------------------------------------------------------------------------
; The inner interpreter
; ---------------------------------------------------------------------------
NEXT:   LDX [B++]
        JMP [[Y]]

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
retmc:  LDB ipsave2
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
        LDAB rlch
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
        LDAB pwch
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
        SUB B,A             ; B = character - '0'
        BM dvbad
        STB dval
        LDA #9
        LDB dval
        SUB B,A
        BM dvck
        BZ dvck
        LDA #'A'            ; not a decimal digit, so try the letters
        LDB dch
        SUB B,A
        BM dvbad
        STB dval
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
pw1:    LDA npow            ; the power just built
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
pw2:    LDA pcur
        LDB pnext
        AAB
        STB pnext
        LDA pcount
        DCA
        STA pcount
        LDB #0
        SUB B,A
        BNZ pw2
        LDA pnext           ; did it wrap round?
        LDB pcur
        SUB B,A
        BM pw3
        JMP pwdone
pw3:    LDA nval            ; is it already past the value?
        LDB pnext
        SUB B,A
        BM pw4
        JMP pwdone
pw4:    LDA npow
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
        JMP pw1
pwdone: LDA npow            ; now take each power out in turn
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
        BM pd2
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
        JMP pwdone
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
        LDAB [Y]
        STAB scr2
        LDA scr2
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


; ---- the runtime halves of the control structures -------------------------
; These have no dictionary entries of their own: the compiling words below lay
; their code field addresses down, and nothing else should reach them.

r_branch: .word rb_code     ; ( -- ) the cell after it is where to go
rb_code: LDA [B]
        STA ipsave
        LDB ipsave
        JMP NEXT

r_qbranch: .word rq_code    ; ( flag -- ) go there when the flag is zero
rq_code: LDA [Z++]
        LDB #0
        SUB B,A
        BZ rq_take
        LDA [B++]           ; not taken: step over the target
        JMP NEXT
rq_take: LDA [B]
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
rl_code: LDA [S++]
        INA
        STA dtmp1
        LDA [S]             ; the limit, without taking it off
        LDB dtmp1
        SUB B,A             ; A = index - limit
        BM rl_again
        JMP rl_done
rl_again: LDA dtmp1
        STA [--S]
        LDA [B]
        STA ipsave
        LDB ipsave
        JMP NEXT
rl_done: LDA [S++]          ; drop the limit
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
        LDA [Z++]
        LDB [Z++]
        AAB
        STB [--Z]
        JMP NEXT

        .word w_plus-4
        .byte 1
        .ascii "-"
w_minus: .code
        LDA [Z++]
        LDB [Z++]
        SUB B,A
        STB [--Z]
        JMP NEXT

        .word w_minus-4
        .byte 3
        .ascii "AND"
w_and:  .code
        LDA [Z++]
        LDB [Z++]
        NAB
        STB [--Z]
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
        LDA [Z++]
        JSR putc
        JMP NEXT

        .word w_emit-7
        .byte 3
        .ascii "KEY"
w_key:  .code
        JSR getc
        LDB #$7f
        NAB
        STB [--Z]
        JMP NEXT

        .word w_key-6
        .byte 2
        .ascii "CR"
w_cr:   .code
        JSR crlf
        JMP NEXT

        .word w_cr-5
        .byte 1
        .ascii "."
w_dot:  .code
        LDA [Z++]
        JSR prnum
        LDA #' '
        JSR putc
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
        LDB [S++]
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
        LDA [Z++]
        LDB [Z++]
        SUB B,A
        BZ tru
        JMP fls

        .word w_eq-4
        .byte 1
        .ascii "<"
w_lt:   .code
        LDA [Z++]           ; ( a b -- flag ) with b on top
        LDB [Z++]
        SUB B,A             ; A = a - b
        BM tru
        JMP fls

        .word w_lt-4
        .byte 1
        .ascii ">"
w_gt:   .code
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
        JSR parseword
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
        LDAB cch
        STAB [Y]
        LDA HERE
        INA
        STA HERE
        LDA ci
        INA
        STA ci
        JMP cn1
cn2:    LDA #DOCOL          ; and the code field
        JSR comma
        LDA newent
        STA LATEST
        LDA #1
        STA STATE
        JMP NEXT

        .word w_colon-4
        .byte $81
        .ascii ";"
w_semi: .code
        LDA #w_exit
        JSR comma
        LDA #0
        STA STATE
        JMP NEXT

        .word w_semi-4
        .byte $82
        .ascii "IF"
w_if:   .code
        LDA #w_qbranch
        JSR comma
        LDA HERE            ; remember the slot to fill in later
        STA [--Z]
        LDA #0
        JSR comma
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
        LDA #w_qbranch
        JSR comma
        LDA [Z++]
        JSR comma
        JMP NEXT

        .word w_until-8
        .byte $85
        .ascii "AGAIN"
w_again: .code
        LDA #w_branch
        JSR comma
        LDA [Z++]
        JSR comma
        JMP NEXT

        .word w_again-8
        .byte $82
        .ascii "DO"
w_do:   .code
        LDA #r_do
        JSR comma
        LDA HERE            ; where LOOP comes back to
        STA [--Z]
        JMP NEXT

        .word w_do-5
        .byte $84
        .ascii "LOOP"
w_loop: .code
        LDA #r_loop
        JSR comma
        LDA [Z++]
        JSR comma
        JMP NEXT

        .word w_loop-7
        .byte 9
        .ascii "IMMEDIATE"
w_imm:  .code
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
        LDAB cch
        STAB [Y+$02]
        JMP NEXT

; A flag of all ones is true, and zero is false, as everywhere else.
tru:    LDA #$ffff
        STA [--Z]
        JMP NEXT
fls:    LDA #0
        STA [--Z]
        JMP NEXT

lastword .equ w_imm-12

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
        STAB scr2
        LDA scr2
        JSR putc
        LDA fi
        INA
        STA fi
        JMP pe1
pe2:    LDA #' '
        JMP putc
