<!--
This file is used to generate your project datasheet. Please fill in the
information below and delete any unused sections.
-->

## How it works

WARD is 4 independent tiny programmable pin-sequencers ("lanes") sharing a
20-pin crossbar and a 4-wire SPI config/data port. Each lane is a small CPU
whose 8 opcodes read pins, write pins, and count cycles (see
[`ARCHITECTURE.md`](../ARCHITECTURE.md) for the full instruction set) — no
protocol logic is fixed in silicon; UART/SPI/I2C/anything-else is a program,
not a hardware block. A lane's instruction memory, which pins it's windowed
onto, and its clock divider are all writable over the SPI port at any time,
so the chip is reprogrammable for new protocols after fabrication.

## How to test

Drive the SPI config port on `ui_in[2:0]` (`cfg_sclk`, `cfg_mosi`,
`cfg_cs_n`) and read `uo_out[0]` (`cfg_miso`). Each transaction is 4 bytes,
MSB-first: `[rw, addr, data_hi, data_lo]` (`rw` bit0: 1=write, 0=read).
`addr[7:6]` selects a lane (0-3), `addr[5]` selects instruction memory
(word address in `addr[4:0]`) vs. a config/data register (`addr[4:0]`: 0 =
pinbase, 1 = jmp_pin, 2 = run, 3 = TX FIFO write, 4 = RX FIFO read).

1. Write a lane's instruction memory (a program — see
   `hardcaml/test/test_ward.ml`'s `test_uart_tx`/`test_core_integration` for
   worked examples, or `programs/` once populated).
2. Write that lane's `pinbase` register to point its 8-pin local window at
   the desired GPIOs (global index 0-4 = `ui_in[7:3]`, 5-11 = `uo_out[7:1]`,
   12-19 = `uio[7:0]` — see `ARCHITECTURE.md` §2/§5).
3. Write `run = 1` to start it.
4. Feed/drain protocol data bytes through that lane's TX/RX FIFO registers
   (addr offsets 3/4) as the program's `PUSH`/`PULL` instructions need them.

The `test/` directory's cocotb testbench (`test.py`) does exactly this over
the actual generated Verilog, and is a good starting reference.

## External hardware

None required to exercise the design logically (the cocotb testbench needs
none). For a physical demo: any host MCU capable of bit-banging or
hardware-driving a 4-wire SPI bus (the config port doesn't require a
specific host — see `ARCHITECTURE.md` §5 for why SPI was chosen over a
custom parallel bus). Depending on which lane program is loaded, the
protocol-facing pins (`ui_in[7:3]`, `uo_out[7:1]`, `uio[7:0]`) connect to
whatever the emulated protocol needs — e.g. a Pmod UART/SPI/I2C breakout
for bring-up, per Tiny Tapeout's [recommended
pinouts](https://tinytapeout.com/hdl/pinouts/).
