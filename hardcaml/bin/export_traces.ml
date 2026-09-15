(* Exports per-cycle signal traces from the *same* scenarios the test suite
   verifies (../test/test_ward.ml), as JSON for the progress dashboard.

   The point of sharing scenarios with the tests rather than writing
   bespoke demo stimulus: whatever the dashboard draws is guaranteed to be
   the behaviour that was actually asserted correct, not a separately
   hand-drawn picture that could drift from the design. Run from hardcaml/:

     dune exec bin/export_traces.exe

   writes ../dashboard/traces.json *)

open Hardcaml
open Ward

module SeqSim = Cyclesim.With_interface (Sequencer.I) (Sequencer.O)
module CoreSim = Cyclesim.With_interface (Core.I) (Core.O)

(* --- tiny JSON writer (avoids a dependency for a handful of records) --- *)
let buf = Buffer.create 65536
let str s = Buffer.add_string buf s
let json_string s = str "\""; str s; str "\""

let json_int_list l =
  str "[";
  List.iteri (fun i v -> if i > 0 then str ","; str (string_of_int v)) l;
  str "]"
;;

let signal ~name ~kind ~values =
  str "{";
  json_string "name"; str ":"; json_string name; str ",";
  json_string "kind"; str ":"; json_string kind; str ",";
  json_string "values"; str ":"; json_int_list values;
  str "}"
;;

let span ~from_ ~to_ ~label ~kind =
  str "{";
  json_string "from"; str ":"; str (string_of_int from_); str ",";
  json_string "to"; str ":"; str (string_of_int to_); str ",";
  json_string "label"; str ":"; json_string label; str ",";
  json_string "kind"; str ":"; json_string kind;
  str "}"
;;

let comma_sep f l = List.iteri (fun i x -> if i > 0 then str ","; f x) l

(* ------------------------------------------------------------------ *)
(* Scenario 1: UART TX of 0xA5 on a single lane.
   Identical program and stimulus to test_uart_tx, whose independent
   waveform decode asserts this trace really does spell 0xA5. *)
let uart_tx_scenario () =
  let open Isa in
  let bit_cycles = 4 in
  let d = bit_cycles - 1 in
  let byte = 0xA5 in
  let cycles = 70 in
  let program =
    [ mk (Set (Set_pindirs, 0b1))
    ; mk (Set (Set_pins, 0b1))
    ; mk (Pull true)
    ; mk (Set (Set_x, 7))
    ; mk ~delay:d (Set (Set_pins, 0b0))
    ; mk ~delay:(d - 1) (Out (Out_pins, 1))
    ; mk (Jmp (X_dec, 5))
    ; mk ~delay:d (Set (Set_pins, 0b1))
    ; mk (Jmp (Always, 1))
    ]
  in
  let sim = SeqSim.create Sequencer.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  inputs.clear := Bits.vdd;
  inputs.run := Bits.gnd;
  Cyclesim.cycle sim;
  inputs.clear := Bits.gnd;
  List.iteri
    (fun addr instr ->
      inputs.imem_we := Bits.vdd;
      inputs.imem_waddr := Bits.of_int ~width:5 addr;
      inputs.imem_wdata := Bits.of_int ~width:16 (Isa.encode instr);
      Cyclesim.cycle sim)
    program;
  inputs.imem_we := Bits.gnd;
  inputs.run := Bits.vdd;
  let tx = ref [] and pc = ref [] and osr = ref [] and x = ref [] in
  for cycle = 0 to cycles - 1 do
    inputs.host_tx_valid := (if cycle = 0 then Bits.vdd else Bits.gnd);
    inputs.host_tx_data := Bits.of_int ~width:8 byte;
    Cyclesim.cycle sim;
    tx := (Bits.to_int !(outputs.pins_out) land 1) :: !tx;
    pc := Bits.to_int !(outputs.pc_debug) :: !pc;
    osr := Bits.to_int !(outputs.osr_debug) :: !osr;
    x := Bits.to_int !(outputs.x_debug) :: !x
  done;
  let tx = List.rev !tx in
  (* Locate the start bit exactly as the test's decoder does, then label
     each bit window, so the annotation is derived from the real trace
     rather than assumed. *)
  let arr = Array.of_list tx in
  let start_idx = ref (-1) in
  Array.iteri
    (fun k v ->
      if !start_idx = -1 && k + 1 < Array.length arr && v = 1 && arr.(k + 1) = 0
      then start_idx := k + 1)
    arr;
  let s = !start_idx in
  let spans =
    if s < 0
    then []
    else (
      let data =
        List.init 8 (fun b ->
          let lo = s + ((b + 1) * bit_cycles) in
          let bit = arr.(lo + (bit_cycles / 2)) in
          (lo, lo + bit_cycles - 1, Printf.sprintf "D%d=%d" b bit, "data"))
      in
      let stop_lo = s + (9 * bit_cycles) in
      let stop_hi = min (stop_lo + bit_cycles - 1) (cycles - 1) in
      ((s, s + bit_cycles - 1, "START", "frame") :: data)
      @ [ (stop_lo, stop_hi, "STOP", "frame") ])
  in
  str "{";
  json_string "id"; str ":"; json_string "uart_tx"; str ",";
  json_string "title"; str ":"; json_string "UART TX - transmitting 0xA5"; str ",";
  json_string "blurb"; str ":"; json_string
    "One lane bit-bangs a full 8N1 UART frame from a byte the host wrote over the config port. The test decodes this exact waveform back to 0xA5 independently of the CPU model - which is how a microcode timing bug was caught that cycle-by-cycle RTL/model agreement had missed.";
  str ",";
  json_string "cycles"; str ":"; str (string_of_int cycles); str ",";
  json_string "signals"; str ":[";
  comma_sep (fun (n, k, v) -> signal ~name:n ~kind:k ~values:v)
    [ ("uart_tx pin", "bit", tx)
    ; ("pc", "bus", List.rev !pc)
    ; ("osr (shift reg)", "bus", List.rev !osr)
    ; ("x (bit counter)", "bus", List.rev !x)
    ];
  str "],";
  json_string "spans"; str ":[";
  comma_sep (fun (f, t, l, k) -> span ~from_:f ~to_:t ~label:l ~kind:k) spans;
  str "]}"
;;

(* ------------------------------------------------------------------ *)
(* Scenario 2: the full chip. Program lane 0's instruction memory,
   pinbase and run register over the real 4-wire SPI config port, then
   watch the resulting toggle appear on the physical uio pins. Same
   scenario as test_core_integration and as the cocotb/Icarus test. *)
let core_scenario () =
  let open Isa in
  let program =
    [ mk (Set (Set_pindirs, 0b1))
    ; mk ~delay:2 (Set (Set_pins, 0b1))
    ; mk ~delay:2 (Set (Set_pins, 0b0))
    ; mk (Jmp (Always, 1))
    ]
  in
  let sim = CoreSim.create Core.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let sclk = ref 0 and mosi = ref 0 and cs_n = ref 1 in
  let uio_out = ref [] and uio_oe = ref [] and miso = ref [] in
  let spans = ref [] in
  let cycle_count = ref 0 in
  let set_pins () =
    inputs.ui_in := Bits.of_int ~width:8 (!sclk lor (!mosi lsl 1) lor (!cs_n lsl 2))
  in
  let tick () =
    set_pins ();
    Cyclesim.cycle sim;
    uio_out := (Bits.to_int !(outputs.uio_out) land 1) :: !uio_out;
    uio_oe := (Bits.to_int !(outputs.uio_oe) land 1) :: !uio_oe;
    miso := (Bits.to_int !(outputs.uo_out) land 1) :: !miso;
    incr cycle_count
  in
  let mark label kind f =
    let from_ = !cycle_count in
    f ();
    spans := (from_, !cycle_count - 1, label, kind) :: !spans
  in
  let send_byte b =
    for i = 7 downto 0 do
      mosi := (b lsr i) land 1;
      sclk := 0;
      tick ();
      sclk := 1;
      tick ()
    done
  in
  let spi_write ~addr ~wdata =
    cs_n := 0;
    sclk := 0;
    tick ();
    send_byte 1;
    send_byte addr;
    send_byte ((wdata lsr 8) land 0xff);
    send_byte (wdata land 0xff);
    cs_n := 1;
    sclk := 0;
    tick ()
  in
  inputs.clear := Bits.vdd;
  inputs.uio_in := Bits.of_int ~width:8 0;
  set_pins ();
  Cyclesim.cycle sim;
  inputs.clear := Bits.gnd;
  (* don't count the reset cycle in the trace *)
  List.iteri
    (fun addr instr ->
      mark (Printf.sprintf "SPI write: imem[%d]" addr) "config" (fun () ->
        spi_write ~addr ~wdata:(Isa.encode instr)))
    program;
  mark "SPI write: pinbase = 12 (uio[0])" "config" (fun () -> spi_write ~addr:0x20 ~wdata:12);
  mark "SPI write: run = 1" "config" (fun () -> spi_write ~addr:0x22 ~wdata:1);
  mark "lane 0 running - toggling uio[0]" "run" (fun () ->
    for _ = 1 to 40 do
      tick ()
    done);
  str "{";
  json_string "id"; str ":"; json_string "core_spi"; str ",";
  json_string "title"; str ":"; json_string "Full chip - programmed over SPI, then running"; str ",";
  json_string "blurb"; str ":"; json_string
    "The whole flow with no back doors: a program, a pin assignment and a run bit are shifted into lane 0 through the real 4-wire SPI config port, and the lane then drives the physical uio[0] pin. The same scenario runs in both simulators - Hardcaml Cyclesim and Icarus Verilog against the generated RTL.";
  str ",";
  json_string "cycles"; str ":"; str (string_of_int !cycle_count); str ",";
  json_string "signals"; str ":[";
  comma_sep (fun (n, k, v) -> signal ~name:n ~kind:k ~values:v)
    [ ("uio[0] out", "bit", List.rev !uio_out)
    ; ("uio[0] oe (driving)", "bit", List.rev !uio_oe)
    ; ("uo_out[0] (cfg miso)", "bit", List.rev !miso)
    ];
  str "],";
  json_string "spans"; str ":[";
  comma_sep (fun (f, t, l, k) -> span ~from_:f ~to_:t ~label:l ~kind:k) (List.rev !spans);
  str "]}"
;;

let () =
  let out_path = if Array.length Sys.argv > 1 then Sys.argv.(1) else "../dashboard/traces.json" in
  str "{";
  json_string "generated_by"; str ":";
  json_string "hardcaml/bin/export_traces.ml (same scenarios as hardcaml/test/test_ward.ml)";
  str ",";
  json_string "scenarios"; str ":[";
  uart_tx_scenario ();
  str ",";
  core_scenario ();
  str "]}";
  let oc = open_out out_path in
  output_string oc (Buffer.contents buf);
  close_out oc;
  Printf.printf "wrote %s (%d bytes)\n" out_path (Buffer.length buf)
;;
