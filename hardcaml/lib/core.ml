(* GP_PAE top level: instantiates [num_lanes] [Sequencer]s, a [Config_port]
   SPI slave, a flat 20-pin crossbar mapping each lane's local 8-pin window
   onto a subset of the chip's real GPIOs, and a small shared 4-flag IRQ
   register -- see ARCHITECTURE.md \167\167 1-6.

   Pin layout (matches info.yaml / ARCHITECTURE.md \167 5):
     ui_in[2:0]  = cfg_sclk, cfg_mosi, cfg_cs_n (dedicated to the config port)
     ui_in[7:3]  = flat global indices 0..4   (input-only from a lane's POV)
     uo_out[0]   = cfg_miso
     uo_out[7:1] = flat global indices 5..11  (output-only from a lane's POV)
     uio[7:0]    = flat global indices 12..19 (the only true bidirectional range)

   Address map for the config port's 8-bit address (see [Config_port]):
     addr[7:6] = lane index (0..3)
     addr[5]   = 0 -> that lane's instruction memory, addr[4:0] = word address
                 1 -> that lane's config/data registers, addr[4:0] = which:
                        0 = pinbase (5 bits)      1 = jmp_pin (3 bits)
                        2 = run (1 bit)            3 = tx fifo write (8 bits)
                        4 = rx fifo read ({rx_valid, rx_data[7:0]}) *)

open Hardcaml
open Signal

let num_lanes = 4
let flat_pins = 20

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; ui_in : 'a [@bits 8]
    ; uio_in : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { uo_out : 'a [@bits 8]
    ; uio_out : 'a [@bits 8]
    ; uio_oe : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

let bits_of ~width f = concat_msb (List.init width f |> List.rev)

(* dynamic (run-time-indexed) 1-bit read from an up-to-32-bit bus, padding
   any width beyond [bus]'s own with gnd -- used throughout for crossbar
   addressing where the index is a config register, not a compile-time
   constant. *)
let dyn_bit (bus : Signal.t) (idx5 : Signal.t) =
  let w = Signal.width bus in
  mux idx5 (List.init 32 (fun k -> if k < w then select bus k k else gnd))
;;

let create (i : Signal.t I.t) : Signal.t O.t =
  let spec = Reg_spec.create () ~clock:i.clock ~clear:i.clear in
  let open Always in
  (* --- per-lane config registers (written over the config port) --- *)
  let pinbase = Array.init num_lanes (fun _ -> Variable.reg spec ~width:5) in
  let jmp_pin_cfg = Array.init num_lanes (fun _ -> Variable.reg spec ~width:3) in
  let run_cfg = Array.init num_lanes (fun _ -> Variable.reg spec ~width:1) in
  let irq_flags = Variable.reg spec ~width:4 in
  (* --- config port I/O pin assignment --- *)
  let cfg_sclk = select i.ui_in 0 0 in
  let cfg_mosi = select i.ui_in 1 1 in
  let cfg_cs_n = select i.ui_in 2 2 in
  (* --- flat input bus: real for ui_in/uio ranges, gnd for the uo_out
     range (no physical input path there), padded to 32 bits for safe
     dynamic addressing *)
  let flat_in =
    bits_of ~width:flat_pins (fun k ->
      if k < 5
      then select i.ui_in (k + 3) (k + 3)
      else if k < 12
      then gnd
      else select i.uio_in (k - 12) (k - 12))
  in
  (* --- break the Config_port <-> lane-outputs combinational cycle: proxy
     Config_port's outputs with wires, use the wires everywhere below, tie
     them to the real outputs once Config_port.create has run (see the
     module doc for why this loop exists: register reads need lane state
     that's only known after instantiating the lanes, but the lanes need
     the write-decode that's only known after instantiating the config
     port -- neither is a real same-cycle hardware loop, addr/we/re are all
     registered outputs of Config_port, so this is purely an artifact of
     OCaml value construction order, not a combinational loop in the
     generated netlist). *)
  let cfg_addr = wire 8 in
  let cfg_we = wire 1 in
  let cfg_re = wire 1 in
  let cfg_wdata = wire 16 in
  let lane_sel = select cfg_addr 7 6 in
  let is_regs_block = select cfg_addr 5 5 in
  let offset = select cfg_addr 4 0 in
  let imem_we_for l = cfg_we &: ~:is_regs_block &: (lane_sel ==:. l) in
  let reg_write_for l = cfg_we &: is_regs_block &: (lane_sel ==:. l) in
  let reg_read_for l = cfg_re &: is_regs_block &: (lane_sel ==:. l) in
  let host_tx_valid_for l = reg_write_for l &: (offset ==:. 3) in
  let host_rx_ready_for l = reg_read_for l &: (offset ==:. 4) in
  (* --- per-lane pin windows (dynamic: pinbase is a runtime register) --- *)
  let flat_in_pad32 = uresize flat_in 32 in
  let lane_pins_in l =
    bits_of ~width:8 (fun local ->
      dyn_bit flat_in_pad32 (pinbase.(l).value +: of_int ~width:5 local))
  in
  (* --- instantiate the lanes --- *)
  let lane_outputs =
    Array.init num_lanes (fun l ->
      Sequencer.create
        { Sequencer.I.clock = i.clock
        ; clear = i.clear
        ; run = run_cfg.(l).value
        ; pins_in = lane_pins_in l
        ; irq_in = irq_flags.value
        ; jmp_pin = jmp_pin_cfg.(l).value
        ; imem_we = imem_we_for l
        ; imem_waddr = offset
        ; imem_wdata = cfg_wdata
        ; host_tx_valid = host_tx_valid_for l
        ; host_tx_data = select cfg_wdata 7 0
        ; host_rx_ready = host_rx_ready_for l
        })
  in
  (* --- output crossbar: for each real global pin position (5..19, i.e.
     the uo_out and uio ranges -- ui_in range 0..4 has no output path),
     OR together whichever lane currently owns and drives it *)
  let global_oe g =
    Array.to_list lane_outputs
    |> List.mapi (fun l (o : Signal.t Sequencer.O.t) ->
      let diff = of_int ~width:5 g -: pinbase.(l).value in
      let in_range = diff <: of_int ~width:5 8 in
      in_range &: dyn_bit o.pindirs_out diff)
    |> List.fold_left ( |: ) gnd
  in
  let global_val g =
    Array.to_list lane_outputs
    |> List.mapi (fun l (o : Signal.t Sequencer.O.t) ->
      let diff = of_int ~width:5 g -: pinbase.(l).value in
      let in_range = diff <: of_int ~width:5 8 in
      let drives = in_range &: dyn_bit o.pindirs_out diff in
      drives &: dyn_bit o.pins_out diff)
    |> List.fold_left ( |: ) gnd
  in
  let uo_out_hi7 = bits_of ~width:7 (fun k -> global_val (k + 5)) in
  let uio_out8 = bits_of ~width:8 (fun k -> global_val (k + 12)) in
  let uio_oe8 = bits_of ~width:8 (fun k -> global_oe (k + 12)) in
  (* --- reg_rdata: combinational response to whatever addr is currently
     latched, used by Config_port during a read transaction --- *)
  let reg16 (v : Signal.t) = uresize v 16 in
  let rx_status l =
    let (o : Signal.t Sequencer.O.t) = lane_outputs.(l) in
    concat_msb [ zero 7; o.host_rx_valid; o.host_rx_data ]
  in
  (* [offset] is 5 bits (32 possible values); [mux] requires exactly one
     choice per possible selector value, so offsets 5..31 (not a defined
     register) all just read back zero. *)
  let reg_rdata_for_lane l =
    let defined =
      [| reg16 pinbase.(l).value
       ; reg16 jmp_pin_cfg.(l).value
       ; reg16 run_cfg.(l).value
       ; reg16 lane_outputs.(l).host_tx_ready
       ; rx_status l
      |]
    in
    mux offset (List.init 32 (fun k -> if k < Array.length defined then defined.(k) else zero 16))
  in
  let reg_rdata =
    mux2 is_regs_block (mux lane_sel (List.init num_lanes reg_rdata_for_lane)) (zero 16)
  in
  let cfg_out =
    Config_port.create
      { Config_port.I.clock = i.clock
      ; clear = i.clear
      ; sclk = cfg_sclk
      ; mosi = cfg_mosi
      ; cs_n = cfg_cs_n
      ; reg_rdata
      }
  in
  cfg_addr <== cfg_out.addr;
  cfg_we <== cfg_out.we;
  cfg_re <== cfg_out.re;
  cfg_wdata <== cfg_out.wdata;
  let any_irq_set =
    Array.to_list lane_outputs |> List.map (fun (o : Signal.t Sequencer.O.t) -> o.irq_set) |> List.fold_left ( |: ) (zero 4)
  in
  let any_irq_clr =
    Array.to_list lane_outputs |> List.map (fun (o : Signal.t Sequencer.O.t) -> o.irq_clr) |> List.fold_left ( |: ) (zero 4)
  in
  compile
    ([ irq_flags <-- ((irq_flags.value |: any_irq_set) &: ~:any_irq_clr) ]
     @ List.init num_lanes (fun l ->
       if_
         (reg_write_for l)
         [ if_ (offset ==:. 0) [ pinbase.(l) <-- select cfg_wdata 4 0 ] []
         ; if_ (offset ==:. 1) [ jmp_pin_cfg.(l) <-- select cfg_wdata 2 0 ] []
         ; if_ (offset ==:. 2) [ run_cfg.(l) <-- select cfg_wdata 0 0 ] []
         ]
         []));
  { O.uo_out = concat_msb [ uo_out_hi7; cfg_out.miso ]; uio_out = uio_out8; uio_oe = uio_oe8 }
;;
