/*
 * WARD -- reprogrammable protocol emulator
 * Jane Street Protocol Emulator ASIC Competition
 * SPDX-License-Identifier: Apache-2.0
 *
 * Thin Tiny Tapeout wrapper around the generated core (src/generated/core.v,
 * produced by `dune exec bin/generate_rtl.exe` from hardcaml/ -- see
 * ARCHITECTURE.md; do not hand-edit core.v). This file only does the two
 * things Hardcaml doesn't know about: the tt_um_* port/name convention
 * (including inverting rst_n into ward_core's active-high `clear`) and
 * tying off `ena` (always 1 whenever the design is powered, per Tiny
 * Tapeout's convention -- nothing here depends on it).
 */

`default_nettype none

module tt_um_ward_protocol_emulator (
    input  wire [7:0] ui_in,    // Dedicated inputs -- see ARCHITECTURE.md \S5: ui_in[2:0] = cfg_sclk/mosi/cs_n
    output wire [7:0] uo_out,   // Dedicated outputs -- uo_out[0] = cfg_miso
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  wire _unused = &{ena, 1'b0};

  ward_core core (
      .clock  (clk),
      .clear  (~rst_n),
      .ui_in  (ui_in),
      .uio_in (uio_in),
      .uo_out (uo_out),
      .uio_out(uio_out),
      .uio_oe (uio_oe)
  );

endmodule
