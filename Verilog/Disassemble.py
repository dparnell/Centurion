#!/usr/bin/env python3
"""Disassemble CPU6 machine code.

    python Disassemble.py opcodes.yaml programs/diag.txt 8000 8001 8060

Takes the machine readable opcode table from the CPU6 reference manual, at
https://github.com/mx-shift/centurion-cpu6-reference-manual/blob/main/data/opcodes.yaml
Download it next to this script; it is not vendored here.

The table names the destination addressing mode in `mode` and the source in
`src`, and either can be the implicit register form, so an instruction's
length comes from whichever of the two is not implicit. Getting that wrong
produces a disassembly that looks plausible and is misaligned, which is how
several confident but wrong readings of diag were arrived at before this
existed.

This is what found diag's DIP switch dispatch: the table at 0x8055 that the
Diag board's switches index, and the TOS machine code monitor at 0x846f."""
import re, sys

def load_opcodes(path):
    ops = {}
    for line in open(path):
        m = re.match(r'\s*0x([0-9A-Fa-f]{2}):\s*\{(.*)\}\s*$', line)
        if not m: continue
        body = m.group(2)
        f = {}
        for k, v in re.findall(r'(\w+):\s*("[^"]*"|\[[^\]]*\]|[^,]+)', body):
            f[k] = v.strip().strip('"')
        ops[int(m.group(1), 16)] = f
    return ops

# operand bytes by addressing mode
FIXED = {'impl': 0, 'implr': 0, 'dir': 2, 'ind': 2, 'pco': 1, 'pcoi': 1,
         'idx': 1, 'rr': 1, 'rc': 1, 'rrs': 1, 'rrsr': 1, 'rrx': 1}

def length(ops, mem, i):
    """Total instruction length in bytes, or None if not decodable."""
    op = ops.get(mem[i])
    if op is None: return 1
    ext = op.get('ext')
    if ext == 'page' or ext == 'dma':
        # 2e/2f: selector, count, then an address or a register+displacement
        sel = mem[i+1] if i+1 < len(mem) else 0
        return 5 if (sel & 0x0f) == 0x0c else 4
    if ext == 'mem':
        return 7                        # selector, count, two 16 bit addresses
    if ext in ('mpush', 'mpop'):
        return 2                        # register mask
    if ext in ('big', 'rii', 'xio'):
        return 2                        # not fully known
    n = 1 + operand_bytes(op)
    # The register-indexed mode carries a displacement byte when bit 3 of its
    # mode nibble is set. Missing that makes the disassembly misalign from
    # there on, which is the failure this file's header warns about.
    if eff_mode(op) == 'idx' and i + 1 < len(mem) and (mem[i+1] & 8):
        n += 1
    # The register-register-extended mode carries a 16 bit operand as well
    # whenever the low bits of its two register nibbles differ.
    if eff_mode(op) == 'rrx' and i + 1 < len(mem):
        b = mem[i+1]
        if ((b >> 4) & 1) or (b & 1):
            n += 2
    return n

IMPLICIT = ('impl', 'implr', 'implr_dir', None)

def eff_mode(op):
    """The addressing mode that actually carries operand bytes.

    The table names the destination in `mode` and the source in `src`, and
    either one can be the implicit register form, so the operand length comes
    from whichever of the two is not implicit."""
    for k in ('src', 'mode'):
        m = op.get(k)
        if m not in IMPLICIT: return m
    return None

def operand_bytes(op):
    m = eff_mode(op)
    if m == 'imm':
        return 2 if op.get('width') == 'w' else 1
    return FIXED.get(m, 0)

def text(ops, mem, i, addr):
    op = ops.get(mem[i])
    if op is None: return '?%02x' % mem[i], 1
    n = length(ops, mem, i)
    mn = op.get('mnemonic', '?')
    mode = eff_mode(op) or 'impl'
    b = mem[i:i+n]
    arg = ''
    if mode == 'imm':
        arg = '#%02x' % b[1] if n == 2 else '#%04x' % ((b[1] << 8) | b[2])
    elif mode in ('dir', 'ind'):
        arg = '%s%04x' % ('@' if mode == 'ind' else '', (b[1] << 8) | b[2])
    elif mode in ('pco', 'pcoi'):
        d = b[1] - 256 if b[1] > 127 else b[1]
        arg = '%s%04x' % ('@' if mode == 'pcoi' else '', (addr + n + d) & 0xffff)
    elif mode == 'idx' and n > 1:
        arg = idx_text(b[1], b[2] if n > 2 else None)
    elif mode in ('rr', 'rc', 'rrs', 'rrsr', 'rrx') and n > 1:
        arg = '%02x' % b[1]
    elif n > 1:
        arg = ' '.join('%02x' % x for x in b[1:])
    return ('%-5s %s' % (mn, arg)).rstrip(), n

WORD_REG = ['A', '?', 'B', '?', 'X', '?', 'Y', '?',
            'Z', '?', 'S', '?', 'C', '?', 'P', '?']

def idx_text(b, disp):
    """The register indexed mode: [reg], [reg++], [--reg], with an optional
    displacement and an optional extra level of indirection."""
    r = WORD_REG[b >> 4]
    # Bits 1:0 are 0 plain, 1 step after, 2 step before. Both bits set is a
    # fourth thing that the emulator does not name either, so say so rather
    # than rendering it as one of the two, which is what this used to do.
    if (b & 3) == 3: r = '?3' + r
    elif b & 2: r = '--' + r
    elif b & 1: r = r + '++'
    if b & 8 and disp is not None:
        d = disp - 256 if disp > 127 else disp
        r += ('+$%02x' % d) if d >= 0 else ('-$%02x' % -d)
    return ('[[%s]]' if b & 4 else '[%s]') % r

def run(ops, mem, base, start, end, stop_at=None):
    a = start
    while a < end:
        i = a - base
        if i + 8 > len(mem): break
        t, n = text(ops, mem, i, a)
        raw = ' '.join('%02x' % x for x in mem[i:i+n])
        print("  %04x: %-14s %s" % (a, raw, t))
        if stop_at and t.split()[0] in stop_at: return a + n
        a += n
    return a

if __name__ == '__main__':
    ops = load_opcodes(sys.argv[1])
    mem = []
    for line in open(sys.argv[2]):
        line = line.split('//')[0].strip()
        for tok in line.split(): mem.append(int(tok, 16))
    base = int(sys.argv[3], 16)
    start = int(sys.argv[4], 16)
    end = int(sys.argv[5], 16)
    run(ops, mem, base, start, end)
