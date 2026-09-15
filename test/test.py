# SPDX-License-Identifier: Apache-2.0
#
# Drives the actual generated Verilog (src/generated/core.v, via the
# tt_um_ward_protocol_emulator wrapper in src/project.v) through Icarus
# Verilog + cocotb -- deliberately a second, independent simulator/language
# from the Hardcaml Cyclesim tests in hardcaml/test/test_ward.ml, so a bug
# has to survive two independently-implemented simulation engines on the
# same generated RTL to slip through (see ARCHITECTURE.md \167 7).
#
# This mirrors hardcaml/test/test_ward.ml's `test_core_integration`: program
# lane 0 over the real 4-wire SPI config port with a small toggle program,
# point it at global pin index 12 (uio[0]) via pinbase, start it, and check
# the toggle actually appears on uio_out[0]/uio_oe[0].

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

CFG_SCLK = 0
CFG_MOSI = 1
CFG_CS_N = 2


def set_cfg_pins(dut, sclk, mosi, cs_n):
    v = (1 if sclk else 0) | (1 << 1 if mosi else 0) | (1 << 2 if cs_n else 0)
    dut.ui_in.value = v


async def spi_send_byte(dut, byte):
    for b in range(7, -1, -1):
        bit = (byte >> b) & 1
        set_cfg_pins(dut, sclk=0, mosi=bit, cs_n=0)
        await ClockCycles(dut.clk, 1)
        set_cfg_pins(dut, sclk=1, mosi=bit, cs_n=0)
        await ClockCycles(dut.clk, 1)


async def spi_write(dut, addr, wdata):
    set_cfg_pins(dut, sclk=0, mosi=0, cs_n=0)
    await ClockCycles(dut.clk, 1)
    await spi_send_byte(dut, 1)  # rw = write
    await spi_send_byte(dut, addr)
    await spi_send_byte(dut, (wdata >> 8) & 0xFF)
    await spi_send_byte(dut, wdata & 0xFF)
    set_cfg_pins(dut, sclk=0, mosi=0, cs_n=1)
    await ClockCycles(dut.clk, 1)


# ISA encoding must match hardcaml/lib/isa.ml's encode_operand exactly --
# see that file for the field layout. This is just SET/JMP, hand-encoded.
def encode_set(dest, imm, delay=0):
    opcode = 2
    operand = ((dest & 0x3) << 6) | ((imm & 0x1F) << 1)
    return (opcode << 13) | (operand << 5) | (delay & 0x1F)


def encode_jmp(cond, addr, delay=0):
    opcode = 0
    operand = ((cond & 0x7) << 5) | (addr & 0x1F)
    return (opcode << 13) | (operand << 5) | (delay & 0x1F)


SET_PINDIRS = 3
SET_PINS = 0


@cocotb.test()
async def test_lane0_toggle_over_spi(dut):
    """Program lane 0 via the real SPI config port; check uio[0] toggles."""
    clock = Clock(dut.clk, 20, unit="ns")  # 50 MHz, matches src/config.json
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0b100  # cs_n idle high
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

    # lane 0, imem block (addr[5]=0), word address = program index
    program = [
        encode_set(SET_PINDIRS, 0b1),
        encode_set(SET_PINS, 0b1, delay=2),
        encode_set(SET_PINS, 0b0, delay=2),
        encode_jmp(0, 1),  # JMP ALWAYS, 1
    ]
    for word_addr, instr in enumerate(program):
        await spi_write(dut, word_addr, instr)

    # lane 0, regs block (addr[5]=1): offset 0 = pinbase -> global 12 (uio[0])
    await spi_write(dut, 0x20, 12)
    # offset 2 = run
    await spi_write(dut, 0x22, 1)

    saw_oe = False
    saw_high = False
    saw_low = False
    for _ in range(40):
        await ClockCycles(dut.clk, 1)
        uio_out = int(dut.uio_out.value)
        uio_oe = int(dut.uio_oe.value)
        if uio_oe & 1:
            saw_oe = True
            if uio_out & 1:
                saw_high = True
            else:
                saw_low = True

    assert saw_oe, "lane 0 never asserted uio_oe[0] (SET PINDIRS didn't take effect)"
    assert saw_high, "uio_out[0] never went high"
    assert saw_low, "uio_out[0] never went low"
