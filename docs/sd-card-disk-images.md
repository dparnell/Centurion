# Storing disk images on the SD card

A design note. The parts of it that have since been built are marked **done**
below; the resource figures for anything that still does not exist are estimates
and marked as such.

The goal is to give the emulated Centurion its disk drives back, backed by
images on the microSD card in the Tang Nano 9K's slot.

## What we are emulating

The **controller board**, not the drive. The CPU should see the same registers
the real CMD, Finch or floppy controller presents, and the FPGA turns seek, read
and write commands into SD block accesses. Emulating drive-level serial data
would be a great deal of work to arrive at the same place.

That puts the fidelity burden in one module, the controller model, and lets
everything below it be an ordinary block device.

## diag already contains the acceptance tests

The diagnostic ROM's menu has, among others:

```
04=CMD AUX MEMORY TEST     07=FLOPPY COMMAND BUFFER TEST   0E=FINCH AUX MEMORY TEST
05=CMD SEEK TEST           08=FLOPPY SEEK TEST             0F=FINCH SEEK TEST
06=CMD READ TEST           09=FLOPPY READ TEST             10=FINCH READ TEST
```

The original vendor wrote our test suite. This is the same leverage tests 01 and
02 have given the CPU itself, and it means "working" has a definition that is
not our own opinion. Aim each stage of the work at making one more of these
pass, and run them under `make diagtest` before going near the hardware.

## Prerequisite: DMA — **done**

The disk controllers are DMA devices, and DMA was the least finished part of
this design. It now works in both directions, on hardware as well as in
simulation, and `make dmatest` is its regression.

The shape of it matters for everything below. **A device on this machine does
not master the bus**: it borrows the CPU's own address registers and its write
strobe, so the transfer engine lives in `CPU6.v` and a controller only supplies
a request, a direction and a byte. The port is `dma_req`, `dma_device_write`,
`dma_wdata`, `dma_step`, `dma_rdata`, `dma_end`, plus `dma_int` for saying a
command has finished. Software drives it with the `0x2f` instruction family:
sub-op 4 sets the map, 0 the address, 2 the count, 6 enables, 7 disables. The
count steps up and stops at `0xffff` without moving that byte.

One consequence worth carrying forward: a byte takes three enabled cycles,
because `writeEnBus` is registered and a two phase engine steps the address
before the strobe reaches the bus. At 5MHz that is about 560KB/s, comfortably
more than any of these drives produced.

The Hawk controller in `HawkDisk.v` is the first consumer, and is the template
for the other two.

## Pins and the physical layer

The Tang Nano 9K brings out four SD pins:

| Signal | Pin | SPI role |
| ------ | --- | -------- |
| `clk`  | 36  | SCK      |
| `cmd`  | 37  | MOSI     |
| `dat0` | 39  | MISO     |
| `dat3` | 38  | CS       |

`dat1` and `dat2` are not available, so **4-bit SD mode is not an option** and
the interface is SPI. That is no loss here: SPI at 13.5 MHz is about 1.7 MB/s,
far more than a 5 MHz CPU driving a 1970s disk controller can consume.

Add these to `tangnano9k.cst` with `PULL_MODE=UP` on MISO. Check the pin
directions against the board schematic before trusting them — the UART pins in
this project were swapped for a long time, and the design drove a pin the
FT2232 also drove while listening on one nothing drove.

## Integration rules this design imposes

Three constraints, all learned the hard way and all recorded in CLAUDE.md:

- **Do not generate a clock in fabric.** Derive the SPI clock as an *enable*
  from the 27 MHz pin. A divided clock on general routing cost this project a
  hold-time violation and then a board that did not run at all.
- **Split the domains the way `mux.v` does.** Its CPU-side register interface is
  gated by the CPU clock enable while its bit-level state machine runs free off
  the board clock. An ungated peripheral sees a single CPU write as several
  board-clock writes. The SD state machine wants to run free; its register
  interface must not.
- **One read mux.** Add `sd_select` to `AddressDecode` and extend the single
  `assign data_r2c = ...`. Never put a second driver on that net: doing so once
  made yosys tie it to a constant and silently delete the program RAM, while
  simulation carried on passing.

Also worth remembering: a block RAM must read every clock with its value held in
fabric flops, or be LUTRAM. Do not let a sector buffer's output be the thing a
clock enable holds.

## Layering

```
DiskController   Centurion-facing registers. The only part that must be faithful.
      |
  DiskImage      unit/cylinder/head/sector -> LBA, and the sector size mismatch
      |
   BlockStore    an extent: base LBA and length. Reads and writes by block number.
      |
    SDCard       SPI init, CMD17 read, CMD24 write, busy flag
```

`BlockStore` is the seam that matters. Everything above it addresses blocks
within an image; everything below it addresses blocks on a card. Getting that
boundary right is what makes the FAT question below a local change rather than a
rewrite.

## Card layout

Three phases, in the order I would build them.

### Phase 1: raw images at fixed offsets

Image 0 at LBA 0, image 1 at a fixed offset, and so on, written with `dd`. The
`BlockStore` extent is a constant. No filesystem logic at all.

This is not the end state, but it is the right way to start: it lets the SD
layer, the controller model and the DMA path all be brought up and debugged
without a filesystem in the picture. When something does not work, there is one
fewer thing it could be.

### Phase 2: FAT as a mount-time bootstrap

This is the recommended end state, and it is much cheaper than "FAT support"
sounds, because of one observation:

> Use the filesystem to *locate* the file, then stop using it.

At mount time, walk MBR to partition entry to boot sector (BPB) to root
directory, find the image by name, and follow its cluster chain. Turn the result
into a `BlockStore` extent, or a short table of extents if the file is
fragmented. From that moment on, every access is a raw LBA read or write and no
filesystem structure is touched again.

Crucially, **writes work in place**. The image file never changes length, so
the FAT and the directory entry never need updating. All the expensive parts of
a filesystem — cluster allocation, FAT chain maintenance, directory updates,
free space accounting, and the crash-consistency problems that come with them —
simply do not arise. The card's metadata is read once and thereafter read-only.

Specifics worth fixing early:

- **FAT32 only, or FAT32 and FAT16.** FAT32's root directory is an ordinary
  cluster chain, which is marginally less special-cased than FAT16's fixed root
  region. Cards over 32 GB usually ship formatted exFAT; **exFAT is a
  substantially bigger job** and the practical answer is to tell the user to
  format the card FAT32.
- **8.3 names only.** `FLOPPY0.IMG`, `CMD0.IMG`. Long filename parsing is real
  logic for no benefit; the long-name directory entries can simply be skipped,
  since every long-named file also has a short alias.
- **Contiguity.** A file written in one go to a freshly formatted card is
  almost always contiguous. Verify the chain at mount time; if it is linear,
  store one extent. If not, either build a small extent table (64 extents is
  ample and costs a couple of kilobits) or refuse to mount and say why.
- **Never write metadata.** Do not create, extend or delete files. The user
  makes the image on a PC at the right size.
- **Keep phase 1 as a fallback.** If no valid FAT signature is found, treat the
  card as raw. That is a few gates and it means a corrupt card cannot make the
  machine unbootable.

Rough estimate for the mount-time parser: a state machine over the existing
512-byte sector buffer, plus the extent table. Something in the region of 400 to
800 LUT4 and no additional block RAM beyond the buffer, which against the 32% of
LUT4 currently used is comfortable. That estimate has not been validated by
building it.

### Phase 3: a full FAT implementation

Almost certainly not worth it. Creating and extending files is where the logic
cost becomes real, and the only thing it buys is the ability to make a new image
from the Centurion side, which a PC does better. If it is ever wanted, a small
soft CPU running a filesystem in software would be a saner shape than a hardware
FAT driver — but that is a large addition to a device that is already 57% full
on block RAM.

## Latency, and why PSRAM matters here

An SD card is not a disk. A 512-byte read is typically under a millisecond, but
a card can stall for 100 ms or more doing internal housekeeping, at a moment of
its choosing. A faithful controller model with realistic timeouts will not
tolerate that in the middle of a transfer.

The PSRAM is no longer idle — it is the CPU's main memory now, behind
`PsramBus.v`. But the die is 8 MB and **the CPU can only address 256 KB of it**,
because the MMU's physical address is eighteen bits. Everything from `0x40000`
up is unreachable by any program and free for exactly this:

- **A whole Hawk platter fits.** 400 cylinders × 2 heads × 16 sectors at a 512
  byte stride is 6.55 MB, which sits above the CPU's 256 KB with room to spare.
  A floppy image is far smaller again.
- So an image can be **served entirely from PSRAM**, loaded from SD at mount
  time and written back when dirty, and SD latency leaves the CPU's path
  completely. No track cache logic is needed for any of the three drives.

That also revises the note's original advice that the **floppy** should be the
first target. That reasoning was about image size and cache logic, and neither
applies once the whole image lives in PSRAM. The Hawk went first instead, for a
different and better reason: its register map is documented in the archive and
modelled in the emulator, and the floppy's is neither, yet.

## Sector size mismatch — designed out

SD blocks are fixed at 512 bytes and a Hawk sector is 400, so the obvious layout
makes a sector straddle a block boundary and need two block reads.

`HawkDisk.v` avoids the whole problem by **storing each sector at a stride of
512 rather than 400**. That wastes 112 bytes a sector — 1.4 MB across a platter,
against 8 MB of PSRAM and a whole SD card — and buys two things worth much more:
the byte address of a sector becomes a shift rather than a multiply by 400, and
one image sector is exactly one SD block. Do the same for the floppy and the
Finch whatever their sector sizes turn out to be.

The geometries themselves still need to come from the archive rather than from
guesswork; the Hawk's is in `HawkMMIO.txt` and is 400 cylinders, 2 heads, 16
sectors of 400 bytes.

## Bring-up order

Each step verifiable on its own, which is what this project rewards:

Written before any of it existed, and it turned out to be worth doing in almost
the opposite order, because the controller model needs no card at all:

1. ~~SD init and a block read with no CPU involvement.~~
2. ~~A memory-mapped SD debug register.~~
3. **The controller model** — **done for the Hawk**, and it did not need the SD
   layer at all. `HawkDisk.v` has one sector buffer and no medium, which is
   enough to exercise the registers, the command handshake, the busy bit, the
   interrupt and the DMA in both directions. `make hawktest` is its regression.
4. **A medium in PSRAM**, above the CPU's 256 KB. Still no SD card: fill it in
   simulation with `$readmemh` and on hardware with whatever is there. This is
   what makes diag's read test meaningful.
5. **SD init and a block read with no CPU involvement**, then loading the image
   into PSRAM at boot, then **FAT mounting** — each as its own step with the
   disk tests still passing either side of it.

## Simulation

Write an SD card model: a module that answers SPI commands from an image loaded
with `$readmemh`. Without it, `make diagtest` cannot run the disk tests and
every change has to be judged on hardware, which this project has already
demonstrated is the slow and error-prone way round.

The card model should be able to inject a long busy period on demand, because
that is the failure mode real cards have and the one a controller model is most
likely to get wrong.

## Disk images: where to get them, and what format they are in

`Nakazoto/CenturionComputer` has `Software/Data Packs`, which is the main
source:

| File | Size | What it is |
| ---- | ---- | ---------- |
| `CENTOS_11/12/13.IMG` | 6651904 | the operating system, 12992 sectors, 406 cylinders |
| `HAWK_DAVE.IMG` | 5324800 | a Hawk platter in the `HawkDump` container, 12800 sectors |
| `MINOS.IMG`, `HWKFIX.IMG`, `HWKRPL2/3.IMG`, `CPU5FIX/PLT.IMG` | 6651904 | more Hawk packs |
| `FINCH2.BIN` | 30469061 | Finch, not looked at |
| `TORI.FFI`, `32MB_TORI.BIN` | 32MB-ish | not looked at |

`billsargent/centurion` also has Finch images under `server/disks`.

**The `.IMG` files need no conversion.** They are flat files of **512 byte
records with 400 bytes of sector data used**, ordered by flat index - cylinder *
32 + head * 16 + sector - which is exactly the stride `HawkDisk.v` uses. That was
chosen for SD block alignment before any real image had been looked at, and it
turns out to be the community's format as well; Meisaka's emulator addresses its
images the same way.

`HAWK_DAVE.IMG` is the exception, and its structure is worth recording: 416 byte
records of `HawkDump\r\n`, a two byte big endian sector number, 400 bytes of
sector data, a two byte checksum and a CRLF. Its payloads match `CENTOS_11.IMG`
at N*512 byte for byte, which is how the format above was established.
`MakeSdImage.py`'s `unhawkdump` flattens one.

**406 cylinders, not 400.** The real packs are 12992 sectors where a nominal
Hawk platter is 12800, so anything sized for the nominal geometry truncates a
real image. `DiskImage.v`'s `MAX_BLOCKS` is 13312 for that reason.

Whatever the image, it goes on the card as an ordinary file - `HAWK0.IMG` by
default, and `DISK_IMAGE` in `tangnano9k.v` sets the 8.3 name. Format the card
FAT32 and copy the file on in one go so it lands contiguously; `Fat32.v` accepts
up to four extents and refuses anything more fragmented rather than carrying a
large table for a case that should not arise.

## Register maps: where they actually are

Not the wiki. The archive's own files are better, and are plain text:

- `Drives/Hawk Drive/HawkMMIO.txt` in `Nakazoto/CenturionComputer` is a dump of
  the Hawk controller's registers, commands, status bits and the packed sector
  address. It is what `HawkDisk.v` is built from, and it settled two things the
  emulator leaves vague - that the unit select register reads back with `f` in
  the high nibble, and the exact `00CC CCCC CCCH SSSS` address format.
- The `DSK2` class in Meisaka's `cen.js` is a working behavioural model of the
  same board, and is the cross check.

The equivalents for the floppy and the Finch have not been located yet, and that
is the first thing to do before either of those is started.
