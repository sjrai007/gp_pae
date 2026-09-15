# WARD Protocol Microcode Design: UART RX, SPI Master, I2C Master

Design document for the three baseline protocols. Grounded in a
line-by-line read of `../isa.ml` (encode/decode + `Isa.Interp`),
`../sequencer.ml` (RTL semantics — which resolved several ambiguities the
architecture doc glosses over), `../core.ml` (pin crossbar, IRQ register,
config address map), and `../../test/test_ward.ml` (the `run_and_compare` /
`test_uart_tx` pattern this design extends).

Status: **design only — none of this is implemented yet.** `protocols/`
contains no `.ml` files and `programs/` is empty. See `../../../NOTES.md`
for where this sits in the plan.

---

## 0. Cross-cutting findings (read this before the per-protocol sections)

These four things affect all three protocols and are the most consequential
findings of this pass — surfacing them was the point of doing the
cycle-accounting exercise, not just producing working-looking microcode.

### 0.1 There is no clock divider in the implemented ISA — the 5-bit delay field caps every instruction at 32 cycles

`ARCHITECTURE.md` §1 asserts each lane "has its own clock divider". Checked:
`Isa.op`/`Isa.instr`, `Isa.Interp.t`, `Sequencer.I`, and `Core`'s per-lane
config registers (`pinbase`, `jmp_pin_cfg`, `run_cfg` — confirmed
exhaustively in `core.ml`) contain **no `clkdiv` field anywhere**. So every
"cycle" in a lane's timing model is a raw core-clock cycle, and `delay` is
5 bits (max 31), giving a hard ceiling of **32 cycles per instruction**.

At the 50 MHz baseline, a real UART bit at 115200 baud is ~434 cycles;
standard-mode I2C's 5 µs half-period is 250 cycles; even a modest 1 MHz SPI
half-period is 25 cycles (that one's actually in range). None of the slower
ones fit in one instruction's delay field.

**Workaround usable today, no RTL change:** a *counted delay loop* —
`Set(Set_y, k); loop: Jmp(Y_dec, loop)` — where the closing `Jmp`'s own
`delay` (also 0–31) multiplies the per-iteration cost, giving up to
`255 × 32 ≈ 8160` cycles from two instructions and one scratch register.
This is a real, deployable pattern. The concrete microcode below uses small
in-range constants (`N=8`, `H=6`) purely so the timing tables stay legible
and match the existing `test_uart_tx` convention of "small constant, same
shape as the real thing" — but **scaling any of these three programs to
real-world baud/SCL/SCLK rates requires inserting a counted delay loop at
each `delay`-bounded step**, costing 2 extra instruction words and
(critically) tying up whichever of X/Y isn't already the bit-counter.

**Resolution chosen (see the approved plan, "Lever B"):** add a
**delay-scale field** — a 1–2 bit multiplier on the existing 5-bit `delay`
(×1/×32, or ×1/×16/×256/×4096), reusing spare operand bits that several
opcodes already have (`Out` has 3 spare, `Wait`/`In` have 2, `Set` has 1;
`Jmp` has none but is a control instruction that never needs a long delay).
This closes the gap properly, eliminates every counted delay loop, keeps
real-rate programs short enough to shrink `imem_depth`, and removes the
counted-loop cycle-accounting bug class entirely. **This change lands
before the microcode below is implemented**, so the programs are written
once at real rates rather than rewritten.

### 0.2 `Set_pins`/`Set_pindirs` are whole-window overwrites, not per-bit set/clear — this breaks the "clock pin + data pin in one lane" pattern

`Set (dest, imm)`'s interpreter/RTL semantics (`Isa.Interp.exec`,
`Sequencer.pinvals_next`/`pindirs_next`) write **every** local pin 0–4 from
the immediate on every execution (`pindirs.(i) <- (imm lsr i) land 1` for
`i` across the window, not just the bits you "meant" to change). Meanwhile
`Out_pins`/`Out_pindirs`/`In_pins` with `n=1` always touch **local index 0
only** (`for i = 0 to n-1`, so `n=1` ⟹ `i=0` exclusively — confirmed in
both `Isa.Interp.exec` and `Sequencer.pinvals_next`'s `via_out` term).
There is no side-set mechanism (unlike RP2040 PIO, which this architecture
is explicitly modeled on) to toggle a clock pin independently of a
data-shift pin.

**Consequence:** any lane that (a) drives a data-dependent bit onto a pin
via `Out_pins`/`Out_pindirs` (necessarily local index 0), and (b) also
wants to toggle a *different* control pin (SCLK, SCL) via
`Set_pins`/`Set_pindirs` in the same instruction stream, will have every
`Set` call clobber local pin 0 back to that instruction's static immediate
— corrupting the just-shifted data bit, including at the worst possible
moment (the sampling edge).

Alternatives considered and rejected:
- **OSR-interleaving** (encode clock bits into the data stream) requires
  the host to pre-encode — breaks the "write a plain byte" interface.
- **Reading the bus level back** to pick a branch is fragile (depends on
  external pull-up settling within 1 cycle; infers digital state from
  analog-ish behavior it shouldn't need to).
- **`Out_pc` dispatch** works in principle (`Isa.Out_pc` / ARCHITECTURE.md
  §3 name this as the intended pattern) but with `n=1` the two branch
  targets are hardwired to instruction addresses 0 and 1, which conflicts
  with PC resetting to 0 on `clear` — address 0 can't simultaneously be
  "cold-boot entry point" and "bit=0 dispatch handler" without extra
  redirect instructions whose placement reopens the same problem.

**Resolution used throughout: split the data-shift pin and the
control-toggle pin into two separate lanes, synchronized by one shared IRQ
flag per bit ("bit_tick").** The pin doing `Out_pins`/`Out_pindirs` never
shares a lane with anything that calls `Set_pins`/`Set_pindirs` on a
different local index. An input-only pin (MISO, or nothing at all) *can*
safely share a lane with `Set`-driven control pins, because `Set` only
writes pins with `pindirs=1`; an input pin is immune by construction. This
is why **SPI needs 2 lanes and I2C needs 2 lanes** — not a choice, a
consequence.

### 0.3 IRQ flags have exactly 1 cycle of cross-lane latency, and the flag budget is tight

`core.ml`: `irq_flags <-- ((irq_flags.value |: any_irq_set) &: ~:any_irq_clr)`
is a **registered** update. A lane's `Irq(set,idx)` commits its effect into
`irq_set_out` (combinational, this cycle), which is latched into the shared
register at that cycle's edge — visible to *another* lane's
`Wait(_, Wait_irq, idx)` starting the **next** cycle, not the same one.
(Confirmed by cross-reading the test harness's own `rtl_irq` bookkeeping in
`run_and_compare`, which models exactly this one-cycle deferral.)
`Wait_irq` auto-clears the flag on wake (`irq_clr_out`'s second term), so
it's a genuine "pulse, consume once" primitive, safe to reuse every bit
period without an explicit clear.

There are only **4 shared flags, chip-wide** (`num_irq = 4`, hardcoded in
`sequencer.ml`, not a Hardcaml functor parameter like `num_lanes`). The
full 3-protocol demo uses exactly 4 (SPI: idx 0,1; I2C: idx 2,3) — **the
flag budget is fully exhausted**, with zero slack for a fourth
cross-lane-coordinated protocol (JTAG/SWD/PS2 from ARCHITECTURE.md §11)
without either time-multiplexing flags or widening `num_irq` (an RTL
change).

### 0.4 A lane's pin window is a fixed 8-wide contiguous block — with 20 global pins and 5 lanes, windows *must* overlap

`pincount = 8` is a Hardcaml-level constant, not a per-lane runtime
register (there's no "pincount" in `Core`'s config registers —
`Isa.Interp`'s `pincount` parameter is a *test-convenience* concept, not
something the RTL exposes). Since `pinbase` selects a contiguous 8-pin
window, 5 lanes claim 5×8=40 index-slots against only 20 physical global
pins — **overlap is unavoidable** once you have more than 2 concurrent
lanes. The RTL does not catch this: `core.ml`'s crossbar just ORs together
whichever lanes claim `pindirs=1` for a given global pin.

Every pin table below therefore needs an explicit **window-overlap safety
argument**, not just an active-pin non-overlap check: for each lane,
confirm which local indices it can *structurally never* drive (because
`Set_pins`/`Set_pindirs` cannot reach local index ≥5 at all — hardware
restriction, the `k < 5` guard in `sequencer.ml`'s
`pinvals_next`/`pindirs_next` — and because every `Out_pins`/`Out_pindirs`
call used here is `n=1`, touching only local index 0). See §7.

---

## 1. UART RX

### 1.1 Pin assignment

One pin, input-only, LSB-first 8N1 (matches the already-shipped UART TX
convention — no bit-order mismatch to worry about, unlike SPI/I2C).

| Signal | Local idx | Global index | Physical | Direction |
|---|---|---|---|---|
| RX | 0 | pinbase+0 (e.g. global 0 = `ui_in[3]`) | `ui_in` range (0–4) | input-only, correct — a lane placed here structurally cannot drive it even by mistake (no output path exists for global 0–4: `core.ml`'s `global_oe`/`global_val` are only defined for g≥5) |

No overlap risk beyond §7: this lane never issues
`Set_pindirs`/`Out_pindirs` with any bit beyond local0, so local1–7
permanently hold their reset value (pindir=0, input).

### 1.2 Algorithm

1. Idle: RX line held high by the external transmitter/pull-up. No
   pindir/pinval setup needed beyond a defensive `Set_pindirs,0`.
2. Block on the falling edge of the start bit: `Wait(pol=0, Wait_pin, 0)`.
   Deliberately matches the real RP2040 PIO UART-RX idiom (no idle-high
   pre-check) — see §6 for why a stricter version is scoped out.
3. Land on the center of data bit 0 (1.5 bit periods after the edge), then
   sample once per bit period for 8 bits via a 2-instruction loop
   (`In(In_pins,1)` + `Jmp(X_dec, ...)`), mirroring the already-verified
   UART TX bug lesson: the loop-closing `Jmp` costs 1 cycle whether taken
   or not, so it must be budgeted out of `In`'s own delay.
4. Optionally re-verify the stop bit is high (cheap framing sanity check —
   see §6 for the real risk this introduces).
5. `Push(blocking)` the byte to the host RX fifo, then loop back to step 2.

### 1.3 Microcode (N = 8 cycles/bit, chosen for a legible demo table; §0.1 covers scaling N up for a real baud)

```
addr  instr                              delay   purpose
0     Set(Set_pindirs, 0)                0       defensive: local0 = input
1     Wait(false, Wait_pin, 0)           10      block for falling edge; land at N+N/2 for bit0 center
2     Set(Set_x, 7)                      0       7 more bits after the first IN
3     In(In_pins, 1)          <- loop    6       sample bit b, LSB-first   (N-2, see §0.1's bug lesson)
4     Jmp(X_dec, 3)                      0       loop 8 times total
5     Wait(true, Wait_pin, 0)            0       (optional) stop-bit sanity check
6     Push(true)                         0       deliver byte to host RX fifo
7     Jmp(Always, 1)                     0       back to arm the next start-bit wait
```

### 1.4 Cycle-by-cycle proof

N=8; frame layout: start bit [0,8), data bit *i* [8(1+i), 8(2+i)), stop bit
[72,80). Falling edge observed at cycle 0 (i.e. `pins_in`=0 for the first
time at cycle 0 — `Wait`'s `exec` polls every cycle, so it commits exactly
then, no missed-edge risk).

| Instr | Executes at cycle | Cost (1+delay) | Lands at |
|---|---|---|---|
| `Wait(0,0)` | 0 | 1+10=11 | commits cycle 0; next instr at 11 |
| `Set(X,7)` | 11 | 1 | next at 12 |
| `In` (bit0) | **12** | 1+6=7 | next at 19 |
| `Jmp X_dec` (taken, X:7→6) | 19 | 1 | back to `In` at 20 |
| `In` (bit1) | **20** | 7 | … |
| `In` (bit *i*) | **12 + 8i** | — | matches bit *i*'s window center = `N+iN+N/2 = 12+8i` ✓ for i=0..7 (12,20,28,36,44,52,60,68) |
| `Jmp X_dec` (8th test, X=0, not taken) | 75 | 1 | falls through to `Wait(1,0)` at 76 |
| `Wait(true,0)` (stop-bit check) | 76 | stop window is [72,80); 76 is inside it → pin already high → commits immediately, cost 1 | `Push` at 77 |
| `Push(true)` | 77 | 1 (host ready) | `Jmp Always` at 78 |
| `Jmp Always -> 1` | 78 | 1 | back at `Wait(0,0)`, **polling from cycle 79** |

Cycle 79 is polling 1 full cycle before a maximally back-to-back next
byte's start bit at cycle 80 — proven safe even with zero inter-byte gap,
not just "usually fine".

**Delay-formula derivation** (for scaling `N`): landing the first `In` at
`N+N/2`, with `Set(X,7)` fixed at `delay=0`, requires `Wait`'s own delay
`D1 = N + N/2 - 2` (= 10 for N=8 ✓). The bitloop's `In` delay is `N-2`,
identical reasoning to the already-shipped `test_uart_tx`.

**Flagged limitation:** the stop-bit `Wait(true, Wait_pin, 0)` will block
forever on a genuine framing error (line never returns high) — a real
hazard, deliberately scoped out (§6), not an oversight.

---

## 2. SPI Master (Mode 0, single CS)

### 2.1 Why 2 lanes, concretely

MOSI (data-dependent, needs `Out_pins` ⟹ local index 0) and SCLK (control
toggle, needs `Set_pins`) cannot share a lane per §0.2. MISO, being
read-only, is immune to `Set_pins`'s clobber (pins with `pindir=0` are
skipped by `Set`'s write logic in both `Isa.Interp` and `sequencer.ml`), so
it *can* share a lane with the clock generator. Final split:

- **Lane `SPI_CLK`**: generates SCLK + CS_n (`Set_pins`), samples MISO
  (`In_pins`, local0).
- **Lane `SPI_MOSI`**: shifts MOSI out (`Out_pins`, local0) only.

Coordinated by one shared IRQ flag ("bit_tick", idx 1) plus a
transaction-start flag ("go", idx 0).

### 2.2 Pin assignment

`SPI_CLK`'s `pinbase` is placed exactly at the `ui_in`/`uo_out` boundary so
its one input (MISO) lands in the last `ui_in` slot and its outputs land in
the first `uo_out` slots, all inside one contiguous window:

| Lane | Local idx | Signal | Global idx | Physical range | Direction |
|---|---|---|---|---|---|
| SPI_CLK (`pinbase=4`) | 0 | MISO | 4 | `ui_in` (0–4) | input-only, correct |
| SPI_CLK | 1 | SCLK | 5 | `uo_out` (5–11) | output-only, correct |
| SPI_CLK | 2 | CS_n | 6 | `uo_out` | output-only, correct |
| SPI_MOSI (`pinbase=7`) | 0 | MOSI | 7 | `uo_out` | output-only, correct |

**Bit-order flag (load-bearing):** `Out_pins`/`Out_pindirs` always emit
OSR's current LSB first. Real SPI devices conventionally expect MSB-first.
This design sends **LSB-first** as the native convention (matching the
already-shipped UART TX, which is correctly LSB-first per the real UART
standard) and requires the **host to bit-reverse the byte before writing it
to the TX fifo** if talking to an MSB-first-only device. Document this in
the golden model (§4) and any host driver code, not just in a comment —
get it wrong and transactions are silently mirrored with no RTL-level
signal that anything is off.

### 2.3 Algorithm

Per byte: `SPI_MOSI` blocks on `Pull(true)` for a host byte, raises "go".
`SPI_CLK` blocks on "go", asserts CS_n low. For 8 bits: `SPI_CLK` raises
"bit_tick" (SCLK still low — safe window), `SPI_MOSI` reacts by shifting
the next OSR bit onto MOSI; `SPI_CLK`, after a fixed setup margin, raises
SCLK (sampling edge — external slave and `SPI_CLK`'s own `In_pins` both
sample MISO here), holds, lowers SCLK, loops. After 8 bits, `SPI_CLK`
deasserts CS_n and `Push`es the captured MISO byte.

### 2.4 Microcode

```
SPI_CLK (local0=MISO in, 1=SCLK out, 2=CS_n out):
 0  Set(Set_pindirs, 0b110)     0    local0 in, local1/2 out
 1  Set(Set_pins, 0b100)        0    idle: CS_n=1 (deasserted), SCLK=0
 2  Wait(true, Wait_irq, 0)     0    block for MOSI lane's "go"
 3  Set(Set_pins, 0b000)        0    assert CS_n=0, SCLK=0
 4  Set(Set_x, 7)               0    8 bits total
 5  Irq(true, 1)      <-loop    4    "bit_tick": safe window to load MOSI
 6  Set(Set_pins, 0b010)        0    raise SCLK=1 (sampling edge)
 7  In(In_pins, 1)              3    sample MISO
 8  Set(Set_pins, 0b000)        0    lower SCLK=0
 9  Jmp(X_dec, 5)               0    loop 8 bits
10  Set(Set_pins, 0b100)        0    deassert CS_n=1
11  Push(true)                  0    deliver captured MISO byte
12  Jmp(Always, 1)              0    next byte

SPI_MOSI (local0=MOSI out only):
 0  Set(Set_pindirs, 0b1)       0
 1  Set(Set_pins, 0b0)          0    MOSI idle low
 2  Pull(true)                  0    block for host TX byte
 3  Irq(true, 0)                0    "go"
 4  Set(Set_x, 7)               0
 5  Wait(true, Wait_irq, 1) <-  0    block for "bit_tick"
 6  Out(Out_pins, 1)            0    drive MOSI = next OSR bit
 7  Jmp(X_dec, 5)               0
```

### 2.5 Cycle-by-cycle proof

**Self-consistency (`SPI_CLK`'s own SCLK period — no cross-lane dependency
for its own timing):**

| Instr | Executes at | Cost | Next at |
|---|---|---|---|
| `Irq(1)` (bit_tick) | 0 | 1+4=5 | 5 |
| `Set(SCLK=1)` | 5 | 1 | 6 |
| `In(MISO)` | 6 | 1+3=4 | 10 |
| `Set(SCLK=0)` | 10 | 1 | 11 |
| `Jmp X_dec` | 11 | 1 | back to `Irq(1)` at 12 |

Period = 12 cycles, self-consistent, repeats identically for all 8 bits
(proven by induction exactly as the UART loop is: no accumulating drift,
since every step's cost is delay-field arithmetic, not conditional on
external state). SCLK high for cycles 5–9 (5 cycles), low for 10 through
4-of-next-period (7 cycles) — not 50/50, acceptable for SPI (no duty-cycle
requirement), tunable via the `In`/second-`Set` delay split if needed.

**Cross-lane margin (why `SPI_MOSI` never misses a deadline):** `Irq(1)`
commits at cycle 0 → shared register latches at cycle 0's edge → visible to
`SPI_MOSI`'s `Wait` starting cycle 1 (§0.3's 1-cycle latency) → `Wait`
commits at 1 → `Out(MOSI)` commits at 2. MOSI is stable from cycle 2, with
**3 full cycles of setup margin** before the sampling edge at cycle 5. This
is deliberately a margin proof, not an exact-cycle proof — `Wait`'s
blocking semantics make exact alignment unnecessary as long as the reacting
lane finishes before the deadline, which is the correct way to reason about
an IRQ-gated (not delay-field-gated) handshake.

---

## 3. I2C Master (with clock stretching)

### 3.1 Why 2 lanes, and the open-drain bit convention

Same root cause as SPI (§0.2): SDA (data-dependent, `Out_pindirs` ⟹
local0) and SCL (control toggle, `Set_pindirs`) can't share a lane. Split:

- **Lane `I2C_SDA`**: `pinval`=0 fixed forever (set once, never touched
  again — I2C open-drain never drives high, so this sidesteps the SPI-style
  value-clobber problem entirely; only *direction* changes per bit). Drives
  via `Out_pindirs` (local0=SDA): `pindir=1` (drive low) when the bit is 0,
  `pindir=0` (release, pulled high) when the bit is 1.
- **Lane `I2C_SCL`**: generates SCL via `Set_pindirs` alone (never touches
  SDA — different lane).

**Bit convention (two host-side transforms, both load-bearing):**
1. `Out_pindirs` copies OSR's bit directly into `pindir` — but we need
   `pindir = NOT(data bit)`. **The host must bit-invert the byte** before
   writing it to the I2C lane's TX fifo (`byte lxor 0xFF`).
2. Like SPI, I2C is conventionally MSB-first, but `Out_pindirs` always
   consumes OSR's current LSB first. **The host must also bit-reverse.**

Both transforms commute, so the host applies `bit_reverse(byte) lxor 0xFF`
once before each `Pull`. Document this prominently anywhere a host driver
or golden model touches I2C bytes — get either transform wrong and the
transaction is silently the bitwise-complement/mirror of what was intended.

### 3.2 Pin assignment

Both SDA and SCL must be true bidirectional (drive-low / release-and-read),
which per §0.4's pin model means **both are forced onto the `uio` range
(12–19)** — the one case in the whole design where the physical constraint
is non-negotiable, not a design choice.

| Lane | Local idx | Signal | Global idx | Physical range | Direction |
|---|---|---|---|---|---|
| I2C_SDA (`pinbase=12`) | 0 | SDA | 12 | `uio` (12–19) | bidir, correct |
| I2C_SCL (`pinbase=13`) | 0 | SCL | 13 | `uio` | bidir, correct |

### 3.3 Algorithm

Per byte (write direction; read direction is structurally symmetric — see
§6 for what's scoped out): `I2C_SDA` blocks on `Pull(true)` for the
(bit-reversed, inverted) address/data byte, drives SDA low while SCL is
still released (START condition), raises "go" (idx 2). `I2C_SCL` blocks on
"go", begins clocking: drives SCL low, then for 8 bits, raises "bit_tick"
(idx 3) while SCL is low (safe window for `I2C_SDA` to update), releases
SCL, **blocks on `Wait(true, Wait_pin, scl_idx)`** — this single instruction
is the entire clock-stretch mechanism, since a slave holding SCL low simply
keeps the `Wait` from committing, with zero corruption of anything
downstream — then drives SCL low again and loops. After 8 bits, `I2C_SDA`
releases SDA for the 9th (ACK) clock and samples it; `I2C_SCL` generates
that 9th clock identically to the other 8.

### 3.4 Microcode (H=6, SCL half-period matching SPI's H for a consistent demo; §0.1 covers scaling to real 100/400 kHz)

```
I2C_SDA (local0=SDA, bidir):
 0  Set(Set_pindirs, 0)        0    SDA released (idle high)
 1  Set(Set_pins, 0)           0    pinval=0, fixed forever
 2  Pull(true)                 0    block for host's pre-transformed byte
 3  Set(Set_pindirs, 0b1)      3    drive SDA low = START (SCL still released/high)
 4  Irq(true, 2)               0    "go": SCL lane may begin clocking
 5  Set(Set_x, 7)              0    8 bits total
 6  Wait(true, Wait_irq, 3)<-  0    block for "bit_tick"
 7  Out(Out_pindirs, 1)        0    pindir(SDA) = OSR's next (pre-inverted) bit
 8  Jmp(X_dec, 6)              0
 9  Set(Set_pindirs, 0)        0    release SDA for ACK bit
10  Wait(true, Wait_irq, 3)    0    wait for ACK-sample tick
11  In(In_pins, 1)             0    sample ACK/NACK into ISR
12  Push(true)                 0    deliver ACK status to host
13  Jmp(Always, 1)             0    next byte (STOP-condition generation sketched, not detailed — §6)

I2C_SCL (local0=SCL, bidir):
 0  Set(Set_pindirs, 0)        0    SCL released (idle high)
 1  Wait(true, Wait_irq, 2)    0    block for "go"
 2  Set(Set_pindirs, 0b1)      3    drive SCL low (begin clocking)
 3  Set(Set_x, 8)              0    8 data bits + 1 ACK clock = 9 total
 4  Irq(true, 3)      <-loop   4    "bit_tick": SDA lane may update now (SCL low)
 5  Set(Set_pindirs, 0)        0    release SCL
 6  Wait(true, Wait_pin, 0)    3    *** clock-stretch wait: block until SCL actually reads 1 ***
 7  Set(Set_pindirs, 0b1)      0    drive SCL low again
 8  Jmp(X_dec, 4)              0    loop 9 times (8 data + ACK)
 9  Jmp(Always, 0)             0    next byte
```

### 3.5 Cycle-by-cycle proof

**Self-consistency, non-stretch case (`I2C_SCL`'s own period):**

| Instr | Executes at | Cost | Next at |
|---|---|---|---|
| `Irq(3)` (bit_tick) | 0 | 1+4=5 | 5 |
| `Set(pindir SCL=0)` release | 5 | 1 | 6 |
| `Wait(true, pin, SCL)` — pull-up already visible, 0 retries | 6 | 1+3=4 | 10 |
| `Set(pindir SCL=1)` drive low | 10 | 1 | 11 |
| `Jmp X_dec` | 11 | 1 | back to `Irq(3)` at 12 |

Period = 12, matching SPI's pattern for consistency. SCL reads high for
cycles 6–9 (4 cycles), low for 10 through 5-of-next-period (7 cycles).

**Clock-stretch case:** if an external slave holds SCL low for `K` extra
cycles, `Wait(true, Wait_pin, 0)` simply doesn't commit until cycle `6+K`
instead of 6 — **every downstream instruction in this iteration shifts by
exactly +K, and every subsequent bit's timing is unaffected** (the next
iteration's `Irq(3)` still fires a fixed number of instructions later, at
absolute cycle `12+K`, and the loop period reverts to 12 for any bit the
slave doesn't stretch). This is the correctness argument for clock
stretching: it's absorbed *locally and losslessly* because `Wait` is
delay-field-independent. The proof is deliberately **structural** (every
instruction after the `Wait` is offset-relative, not absolute-cycle-
relative) rather than a numeric hand-simulation of one arbitrary `K` —
which is the right level of rigor for a primitive whose whole point is
"block for an externally-determined, unbounded duration".

**Cross-lane margin (`I2C_SDA` reacting to "bit_tick"):** `Irq(3)` commits
at cycle 0 → visible to `I2C_SDA`'s `Wait` at cycle 1 → commits at 1 →
`Out_pindirs` commits at 2. SDA's new direction is settled by cycle 2,
giving 3 cycles of margin before `I2C_SCL` releases SCL at cycle 5 —
comfortably before the earliest a slave or bus observer could sample (SCL
isn't even guaranteed high until cycle 6).

**START condition correctness:** `I2C_SDA` drives SDA low at instruction 3
while SCL is still fully released ("go" hasn't been raised yet) — satisfies
I2C's defining START requirement (SDA falls while SCL is high) *by
construction*, since `I2C_SCL` cannot begin driving SCL low until it
observes "go", which is raised strictly after SDA has already been pulled
low.

---

## 4. Golden software model design (`uart.ml`, `spi.ml`, `i2c.ml`)

None of these exist yet — sketched interfaces below, pure OCaml, no
Hardcaml/ISA dependency, matching ARCHITECTURE.md §7's stated intent
("independent of the ISA/RTL… a SECOND independent check beyond
decode-the-trace-by-hand").

```ocaml
(* uart.ml *)
type config = { bit_cycles : int } (* no parity/framing-error modeling, see §6 *)

val encode_frame : config -> byte:int -> bool list
(* idle-relative levels for one 8N1 frame: start(0), 8 data bits LSB-first, stop(1) *)

val decode_trace : config -> trace:int array -> start_search_from:int -> int option
(* find start-bit falling edge, mid-bit sample x8, return decoded byte or None if no
   valid stop bit -- reusable version of test_uart_tx's inline decode logic *)
```

```ocaml
(* spi.ml *)
type mode = Mode0 (* CPOL=0,CPHA=0 only -- see §6 *)
type bit_order = Lsb_first | Msb_first
type config = { half_period_cycles : int; mode : mode; bit_order : bit_order }

val host_encode : config -> byte:int -> int
(* applies the bit-reversal convention from §2.2 if bit_order = Msb_first *)

val expected_sclk_levels : config -> n_bits:int -> bool list
val expected_mosi_levels : config -> byte:int -> bool list

val decode_miso : config -> miso_trace:int array -> sclk_trace:int array -> int
(* samples miso_trace at every sclk rising edge; independent of any assumed lane split *)
```

```ocaml
(* i2c.ml *)
type config = { half_period_cycles : int }
type event = Start | Byte of int * bool (* byte, ack *) | Stop

val host_encode : config -> byte:int -> int
(* applies BOTH the bit-inversion and bit-reversal conventions from §3.1 *)

val decode_trace : config -> sda_trace:int array -> scl_trace:int array -> event list
(* pure edge/level decoder: START = SDA falls while SCL high, STOP = SDA rises while
   SCL high, data bits sampled at SCL highs in between. Level-driven, not
   cycle-counted, so it is correct regardless of clock-stretch duration by
   construction -- this is the property that makes it a good property-test oracle *)
```

Key design property across all three: **the decoder side is edge/level-
driven, never cycle-counted against an assumed period.** That's what makes
them usable as oracles for clock-stretched I2C traces and for
randomized-jitter SPI/UART traces without the golden model itself needing
to know the lane program's exact delay values.

---

## 5. Test plan

### 5.1 Directed tests (per protocol, mirroring `test_uart_tx`'s two-layer structure)

1. **UART RX** — single-lane, extends `run_and_compare` directly (no infra
   changes needed). Stimulus: `pins_in` synthesizes a UART frame (via
   `Uart.encode_frame`) for a fixed byte at a fixed cycle offset. Assert
   (a) RTL/interpreter agree every cycle (existing checks), and (b) the RX
   fifo's drained byte matches what was sent.
2. **SPI** and **I2C** — both need a **new** test harness capability:
   `run_and_compare` today drives exactly one `Sequencer` against exactly
   one `Isa.Interp`, with `irq_in` synthesized from that *same* lane's own
   `irq_set`/`irq_clr` — it does not model two independent lanes sharing
   one IRQ register. Two options, in preference order:
   - **Preferred: Core-level test**, extending the proven
     `test_core_integration` pattern (programs a lane over the real SPI
     config port, reads real `uio_out`/`uio_oe`). Load both lanes'
     programs, set both `pinbase`s per §2.2/§3.2, assert `run=1` on both,
     and independently decode the *physical* pin trace via the golden model
     (§4). Exercises the real shared `irq_flags` register and the real
     crossbar — exactly the things §0.3/§0.4 flag as risky.
   - Fallback (faster iteration during development): a **2-lane
     interpreter harness** — two `Isa.Interp.t` instances driven by a
     single outer loop sharing one mutable `irq: bool array`, with the
     update-then-use-next-iteration ordering that already matches
     `run_and_compare`'s `rtl_irq` bookkeeping (§0.3). Useful for debugging
     the handshake before paying for a full Cyclesim run, but **not** a
     substitute for the Core-level check, since it can't catch a
     crossbar/address-map bug.
3. **Independent trace decode (both)**: after the cross-check passes,
   capture the physical pin traces for ~3 bytes and run them through
   `Spi.decode_miso`/`I2c.decode_trace`, asserting decoded bytes/ACKs match
   what was sent. This is the step that actually catches microcode timing
   bugs, per the `test_uart_tx` lesson — RTL-vs-interpreter agreement alone
   would validate a self-consistently *wrong* period just as happily as a
   correct one.

### 5.2 Property-based / randomized extension

For each protocol, generate N trials (e.g. 1000+) randomizing:
- **UART**: byte value (0–255), small ±1–2 cycle jitter on the transmitting
  stimulus's edge timing (tests the mid-bit sampling margin, not just the
  nominal case).
- **SPI**: byte value, MISO trace injected by the test (random per-bit,
  since MISO is externally driven — the master doesn't control it), and
  small jitter on when MISO changes relative to the expected window.
- **I2C**: byte value, ACK/NACK response (random), and **clock-stretch
  duration** injected via the SCL stimulus (0 up to some max K, per §3.5's
  proof that this should only ever delay, never corrupt).

**Invariant checked every trial** (three layers, same as directed but
automated): (1) RTL/interpreter agreement every cycle; (2) golden-model
round-trip — decoded value equals the byte fed in; (3) for I2C
specifically, a **monotonicity check**: transaction completion cycle is
non-decreasing in stretch duration K, and the decoded byte is *identical*
regardless of K (stretching must never change the decoded value, only when
it arrives). That directly targets §3.5's correctness argument and is cheap
to assert automatically but easy to get subtly wrong by hand.

---

## 6. Explicitly scoped out (documented decisions, not silent gaps)

| Protocol | Scoped out | Reason |
|---|---|---|
| UART RX | Parity bit, configurable data/stop bit counts, framing-error recovery | Fixed 8N1 covers the competition demo's needs; the stop-bit `Wait` blocking forever on a bad frame is a real hazard left as a known limitation (a production version would need a bounded retry, e.g. counted via Y, instead of an unconditional blocking `Wait`) |
| UART RX | Idle-high pre-check before the start-bit `Wait` (glitch/noise rejection) | Matches the real RP2040 PIO idiom as shipped; adding a midpoint re-check of the start bit is a cheap 1-instruction addition later but adds cycle-budget complexity not justified for a first pass |
| SPI | Mode 1/2/3 (CPOL/CPHA variants), multi-slave/multiple CS lines, configurable bit order at the ISA level | Mode 0 alone proves the mechanism; CPHA=1 in particular changes *which* edge is setup vs. sample and would need re-deriving §2.5's table from scratch — same shape, not done here |
| I2C | Multi-master arbitration / clock synchronization, 10-bit addressing, general call, read-direction microcode (structurally symmetric, not written out), repeated-START multi-transaction sequences | Assumes a single master on the bus; real arbitration (detecting SDA driven low by another master when we expected our own level) needs an extra per-bit compare that changes the loop structure meaningfully — a genuinely separate design pass |
| All three | Real baud/SCL/SCLK rates at 50 MHz (§0.1) | Addressed by the delay-scale ISA change landing before implementation; until then the counted-delay-loop pattern is the documented workaround |

---

## 7. Multi-lane concurrency and the "run all three at once" demo

### 7.1 Lane budget reality check

Given §0.2, SPI needs 2 lanes and I2C needs 2 lanes. UART RX needs 1.
**Total for genuinely concurrent UART+SPI+I2C = 5 lanes**, exceeding the
current 4-lane default. Two honest options:

- **Recommended: bump `num_lanes` to 5.** ARCHITECTURE.md §6's design-time
  estimate attributes ~220 flops (datapath) + ~2050 flops (instruction
  memory) to the *combined* 4 lanes, i.e. ~55 + ~512 ≈ 567 flops for one
  additional lane, against a measured 12,442-cell/2,462-flop total already
  well under the ~24K budget. Small, well-understood, already-parameterized
  (`num_lanes` is a Hardcaml parameter). This is the headline demo the
  brief explicitly wants. **Note:** combined with the planned `imem_depth`
  right-sizing, 5 lanes actually costs *less* imem area than today's 4.
- **Fallback within the current 4-lane baseline:** run I2C (2 lanes) + SPI
  (2 lanes) concurrently — exactly fills 4 lanes and literally satisfies
  "two protocols running simultaneously and independently". UART RX would
  be demoed standalone.

### 7.2 Concrete 5-lane demo pin table

| Lane | Program | `pinbase` | Active local pins | Active global pins |
|---|---|---|---|---|
| L0 | UART_RX | 0 | 0 | 0 (`ui_in[3]`) |
| L1 | I2C_SDA | 12 | 0 | 12 (`uio[0]`) |
| L2 | I2C_SCL | 13 | 0 | 13 (`uio[1]`) |
| L3 | SPI_CLK | 4 | 0,1,2 | 4 (`ui_in[7]`), 5 (`uo_out[1]`), 6 (`uo_out[2]`) |
| L4 | SPI_MOSI | 7 | 0 | 7 (`uo_out[3]`) |

**Window-overlap safety argument (§0.4's concern, resolved per-pair):**

- L0 (window 0–7) overlaps L3 (window 4–11) at global 4–7. L0 never issues
  `Set_pindirs`/`Out_pindirs` beyond local0 (its boot `Set_pindirs,0` only
  reaches local0–4 anyway per the `k<5` hardware restriction, and it never
  uses `Out_pindirs` at all), so L0's local4–7 are permanently pindir=0 —
  safe.
- L3 (window 4–11) overlaps L4 (window 7–14) at global 7–11. L3's microcode
  only ever sets local0–2 (`Set_pindirs, 0b110`); local3–7 untouched,
  permanently pindir=0 — safe, including at global7 where L4 actively
  drives.
- L4 (window 7–14) overlaps L1 (window 12–19) at global 12–14. L4 only ever
  touches local0 (`Set_pindirs, 0b1`, then `Out_pins` with n=1); local5–7
  (global 12–14) permanently pindir=0 — safe.
- L1 (window 12–19) overlaps L2 (window 13–20) at global 13–19. L1 only
  uses `Out_pindirs` with n=1 (local0) and `Set_pindirs` restricted to
  local0–4 by hardware, with bits 1–4 always 0 in every instruction here —
  local1–7 permanently pindir=0, including at global13 where L2 is active —
  safe. (Global 20 in L2's nominal window is out of range; `core.ml`'s
  crossbar simply doesn't route beyond global19, harmless.)

> **Maintenance warning for whoever implements this:** this safety argument
> is a property of the *specific instructions chosen* (every
> `Out_pins`/`Out_pindirs` call here is `n=1`; every `Set_pindirs`/`Set_pins`
> immediate has zero bits beyond the intended local index), **not** a
> property the hardware enforces. Any future revision that adds a wider
> `Out_pindirs`/`Out_pins` call, or a nonzero high bit to a `Set_pindirs`
> immediate on any of these five lanes, must re-verify against this table
> before deployment. There is no RTL-level guard.

**IRQ flag budget for this demo:** SPI uses idx 0 ("go") and 1
("bit_tick"); I2C uses idx 2 ("go") and 3 ("bit_tick"). All 4 available
flags are consumed — UART RX needs none, leaving **zero headroom** for a
6th lane needing cross-lane coordination without widening `num_irq` or
time-multiplexing an existing flag.

---

## Critical files for implementation

- `../isa.ml` — encode/decode + `Isa.Interp`; every microcode listing above
  must round-trip through this and match `Isa.Interp.step` cycle-for-cycle
- `../sequencer.ml` — the RTL semantics that resolved every ambiguity in
  this design (`Set`/`Out` clobber behavior, `pincount=8` fixed, the `k<5`
  restriction, IRQ latch timing)
- `../core.ml` — pin crossbar (`pinbase`, `global_oe`/`global_val`,
  `flat_in`), shared `irq_flags`, config address map — needed for the
  5-lane pinbase assignments and the Core-level test harness
- `../../test/test_ward.ml` — `run_and_compare`, `test_uart_tx`,
  `test_core_integration`; SPI/I2C directed tests extend the last of these
- `uart.ml` / `spi.ml` / `i2c.ml` (this directory) — do not yet exist;
  interfaces sketched in §4
- `../../../NOTES.md` — §0.1 (missing clkdiv) and §7.1 (5-lane
  recommendation) are logged there as open items
