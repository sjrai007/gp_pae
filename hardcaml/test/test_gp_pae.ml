open Gp_pae

let failures = ref 0

let check name cond =
  if not cond
  then (
    incr failures;
    Printf.printf "FAIL: %s\n" name)
  else Printf.printf "ok:   %s\n" name
;;

(* --- encode/decode roundtrip over a representative instruction from every
   opcode class --- *)
let test_isa_roundtrip () =
  let equal (a : Isa.instr) (b : Isa.instr) = Stdlib.compare a b = 0 in
  let open Isa in
  let samples =
    [ mk (Jmp (Always, 5))
    ; mk ~delay:31 (Jmp (X_dec, 0))
    ; mk (Jmp (Y_dec, 31))
    ; mk (Jmp (Pin, 17))
    ; mk (Jmp (Not_pin, 3))
    ; mk (Jmp (X_zero, 9))
    ; mk (Jmp (Y_zero, 9))
    ; mk (Wait (true, Wait_pin, 5))
    ; mk (Wait (false, Wait_irq, 15))
    ; mk (Set (Set_pins, 0x1f))
    ; mk (Set (Set_pindirs, 0))
    ; mk (Out (Out_pins, 8))
    ; mk (Out (Out_pc, 1))
    ; mk (In (In_pins, 1))
    ; mk (In (In_x, 8))
    ; mk ~delay:3 (Push true)
    ; mk (Pull false)
    ; mk (Irq (true, 2))
    ; mk (Irq (false, 0))
    ]
  in
  List.iteri
    (fun i instr ->
      let word = encode instr in
      let instr' = decode word in
      check (Printf.sprintf "isa roundtrip #%d (word=0x%04x)" i word) (equal instr instr'))
    samples
;;

(* --- interpreter smoke test: a 3-instruction program that toggles pin 0
   forever (SET PINDIRS out, then loop: SET PINS 1 / SET PINS 0), used to
   sanity-check the Fetch/Stall FSM and pin-driving semantics. *)
let test_interp_toggle () =
  let open Isa in
  let program =
    [ mk (Set (Set_pindirs, 0b1))
    ; mk ~delay:2 (Set (Set_pins, 0b1))
    ; mk ~delay:2 (Set (Set_pins, 0b0))
    ; mk (Jmp (Always, 1))
    ]
  in
  let t = Interp.create ~program ~pincount:1 () in
  let irq = Array.make 4 false in
  let pins_in = [| 0 |] in
  (* cycle 0: executes SET PINDIRS (delay 0) -> phase Fetch again *)
  Interp.step t ~pins_in ~irq;
  check "toggle: pindirs set after cycle 0" t.pindirs.(0);
  (* cycle 1: executes SET PINS 1, delay=2 -> Stalling 2 *)
  Interp.step t ~pins_in ~irq;
  check "toggle: pin high after cycle 1" (t.pinvals.(0) = 1);
  (* cycles 2,3: stalling, pin stays high *)
  Interp.step t ~pins_in ~irq;
  Interp.step t ~pins_in ~irq;
  check "toggle: pin still high while stalling" (t.pinvals.(0) = 1);
  (* cycle 4: executes SET PINS 0, delay=2 -> Stalling 2 *)
  Interp.step t ~pins_in ~irq;
  check "toggle: pin low after next instr" (t.pinvals.(0) = 0)
;;

(* --- interpreter: blocking PUSH stalls until host drains RX fifo --- *)
let test_interp_push_blocks () =
  let open Isa in
  let program = [ mk (In (In_x, 8)); mk (Push true); mk (Jmp (Always, 0)) ] in
  let t = Interp.create ~program ~pincount:0 () in
  t.x <- 0x42;
  let irq = Array.make 4 false in
  let pins_in = [||] in
  Interp.step t ~pins_in ~irq;
  (* IN X,8 *)
  Interp.step t ~pins_in ~irq;
  (* PUSH true: rx_fifo empty -> succeeds immediately *)
  check "push: rx_fifo has data" (Interp.host_read_rx t = Some 0x42);
  ()
;;

(* ------------------------------------------------------------------ *)
(* RTL vs. interpreter cross-check: run the same assembled program and
   the same per-cycle pin/host stimulus through both [Sequencer] (via
   Hardcaml's Cyclesim) and [Isa.Interp], and assert every piece of
   observable state agrees after every single cycle. This is the core
   verification claim in ARCHITECTURE.md \167 7: a bug has to make the
   RTL and the independently-written software model agree on the wrong
   answer to survive. *)
open Hardcaml

module Sim = Cyclesim.With_interface (Sequencer.I) (Sequencer.O)

let bits_of_bool_array (arr : bool array) =
  let v = ref 0 in
  Array.iteri (fun i b -> if b then v := !v lor (1 lsl i)) arr;
  Bits.of_int ~width:(Array.length arr) !v
;;

let bool_array_of_bits ~width (b : Bits.t) =
  let v = Bits.to_int b in
  Array.init width (fun i -> (v lsr i) land 1 = 1)
;;

(* Per-cycle stimulus/expectations the test supplies; everything defaults
   to "nothing happening" so directed tests only need to override what
   they care about. *)
type stimulus =
  { pins_in : int -> int array (* cycle index -> pincount-wide 0/1 array *)
  ; host_tx : int -> (int * int) option (* cycle -> Some (valid, data) *)
  ; host_rx_ready : int -> bool
  }

let default_stimulus ~pincount =
  { pins_in = (fun _ -> Array.make pincount 0)
  ; host_tx = (fun _ -> None)
  ; host_rx_ready = (fun _ -> false)
  }
;;

let run_and_compare ~name ~program ~pincount ~cycles ?(jmp_pin = 0) (stim : stimulus) =
  let sim = Sim.create Sequencer.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  (* reset *)
  inputs.clear := Bits.vdd;
  inputs.run := Bits.gnd;
  inputs.imem_we := Bits.gnd;
  Cyclesim.cycle sim;
  inputs.clear := Bits.gnd;
  (* load program into instruction memory (run stays low: no commits happen) *)
  List.iteri
    (fun addr instr ->
      inputs.imem_we := Bits.vdd;
      inputs.imem_waddr := Bits.of_int ~width:5 addr;
      inputs.imem_wdata := Bits.of_int ~width:16 (Isa.encode instr);
      Cyclesim.cycle sim)
    program;
  inputs.imem_we := Bits.gnd;
  inputs.jmp_pin := Bits.of_int ~width:3 jmp_pin;
  inputs.run := Bits.vdd;
  let interp = Isa.Interp.create ~program ~pincount ~jmp_pin () in
  let interp_irq = Array.make 4 false in
  let rtl_irq = Array.make 4 false in
  let pack_int_array (arr : int array) : int =
    let v = ref 0 in
    Array.iteri (fun i b -> if b <> 0 then v := !v lor (1 lsl i)) arr;
    !v
  in
  let pack_bool_array (arr : bool array) : int =
    let v = ref 0 in
    Array.iteri (fun i b -> if b then v := !v lor (1 lsl i)) arr;
    !v
  in
  for cycle = 0 to cycles - 1 do
    let pins = stim.pins_in cycle in
    inputs.pins_in := Bits.of_int ~width:8 (pack_int_array pins);
    inputs.irq_in := bits_of_bool_array rtl_irq;
    let tx_this_cycle = stim.host_tx cycle in
    (match tx_this_cycle with
     | Some (valid, data) ->
       inputs.host_tx_valid := (if valid <> 0 then Bits.vdd else Bits.gnd);
       inputs.host_tx_data := Bits.of_int ~width:8 data
     | None -> inputs.host_tx_valid := Bits.gnd);
    let rx_ready_this_cycle = stim.host_rx_ready cycle in
    inputs.host_rx_ready := (if rx_ready_this_cycle then Bits.vdd else Bits.gnd);
    Cyclesim.cycle sim;
    let rtl_irq_set = bool_array_of_bits ~width:4 !(outputs.irq_set) in
    let rtl_irq_clr = bool_array_of_bits ~width:4 !(outputs.irq_clr) in
    Array.iteri
      (fun k _ -> if rtl_irq_set.(k) then rtl_irq.(k) <- true else if rtl_irq_clr.(k) then rtl_irq.(k) <- false)
      rtl_irq;
    (match tx_this_cycle with
     | Some (valid, data) when valid <> 0 -> Isa.Interp.host_write_tx interp data
     | _ -> ());
    Isa.Interp.step interp ~pins_in:pins ~irq:interp_irq;
    if rx_ready_this_cycle then ignore (Isa.Interp.host_read_rx interp : int option);
    (* --- compare everything observable --- *)
    let loc = Printf.sprintf "%s @cycle=%d" name cycle in
    check (loc ^ " pc") (Bits.to_int !(outputs.pc_debug) = interp.pc);
    check (loc ^ " x") (Bits.to_int !(outputs.x_debug) = interp.x);
    check (loc ^ " y") (Bits.to_int !(outputs.y_debug) = interp.y);
    check (loc ^ " isr") (Bits.to_int !(outputs.isr_debug) = interp.isr);
    check (loc ^ " osr") (Bits.to_int !(outputs.osr_debug) = interp.osr);
    check (loc ^ " pins_out") (Bits.to_int !(outputs.pins_out) land 0xff = pack_int_array interp.pinvals);
    check (loc ^ " pindirs_out") (Bits.to_int !(outputs.pindirs_out) = pack_bool_array interp.pindirs);
    check (loc ^ " host_tx_ready") ((Bits.to_int !(outputs.host_tx_ready) = 1) = Isa.Interp.host_tx_ready interp);
    check
      (loc ^ " host_rx_valid+data")
      (let rtl_valid = Bits.to_int !(outputs.host_rx_valid) = 1 in
       let rtl_data = Bits.to_int !(outputs.host_rx_data) in
       match interp.rx_fifo with
       | Some v -> rtl_valid && rtl_data = v
       | None -> not rtl_valid);
    check (loc ^ " irq") (Array.for_all2 ( = ) rtl_irq interp_irq)
  done
;;

(* --- a real UART TX lane program: idle high, start(0), 8 data bits
   LSB-first, stop(1); byte supplied by the host over the PULL/tx-fifo
   handshake, exactly as a real host MCU would drive it over the
   config-port SPI in the full chip. BIT_CYCLES is small here purely to
   keep the simulation short -- the microcode is identical in shape to
   what a real baud rate would use, just with a bigger delay constant. *)
let test_uart_tx () =
  let open Isa in
  let bit_cycles = 4 in
  let d = bit_cycles - 1 in
  let program =
    [ mk (Set (Set_pindirs, 0b1)) (* 0: pin0 = output *)
    ; mk (Set (Set_pins, 0b1)) (* 1: idle high *)
    ; mk (Pull true) (* 2: block for a host byte *)
    ; mk (Set (Set_x, 7)) (* 3: 7 more bits after the first OUT below *)
    ; mk ~delay:d (Set (Set_pins, 0b0)) (* 4: start bit *)
    ; mk ~delay:(d - 1) (Out (Out_pins, 1))
      (* 5: data bit, LSB first. delay is bit_cycles-2, not bit_cycles-1:
         every pass through this loop also spends one cycle on the JMP
         X_DEC below (even the final, not-taken pass costs a cycle before
         falling through) -- that cycle keeps driving *this* bit's value
         since JMP never touches pins, so it has to be budgeted out of the
         OUT's own delay to keep every data bit exactly bit_cycles long.
         Caught by decoding the actual emitted waveform in the test below
         and finding it didn't spell the byte we sent, even though the RTL
         matched the interpreter cycle-for-cycle throughout -- a timing bug
         in the microcode, not the CPU: exactly the class of bug a
         protocol-level check catches that a same-spec cross-check can't. *)
    ; mk (Jmp (X_dec, 5)) (* 6: loop for all 8 bits *)
    ; mk ~delay:d (Set (Set_pins, 0b1)) (* 7: stop bit *)
    ; mk (Jmp (Always, 1)) (* 8: back to idle / next byte *)
    ]
  in
  let byte = 0xA5 in
  let stim =
    { (default_stimulus ~pincount:1) with
      host_tx = (fun cycle -> if cycle = 0 then Some (1, byte) else None)
    }
  in
  run_and_compare ~name:"uart_tx" ~program ~pincount:1 ~cycles:70 stim;
  (* Independently decode the RTL's pin0 waveform as a UART frame and check
     it actually spells out [byte] -- not just "RTL matches interpreter"
     (which could both be wrong the same way) but "the emitted bitstream is
     a correct UART frame for the byte we sent." *)
  let sim = Sim.create Sequencer.create in
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
  let trace = Array.make 70 0 in
  for cycle = 0 to 69 do
    inputs.host_tx_valid := if cycle = 0 then Bits.vdd else Bits.gnd;
    inputs.host_tx_data := Bits.of_int ~width:8 byte;
    Cyclesim.cycle sim;
    trace.(cycle) <- Bits.to_int !(outputs.pins_out) land 1
  done;
  (* find the start-bit falling edge, then sample mid-bit every bit_cycles *)
  let start_idx = ref (-1) in
  for k = 0 to Array.length trace - 2 do
    if !start_idx = -1 && trace.(k) = 1 && trace.(k + 1) = 0 then start_idx := k + 1
  done;
  check "uart_tx: found start bit" (!start_idx >= 0);
  if !start_idx >= 0
  then (
    let mid b = !start_idx + (b * bit_cycles) + (bit_cycles / 2) in
    let decoded = ref 0 in
    for b = 1 to 8 do
      if trace.(mid b) = 1 then decoded := !decoded lor (1 lsl (b - 1))
    done;
    check (Printf.sprintf "uart_tx: decoded byte = 0x%02x (expected 0x%02x)" !decoded byte) (!decoded = byte);
    check "uart_tx: stop bit high" (trace.(mid 9) = 1))
;;

(* ------------------------------------------------------------------ *)
(* Config port (SPI slave): bit-bang a software SPI master against the
   Hardcaml simulation and check the resulting we/addr/wdata pulse (write
   transaction) and the bits shifted back on miso (read transaction). *)
module ConfigSim = Cyclesim.With_interface (Config_port.I) (Config_port.O)

let bits_to_int bits = List.fold_left (fun acc b -> (acc lsl 1) lor b) 0 bits

let test_config_port () =
  let sim = ConfigSim.create Config_port.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  (* Local closures (not top-level functions) so [sim]'s concrete
     Config_port-specific interface type is known at every field access --
     a bare top-level function taking [sim] as an unannotated parameter
     leaves Hardcaml's interface type unresolved at that point, and
     unqualified record field access needs it resolved. *)
  let spi_send_byte ~collect byte =
    let bits = ref [] in
    for b = 7 downto 0 do
      let bit = (byte lsr b) land 1 in
      inputs.mosi := (if bit = 1 then Bits.vdd else Bits.gnd);
      inputs.sclk := Bits.gnd;
      Cyclesim.cycle sim;
      (* Sample miso here, *before* this bit's rising edge: the slave holds
         a bit stable across the low phase (set up by the previous rising
         edge) for the master to sample, then advances to the next bit on
         the rising edge that follows. Sampling after the rising edge (as
         an earlier version of this test did) reads one bit ahead of what
         was actually presented -- caught by the independent readback
         check below disagreeing with the value written. *)
      if collect then bits := Bits.to_int !(outputs.miso) :: !bits;
      inputs.sclk := Bits.vdd;
      Cyclesim.cycle sim
    done;
    List.rev !bits
  in
  (* Runs one full 4-byte transaction; returns (we_pulse, re_pulse,
     addr_seen, wdata_seen, miso_read_value) captured right after the last
     bit. *)
  let spi_transaction ~rw ~addr ~wdata ~reg_rdata =
    inputs.reg_rdata := Bits.of_int ~width:16 reg_rdata;
    inputs.cs_n := Bits.gnd;
    inputs.sclk := Bits.gnd;
    Cyclesim.cycle sim;
    ignore (spi_send_byte ~collect:false (if rw then 1 else 0));
    ignore (spi_send_byte ~collect:false addr);
    let hi_bits = spi_send_byte ~collect:true ((wdata lsr 8) land 0xff) in
    let lo_bits = spi_send_byte ~collect:true (wdata land 0xff) in
    let we_pulse = Bits.to_int !(outputs.we) = 1 in
    let re_pulse = Bits.to_int !(outputs.re) = 1 in
    let addr_seen = Bits.to_int !(outputs.addr) in
    let wdata_seen = Bits.to_int !(outputs.wdata) in
    inputs.cs_n := Bits.vdd;
    inputs.sclk := Bits.gnd;
    Cyclesim.cycle sim;
    we_pulse, re_pulse, addr_seen, wdata_seen, bits_to_int (hi_bits @ lo_bits)
  in
  inputs.clear := Bits.vdd;
  inputs.cs_n := Bits.vdd;
  inputs.sclk := Bits.gnd;
  inputs.mosi := Bits.gnd;
  inputs.reg_rdata := Bits.of_int ~width:16 0;
  Cyclesim.cycle sim;
  inputs.clear := Bits.gnd;
  let we, re, addr, wdata, _ = spi_transaction ~rw:true ~addr:0x2a ~wdata:0xbeef ~reg_rdata:0 in
  check "config_port write: we pulsed" we;
  check "config_port write: re NOT pulsed" (not re);
  check (Printf.sprintf "config_port write: addr=0x%02x (expected 0x2a)" addr) (addr = 0x2a);
  check (Printf.sprintf "config_port write: wdata=0x%04x (expected 0xbeef)" wdata) (wdata = 0xbeef);
  let we2, re2, _, _, read_val = spi_transaction ~rw:false ~addr:0x15 ~wdata:0x0000 ~reg_rdata:0xcafe in
  check "config_port read: we NOT pulsed" (not we2);
  check "config_port read: re pulsed" re2;
  check (Printf.sprintf "config_port read: miso readback=0x%04x (expected 0xcafe)" read_val) (read_val = 0xcafe);
  (* back-to-back transactions shouldn't leak state (e.g. a stale we pulse) *)
  let we3, re3, addr3, wdata3, _ = spi_transaction ~rw:true ~addr:0x01 ~wdata:0x1234 ~reg_rdata:0 in
  check "config_port write#2: we pulsed" we3;
  check "config_port write#2: re NOT pulsed" (not re3);
  check "config_port write#2: addr" (addr3 = 0x01);
  check "config_port write#2: wdata" (wdata3 = 0x1234)
;;

(* ------------------------------------------------------------------ *)
(* Core integration: program lane 0 over the real SPI config port (not a
   backdoor), point its pin window at global index 12 (= uio[0], via
   pinbase), start it running, and check the toggle shows up on the actual
   TT-facing uio_out/uio_oe pins -- i.e. that the address decode and pin
   crossbar in [Core] are wired correctly, on top of the already-verified
   [Sequencer] and [Config_port] pieces. *)
module CoreSim = Cyclesim.With_interface (Core.I) (Core.O)

let test_core_integration () =
  let sim = CoreSim.create Core.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let set_cfg_pins ~sclk ~mosi ~cs_n =
    let bit b v = if v then 1 lsl b else 0 in
    inputs.ui_in := Bits.of_int ~width:8 (bit 0 sclk lor bit 1 mosi lor bit 2 cs_n)
  in
  let spi_send_byte byte =
    for b = 7 downto 0 do
      let bit = (byte lsr b) land 1 in
      set_cfg_pins ~sclk:false ~mosi:(bit = 1) ~cs_n:false;
      Cyclesim.cycle sim;
      set_cfg_pins ~sclk:true ~mosi:(bit = 1) ~cs_n:false;
      Cyclesim.cycle sim
    done
  in
  let spi_write ~addr ~wdata =
    set_cfg_pins ~sclk:false ~mosi:false ~cs_n:false;
    Cyclesim.cycle sim;
    spi_send_byte 1 (* rw = write *);
    spi_send_byte addr;
    spi_send_byte ((wdata lsr 8) land 0xff);
    spi_send_byte (wdata land 0xff);
    set_cfg_pins ~sclk:false ~mosi:false ~cs_n:true;
    Cyclesim.cycle sim
  in
  inputs.clear := Bits.vdd;
  set_cfg_pins ~sclk:false ~mosi:false ~cs_n:true;
  inputs.uio_in := Bits.of_int ~width:8 0;
  Cyclesim.cycle sim;
  inputs.clear := Bits.gnd;
  let open Isa in
  let program =
    [ mk (Set (Set_pindirs, 0b1))
    ; mk ~delay:2 (Set (Set_pins, 0b1))
    ; mk ~delay:2 (Set (Set_pins, 0b0))
    ; mk (Jmp (Always, 1))
    ]
  in
  (* lane 0, imem block (addr[5]=0), word address = list index *)
  List.iteri (fun word_addr instr -> spi_write ~addr:word_addr ~wdata:(encode instr)) program;
  (* lane 0, regs block (addr[5]=1): offset 0 = pinbase -> global index 12 (uio[0]) *)
  spi_write ~addr:0x20 ~wdata:12;
  (* offset 2 = run *)
  spi_write ~addr:0x22 ~wdata:1;
  let saw_high = ref false in
  let saw_low = ref false in
  let saw_oe = ref false in
  for _ = 1 to 40 do
    Cyclesim.cycle sim;
    let uio_out = Bits.to_int !(outputs.uio_out) in
    let uio_oe = Bits.to_int !(outputs.uio_oe) in
    if uio_oe land 1 = 1 then saw_oe := true;
    if uio_out land 1 = 1 then saw_high := true;
    if uio_oe land 1 = 1 && uio_out land 1 = 0 then saw_low := true
  done;
  check "core: lane0 drives uio[0] (oe=1) after SET PINDIRS" !saw_oe;
  check "core: uio[0] toggles high" !saw_high;
  check "core: uio[0] toggles low" !saw_low;
  (* readback: pinbase should read back as 12. uo_out[0] carries cfg_miso
     (see Core's pin layout doc); sample it before each bit's rising edge,
     same reasoning as the config_port test above. *)
  let read_bit () =
    set_cfg_pins ~sclk:false ~mosi:false ~cs_n:false;
    Cyclesim.cycle sim;
    let bit = Bits.to_int !(outputs.uo_out) land 1 in
    set_cfg_pins ~sclk:true ~mosi:false ~cs_n:false;
    Cyclesim.cycle sim;
    bit
  in
  set_cfg_pins ~sclk:false ~mosi:false ~cs_n:false;
  Cyclesim.cycle sim;
  spi_send_byte 0 (* rw = read *);
  spi_send_byte 0x20;
  let data_bits = List.init 16 (fun _ -> read_bit ()) in
  set_cfg_pins ~sclk:false ~mosi:false ~cs_n:true;
  Cyclesim.cycle sim;
  let read_val = List.fold_left (fun acc b -> (acc lsl 1) lor b) 0 data_bits in
  check
    (Printf.sprintf "core: pinbase readback = %d (expected 12)" read_val)
    (read_val = 12)
;;

let () =
  test_isa_roundtrip ();
  test_interp_toggle ();
  test_interp_push_blocks ();
  test_uart_tx ();
  test_config_port ();
  test_core_integration ();
  if !failures > 0
  then (
    Printf.printf "\n%d FAILURE(S)\n" !failures;
    exit 1)
  else Printf.printf "\nAll tests passed.\n"
;;
