#!/usr/bin/env python3
"""Generate programs/serial.txt: print a message on MUX 0, polling the status register.

Per character:
    LDAL 0xf200     81 f2 00    read the status register
    SLAL x6         2d          shift bit 1 (transmitter ready) up into bit 7
    BP  wait        17 f5       bit 7 clear means busy, so go round again
    LDAL #c         80 cc
    STAL 0xf201     a1 f2 01    hand the byte to the transmitter
That is 16 bytes each. Execution starts at address 0 because the reset vector read
aliases onto the start of the block RAM, and the loop jumps to 0x80xx which aliases
back into it.
"""
MESSAGE = "Hellorld!\r\n"
START = 0x02

out = [("01", "NOP"), ("01", "NOP")]
addr = START
for ch in MESSAGE:
    label = repr(ch)[1:-1]
    out += [("81", f"LDAL #f200   ; wait for '{label}'"), ("f2", ""), ("00", "")]
    out += [("2d", "SLAL")] * 6
    # branch target is this character's wait, 11 bytes back from the next instruction
    out += [("17", "BP -11       ; still busy"), ("f5", "")]
    out += [("80", f"LDAL #{ord(ch):02x}     ; '{label}'"), (f"{ord(ch):02x}", "")]
    out += [("a1", "STAL #f201   ; send it"), ("f2", ""), ("01", "")]
    addr += 16

out += [("71", f"JMP #80{START:02x}    ; round again"), ("80", ""), (f"{START:02x}", "")]
assert len(out) <= 256, f"program is {len(out)} bytes, block RAM holds 256"
while len(out) < 256:
    out.append(("01", ""))

with open("programs/serial.txt", "w") as f:
    for byte, comment in out:
        f.write(f"{byte} // {comment}\n" if comment else f"{byte}\n")
print(f"wrote programs/serial.txt, {addr + 3} bytes of code")
