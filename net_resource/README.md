# net_resource — external ideas, comments, competitive landscape

A place to dump useful things found on the internet about this competition —
comments, competitor repos, ideas worth stealing or avoiding — separate from
our own design docs (`../ARCHITECTURE.md`, `../NOTES.md`) so sourced material
stays clearly distinguished from our own decisions.

Note on provenance: LinkedIn's actual comment thread
(linkedin.com/company/jane-street-global/posts/) is behind their login wall
and not fetchable here — if you have it open in a browser, worth pasting
anything useful in below by hand. Everything captured so far instead comes
from public competitor repos surfaced by web search (see
[`competitor-scan.md`](competitor-scan.md)), which turned out to be a richer
source than the LinkedIn comments would likely have been anyway.

## Files

- [`competitor-scan.md`](competitor-scan.md) — other public competition
  entries found on GitHub (as of 2026-09-15), what they're doing
  differently, and what we should consider adopting.

## Headline takeaways already acted on

1. **Host interface: SPI slave, not a parallel bus.** BitLoom uses a 4-wire
   SPI slave for host↔chip communication ("any MCU can drive it"). Our
   original config-port sketch (ARCHITECTURE.md §5) used a byte-parallel
   bus that permanently ate 10 of our 24 GPIOs. Switched to a 4-wire SPI
   slave (3 dedicated-in + 1 dedicated-out pins) — frees ~6 pins for actual
   protocol lanes. Also just a better idea on its own merits: standard,
   any host MCU can bit-bang or hardware-SPI it, no custom protocol to
   document for board bring-up. See ARCHITECTURE.md §5 (updated).
2. **Deadline/absolute-time scheduling** (BitLoom's `wait time` against a
   free-running timebase register, vs. plain relative delay-after-instruction
   like classic PIO) is a genuinely good idea for protocols where different
   branches through a program take different numbers of instructions but
   need to land on the same absolute sample instant (their examples: UART
   RX, Manchester decode). We're **not** adopting it for v1 — our lane
   programs keep code paths constant-length between WAITs, which sidesteps
   the problem without the extra timebase/deadline register hardware — but
   it's flagged in ARCHITECTURE.md as a considered alternative / possible
   v2 enhancement if a protocol turns out to need genuinely variable-length
   branches between timing-critical points.
3. Confirms our instinct on verification approach (independent
   language-level reference models + constrained-random testing) is roughly
   where other serious entries are landing too — BitLoom uses Python
   reference models per protocol, 2AMLogic's spec explicitly calls for
   "constrained-random protocol traffic with independent reference models"
   plus formal properties. Reassuring convergence, not a reason to change
   anything (our OCaml/Hardcaml version of the same idea, described in
   ARCHITECTURE.md §7, is a fine equivalent — arguably strengthened by also
   cross-checking two independent simulators on the *same* generated RTL).
4. 2AMLogic's spec explicitly calls out "deterministic cycle-level timing,
   no data-dependent instruction latency" as a requirement. Worth stating
   explicitly in our own docs that this holds for GP_PAE too (true by
   construction: every instruction is 1 cycle + a fixed programmed delay,
   except WAIT/blocking-PUSH/PULL which block on genuinely external
   conditions — not on operand *values* — which is the correct and
   unavoidable exception, not a violation of the principle).

## Not yet done

- Get the actual LinkedIn comment thread content (needs a logged-in
  browser) — ask the user to paste it in if they think there's something
  in there worth mining beyond what competitor-scan.md already found.
- Revisit this scan periodically as more teams post repos before the
  2027-01-18 deadline.
