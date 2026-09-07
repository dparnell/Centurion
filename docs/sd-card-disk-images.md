# Storing disk images on the SD card

A design note, not an implementation. Nothing here has been built yet, and the
resource figures for anything that does not exist are estimates and marked as
such.

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

## Prerequisite: DMA

The disk controllers are DMA devices, and DMA is the least finished part of this
design. The F11 and M13 addressable latches capture the DMA control bits but
nothing reads them, the DP bus sources at `d2d3` 11 and 12 are stubs, and the
`DMA` instruction (opcode 0x2F) has never been looked at.

**Scope DMA before writing any SD code.** A disk controller with nowhere to put
its data is not useful. 0x2F is an extended instruction family exactly like
`PAGE` (0x2E), and the same microcode tracing recipe applies: log
`dbg_uc_address` with `k11`, `e6`, `h11` and `d2d3` from the fetch of the
instruction, and read the loop against the field decoders in `CPU6.v`.

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

`PsramController` is already instantiated in `tangnano9k.v` and nothing drives
it. That is 8 MB of external memory sitting idle, and it is the answer:

- **A floppy image fits entirely in PSRAM.** Load it from SD at boot, serve
  every access from PSRAM, write back when dirty. SD latency leaves the CPU's
  path completely.
- **For CMD and Finch images, PSRAM becomes a track cache.** Read a whole track
  on a seek, serve sectors from it, write back on eviction.

This also means the **floppy is the right first target**, not the hard disk. It
is the smallest image, it needs no cache logic, and it gives the idle PSRAM
controller its first real use.

## Sector size mismatch

SD blocks are fixed at 512 bytes. The Centurion formats are very unlikely to
match, so `DiskImage` has to map an image sector onto a block plus an offset,
and a sector that straddles a block boundary needs two block reads. If a track
lives in PSRAM this disappears for the floppy, but it still applies to whatever
fills the cache.

The actual geometries and sector sizes need to come from the Nakazoto wiki
rather than from guesswork.

## Bring-up order

Each step verifiable on its own, which is what this project rewards:

1. **SD init and a block read with no CPU involvement.** Dump the result over
   the existing `StatusDump` path or the LED panel. This takes the entire SD
   layer off the table as a suspect before it is ever wired to the bus.
2. **A memory-mapped SD debug register**, exercised by a small hand-written
   CPU6 program in `programs/`. Proves the bus integration separately from the
   controller model.
3. **The controller model**, judged by diag's disk tests.
4. **PSRAM backing**, then **FAT mounting**, each as its own step with the disk
   tests still passing either side of it.

## Simulation

Write an SD card model: a module that answers SPI commands from an image loaded
with `$readmemh`. Without it, `make diagtest` cannot run the disk tests and
every change has to be judged on hardware, which this project has already
demonstrated is the slow and error-prone way round.

The card model should be able to inject a long busy period on demand, because
that is the failure mode real cards have and the one a controller model is most
likely to get wrong.

## What to look up before starting

- Controller register maps and disk geometries, from the Nakazoto wiki.
- Whether the CPU6 reference manual documents the `DMA` instruction and the DMA
  bus protocol.

Both of these are questions about the original hardware rather than about this
Verilog, and the references answer them faster and more reliably than inference
from the microcode does.
