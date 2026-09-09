#!/usr/bin/env python3
"""Exercise the machine's memory through TOS, the diag ROM's machine code monitor.

Build with "make DIP=1a" so the Diag board's switches select TOS, load it, and run
this. It writes one address-dependent byte into every 2K page the running map
reaches and reads them all back, which is an end to end check of the memory
through the CPU, the MMU and the bus - the PSRAM included - rather than of a
memory controller on its own.

It drives the board over the FT2232's second channel with pyftdi, so it needs no
tty and no uucp group; see the notes in CLAUDE.md. Do not run it while anything
else has the board.

Three things about TOS that are easy to get wrong:

  * The examine command is "M" immediately followed by the address, with no
    space. "M 8001" is not the same thing - TOS reads the space as a step and
    then takes the address as 008001.
  * Space steps forward and prints the next byte; typing two hex digits followed
    by a space writes one. Carriage return goes back to the prompt.
  * Virtual 0xf000 to 0xffff is NOT memory. The running map points those two
    pages at the I/O page at physical 0x3f000, so virtual 0xf110 reads the Diag
    board's DIP switches and virtual 0xf200 is the MUX. Writing there takes the
    console away and the monitor stops answering, which looks exactly like a
    memory fault and is not one.
"""

import argparse
import re
import sys
import time

from pyftdi.serialext import serial_for_url

URL = 'ftdi://ftdi:2232:/2'
ROM_PAGES = range(16, 20)        # 0x8000..0x9fff, the diag ROM
IO_PAGES = range(30, 32)         # 0xf000..0xffff, mapped to the I/O page


class Tos:
    def __init__(self, url=URL):
        self.port = serial_for_url(url, baudrate=19200, bytesize=7,
                                   parity='N', stopbits=1, timeout=0.05)

    def drain(self, seconds):
        end = time.time() + seconds
        got = b''
        while time.time() < end:
            data = self.port.read(512)
            if data:
                got += data
        return got

    def send(self, text, wait=0.35):
        for ch in text:
            self.port.write(ch.encode('ascii'))
            time.sleep(0.06)
        return self.drain(wait)

    def deposit(self, addr, value):
        self.send("\r", 0.3)
        self.send("M%04X" % addr, 0.3)
        self.send(" ", 0.3)                  # show the byte that is there
        self.send("%02X " % value, 0.35)     # type a value; space commits and steps
        self.send("\r", 0.3)

    def examine(self, addr):
        self.send("\r", 0.3)
        self.send("M%04X" % addr, 0.3)
        out = self.send(" ", 0.5)
        self.send("\r", 0.3)
        text = ''.join(chr(c) if 32 <= c < 127 else ' ' for c in out)
        found = re.findall(r'\b([0-9A-F]{2})\b', text)
        return int(found[0], 16) if found else None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--offset', type=lambda s: int(s, 0), default=0x100,
                    help='byte within each 2K page to test (default 0x100)')
    args = ap.parse_args()

    tos = Tos()
    banner = tos.drain(3)
    if b'\\' not in banner and banner:
        print("note: no TOS prompt in the banner %r - is this a DIP=1a build?"
              % banner[:40])

    pages = [p for p in range(32) if p not in ROM_PAGES and p not in IO_PAGES]
    expected = {}
    for page in pages:
        addr = page * 0x800 + args.offset
        # Address dependent, so that an aliased page fails rather than passing,
        # and never zero, so a page that simply reads back as empty is not
        # mistaken for one that worked.
        expected[addr] = ((page * 7 + 0x31) & 0xff) | 0x11
        tos.deposit(addr, expected[addr])

    bad = []
    for addr in sorted(expected):
        got = tos.examine(addr)
        if got != expected[addr]:
            bad.append((addr, expected[addr], got))

    for addr, want, got in bad:
        print("  MISMATCH %04X: wrote %02X, read %s"
              % (addr, want, "nothing" if got is None else "%02X" % got))
    if bad:
        print("FAIL: %d of %d pages wrong" % (len(bad), len(expected)))
        return 1
    print("ok: all %d pages read back what was written" % len(expected))
    return 0


if __name__ == '__main__':
    sys.exit(main())
