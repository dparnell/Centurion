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


def _u16(b, o):
    return b[o] | b[o + 1] << 8


def _u32(b, o):
    return b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24


def _put32(b, o, v):
    b[o:o + 4] = v.to_bytes(4, "little")


def _fragment(data, name, runs):
    """Relocate a contiguous file into `runs` scattered pieces, in place."""
    bs = 0                                        # the volume's own sector 0
    spc = data[bs + 13]
    reserved = _u16(data, bs + 14)
    num_fats = data[bs + 16]
    fat_sz = _u32(data, bs + 36)
    root_cluster = _u32(data, bs + 44)
    fat0 = reserved
    data0 = reserved + num_fats * fat_sz

    def fat_get(c):
        return _u32(data, (fat0 + (c * 4) // SECTOR) * SECTOR + (c * 4) % SECTOR) & 0x0fffffff

    def fat_set(c, v):
        for f in range(num_fats):
            base = (fat0 + f * fat_sz + (c * 4) // SECTOR) * SECTOR + (c * 4) % SECTOR
            _put32(data, base, v)

    def cluster_bytes(c):
        off = (data0 + (c - 2) * spc) * SECTOR
        return off, spc * SECTOR

    # Find the directory entry, following the root chain.
    want = name.replace(".", "").ljust(8)[:8].encode() if False else None
    stem, _, ext = name.partition(".")
    want = (stem.ljust(8) + ext.ljust(3)).upper().encode()
    ent = None
    c = root_cluster
    while ent is None and 2 <= c < 0x0ffffff8:
        for s_i in range(spc):
            base = (data0 + (c - 2) * spc + s_i) * SECTOR
            for off in range(0, SECTOR, 32):
                e = data[base + off:base + off + 32]
                if e[0] == 0:
                    break
                if bytes(e[0:11]) == want and e[11] != 0x0f:
                    ent = base + off
        c = fat_get(c)
    if ent is None:
        raise RuntimeError("could not find %s to fragment" % name)

    first = _u16(data, ent + 20) << 16 | _u16(data, ent + 26)
    chain = []
    c = first
    while 2 <= c < 0x0ffffff8:
        chain.append(c)
        c = fat_get(c)

    # New homes: `runs` equal pieces, each pushed further past the end of the
    # old chain so the gaps between them are real.
    per = len(chain) // runs
    gap = per * 2
    new = []
    base = chain[-1] + 8
    for r in range(runs):
        start = base + r * gap
        n = per if r < runs - 1 else len(chain) - per * (runs - 1)
        new.extend(range(start, start + n))

    old_data = [bytes(data[cluster_bytes(c)[0]:cluster_bytes(c)[0] + spc * SECTOR])
                for c in chain]
    for c in chain:
        fat_set(c, 0)
    for i, c in enumerate(new):
        off, n = cluster_bytes(c)
        data[off:off + n] = old_data[i]
        fat_set(c, new[i + 1] if i + 1 < len(new) else 0x0fffffff)
    data[ent + 26:ent + 28] = (new[0] & 0xffff).to_bytes(2, "little")
    data[ent + 20:ent + 22] = ((new[0] >> 16) & 0xffff).to_bytes(2, "little")


def fat32(path, part_lba=2048, part_sectors=131072, name="HAWK0.IMG",
           file_blocks=128, fragment=False):
    """A real FAT32 volume, made by mkfs.vfat and mcopy, inside a real MBR.

    Building this with the actual tools rather than by hand is the whole point:
    the Verilog parser is then tested against what a card formatted on a PC
    genuinely looks like, not against my own reading of the specification. The
    file's contents encode their own block number, so a parser that resolves a
    cluster to the wrong place is caught rather than merely producing bytes.
    """
    import subprocess
    import tempfile

    work = tempfile.mkdtemp()
    part = os.path.join(work, "part.img")
    with open(part, "wb") as f:
        f.truncate(part_sectors * SECTOR)
    # One sector per cluster keeps the cluster count above FAT32's 65525 floor
    # for a volume this size, so mkfs really does produce FAT32.
    subprocess.run(["mkfs.vfat", "-F", "32", "-s", "1", "-n", "CENTURION", part],
                   check=True, capture_output=True)
    def content(path, blocks, seed=13):
        with open(path, "wb") as f:
            for k in range(blocks):
                f.write(bytes((k * seed + j) & 0xff for j in range(SECTOR)))

    def zeros(path, blocks):
        with open(path, "wb") as f:
            f.truncate(blocks * SECTOR)

    payload = os.path.join(work, name)
    content(payload, file_blocks)

    subprocess.run(["mcopy", "-i", part, payload, "::" + name],
                   check=True, capture_output=True)

    data = bytearray(open(part, "rb").read())
    if fragment:
        # Scatter the file's clusters. A single extent is the easy case and the
        # extent table is the part of the parser most likely to be wrong, so the
        # fragmented case has to be tested - but mcopy appends rather than
        # filling holes, so no amount of copying and deleting will fragment
        # anything. Relocating the clusters afterwards produces exactly what a
        # genuinely fragmented file looks like on the disk, in a volume that is
        # still the one mkfs.vfat made.
        _fragment(data, name, runs=4)
    open(part, "wb").write(data)

    img = Sparse()

    # An MBR with one FAT32 LBA partition, which is what a card formatted by a
    # PC actually has. Type 0x0c is "FAT32 with LBA", the usual one.
    mbr = bytearray(SECTOR)
    entry = 0x1be
    mbr[entry + 0] = 0x00                       # not bootable
    mbr[entry + 1:entry + 4] = b"\xfe\xff\xff"  # CHS, meaningless and ignored
    mbr[entry + 4] = 0x0c
    mbr[entry + 5:entry + 8] = b"\xfe\xff\xff"
    mbr[entry + 8:entry + 12] = part_lba.to_bytes(4, "little")
    mbr[entry + 12:entry + 16] = part_sectors.to_bytes(4, "little")
    mbr[510:512] = b"\x55\xaa"
    img.put(0, mbr)

    # Everything in the partition that is not all zeros. An unwritten sector of
    # a formatted volume genuinely reads as zeros, so leaving them out loses
    # nothing and takes the file from four million lines to a few thousand.
    for i in range(part_sectors):
        sec = data[i * SECTOR:(i + 1) * SECTOR]
        if any(sec):
            img.put(part_lba + i, sec)
    return img.write(path)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    kind, out = sys.argv[1], sys.argv[2]
    if kind == "pattern":
        n = pattern(out)
    elif kind == "fat32":
        n = fat32(out)
    elif kind == "fat32frag":
        n = fat32(out, fragment=True)
    else:
        sys.exit("unknown image kind: %s" % kind)
    print("%s: %d sectors" % (out, n))
