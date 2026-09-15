# Working notes / open questions

Running log for things that need a human decision, an email to the
organizers, or just haven't been gotten to yet. Keep this current — it's the
handoff doc for picking this project back up.

## Open questions for organizers (asic-competition@janestreet.com)

1. ~~**Tile shape for the 6x4 budget.**~~ **RESOLVED** (2026-09-15, from
   the competition rules text): the rules say explicitly *"Set the tile
   size in info.yaml to 6x4."* — the value is literal, and supersedes the
   template's documented `1x1..8x2` menu. `info.yaml` now has
   `tiles: "6x4"`. The organizers are evaluating a possible bump to 8x4
   (~30% more area) and will announce it if it happens; no action needed
   from us, but worth re-checking before submission.
2. ~~**SRAM hard macro availability.**~~ **RESEARCHED, deferred to Phase C**
   — not an open question for the organizers any more. The rules themselves
   recommend SRAM over flip-flops for instruction memory, and
   `tt_um_urish_sram_test` (https://github.com/urish/ttihp-sram-test) is a
   working reference: IHP `sg13g2` single-port synchronous macros, exact
   17-port blackbox signature captured, 1-cycle *registered* read latency,
   per-bit write mask; 1024x8 = 49,419 um^2 (needs >=2x1 tiles), 256x8 =
   17,547 um^2. Density is 2.6-3.7x better per bit than flops.
   **Not adopted yet** because (a) the cheaper Levers A+B (right-size
   `imem_depth`, add a delay-scale field) cut instruction memory
   substantially first, (b) the registered read latency means a real
   fetch-stage pipelining change plus multi-lane arbitration that must
   preserve cycle-exact determinism, and (c) Tiny Tapeout's own docs flag
   the macro integration as "not trivial... fragile... subject to change"
   (custom LibreLane macro placement/rotation, hand-written PDN config
   because the macro's power pins are on a different metal layer than the
   default grid expects, DRC/LVS blackbox exceptions). Revisit in Phase C
   on measured numbers.
3. **Team composition** — post says solo is fine, teams "strongly
   recommended." Decide whether we're recruiting collaborators before the
   Jan 18 2027 deadline.

## Status (update as we go)

- [x] Read competition post + Tiny Tapeout CMOS5L docs, cloned the real
      `ttihp-verilog-template` (cmos5l branch) for ground truth on ports /
      `info.yaml` / cocotb test harness / CI workflows.
- [x] Chose Hardcaml (OCaml) as the HDL — user decision, see conversation.
- [x] Architecture drafted: N-lane programmable pin-sequencer ("PIO-lite"),
      shared instruction-store-per-lane (no SRAM macro dependency), hardwired
      config/bootstrap port, 16-bit ISA with shared delay field. Full writeup
      in `ARCHITECTURE.md`.
- [x] Repo scaffolded: `hardcaml/` (OCaml source of truth), `src/` (TT
      deliverable — wrapper + generated Verilog), `test/` (TT cocotb
      harness, copied from template), `programs/` (assembled microcode),
      `.github/workflows/` (TT hardening CI, copied from template, + a
      Hardcaml test workflow).
- [x] Toolchain installed locally: opam + dune + hardcaml + hardcaml_waveterm
      + core (switch `hardcaml-ward`), Python 3.12 venv with cocotb 2.0.1 /
      pytest (matching TT's pinned versions), yosys and iverilog were
      already present via Homebrew.
- [x] `hardcaml/lib/isa.ml`: instruction encode/decode + a cycle-accurate
      software interpreter (`Isa.Interp`), used as the golden oracle
      everything else is checked against. Caught and fixed a real bug here
      (ISR must truncate to 8 bits like the real shift-register hardware
      does — an unmasked OCaml `lsl` would grow it unboundedly across
      repeated `IN`s) *before* it could cause a silent RTL/interpreter
      mismatch.
- [x] `hardcaml/lib/sequencer.ml`: one lane's full RTL (fetch/decode/
      execute, all 8 opcodes, PC/X/Y/ISR/OSR, per-lane instruction memory,
      TX/RX FIFOs). Cross-checked cycle-by-cycle against `Isa.Interp` via
      Hardcaml `Cyclesim` — every piece of observable state (pc, x, y, isr,
      osr, pins, pindirs, fifos, irq) asserted equal every cycle.
- [x] `hardcaml/lib/config_port.ml`: the 4-wire SPI slave (see
      ARCHITECTURE.md §5). Tested by bit-banging real SPI transactions in
      OCaml against the Cyclesim model. Caught and fixed a real timing bug
      here: `reg_rdata` was being latched on the *same* edge that
      `addr_reg` updates, so a read always returned the *previous*
      transaction's register, not the one just addressed — a register
      can't see its own not-yet-applied update from combinational logic
      downstream of it. Fixed by deferring the latch one cycle
      (`just_got_addr`).
- [x] `hardcaml/lib/core.ml`: the full N-lane top — 4× `Sequencer`, one
      `Config_port`, the flat 20-pin crossbar (dynamic pinbase-indexed
      routing, built with `wire`/`<==` to break the "register read needs
      lane outputs, lanes need register-write decode, register-write
      decode needs the config port, the config port needs register reads"
      construction-order cycle — not a real hardware combinational loop,
      just an OCaml value-ordering one), and the shared 4-flag IRQ
      register. Tested via a full over-SPI integration test: program lane
      0's instruction memory, `pinbase`, and `run` register through the
      *actual* SPI protocol, and check the resulting toggle appears on the
      correct physical `uio` pin, plus a register readback. This is what
      caught the `config_port` read-latch bug above.
- [x] `hardcaml/bin/generate_rtl.ml` → `src/generated/core.v` (28K lines),
      wired into `src/project.v` (thin `tt_um_ward_protocol_emulator`
      wrapper, rst_n→clear inversion, `ena` tied off). `info.yaml`
      `source_files`/`top_module` updated to match.
- [x] **Independent-simulator check**: `test/test.py` (real cocotb, not a
      placeholder) runs the *same* program-over-SPI / pinbase / toggle
      scenario as the Hardcaml integration test, but against the generated
      Verilog through Icarus — a completely different simulator/language
      stack. Passes clean (`make -B` in `test/`, 0 failures in
      `results.xml`). This is the "two independent simulators, same
      generated RTL" claim from ARCHITECTURE.md §7 actually holding up in
      practice, not just an aspiration.
- [x] First Yosys area check (generic `synth`, not yet PDK-mapped): 12,442
      cells (2,462 flops + 9,980 combinational) — inside the ~24K budget
      with room to spare. ARCHITECTURE.md §6 updated with the real numbers
      and an honest note on where the combinational count is higher than
      necessary (bit-at-a-time crossbar muxing — a known, deliberate
      correctness-over-gate-count trade for now).
- [x] `dune build` + `dune test` (or `dune exec test/test_ward.exe`): **742
      checks, 0 failures**, covering ISA roundtrip, the interpreter, a real
      UART TX byte transmitted end-to-end and independently decoded off the
      waveform (not just RTL-vs-interpreter agreement — this caught a
      *third* class of bug, a microcode timing mistake that both RTL and
      interpreter faithfully agreed on: the loop's `JMP X_DEC` costs a
      cycle that has to be budgeted out of the data-bit delay, or every bit
      period runs long and the byte comes out scrambled even though
      "RTL matches interpreter" was true the whole time), config_port SPI
      framing, and the full core-level SPI-program-and-toggle integration.
- [ ] Golden protocol-level software models (`hardcaml/lib/protocols/
      {uart,spi,i2c}.ml`) as reusable modules, and property-based
      (randomized stimulus) Cyclesim tests — what exists today is a solid
      directed UART TX test plus generic infrastructure
      (`run_and_compare`/`spi_transaction` in `test_ward.ml`) that a
      randomized-stimulus pass can build on directly; the randomization
      itself isn't written yet.
- [~] UART RX, SPI (master), I2C (master, incl. clock stretching) lane
      programs — **fully designed, not yet implemented**: pin assignments,
      instruction-by-instruction microcode, hand-verified cycle-by-cycle
      timing proofs, golden-model interfaces and a test plan are all
      written up in `hardcaml/lib/protocols/DESIGN.md`. Implementation is
      gated on the delay-scale ISA change (see findings below) so the
      microcode gets written once at real rates instead of twice.
      Original wording follows for context — UART TX is proven end-to-end; these are the next protocols
      to actually write and test now that the CPU is solid.
- [ ] Stretch: USB low-speed, 10BASE-T Manchester lane programs.
- [ ] Bonus protocols named in the full brief (beyond UART/SPI/I2C +
      USB/10BASE-T stretch): JTAG, SWD, PS/2, CAN bus — see
      ARCHITECTURE.md §11 for fit/difficulty per protocol. JTAG/SWD/PS2
      should be easy once the core works; CAN (bit-stuffing + CRC-15) is a
      deliberate stretch-of-stretch.
- [ ] "Logic analyzer" mode (IN-only lane program + PUSH loop = passive
      sniffer using the same hardware as protocol emulation) — directly
      serves the brief's own "hardware debugging and reverse engineering"
      framing, cheap to add once IN/PUSH work. See ARCHITECTURE.md §11.
- [ ] FPGA validation before committing to the ASIC flow (brief suggests
      this explicitly) — TT template ships an ICE40UP5K bitstream workflow
      (`.github/workflows/fpga.yaml`, currently push-disabled). Needs an
      actual FPGA board — ask the user if they have one.
- [ ] Fill in `info.yaml` author/discord/title for real, `docs/info.md`
      datasheet content, sign up via the Google Form.
- [ ] Push repo to GitHub as public/open-source (competition requirement),
      wire up the real CI (currently copied but unverified against our
      module name).

## Findings from the protocol design pass (2026-09-15)

Reading the RTL line-by-line while designing the UART RX / SPI / I2C
microcode surfaced four things that need action independent of writing the
protocol code. Full detail in `hardcaml/lib/protocols/DESIGN.md` §0.

1. **`ARCHITECTURE.md` claimed each lane "has its own clock divider" — it
   was never implemented.** No `clkdiv` exists anywhere in
   `isa.ml`/`sequencer.ml`/`core.ml`. With `delay` capped at 5 bits (32
   cycles) and no divider, the ISA *cannot* express a real 115200-baud UART
   bit (~434 cycles at 50 MHz) without a 2-instruction counted delay loop
   per timed step. Doc has been corrected. **Fix chosen: add a delay-scale
   field** (a 1-2 bit multiplier on `delay`, reusing spare operand bits
   several opcodes already have), which closes the gap, shortens every
   real-rate program, and kills the counted-loop cycle-accounting bug class.
   Lands *before* the protocol microcode is implemented.
2. **`Set_pins`/`Set_pindirs` overwrite the whole pin window, not per-bit**
   — there is no side-set mechanism (unlike the RP2040 PIO this is modeled
   on). A lane therefore cannot cleanly toggle a clock pin via `Set` *and*
   shift a data bit via `Out_pins` (which always targets local index 0):
   the `Set` clobbers the just-shifted bit. **This is why SPI and I2C each
   need 2 lanes**, coordinated by a shared IRQ flag per bit — a consequence
   of the ISA, not a design preference.
3. **Only 4 IRQ flags exist chip-wide**, with a confirmed 1-cycle
   cross-lane latency. Concurrent SPI (2 flags) + I2C (2 flags) exhausts
   the entire budget — zero headroom for a Phase B protocol (JTAG/SWD)
   needing its own coordination without time-multiplexing a flag or
   widening `num_irq` (an RTL change). Decide when JTAG/SWD get scheduled.
4. **Pin windows are a fixed 8-wide contiguous block** (`pincount` is a
   compile-time constant, not a runtime register). With 20 usable global
   pins, running all three protocols concurrently (5 lanes) means windows
   *must* overlap, and the RTL does not arbitrate — it just ORs whichever
   lanes claim a pin. Handled by an explicit per-lane-pair safety argument
   in `DESIGN.md` §7.2. **That argument is a property of the specific
   instructions chosen, not something the hardware enforces** — anyone
   editing those programs must re-verify it.

Also: the full 3-protocol concurrent demo needs **5 lanes, not 4**.
`num_lanes` is already a Hardcaml parameter so this is cheap (~567 flops),
and combined with the planned instruction-memory right-sizing it costs
*less* area than today's 4-lane configuration.

## Idea on file: full agent-hierarchy orchestration (proposed by Suresh, not adopted)

Suresh proposed running the whole project as a hierarchical agent
orchestration, mirroring a real ASIC organisation:

```
main_orchestrator
├─ FrontEnd_agent   → RTL_agent, verification_agent, tb_gen_agent,
│                     schematic_gen_agent, progress_track_agent, html_gen_agent
├─ Synthesis_agent  → syn_generic_agent, syn_map_agent, lec_verify_agent
├─ Implement_agent  → floorplan, place, cts, postroute, signoff_sta
├─ PPA_agent        → rtl_feedback_agent, ppa_opt_agent, feas_agent
└─ flow_agent       → ties the above together, runs stages in parallel where
                      possible, and shows a live "what is running and where
                      has it reached" view
```

**Not adopted for now** (Suresh agreed after discussing the tradeoffs): the
existing `spec-to-gds` agent already covers the Synthesis + Implement scope
as one integrated flow, so splitting it into 8 agents would rebuild what
exists; most individual PnR stages are mechanical tool invocations where an
agent adds nothing over running the command; and the live-progress view is
a native feature of the Workflow tool rather than something to hand-build.

**Kept on record because the structure is sound** — it maps cleanly onto how
this work actually decomposes, and if the project grows a team where
per-stage ownership maps to different people, this is likely the right shape
to revisit.

## Decisions made (with rationale, so we don't re-litigate)

- **4 lanes by default**, parameterized in Hardcaml so we can sweep 3–5 and
  pick based on measured area, not guesswork.
- **No SRAM macro dependency** for the baseline — register-file instruction
  memory per lane, statically sliced, to avoid depending on unconfirmed
  macro availability (open question #2 above).
- **50 MHz baseline clock** (TT template default) rather than assuming a
  higher clock works — upside only after STA confirms margin.
- **32-word instruction memory per lane** (not 64 as originally sketched in
  an early ARCHITECTURE.md draft) — chosen so `JMP`'s address field (5 bits)
  fits alongside its 3-bit condition field inside the ISA's uniform 8-bit
  operand budget without breaking the "every opcode has the same 3+8+5
  layout" regularity. Halves the dominant area cost (instruction memory)
  for free; revisit only if a protocol genuinely needs a longer program.
- **32-bit instruction memory address space is per-lane, not shared** —
  each lane only ever addresses its own slice, so no multi-port memory
  arbitration is needed (see ARCHITECTURE.md §4).
- **Config port register reads must be latched at least one cycle after the
  address that selects them, never on the same edge** — learned the hard
  way (see the `config_port` read-latch bug in the Status log above).
  Worth remembering for *any* future addressable-register interface in
  this design: a register can never combinationally depend on another
  register's own not-yet-applied update in the same cycle, however
  tempting that looks on paper.
