# GP_PAE — Reprogrammable Protocol Emulator ASIC

*General Purpose Protocol ASIC Emulator*

[![tests](https://github.com/sjrai007/gp_pae/actions/workflows/test.yaml/badge.svg)](https://github.com/sjrai007/gp_pae/actions/workflows/test.yaml)
[![hardcaml](https://github.com/sjrai007/gp_pae/actions/workflows/hardcaml.yaml/badge.svg)](https://github.com/sjrai007/gp_pae/actions/workflows/hardcaml.yaml)
[![gds](https://github.com/sjrai007/gp_pae/actions/workflows/gds.yaml/badge.svg)](https://github.com/sjrai007/gp_pae/actions/workflows/gds.yaml)
[![docs](https://github.com/sjrai007/gp_pae/actions/workflows/docs.yaml/badge.svg)](https://github.com/sjrai007/gp_pae/actions/workflows/docs.yaml)

Entry for the [Jane Street Protocol Emulator ASIC Competition](https://blog.janestreet.com/protocol-emulator-asic-competition/):
an open-source, general-purpose protocol emulator ASIC on Tiny Tapeout /
IHP 130nm CMOS5L, built from a **tiny CPU whose instruction set reads pins,
writes pins, and counts cycles** — per the brief, not fixed protocol blocks.

GP_PAE is **N independent tiny sequencer "lanes"** sharing a pin crossbar and a
post-fabrication-writable instruction store, so it emulates UART, SPI, and
I2C simultaneously and independently out of the box, and can be reprogrammed
after fabrication to emulate protocols that don't exist yet — including the
stretch goals (low-speed USB, 10BASE-T / 10Mbit Ethernet).

**Design docs:** [`ARCHITECTURE.md`](ARCHITECTURE.md) (the real content — ISA,
lane/pin model, area budget, verification methodology) · [`NOTES.md`](NOTES.md)
(status, open questions, decisions log — read this before picking the project
back up).

## Repo layout

```
hardcaml/       OCaml/Hardcaml source of truth for the core (ISA, lane
                datapath, N-lane top, golden protocol models, tests)
programs/       Assembled protocol microcode (.asm sources + assembled .hex)
src/            Tiny Tapeout deliverable: project.v wrapper + generated
                Verilog (src/generated/, checked in, regenerated from
                hardcaml/)
test/           Standard Tiny Tapeout cocotb testbench (RTL + gate-level)
docs/info.md    Tiny Tapeout datasheet
info.yaml       Tiny Tapeout project metadata
```

## Status

The core CPU works and is verified two independent ways: the Hardcaml core
(`hardcaml/`) passes 742 checks (`dune test`) cross-checking the RTL against
a from-scratch OCaml interpreter cycle-by-cycle, a real UART byte decoded
off the emitted waveform, and a full lane programmed over the actual 4-wire
SPI config port; the *generated Verilog* separately passes a cocotb test
against Icarus Verilog (`test/`, a completely different simulator/language
stack from the Hardcaml one). Area is ~12.4K cells (generic synthesis,
not yet PDK-mapped), comfortably inside the ~24K tile budget.

Not yet done: actual UART/SPI/I2C protocol programs (only a UART TX proof
of concept exists so far), the stretch/bonus protocols, PDK-mapped
synthesis and place & route, and the open questions in `NOTES.md` (tile
shape for the chipathon's 6×4 allocation, in particular — **don't submit
without resolving that one**). See [`NOTES.md`](NOTES.md) for the live,
detailed checklist.

## Continuous integration

Both halves of the verification claim run on every push, and they are
genuinely independent of each other:

| Workflow | What it proves |
|---|---|
| `hardcaml` | Builds the Hardcaml design and runs the full check suite — the RTL against a from-scratch software model of the same instruction set, cycle by cycle. Also regenerates the Verilog and fails if it differs from what is committed. |
| `test` | Runs the generated Verilog through **Icarus Verilog** with cocotb — a different simulator, a different language, same design. |
| `gds` | Tiny Tapeout's real RTL-to-GDS hardening flow, plus their submission precheck and a gate-level test. |
| `docs` | Builds the Tiny Tapeout datasheet from `info.yaml` and `docs/info.md`. |

## Building / testing

```sh
# Hardcaml core: build + the full cross-checked test suite + regenerate Verilog
# (hardcaml-ward is just the local opam switch name, unrelated to the project)
cd hardcaml && eval "$(opam env --switch=hardcaml-ward --set-switch)"
dune build && dune exec test/test_gp_pae.exe   # 742 checks, 0 failures
dune exec bin/generate_rtl.exe               # writes ../src/generated/core.v

# Tiny Tapeout cocotb testbench against the generated Verilog, independently
cd ../ && source .venv/bin/activate
cd test && make -B                           # PASS, see results.xml
```

## License

Apache-2.0 (matching the Tiny Tapeout template), see [`LICENSE`](LICENSE).
