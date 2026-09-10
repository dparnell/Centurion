#!/usr/bin/env python3
"""Build the SD card images the simulation testbenches read.

$readmemh takes "@address" directives, so an image can be sparse: a four
megabyte card whose interesting sectors are the boot block, a couple of FAT
sectors and a directory costs a few thousand lines rather than four million.
That is what makes simulating a real filesystem affordable.

    MakeSdImage.py pattern OUT.hex     a plain pattern card, for the SPI layer
    MakeSdImage.py fat32 OUT.hex       a genuine FAT32 volume with an image file
"""
import os
import sys

SECTOR = 512


class Sparse:
    """Sectors by number, written out as a sparse $readmemh file."""

    def __init__(self):
        self.sectors = {}

    def put(self, lba, data):
        assert len(data) <= SECTOR
        self.sectors[lba] = bytes(data) + bytes(SECTOR - len(data))

    def write(self, path):
        lines = []
        for lba in sorted(self.sectors):
            lines.append("@%X" % (lba * SECTOR))
            lines.extend("%02x" % b for b in self.sectors[lba])
        with open(path, "w") as f:
            f.write("\n".join(lines) + "\n")
        return len(self.sectors)


def pattern(path):
    """A card with three recognisable sectors, for bringing up the SPI layer."""
    img = Sparse()
    img.put(0, bytes([0x53, 0x44, 0x30, 0x30] +
                     [(i * 7 + 3) & 0xff for i in range(4, SECTOR)]))
    img.put(1, bytes(SECTOR))
    img.put(17, bytes((i ^ 0x5a) & 0xff for i in range(SECTOR)))
    return img.write(path)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    kind, out = sys.argv[1], sys.argv[2]
    if kind == "pattern":
        n = pattern(out)
    else:
        sys.exit("unknown image kind: %s" % kind)
    print("%s: %d sectors" % (out, n))
