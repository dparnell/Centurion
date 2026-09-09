#!/usr/bin/env python3
"""A small assembler for the Centurion CPU6.

    python Assemble.py forth.s programs/forth.txt

Programs for this machine used to be hand written as hex bytes with comments,
which is fine for a twenty byte blink loop and hopeless for anything larger.
This produces the same `programs/*.txt` format, so nothing downstream changes.

The opcode table below is derived from the CPU6 reference manual's
data/opcodes.yaml and is embedded rather than read at run time, so that a
checked in program can be rebuilt without fetching anything. "--verify
opcodes.yaml" cross checks the two, and "--roundtrip programs/diag.txt 8000"
re-encodes every instruction the disassembler can read out of a real program
and reports any that do not come back byte for byte - which is how the operand
encodings below were confirmed against six thousand real instructions rather
than against my reading of a manual.

Syntax
------
    ; comment                    ANY line may end with a comment
    label:                       a label, on its own line or before an opcode
    NAME .equ $1234              a constant
        .org $8000               set the assembly address
        .byte $01, 'A', 13       bytes
        .word $1234, label       big endian words, as the machine stores them
        .ascii  "text"           bytes, no terminator
        .asciiz "text"           bytes, NUL terminated
        .space 32                that many zero bytes
        .code                    a code field pointing at the code after it
        .align 2                 pad to a multiple

Operands
--------
        LDA  #$1234     immediate      LDA  $1234      direct
        LDA  @$1234     indirect       LDA  label      direct
        JMP  *label     pc relative     JMP  @*label    relative indirect
        BNZ  label      pc relative, the assembler works out the displacement
        LDA  [X]        through a register       LDA [X++]   and step it after
        LDA  [--X]      step it first            LDA [X+$10] with displacement
        LDA  [[X]]      through the word the register points at
        ADD  A,B        register to register     INR X,1     register and count

Registers are A B X Y Z S C P as words, and AH AL BH BL XH XL YH YL ZH ZL SH
SL CH CL PH PL as their halves. A word register's nibble is twice its number,
which is the one encoding detail worth knowing when reading a hex dump.
"""

import argparse
import re
import sys

# (addressing mode, width, opcode) for every non-extended instruction.
OPCODES = {
    'AAB':  [('impl', 'w', 0x58)],
    'AABB': [('impl', 'b', 0x48)],
    'ADD':  [('rr', 'w', 0x50)],
    'ADDB': [('rr', 'b', 0x40)],
    'AND':  [('rr', 'w', 0x52)],
    'ANDB': [('rr', 'b', 0x42)],
    'BCK':  [('pco', 'b', 0x1f)],
    'BF':   [('pco', 'b', 0x12)],
    'BGZ':  [('pco', 'b', 0x18)],
    'BI':   [('pco', 'b', 0x1e)],
    'BL':   [('pco', 'b', 0x10)],
    'BLE':  [('pco', 'b', 0x19)],
    'BM':   [('pco', 'b', 0x16)],
    'BNF':  [('pco', 'b', 0x13)],
    'BNL':  [('pco', 'b', 0x11)],
    'BNZ':  [('pco', 'b', 0x15)],
    'BP':   [('pco', 'b', 0x17)],
    'BS1':  [('pco', 'b', 0x1a)],
    'BS2':  [('pco', 'b', 0x1b)],
    'BS3':  [('pco', 'b', 0x1c)],
    'BS4':  [('pco', 'b', 0x1d)],
    'BZ':   [('pco', 'b', 0x14)],
    'CL':   [('impl', 'b', 0x08)],
    'CLA':  [('impl', 'w', 0x3a)],
    'CLAB': [('impl', 'b', 0x2a)],
    'CLR':  [('rc', 'w', 0x32)],
    'CLRB': [('rc', 'b', 0x22)],
    'DAO':  [('impl', 'b', 0x57)],
    'DCA':  [('impl', 'w', 0x39)],
    'DCAB': [('impl', 'b', 0x29)],
    'DCK':  [('impl', 'b', 0xc6)],
    'DCR':  [('rc', 'w', 0x31)],
    'DCRB': [('rc', 'b', 0x21)],
    'DCX':  [('impl', 'w', 0x3f)],
    'DI':   [('impl', 'b', 0x05)],
    'DIV':  [('rrx', 'w', 0x78)],
    'DLY':  [('impl', 'b', 0x0e)],
    'DPE':  [('impl', 'b', 0x86)],
    'EAO':  [('impl', 'b', 0x56)],
    'ECK':  [('impl', 'b', 0xb6)],
    'EI':   [('impl', 'b', 0x04)],
    'EPE':  [('impl', 'b', 0x76)],
    'HLT':  [('impl', 'b', 0x00)],
    'INA':  [('impl', 'w', 0x38)],
    'INAB': [('impl', 'b', 0x28)],
    'INR':  [('rc', 'w', 0x30)],
    'INRB': [('rc', 'b', 0x20)],
    'INX':  [('impl', 'w', 0x3e)],
    'IVA':  [('impl', 'w', 0x3b)],
    'IVAB': [('impl', 'b', 0x2b)],
    'IVR':  [('rc', 'w', 0x33)],
    'IVRB': [('rc', 'b', 0x23)],
    'JMP':  [('dir', 'b', 0x71), ('idx', 'b', 0x75), ('ind', 'b', 0x72),
             ('pco', 'b', 0x73), ('pcoi', 'b', 0x74)],
    'JSR':  [('dir', 'b', 0x79), ('idx', 'b', 0x7d), ('ind', 'b', 0x7a),
             ('pco', 'b', 0x7b), ('pcoi', 'b', 0x7c)],
    'LDA':  [('dir', 'w', 0x91), ('idx', 'w', 0x95), ('imm', 'w', 0x90),
             ('ind', 'w', 0x92), ('pco', 'w', 0x93), ('pcoi', 'w', 0x94)],
    'LDAB': [('dir', 'b', 0x81), ('idx', 'b', 0x85), ('imm', 'b', 0x80),
             ('ind', 'b', 0x82), ('pco', 'b', 0x83), ('pcoi', 'b', 0x84)],
    'LDB':  [('dir', 'w', 0xd1), ('idx', 'w', 0xd5), ('imm', 'w', 0xd0),
             ('ind', 'w', 0xd2), ('pco', 'w', 0xd3), ('pcoi', 'w', 0xd4)],
    'LDBB': [('dir', 'b', 0xc1), ('idx', 'b', 0xc5), ('imm', 'b', 0xc0),
             ('ind', 'b', 0xc2), ('pco', 'b', 0xc3), ('pcoi', 'b', 0xc4)],
    'LDX':  [('dir', 'w', 0x61), ('idx', 'w', 0x65), ('imm', 'w', 0x60),
             ('ind', 'w', 0x62), ('pco', 'w', 0x63), ('pcoi', 'w', 0x64)],
    'LST':  [('dir', 'b', 0x6e)],
    'MUL':  [('rrx', 'w', 0x77)],
    'MVL':  [('impl', 'w', 0xf7)],
    'NAB':  [('impl', 'w', 0x5a)],
    'NABB': [('impl', 'b', 0x4a)],
    'NOP':  [('impl', 'b', 0x01)],
    'ORE':  [('rr', 'w', 0x54)],
    'OREB': [('rr', 'b', 0x44)],
    'ORI':  [('rr', 'w', 0x53)],
    'ORIB': [('rr', 'b', 0x43)],
    'PCX':  [('impl', 'w', 0x0d)],
    'RF':   [('impl', 'b', 0x03)],
    'RI':   [('impl', 'b', 0x0a)],
    'RL':   [('impl', 'b', 0x07)],
    'RLR':  [('rc', 'w', 0x37)],
    'RLRB': [('rc', 'b', 0x27)],
    'RRR':  [('rc', 'w', 0x36)],
    'RRRB': [('rc', 'b', 0x26)],
    'RSR':  [('impl', 'b', 0x09)],
    'RSV':  [('impl', 'b', 0x0f)],
    'SAB':  [('impl', 'w', 0x59)],
    'SABB': [('impl', 'b', 0x49)],
    'SEP':  [('impl', 'b', 0xa6)],
    'SF':   [('impl', 'b', 0x02)],
    'SL':   [('impl', 'b', 0x06)],
    'SLA':  [('impl', 'w', 0x3d)],
    'SLAB': [('impl', 'b', 0x2d)],
    'SLR':  [('rc', 'w', 0x35)],
    'SLRB': [('rc', 'b', 0x25)],
    'SOP':  [('impl', 'b', 0x96)],
    'SRA':  [('impl', 'w', 0x3c)],
    'SRAB': [('impl', 'b', 0x2c)],
    'SRR':  [('rc', 'w', 0x34)],
    'SRRB': [('rc', 'b', 0x24)],
    'SST':  [('dir', 'b', 0x6f)],
    'STR':  [('rrsr', 'w', 0xd6)],
    'STA':  [('dir', 'w', 0xb1), ('idx', 'w', 0xb5), ('imm', 'w', 0xb0),
             ('ind', 'w', 0xb2), ('pco', 'w', 0xb3), ('pcoi', 'w', 0xb4)],
    'STAB': [('dir', 'b', 0xa1), ('idx', 'b', 0xa5), ('imm', 'b', 0xa0),
             ('ind', 'b', 0xa2), ('pco', 'b', 0xa3), ('pcoi', 'b', 0xa4)],
    'STB':  [('dir', 'w', 0xf1), ('idx', 'w', 0xf5), ('imm', 'w', 0xf0),
             ('ind', 'w', 0xf2), ('pco', 'w', 0xf3), ('pcoi', 'w', 0xf4)],
    'STBB': [('dir', 'b', 0xe1), ('idx', 'b', 0xe5), ('imm', 'b', 0xe0),
             ('ind', 'b', 0xe2), ('pco', 'b', 0xe3), ('pcoi', 'b', 0xe4)],
    'STX':  [('dir', 'w', 0x69), ('idx', 'w', 0x6d), ('imm', 'w', 0x68),
             ('ind', 'w', 0x6a), ('pco', 'w', 0x6b), ('pcoi', 'w', 0x6c)],
    'SUB':  [('rr', 'w', 0x51)],
    'SUBB': [('rr', 'b', 0x41)],
    'SVC':  [('imm', 'b', 0x66)],
    'SYN':  [('impl', 'b', 0x0c)],
    'XAB':  [('impl', 'w', 0x5d)],
    'XABB': [('impl', 'b', 0x4d)],
    'XAS':  [('impl', 'w', 0x5f)],
    'XASB': [('impl', 'b', 0x4f)],
    'XAX':  [('impl', 'w', 0x5b)],
    'XAXB': [('impl', 'b', 0x4b)],
    'XAY':  [('impl', 'w', 0x5c)],
    'XAYB': [('impl', 'b', 0x4c)],
    'XAZ':  [('impl', 'w', 0x5e)],
    'XAZB': [('impl', 'b', 0x4e)],
    'XFR':  [('rrs', 'w', 0x55)],
    'XFRB': [('rr', 'b', 0x45)],
}

# The count field of a register-and-count instruction is stored one less than
# it reads, for the two that count rather than select.
RC_BIAS = {'INR': 1, 'DCR': 1, 'INRB': 1, 'DCRB': 1}

# A conditional branch reaches 127 bytes either way. When the target is further
# than that the assembler branches over a jump instead, which is what an
# assembler is for; writing that out by hand turns readable code into a thicket
# of skip labels.
#
# It uses the same condition rather than the opposite one, over an extra jump.
# That costs three bytes and is the only safe thing to do here: BM and BP are
# not complements on this machine - after a subtraction BM behaves and BP does
# not - so relaxing BM into BP produced a loop that never ended and looked for
# all the world like a bug in the loop.

WORD_REGS = {'A': 0, 'B': 1, 'X': 2, 'Y': 3, 'Z': 4, 'S': 5, 'C': 6, 'P': 7}
BYTE_REGS = {}
for _n, _i in WORD_REGS.items():
    BYTE_REGS[_n + 'H'] = _i * 2
    BYTE_REGS[_n + 'L'] = _i * 2 + 1

# Extended instructions, whose operands this assembler emits literally rather
# than trying to model. PAGE is the one the FORTH kernel needs.
EXTENDED = {'PAGE': 0x2e, 'DMA': 0x2f, 'MEM': 0x47, 'STK': 0x7e, 'POP': 0x7f}


WORD_NAMES = ['A', '?', 'B', '?', 'X', '?', 'Y', '?',
              'Z', '?', 'S', '?', 'C', '?', 'P', '?']
BYTE_NAMES = ['AH', 'AL', 'BH', 'BL', 'XH', 'XL', 'YH', 'YL',
              'ZH', 'ZL', 'SH', 'SL', 'CH', 'CL', 'PH', 'PL']


class AsmError(Exception):
    pass


def word_nibble(name):
    if name.upper() not in WORD_REGS:
        raise AsmError("not a word register: %s" % name)
    return WORD_REGS[name.upper()] * 2


def byte_nibble(name):
    if name.upper() not in BYTE_REGS:
        raise AsmError("not a byte register: %s" % name)
    return BYTE_REGS[name.upper()]


def reg_nibble(name, width):
    return byte_nibble(name) if width == 'b' else word_nibble(name)


class Assembler:
    def __init__(self):
        self.relaxed = set()        # lines whose branch needs the long form
        # The first sizing pass has no label values yet, so every forward
        # branch looks impossibly far. Relaxing on that basis marks nearly all
        # of them, which is merely wasteful - except that it also turned a
        # perfectly ordinary loop into one that never ended, because BM and BP
        # are not complements on this machine.
        self.have_labels = False
        self.labels = {}
        self.out = bytearray()
        self.org = 0
        self.start = None
        self.listing = []

    # ---- expressions -------------------------------------------------
    def value(self, text, need=True):
        """A number, a character, a label, or a sum or difference of those."""
        text = text.strip()
        if not text:
            raise AsmError("empty expression")
        # A quoted character first, before the split below, or '-' and '+'
        # come apart into their own operators.
        if len(text) == 3 and text[0] == "'" and text[2] == "'":
            return ord(text[1])
        total, sign, i = 0, 1, 0
        for part in re.split(r'([+-])', text):
            part = part.strip()
            if part == '+':
                sign = 1
                continue
            if part == '-':
                sign = -1
                continue
            if not part:
                continue
            total += sign * self.term(part, need)
            sign = 1
            i += 1
        return total & 0xffff

    def term(self, t, need):
        if t.startswith('$'):
            return int(t[1:], 16)
        if t.lower().startswith('0x'):
            return int(t[2:], 16)
        if len(t) == 3 and t[0] == "'" and t[2] == "'":
            return ord(t[1])
        if re.fullmatch(r'\d+', t):
            return int(t)
        if t in self.labels:
            return self.labels[t]
        if need:
            raise AsmError("unknown symbol: %s" % t)
        return 0

    # ---- operand forms -----------------------------------------------
    IDX_RE = re.compile(r'^\s*(--)?\s*([A-Za-z]+)\s*(\+\+)?\s*'
                        r'([+-]\s*\S+)?\s*$')

    def index_operand(self, text, size_only):
        """[reg], [reg++], [--reg], [reg+d], [reg-d] and the doubly
        indirect [[...]] form. The displacement may be negative, which the
        first version of this did not allow and which real code uses."""
        body = text.strip()
        double = body.startswith('[[')
        body = body.strip('[').rstrip(']')
        m = self.IDX_RE.match(body)
        if not m:
            raise AsmError("cannot read the register operand %r" % text)
        predec, reg, postinc, disp = m.groups()
        flags = 0
        if postinc:
            flags |= 1
        if predec:
            flags |= 2
        if double:
            flags |= 4
        extra = b''
        if disp is not None:
            flags |= 8
            sign = -1 if disp.strip()[0] == '-' else 1
            d = sign * self.value(disp.strip()[1:], not size_only)
            d = d - 0x10000 if d > 0x7fff else d
            if not -128 <= d <= 127:
                raise AsmError("displacement %d out of range" % d)
            extra = bytes([d & 0xff])
        return 'idx', bytes([(word_nibble(reg) << 4) | flags]) + extra

    def operand(self, text, width, here, size_only=False):
        """Return (mode, extra_bytes)."""
        text = text.strip()
        if text == '':
            return 'impl', b''
        if text.startswith('#'):
            v = self.value(text[1:], not size_only)
            return 'imm', bytes([v & 0xff]) if width == 'b' \
                else bytes([(v >> 8) & 0xff, v & 0xff])
        if text.startswith('@*'):
            return 'pcoi', bytes([self.displacement(text[2:], here, size_only)])
        if text.startswith('*'):
            return 'pco', bytes([self.displacement(text[1:], here, size_only)])
        if text.startswith('@'):
            v = self.value(text[1:], not size_only)
            return 'ind', bytes([(v >> 8) & 0xff, v & 0xff])
        if text.startswith('['):
            return self.index_operand(text, size_only)
        # bare: a direct address
        v = self.value(text, not size_only)
        return 'dir', bytes([(v >> 8) & 0xff, v & 0xff])

    def displacement(self, expr, here, size_only):
        """A pc relative operand is one byte, so the instruction is two."""
        target = self.value(expr, not size_only)
        d = (target - (here + 2)) & 0xffff
        d = d - 0x10000 if d > 0x7fff else d
        if not size_only and not -128 <= d <= 127:
            raise AsmError("%s is %d bytes away, too far to reach" % (expr, d))
        return d & 0xff

    def encode(self, mnemonic, arg, here, size_only=False, lineno=None):
        mn = mnemonic.upper()
        if mn in EXTENDED:
            args = [a for a in arg.split(',') if a.strip()]
            out = bytearray([EXTENDED[mn]])
            for n, a in enumerate(args):
                v = self.value(a, not size_only)
                # PAGE and DMA end with the memory address the block move
                # reads or writes, which is a word.
                if mn in ('PAGE', 'DMA') and n == 2:
                    out += bytes([(v >> 8) & 0xff, v & 0xff])
                else:
                    out.append(v & 0xff)
            return bytes(out)
        if mn not in OPCODES:
            raise AsmError("unknown instruction: %s" % mnemonic)
        forms = {m: (w, op) for m, w, op in OPCODES[mn]}

        # register-to-register and register-and-count take "R,R" or "R,n"
        two_reg = ('rr', 'rrs', 'rrsr', 'rrx')
        if any(m in forms for m in two_reg) or 'rc' in forms:
            mode = next((m for m in two_reg if m in forms), 'rc')
            width, op = forms[mode]
            if ',' not in arg:
                raise AsmError("%s needs two operands" % mn)
            lhs, rhs = [p.strip() for p in arg.split(',', 1)]
            if mode == 'rc':
                n = self.value(rhs, not size_only) - RC_BIAS.get(mn, 0)
                if not 0 <= n <= 15:
                    raise AsmError("%s count out of range" % mn)
                return bytes([op, (reg_nibble(lhs, width) << 4) | n])
            return bytes([op, (reg_nibble(lhs, width) << 4)
                          | reg_nibble(rhs, width)])

        if 'pco' in forms and len(forms) == 1:      # a branch: always relative
            width, op = forms['pco']
            target = self.value(arg.lstrip('*'), not size_only)
            if lineno in self.relaxed:
                #   B<cond> over the first jump
                #   JMP carry on
                #   JMP the real target
                # carry on:
                cont = here + 8
                return bytes([op, 3,
                              0x71, (cont >> 8) & 0xff, cont & 0xff,
                              0x71, (target >> 8) & 0xff, target & 0xff])
            d = (target - (here + 2)) & 0xffff
            d = d - 0x10000 if d > 0x7fff else d
            if not -128 <= d <= 127 and self.have_labels:
                self.relaxed.add(lineno)
                return bytes(8)     # the right size; the value comes next pass
            if not -128 <= d <= 127 and not size_only:
                raise AsmError("branch to %s is %d bytes away, too far"
                               % (arg, d))
            return bytes([op, d & 0xff])

        width = OPCODES[mn][0][1]
        mode, extra = self.operand(arg, width, here, size_only)
        if mode not in forms:
            raise AsmError("%s has no %s form" % (mn, mode))
        return bytes([forms[mode][1]]) + extra

    # ---- the two passes ----------------------------------------------
    # A label may end with a colon, or be followed directly by .equ, which is
    # how constants read most naturally.
    LINE_RE = re.compile(r'^\s*(?:(\w+)(?::|(?=\s+\.equ\b)))?\s*(\S+)?\s*(.*)$')

    def line_bytes(self, label, opc, arg, here, size_only, lineno=None):
        if opc is None:
            return b''
        o = opc.lower()
        if o == '.org':
            return None                      # handled by the caller
        if o in ('.byte', '.db'):
            vals = []
            for p in split_args(arg):
                if p.startswith('"'):
                    vals.extend(unquote(p))
                else:
                    vals.append(self.value(p, not size_only) & 0xff)
            return bytes(vals)
        if o in ('.word', '.dw'):
            out = bytearray()
            for p in split_args(arg):
                v = self.value(p, not size_only)
                out += bytes([(v >> 8) & 0xff, v & 0xff])
            return bytes(out)
        if o == '.ascii':
            return bytes(unquote(arg.strip()))
        if o == '.asciiz':
            return bytes(unquote(arg.strip())) + b'\x00'
        if o == '.code':
            # A primitive's code field holds the address of its machine code,
            # which follows immediately. Writing that as a literal would mean
            # naming every primitive twice.
            return bytes([((here + 2) >> 8) & 0xff, (here + 2) & 0xff])
        if o in ('.space', '.ds'):
            return bytes(self.value(arg, not size_only))
        if o == '.align':
            n = self.value(arg, not size_only)
            pad = (-here) % n
            return bytes(pad)
        if o == '.equ':
            return b''
        return self.encode(opc, arg, here, size_only, lineno)

    def assemble(self, text):
        self.pass_over(text, True)      # a first pass, to learn the labels
        self.have_labels = True
        for _ in range(20):
            before = set(self.relaxed)
            self.pass_over(text, True)
            if self.relaxed == before:
                break
        else:
            raise AsmError("branch relaxation did not settle")
        return self.pass_over(text, False)

    def pass_over(self, text, size_only):
        for size_only in (size_only,):
            here = self.org
            self.out = bytearray()
            self.listing = []
            first = None
            for lineno, raw in enumerate(text.splitlines(), 1):
                line = strip_comment(raw).rstrip()
                if not line.strip():
                    continue
                m = self.LINE_RE.match(line)
                label, opc, arg = m.groups()
                arg = (arg or '').strip()
                try:
                    if opc and opc.lower() == '.equ':
                        if not label:
                            raise AsmError(".equ needs a name")
                        self.labels[label] = self.value(arg, not size_only)
                        continue
                    if opc and opc.lower() == '.org':
                        new = self.value(arg, not size_only)
                        if first is None:
                            self.org, here, first = new, new, new
                        else:
                            if new < here:
                                raise AsmError(".org goes backwards")
                            self.out += bytes(new - here)
                            here = new
                        if label:
                            self.labels[label] = here
                        continue
                    if label:
                        self.labels[label] = here
                    data = self.line_bytes(label, opc, arg, here, size_only,
                                           lineno)
                except AsmError as e:
                    raise AsmError("line %d: %s\n    %s" % (lineno, e, raw))
                if data is None:
                    continue
                if not size_only and data:
                    self.listing.append((here, data, raw.strip()))
                self.out += data
                here += len(data)
        return bytes(self.out)


def strip_comment(line):
    """Take off a trailing comment, but not one inside a string.

    The comment character is also a perfectly good thing to want in a string -
    a FORTH kernel has to name a word ";" - and stripping it blindly turned
    .ascii ";" into a zero length name, which broke a dictionary chain without
    a word of complaint from anything."""
    out = []
    quoted = False
    for i, ch in enumerate(line):
        if ch == '"':
            quoted = not quoted
        elif ch == ';' and not quoted:
            break
        out.append(ch)
    return ''.join(out)


def split_args(text):
    out, cur, q = [], '', False
    for ch in text:
        if ch == '"':
            q = not q
        if ch == ',' and not q:
            out.append(cur.strip())
            cur = ''
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def unquote(text):
    text = text.strip()
    if not (text.startswith('"') and text.endswith('"')):
        raise AsmError("expected a quoted string, got %r" % text)
    body = text[1:-1]
    body = body.replace('\\r', '\r').replace('\\n', '\n')
    body = body.replace('\\0', '\0').replace('\\\\', '\\')
    return [ord(c) & 0xff for c in body]


def write_image(path, data, org, listing):
    with open(path, 'w') as f:
        f.write("// Assembled by Assemble.py; do not edit by hand.\n")
        by_addr = {a: (d, src) for a, d, src in listing}
        addr = org
        i = 0
        while i < len(data):
            if addr in by_addr:
                d, src = by_addr[addr]
                f.write("%s\n" % ' '.join("%02x" % b for b in d)
                        if False else '')
                for j, b in enumerate(d):
                    f.write("%02x%s\n" % (b, ("  // %04x  %s" % (addr, src))
                                          if j == 0 else ""))
                addr += len(d)
                i += len(d)
            else:
                f.write("%02x\n" % data[i])
                addr += 1
                i += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('source', nargs='?')
    ap.add_argument('output', nargs='?')
    ap.add_argument('--verify', metavar='OPCODES_YAML',
                    help='cross check the embedded table against the manual')
    ap.add_argument('--roundtrip', nargs=2, metavar=('PROGRAM', 'ORG'),
                    help='re-encode a real program and report any differences')
    args = ap.parse_args()

    if args.verify:
        return verify(args.verify)
    if args.roundtrip:
        return roundtrip(args.roundtrip[0], int(args.roundtrip[1], 16))

    if not args.source or not args.output:
        ap.error("need a source and an output, or --verify/--roundtrip")
    asm = Assembler()
    try:
        data = asm.assemble(open(args.source).read())
    except AsmError as e:
        print("error: %s" % e, file=sys.stderr)
        return 1
    write_image(args.output, data, asm.org, asm.listing)
    print("%s: %d bytes from %04x to %04x"
          % (args.output, len(data), asm.org, asm.org + len(data) - 1))
    return 0


def verify(path):
    sys.path.insert(0, '.')
    from Disassemble import load_opcodes, eff_mode
    ops = load_opcodes(path)
    theirs = {}
    for a, o in ops.items():
        if o.get('illegal') or o.get('ext'):
            continue
        if 'implr_dir' in (o.get('mode'), o.get('src')):
            continue
        theirs[(o['mnemonic'], eff_mode(o) or 'impl', o.get('width', 'b'))] = a
    mine = {(mn, m, w): op for mn, fs in OPCODES.items() for m, w, op in fs}
    bad = 0
    for k in sorted(set(mine) | set(theirs), key=str):
        if mine.get(k) != theirs.get(k):
            print("  differs %s: embedded %s, manual %s"
                  % (k, mine.get(k), theirs.get(k)))
            bad += 1
    print("%d entries checked, %d differences" % (len(theirs), bad))
    return 1 if bad else 0


def roundtrip(path, org):
    """Re-encode everything the disassembler can read, and compare bytes."""
    sys.path.insert(0, '.')
    from Disassemble import load_opcodes, text as dis_text
    ops = load_opcodes('opcodes.yaml')
    mem = []
    for line in open(path):
        line = line.split('//')[0].strip()
        for tok in line.split():
            mem.append(int(tok, 16))
    asm = Assembler()
    checked = same = skipped = 0
    bad = []
    i = 0
    while i + 8 < len(mem):
        addr = org + i
        t, n = dis_text(ops, mem, i, addr)
        parts = t.split(None, 1)
        mn = parts[0]
        arg = parts[1] if len(parts) > 1 else ''
        i += n
        if mn not in OPCODES or mn.startswith('?'):
            skipped += 1
            continue
        # Re-encode in the form the program actually used, rather than
        # guessing from the printed text: the disassembler shows a pc
        # relative jump as an absolute target, which would otherwise come
        # back as the direct form and count as a false difference.
        opbyte = mem[i - n]
        form = next((m for m, w, o in OPCODES[mn] if o == opbyte), None)
        if form is None:
            skipped += 1
            continue
        if form == 'imm':
            arg = '#$' + arg.lstrip('#')
        elif form == 'dir':
            arg = '$' + arg
        elif form == 'ind':
            arg = '@$' + arg.lstrip('@')
        elif form == 'pco':
            arg = '*$' + arg
        elif form == 'pcoi':
            arg = '@*$' + arg.lstrip('@')
        elif form == 'idx':
            if '?' in arg:      # an unnamed register or step mode
                skipped += 1
                continue
        elif form in ('rr', 'rrs', 'rrsr', 'rrx'):
            if form == 'rrx' and n > 2:
                skipped += 1     # carries an address as well; not modelled
                continue
            b = mem[i - n + 1]
            width = next(w for m, w, o in OPCODES[mn] if o == opbyte)
            names = BYTE_NAMES if width == 'b' else WORD_NAMES
            if names[b >> 4] == '?' or names[b & 15] == '?':
                skipped += 1
                continue
            arg = '%s,%s' % (names[b >> 4], names[b & 15])
        elif form == 'rc':
            b = mem[i - n + 1]
            width = next(w for m, w, o in OPCODES[mn] if o == opbyte)
            names = BYTE_NAMES if width == 'b' else WORD_NAMES
            if names[b >> 4] == '?':
                skipped += 1
                continue
            arg = '%s,%d' % (names[b >> 4], (b & 15) + RC_BIAS.get(mn, 0))
        elif form == 'impl':
            arg = ''
        else:
            skipped += 1
            continue
        checked += 1
        try:
            got = asm.encode(mn, arg, addr)
        except AsmError as e:
            bad.append((addr, t, str(e)))
            continue
        want = bytes(mem[i - n:i])
        if got == want:
            same += 1
        else:
            bad.append((addr, t, "encoded %s, program has %s"
                        % (got.hex(), want.hex())))
    for addr, t, why in bad[:20]:
        print("  %04x  %-20s %s" % (addr, t, why))
    print("%d instructions re-encoded, %d identical, %d differed, %d skipped"
          % (checked, same, len(bad), skipped))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
