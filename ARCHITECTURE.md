# Architecture — WARD: a reprogrammable protocol-emulator ASIC

Submission for the [Jane Street Protocol Emulator ASIC Competition](https://blog.janestreet.com/protocol-emulator-asic-competition/)
(Tiny Tapeout, IHP 130nm CMOS5L, 6×4 tile budget, deadline 2027-01-18).

The brief mandates the approach: *"a tiny CPU with an instruction set designed
for reading pins, writing pins, counting cycles"* rather than fixed protocol
blocks. WARD is that CPU — but it's actually **N independent tiny CPUs**
("lanes"), each a minimal programmable sequencer, sharing a pin crossbar and a
post-fab-writable instruction store. The design is generated in
[Hardcaml](https://hardcaml.org) (OCaml) so the lane count, memory depth, and
datapath widths are build-time parameters we sweep and measure rather than
hand-guess, and so verification can be done with randomized/property-based
testing against golden software models instead of only hand-written directed
tests.

## 1. Why multiple lanes, not one CPU

A single sequencer bit-banging UART, SPI, *and* I2C by time-slicing one
instruction stream can't hold precise, independent timing for all three at
once — protocol edges don't line up, and jitter from instruction dispatch on
one protocol leaks into another. Real-world precedent for the "many tiny
independent pin-sequencers, one core clock" approach is the RP2040's PIO
block; WARD applies the same idea at ASIC scale, with its own ISA, sized to
fit a Tiny Tapeout tile budget.

Each lane:
- runs its own program counter over a **shared, statically-partitioned
  instruction store** (no multi-port SRAM needed — see §4),
- owns a window of the physical GPIOs, positioned at load time via the
  `pinbase` register (window *width* is a fixed compile-time 8, not a
  runtime register), with per-pin direction set by the running program —
  so lane↔pin assignment is itself part of "the program". Note that with
  20 lane-usable pins, running 5 lanes means windows necessarily overlap;
  the hardware does not arbitrate overlap, so non-conflict is a property
  of the loaded programs and is argued explicitly per lane-pair in
  `hardcaml/lib/protocols/DESIGN.md` §7.2, and
- sets its own bit timing from the per-instruction `delay` field, so one
  core clock serves I2C standard/fast mode, arbitrary UART bauds,
  multi-MHz SPI, USB low-speed (1.5 Mbit, bit-locked), and 10BASE-T
  Manchester (10 Mbit) simultaneously, each lane timing itself
  independently. No per-protocol PLL, no fixed baud table baked into
  silicon.

  > **Correction (2026-09-15).** An earlier revision of this document
  > claimed each lane "has its own clock divider". It does not — no
  > `clkdiv` register was ever implemented, in `isa.ml`, `sequencer.ml`,
  > or `core.ml`. Timing comes solely from the 5-bit per-instruction
  > `delay` field, which caps a single instruction at 32 cycles: far short
  > of one real UART bit at 115200 baud (~434 cycles at 50 MHz) or an I2C
  > standard-mode half-period (250 cycles). Today that gap is bridged by a
  > *counted delay loop* (`Set Y,k` + a closing `Jmp(Y_dec,...)`, reaching
  > ~8160 cycles from two instructions, at the cost of tying up a scratch
  > register). The planned fix is a **delay-scale field** — a 1-2 bit
  > multiplier on `delay`, fitted into operand bits that several opcodes
  > already leave spare — which restores the intended capability, shortens
  > every real-rate program, and removes the counted-loop
  > cycle-accounting bug class. See `hardcaml/lib/protocols/DESIGN.md`
  > §0.1 and `NOTES.md`.

  Baseline clock target is the TT template's default 50 MHz (20 ns,
  `src/config.json`) — enough headroom above 10 Mbit line rate for
  4x-oversampled Manchester decode on the stretch goal. We'll push this
  higher once static timing analysis on the synthesized design shows
  margin; treat 50 MHz as the committed baseline, anything above as
  upside.

This directly targets the "unique functionality" judging axis: running UART +
SPI + I2C *concurrently and independently*, post-fab-reprogrammable to swap
any lane to a new protocol without touching the other lanes, is the headline
demo.

Default configuration: **4 lanes**. Lane count is a Hardcaml functor
parameter (`Core.Make (struct let num_lanes = 4 ... end)`), so we can
synthesize 3/4/5-lane variants and pick whichever fits the tile budget with
the best functionality/area trade-off — see §6.

## 2. Pin budget

Tiny Tapeout gives 24 usable GPIOs plus `clk`/`rst_n`:

| Pins | Count | Direction | Notes |
|---|---|---|---|
| `ui_in[7:0]` | 8 | in only | extra RX-type lines, config-port data-in |
| `uo_out[7:0]` | 8 | out only | TX-type lines, config-port data-out/status |
| `uio[7:0]` | 8 | **bidir**, per-pin OE | the only pins that can do open-drain-style I2C (drive 0 / release), USB D+/D− turnaround, etc. |

`uio` is the scarce resource — protocols needing true bidirectional/open-drain
behavior (I2C SDA+SCL clock-stretch, USB D+/D−) must live there. `ui_in`/
`uo_out` cover simplex lines (UART TX/RX, SPI SCLK/MOSI/CS out, MISO in,
10BASE-T TX/RX Manchester). Lane pin windows are software-assigned so any
lane can be pointed at any free pins at load time.

## 3. Instruction set

16-bit instruction word, 3-bit opcode class, plus a **shared delay field**:
whichever operand bits an instruction's class doesn't need, the assembler
packs with a 0–31 cycle post-instruction stall — the same trick PIO uses to
get cycle-accurate timing without spending whole instruction slots on NOPs.
This is what "counting cycles" in the brief means in practice.

Per-lane state: `PC`, two 8-bit scratch/loop counters `X`/`Y`, an 8-bit input
shift register `ISR`, an 8-bit output shift register `OSR`, one 1-deep RX
FIFO and one 1-deep TX FIFO (the handshake to/from the host-facing side of
the chip), plus the load-time-only `pinbase` and `jmp_pin` registers and the `run`
bit. (There is no `pincount` register — window width is a compile-time
constant of 8 — and no `clkdiv` register; see the correction in §1.)

| Class | Form | Semantics |
|---|---|---|
| `JMP` | `cond, addr` | `cond ∈ {ALWAYS, X--!=0, Y--!=0, PIN, !PIN, X==0, Y==0}`; absolute jump within the lane's instruction slice |
| `WAIT` | `pol, src, idx` | stall until a pin or a shared IRQ flag equals `pol`; the core synchronization primitive (start-bit edge, SCL edge, CTS, start condition, …) |
| `SET` | `dest, imm5` | `dest ∈ {PINS, PINDIRS, X, Y}` — drive an immediate onto the pin window / set per-pin direction / load a counter |
| `OUT` | `dest, n` | shift `n` bits out of `OSR` to `dest ∈ {PINS, X, Y, PC, NULL}` (`PC` enables computed jumps for protocol dispatch tables) |
| `IN` | `src, n` | shift `n` bits from `src ∈ {PINS, X, Y}` into `ISR` |
| `PUSH`/`PULL` | `blocking` | move `ISR`→RX FIFO / TX FIFO→`OSR`; blocking stalls until the host has drained/filled the FIFO, non-blocking proceeds regardless — natural flow control between protocol bit-rate and byte-rate host interface |
| `IRQ` | `set/clr, idx` | a handful of cross-lane flags, for multi-lane coordination (e.g. a clock-stretch watcher lane signalling a data lane); *waiting* on a flag is `WAIT` with `src = IRQ`, not a separate case here |

`NOP` isn't a dedicated opcode — it's `JMP (Always, pc+1)`, free.

`Isa.encode`/`Isa.decode` (`hardcaml/lib/isa.ml`) are the single source of
truth for the bit encoding, used by both the Hardcaml decoder and the
"assembler": programs are written directly as typed OCaml `Isa.instr list`
values (not a separate text mnemonic language — this is the actual mechanism
for "support new protocols after fabrication": writing a new protocol is
writing a new OCaml value + reflashing the instruction memory over the
config-port SPI, not new RTL). A text-format assembler/disassembler on top
of the same encoding is a nice-to-have, not yet built.

**Considered and deferred**: absolute-time "deadline" scheduling (a shared
free-running cycle counter plus a per-lane deadline register, so a `WAIT
DEADLINE` can be reached via different-length code paths and still land on
the same sample instant) instead of our relative delay-after-instruction
field. A competing entry (BitLoom, see `net_resource/competitor-scan.md`)
does this and it's a genuinely good idea for protocols with data-dependent
branch lengths between timing-critical points. We're keeping the simpler
relative-delay model for v1 since our lane programs keep inter-WAIT code
paths constant-length by construction, and revisit only if a stretch
protocol (USB/10BASE-T) turns out to need it.

## 4. Instruction memory: no hard macro dependency

Tiny Tapeout's IHP CMOS5L shuttle has a demonstrated SRAM hard macro
(`tt_um_urish_sram_test`, 1KB), but its general availability to arbitrary
chipathon submissions isn't confirmed in the docs — flagged as an open
question to the organizers (see `NOTES.md`). The baseline design does **not**
depend on it: each lane's instruction store is a small synthesizable
register file (default 64×16 bits, ~1024 flops/lane), statically sliced at
build time — no multi-port memory arbitration needed since each lane only
ever addresses its own slice. If the SRAM macro turns out to be freely
available, a follow-up variant can pool it as a larger shared instruction
store across lanes (more program depth for the USB/Ethernet stretch
protocols) — kept as a stretch enhancement, not a dependency of the base
submission.

## 5. Configuration / bootstrap port

Problem: if all 24 GPIOs are owned by lanes running protocols, how does a
host reprogram the chip? Answer: a small **hardwired loader**, outside the
lane array, always live regardless of lane state, exposed as a **4-wire SPI
slave** (`cfg_sclk`, `cfg_mosi`, `cfg_cs_n` as dedicated inputs, `cfg_miso`
as a dedicated output) giving read/write access to every lane's instruction
slice, pin-window registers, clock divider, and run/halt/reset bit. It's a
few registers, an address decoder, and a shift register, not a "lane", and
it's real writable state — the concrete answer to "reprogrammable after
fabrication", independent of whatever protocol the lanes are currently
emulating.

(Earlier draft of this section used a custom byte-parallel bus that
permanently claimed 10 of the 24 GPIOs. Switched to SPI slave after seeing a
competing entry — BitLoom, see `net_resource/competitor-scan.md` — use the
same idea: it's a better choice on its own merits, standard enough that any
host MCU can drive it without a bespoke protocol to document, *and* it only
costs 4 pins instead of 10. That leaves **20 of 24 GPIOs** free for lane pin
windows: `ui_in[7:3]` (5), `uo_out[7:1]` (7), `uio[7:0]` (8) — up from 14.)

## 6. Area budget

Target: 6×4 tiles ≈ 0.7 mm², ~1K cells/tile ⇒ **~24K logic cells** ballpark.

**Measured** (generic Yosys `synth` on the generated `ward_core.v`, i.e.
mapped to abstract AND/OR/MUX/DFF primitives — not yet mapped to IHP's
`sg13g2` standard-cell library or placed/routed, but a solid proxy):

```
12,442 cells total
  2,462 flops  ($_SDFFE_PP0P_ + $_SDFF_PP0_)
  9,980 combinational (AND/NAND/OR/NOR/ANDNOT/ORNOT/XOR/XNOR/MUX/NOT)
```

The flop count lands almost exactly where the design-time estimate below
predicted (4 lanes × 32×16 instruction memory dominates, as expected); the
combinational count is on the high side of what a from-scratch hand-written
RTL would produce, because several places in the Hardcaml source (the pin
crossbar's dynamic addressing in particular — `dyn_bit`/`bits_of` in
`core.ml`) build muxes one bit at a time rather than as vectorized
operations. That's a known, deliberate trade for implementation-correctness
confidence within this session's time budget over gate-count optimization —
flagged in `NOTES.md` as a real follow-up once the design needs to be
squeezed, not yet a problem: **~12.4K cells is comfortably inside the ~24K
budget**, with room to spare for the stretch protocols.

*Design-time estimate this measurement is checked against, kept for the
record:*

| Block | Rough flop count | Notes |
|---|---|---|
| 4× instruction memory (32×16) | ~2,050 | dominant cost |
| 4× lane datapath (PC/X/Y/ISR/OSR/FIFOs/config regs) | ~220 | |
| Pin crossbar + config port | ~150 | |
| **Total (flops)** | **~2,400** | vs. 2,462 measured |

Still pending: mapping to the actual IHP `sg13g2` standard-cell library and
a real OpenROAD place & route run (the number that actually counts for the
6×4 tile fit) — generic synthesis cell counts are a reasonable proxy but
not a substitute. Tracked in `NOTES.md`.

## 7. Verification methodology

This is the other judged axis, and where Hardcaml earns its keep:

1. **Golden software models** — bit-exact OCaml behavioral models of UART,
   SPI, and I2C (`hardcaml/lib/protocols/*.ml`), independent of the ISA/RTL.
2. **Property-based testing** — for each protocol, generate randomized
   assembled programs *and* randomized stimulus (bytes, baud/clkdiv, clock
   stretching, arbitrary start/stop timing) and run them through
   `Hardcaml.Cyclesim`, asserting bit-exact agreement with the golden model
   across thousands of trials — materially more coverage than hand-written
   directed tests for the same effort.
3. **Two independent simulators, same generated RTL** — the identical
   assembled programs and golden-model expectations drive both the OCaml
   `Cyclesim` run *and* the standard Tiny Tapeout cocotb/Icarus testbench
   against the Hardcaml-generated Verilog (and later the post-synthesis
   gate-level netlist), so a bug has to survive two independently-implemented
   simulation engines to slip through.
4. **Waveform-driven debugging in the house style** — `hardcaml_waveterm` for
   inline ASCII waveform inspection (a direct nod to Jane Street's own
   ["Using ASCII Waveforms to Test Hardware Designs"](https://blog.janestreet.com/using-ascii-waveforms-to-test-hardware-designs/)
   post) plus VCD export for a polished multi-protocol scope-style demo view.

## 8. Repo layout

```
hardcaml/            OCaml/Hardcaml source of truth for the core
  lib/isa.ml            instruction encoding, assembler, disassembler
  lib/sequencer.ml       single-lane datapath + decode (Hardcaml)
  lib/core.ml            N-lane top: crossbar, config port, generator params
  lib/protocols/         golden software models (UART/SPI/I2C) for verification
  bin/generate_rtl.ml    emits src/generated/core.v
  test/                  Cyclesim + property-based tests, hardcaml_waveterm dumps
programs/             assembled protocol microcode (source .asm + assembled .hex)
src/                  Tiny Tapeout deliverable: project.v wrapper (instantiates
                      generated core.v), config.json (TT hardening config)
test/                 standard TT cocotb testbench (RTL + gate-level)
docs/info.md          TT datasheet
info.yaml             TT project metadata (title, tiles, pinout, source_files)
```

## 9. Open questions (tracked in `NOTES.md`)

- Confirm 6×4 (vs. template's documented `1x1..8x2` standard shapes) is a
  real allocatable shape for this chipathon, and whether 8×4 becomes
  available — affects §6 budget.
- Confirm whether the IHP SRAM hard macro is available to arbitrary
  chipathon submissions (§4) — would let us grow instruction memory depth
  significantly for the stretch protocols without spending logic cells.
- Team size / composition — post currently says solo work is fine, teams
  "strongly recommended".

## 10. PIO vs. PRU — and what we did differently

The brief points at two existing precedents and asks what we'd do
differently:

- **RP2040 PIO**: minimal state machines, no general ALU, tiny instruction
  set, very cheap per-lane — but locked to a fixed program length per
  "wrap" and no notion of absolute time (a program's timing is entirely
  relative, instruction-to-instruction). Also MCU-integrated: PIO exists
  *inside* a chip that also has real CPUs to feed it; it was never meant to
  be the whole story.
- **TI PRU** (Sitara PRUSS): the opposite end — a full 32-bit RISC-ish core
  per unit (real ALU, general register file, branch/call, much larger
  instruction memory), general-purpose enough to run real protocol stacks
  (EtherCAT, industrial fieldbus) but correspondingly far too large for a
  6×4 Tiny Tapeout tile budget — a single PRU core alone is a different
  scale of design than our entire area budget.

WARD deliberately sits at the PIO end of that spectrum (many minimal lanes,
not one general core) because the area budget makes that the only viable
choice at this die size — but it departs from PIO in the two ways detailed
above: **SPI-slave host interface instead of MCU-integrated** (§5, so the
chip is useful standalone, not just as a peripheral inside a bigger SoC —
directly serving the brief's own stated use case, a standalone hardware
debugging/reverse-engineering tool) and a **flat, software-assigned 24-pin
crossbar instead of a fixed pin mapping** (§2, so pin↔lane assignment is
itself part of "the program," not wired in at synthesis time — important
for the "supports new protocols after fabrication" requirement, since a
future protocol's pin count/role pattern is unknown today). We also
considered and explicitly rejected PRU-style generality (§3's "considered
and deferred" note on deadline scheduling is the same instinct in miniature
— add just enough beyond pure-PIO-minimalism to solve a real problem, not a
full RISC core) in favor of staying small enough that 4 lanes fit
comfortably inside the budget with room to spare (§6).

## 11. What else this architecture makes possible

The brief explicitly invites this, and it's also just the most honest
answer to "why build it this way": a flat pin crossbar plus lanes that can
be independently pointed at IN-only or OUT-only roles means **the same
hardware that emulates a protocol can instead passively listen to one** —
directly serving the brief's own framing of this as "a useful tool for
hardware debugging and reverse engineering." Concretely, once a lane's
program is just `IN PINS,n` / `PUSH` in a tight loop with no drive side, it
is a logic-analyzer channel with a real host-facing FIFO, for free, using
the exact same silicon as the UART/SPI/I2C emulation lanes — not a separate
mode requiring separate hardware. (A leading competing entry independently
converged on the same idea — see `net_resource/competitor-scan.md` — which
is a good sign it's a real capability and not just a nice story.)

Other named-in-the-brief protocols we intend to add as bonus microcode once
UART/SPI/I2C are solid (no RTL changes needed — this is the whole point of
the architecture: new protocols are new programs):

- **JTAG** — TAP controller is a natural fit for our model: `TMS`/`TDI` are
  simple output shifts, `TDO` an input shift, the 16-state TAP FSM is
  exactly the kind of small branchy sequence `JMP` handles well. Arguably
  *easier* to emulate than SPI given our ISA.
- **SWD** — 2-wire (`SWCLK`/`SWDIO`), bidirectional with turnaround cycles;
  same `PINDIRS`-at-runtime mechanism I2C already needs (§3's `Out_pindirs`
  / `Set_pindirs`).
- **PS/2** — device-clocked open-drain clock+data, 11-bit frames with
  parity; another natural fit, similar shape to I2C.
- **CAN bus** (the hardest of the named list, likely a stretch-of-stretch)
  — needs bit-stuffing and a running CRC-15, which is genuinely more than
  the other protocols ask of a lane's per-instruction logic. Worth
  attempting late specifically *because* it's harder: getting it working
  within an ISA designed around "read pins, write pins, count cycles" would
  be a strong demonstration that the instruction set generalizes past
  simple framed serial protocols to real bus arbitration.

FPGA validation: the Tiny Tapeout template already wires up an ICE40UP5K
bitstream build (`.github/workflows/fpga.yaml`, currently disabled on push —
see template comment) as the brief suggests doing before committing to the
ASIC flow. Enabling that and actually testing on real FPGA hardware is on
the NOTES.md TODO list, pending access to a board.
