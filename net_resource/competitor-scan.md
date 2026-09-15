# Competitor scan — public entries found 2026-09-15

Found via web search (`Jane Street LinkedIn "protocol emulator" ASIC
competition comments`) — not from LinkedIn itself (login-walled), but this
turned out to be a better source: several teams already have public repos.

## [sheehanmunim/bitloom](https://github.com/sheehanmunim/bitloom) — most developed of the three

"Four tiny programmable I/O state machines bit-bang protocols from firmware
with cycle-exact timing, so new protocols can be added after fabrication."
6×4 tiles, IHP CMOS5L via Tiny Tapeout — same target as us.

- **4 identical lanes**, each with PC, X/Y regs, instruction/shift reg,
  **timebase (T) + deadline (DL) register**, fractional clock divider,
  4-deep FIFOs. Same lane-count instinct as ours (we also defaulted to 4).
- **ISA**: 8 opcodes in 16 bits — `jmp, wait, in, out, push/pull, mov, set,
  time` — plus 4 delay/side-set bits per instruction. Notably close in
  spirit to ours (also 16-bit, also a small fixed opcode set with a shared
  timing field), different in the details (they have `mov` as a distinct
  opcode where we fold register moves into `out`/`in`; they have a
  dedicated `time` opcode for their deadline scheme).
- **Deadline scheduling** (the interesting bit): instead of PIO-style
  "stall N cycles after this instruction," a program can `wait time`
  against an absolute deadline register, so two different branches through
  a program (different instruction counts) still land on the same sample
  instant. Solves UART RX / Manchester timing without forcing every code
  path to be hand-balanced to the same length. See our take in
  `README.md` — not adopting for v1, tracked as a possible v2 enhancement.
- **Host interface: 4-wire SPI slave**, not MCU-integrated like RP2040's
  PIO. "Any MCU can drive it." → we adopted this idea directly, see
  ARCHITECTURE.md §5.
- **Verification**: independent **Python** reference models per protocol
  (UART codec, SPI slave, I2C state machine, WS2812 decoder, Manchester
  validator), constrained-random with seeded payloads for reproducibility,
  plus **formal verification via Yosys SAT** proving FIFO invariants hold
  for 24 cycles post-reset. The formal-FIFO-invariant piece is a nice,
  cheap addition worth considering for us too (see NOTES.md open items).
- **Protocols shipped**: UART TX/RX, SPI master, I2C master (repeated
  start + NACK handling), **WS2812 LED driver**, Manchester TX, edge-
  timestamp capture "for reverse engineering" — notably they did *not*
  do USB or 10BASE-T (the two stretch goals named in the actual brief),
  and instead built WS2812 (not in the brief at all) and a
  reverse-engineering/logic-analyzer mode. Worth noting as a possible
  differentiation angle either way: doing the *actual* named stretch goals
  (USB-LS, 10BASE-T) that a leading competitor skipped could stand out,
  precisely because it's harder and more clearly matches the brief.
- **Limitations they admit**: flip-flop-based instruction memory (64 words;
  they note SRAM would help density — same tradeoff we discussed in
  ARCHITECTURE.md §4), host SPI capped ~6.25 MHz at 50 MHz system clock,
  not yet taped out (CI GDS run is their area/timing source of truth, i.e.
  no real synthesis numbers published yet either).
- Explicitly AI-paired: "The RTL, firmware, assembler, models and this
  documentation were written with Claude (Anthropic) as the pair
  programmer, directed and reviewed by Sheehan Munim."

## [2AMLogic/sg13cmos5l-protocol-emulator](https://github.com/2AMLogic/sg13cmos5l-protocol-emulator) — process-heavy, no RTL yet

Spec-ratification phase only (issue #1: "Ratify the target spec"). No code.
Interesting for their *process*, not their design:

- Requires a **target-spec table** with sourced commitments per row, and a
  **gap-to-submission tracker** — a useful pattern in general (make every
  spec claim traceable to a source, track what's proven vs. assumed). We're
  doing a lighter version of this via NOTES.md's open-questions list.
- ISA decision record explicitly demands: "deterministic cycle-level timing
  guarantees, **no data-dependent instruction latency**" — see our note on
  this in `README.md` (we satisfy it; worth stating explicitly).
- Flow: primary Yosys/OpenROAD, secondary LibreSOC reference flow, with a
  decision record reconciling GDS output between the two — more process
  than we need to replicate, but the underlying worry (does the local flow
  match Tiny Tapeout's CI hardening flow bit-for-bit?) is legitimate and
  worth keeping in mind once we get to synthesis.
- Verification plan: formal properties (timing determinism, pin-write
  latency) + constrained-random + independent reference models + gate-level
  regression + "AI-assisted verification with append-only audit trails."

## [mtanneer/janestreet.asic.protocol-emulator](https://github.com/mtanneer/janestreet.asic.protocol-emulator) — scaffold only

Explicitly a placeholder stage: `src/project.v` is "a dummy placeholder...
used to validate the sim/build/CI pipeline before real RTL exists." Real
design lives in a not-yet-fetched `SPEC.md`. Worth another look later.
Notable infra choices: Verilator lint, cocotb+FuseSoC sim, Yosys synthesis
check, gitleaks secret scanning, custom ~830MB Docker toolchain
(`hpretl/iic-osic-tools`-derived), protected main branch with required PR
review — solid CI hygiene, none of it architecturally novel.

## [derek-suwho/protocol-emulator-asic](https://github.com/derek-suwho/protocol-emulator-asic) — too early to assess

Only a README stub was fetchable; says "a deterministic protocol engine"
for "UART, SPI, I2C, and other digital protocols in firmware," references
an architecture/ISA doc not yet inspected. Revisit later.
