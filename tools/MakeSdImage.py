#!/usr/bin/env python3
"""Build the SD card images the simulation testbenches read.

$readmemh takes "@address" directives, so an image can be sparse: a four
megabyte card whose interesting sectors are the boot block, a couple of FAT
sectors and a directory costs a few thousand lines rather than four million.
That is what makes simulating a real filesystem affordable.

    MakeSdImage.py pattern OUT.hex          a pattern card, for the SPI layer
    MakeSdImage.py fat32 OUT.hex            a FAT32 volume with a synthetic image
    MakeSdImage.py fat32frag OUT.hex        the same, deliberately fragmented
    MakeSdImage.py hawk SRC.IMG OUT.hex [N] a FAT32 volume holding a real Hawk
                                            image, or its first N sectors

The Hawk images in the Nakazoto archive under Software/Data Packs are flat
files of **512 byte records with 400 bytes of sector data used** - which is the
stride HawkDisk.v uses, so they need no conversion at all. Sectors are ordered
by flat index, cylinder * 32 + head * 16 + sector. CENTOS_11.IMG and its
siblings are 6651904 bytes, 12992 sectors, 406 cylinders.

HAWK_DAVE.IMG is a different container: 416 byte records of "HawkDump\r\n", a
two byte big endian sector number, 400 bytes of data, a two byte checksum and a
CRLF. unhawkdump() below turns one into the flat form.
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


def _mbr(part_lba, part_sectors):
    """One FAT32 LBA partition, which is what a card formatted by a PC has."""
    mbr = bytearray(SECTOR)
    e = 0x1be
    mbr[e + 0] = 0x00                          # not bootable
    mbr[e + 1:e + 4] = b"\xfe\xff\xff"         # CHS, meaningless and ignored
    mbr[e + 4] = 0x0c                          # FAT32 with LBA, the usual type
    mbr[e + 5:e + 8] = b"\xfe\xff\xff"
    mbr[e + 8:e + 12] = part_lba.to_bytes(4, "little")
    mbr[e + 12:e + 16] = part_sectors.to_bytes(4, "little")
    mbr[510:512] = b"\x55\xaa"
    return mbr


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

    img.put(0, _mbr(part_lba, part_sectors))

    # Everything in the partition that is not all zeros. An unwritten sector of
    # a formatted volume genuinely reads as zeros, so leaving them out loses
    # nothing and takes the file from four million lines to a few thousand.
    for i in range(part_sectors):
        sec = data[i * SECTOR:(i + 1) * SECTOR]
        if any(sec):
            img.put(part_lba + i, sec)
    return img.write(path)


def unhawkdump(data):
    """A HawkDump container -> the flat 512 byte stride form."""
    REC, TAG = 416, b"HawkDump\r\n"
    if not data.startswith(TAG):
        return data                       # already flat
    out = bytearray()
    for n in range(len(data) // REC):
        rec = data[n * REC:(n + 1) * REC]
        if rec[:10] != TAG:
            raise RuntimeError("record %d is not a HawkDump record" % n)
        num = int.from_bytes(rec[10:12], "big")
        if num != n & 0xffff:
            raise RuntimeError("record %d says it is sector %d" % (n, num))
        out += rec[12:412] + bytes(SECTOR - 400)
    return bytes(out)


def hawk(path, src, sectors=None, part_lba=2048, name="HAWK0.IMG"):
    """A FAT32 volume holding a real Hawk image, or the front of one.

    A whole 6.6MB image is a perfectly good thing to put on a card and a poor
    thing to simulate, so `sectors` takes just the front of it - enough to prove
    the controller reads real sectors from real offsets without asking iverilog
    to load thirteen thousand of them.
    """
    import subprocess
    import tempfile

    data = unhawkdump(open(src, "rb").read())
    if sectors:
        data = data[:sectors * SECTOR]
    # The volume has to hold the file with room for its metadata.
    part_sectors = max(131072, (len(data) // SECTOR) * 2 + 8192)

    work = tempfile.mkdtemp()
    part = os.path.join(work, "part.img")
    with open(part, "wb") as f:
        f.truncate(part_sectors * SECTOR)
    subprocess.run(["mkfs.vfat", "-F", "32", "-s", "1", "-n", "CENTURION", part],
                   check=True, capture_output=True)
    payload = os.path.join(work, name)
    open(payload, "wb").write(data)
    subprocess.run(["mcopy", "-i", part, payload, "::" + name],
                   check=True, capture_output=True)

    vol = bytearray(open(part, "rb").read())
    img = Sparse()
    img.put(0, _mbr(part_lba, part_sectors))
    for i in range(part_sectors):
        sec = vol[i * SECTOR:(i + 1) * SECTOR]
        if any(sec):
            img.put(part_lba + i, sec)
    return img.write(path)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    kind = sys.argv[1]
    if kind == "hawk":
        if len(sys.argv) < 4:
            sys.exit(__doc__)
        src, out = sys.argv[2], sys.argv[3]
        n = hawk(out, src, int(sys.argv[4]) if len(sys.argv) > 4 else None)
        print("%s: %d sectors" % (out, n))
        raise SystemExit
    out = sys.argv[2]
    if kind == "pattern":
        n = pattern(out)
    elif kind == "fat32":
        n = fat32(out)
    elif kind == "fat32frag":
        n = fat32(out, fragment=True)
    elif kind == "fat32longname":
        # The name a real Centurion image usually has. Nine characters before
        # the dot is not an 8.3 name, so FAT32 stores a long name entry plus a
        # generated alias, and only the alias is visible to the parser.
        n = fat32(out, name="CENTOS_13.IMG")
    else:
        sys.exit("unknown image kind: %s" % kind)
    print("%s: %d sectors" % (out, n))
