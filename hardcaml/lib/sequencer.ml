(* WARD lane: one programmable pin-sequencer, implementing the ISA in
   [Isa]. This is a straight, cycle-accurate transcription of
   [Isa.Interp] into Hardcaml -- the two are checked against each other in
   [Test_ward] (same assembled programs, same stimulus, same-cycle
   register-state comparison).

   Design note on style: register "next value" logic is built functionally
   (plain [Signal.t] muxes), not with the imperative [Always] DSL for the
   per-register-per-opcode contribution tables (pinvals/pindirs/x/y/isr/osr),
   because those are naturally expressed as "for each bit/opcode, pick a
   contributor" tables. The [Always] DSL is used only for the final
   apply-or-hold step, where its implicit "unassigned = hold" semantics are
   exactly what's wanted. *)

open Hardcaml
open Signal

let pincount = 8
let num_irq = 4
let imem_depth = Isa.imem_depth (* 32 *)
let addr_width = 5

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; run : 'a (* 0 = halted: never commits, releases pins (pindirs_out = 0) *)
    ; pins_in : 'a [@bits 8]
    ; irq_in : 'a [@bits 4]
    ; jmp_pin : 'a [@bits 3] (* config-time: which local pin JMP PIN/NOT_PIN tests *)
    ; imem_we : 'a
    ; imem_waddr : 'a [@bits 5]
    ; imem_wdata : 'a [@bits 16]
    ; host_tx_valid : 'a
    ; host_tx_data : 'a [@bits 8]
    ; host_rx_ready : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { pins_out : 'a [@bits 8]
    ; pindirs_out : 'a [@bits 8] (* 1 = this lane drives the pin *)
    ; irq_set : 'a [@bits 4] (* one-cycle pulse per flag this lane wants set *)
    ; irq_clr : 'a [@bits 4]
    ; host_tx_ready : 'a
    ; host_rx_valid : 'a
    ; host_rx_data : 'a [@bits 8]
    ; pc_debug : 'a [@bits 5]
    ; x_debug : 'a [@bits 8]
    ; y_debug : 'a [@bits 8]
    ; isr_debug : 'a [@bits 8]
    ; osr_debug : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

(* Build a [width]-bit signal whose bit [i] is [f i], for i = 0..width-1
   (bit 0 = LSB). [concat_msb] wants its list MSB-first, hence the [rev]. *)
let bits_of ~width f = concat_msb (List.init width f |> List.rev)

(* [lt n i] = (i < n), as a 1-bit signal, where [n] is a same-width dynamic
   signal and [i] is a compile-time OCaml int. Used to build "the low n
   bits of a register" style masks where n is only known at run time
   (instruction memory is writable, so n is not a synthesis-time constant). *)
let lt (n : Signal.t) (i : int) : Signal.t = of_int ~width:(Signal.width n) i <: n

let create (i : Signal.t I.t) : Signal.t O.t =
  let spec = Reg_spec.create () ~clock:i.clock ~clear:i.clear in
  let open Always in
  let pc = Variable.reg spec ~width:addr_width in
  let x = Variable.reg spec ~width:8 in
  let y = Variable.reg spec ~width:8 in
  let isr = Variable.reg spec ~width:8 in
  let osr = Variable.reg spec ~width:8 in
  let pindirs = Variable.reg spec ~width:pincount in
  let pinvals = Variable.reg spec ~width:pincount in
  let stalling = Variable.reg spec ~width:1 in
  let stall_count = Variable.reg spec ~width:5 in
  let tx_valid = Variable.reg spec ~width:1 in
  let tx_data = Variable.reg spec ~width:8 in
  let rx_valid = Variable.reg spec ~width:1 in
  let rx_data = Variable.reg spec ~width:8 in
  let imem = Array.init imem_depth (fun _ -> Variable.reg spec ~width:16) in
  (* --- instruction fetch (combinational read of the current PC) --- *)
  let instr_word = mux pc.value (Array.to_list (Array.map (fun (v : Always.Variable.t) -> v.value) imem)) in
  let opcode = select instr_word 15 13 in
  let operand = select instr_word 12 5 in
  let delay_field = select instr_word 4 0 in
  let is_op op_val = opcode ==:. op_val in
  (* --- per-class operand decode (bit positions match Isa.encode_operand) --- *)
  let jmp_cond = select operand 7 5 in
  let jmp_addr = select operand 4 0 in
  let wait_pol = select operand 7 7 in
  let wait_src_is_irq = select operand 6 6 in
  let wait_idx = select operand 5 2 in
  (* 4 bits *)
  let set_dest = select operand 7 6 in
  let set_imm = select operand 5 1 in
  (* 5 bits *)
  let out_dest = select operand 7 5 in
  let out_nm1 = select operand 4 2 in
  (* 3 bits *)
  let in_src = select operand 7 6 in
  let in_nm1 = select operand 5 3 in
  (* 3 bits *)
  let fifo_blocking = select operand 7 7 in
  let irq_is_set = select operand 7 7 in
  let irq_idx = select operand 5 2 in
  (* 4 bits *)
  let out_n = uresize out_nm1 4 +:. 1 in
  (* 1..8 *)
  let in_n = uresize in_nm1 4 +:. 1 in
  (* --- pin reads: self-driven value when this lane owns the pin, else the
     externally-sampled input --- *)
  let pin_read_bus = (pindirs.value &: pinvals.value) |: (~:(pindirs.value) &: i.pins_in) in
  let read_pin3 (idx3 : Signal.t) = mux idx3 (List.init pincount (fun k -> select pin_read_bus k k)) in
  let jmp_level = read_pin3 i.jmp_pin in
  let wait_pin_level = read_pin3 (select wait_idx 2 0) in
  let irq_in_padded = uresize i.irq_in 16 in
  let wait_irq_level = mux wait_idx (List.init 16 (fun k -> select irq_in_padded k k)) in
  let wait_level = mux2 wait_src_is_irq wait_irq_level wait_pin_level in
  let wait_ready = wait_level ==: wait_pol in
  let push_ready = ~:(rx_valid.value) |: ~:fifo_blocking in
  let pull_ready = tx_valid.value |: ~:fifo_blocking in
  let ready_by_opcode =
    mux
      opcode
      [ vdd (* jmp *)
      ; wait_ready
      ; vdd (* set *)
      ; vdd (* out *)
      ; vdd (* in *)
      ; push_ready
      ; pull_ready
      ; vdd (* irq *)
      ]
  in
  let fetching = ~:(stalling.value) &: i.run in
  let committed = fetching &: ready_by_opcode in
  (* --- JMP --- *)
  let take_xdec = x.value <>:. 0 in
  let take_ydec = y.value <>:. 0 in
  let jmp_take =
    mux
      jmp_cond
      [ vdd (* always *)
      ; take_xdec
      ; take_ydec
      ; jmp_level (* pin *)
      ; ~:jmp_level (* not_pin *)
      ; x.value ==:. 0
      ; y.value ==:. 0
      ; gnd (* unused code 7 *)
      ]
  in
  let jmp_next_pc = mux2 jmp_take jmp_addr (pc.value +:. 1) in
  let pc_plus1 = pc.value +:. 1 in
  let out_pc_target = select osr.value (addr_width - 1) 0 in
  let next_pc =
    mux
      opcode
      [ jmp_next_pc
      ; pc_plus1 (* wait *)
      ; pc_plus1 (* set *)
      ; mux2 (out_dest ==:. 3) out_pc_target pc_plus1 (* out: Out_pc computed jump *)
      ; pc_plus1 (* in *)
      ; pc_plus1 (* push *)
      ; pc_plus1 (* pull *)
      ; pc_plus1 (* irq *)
      ]
  in
  (* the low [n] bits of [value] (dynamic n), zero elsewhere -- used for
     OUT -> X/Y and IN's source masking *)
  let masked_low (value : Signal.t) (n : Signal.t) =
    bits_of ~width:8 (fun k -> mux2 (lt n k) (select value k k) gnd)
  in
  let next_x =
    mux
      opcode
      [ mux2 ((jmp_cond ==:. 1) &: take_xdec) (x.value -:. 1) x.value
      ; x.value
      ; mux2 (set_dest ==:. 1) (uresize set_imm 8) x.value
      ; mux2 (out_dest ==:. 1) (masked_low osr.value out_n) x.value
      ; x.value
      ; x.value
      ; x.value
      ; x.value
      ]
  in
  let next_y =
    mux
      opcode
      [ mux2 ((jmp_cond ==:. 2) &: take_ydec) (y.value -:. 1) y.value
      ; y.value
      ; mux2 (set_dest ==:. 2) (uresize set_imm 8) y.value
      ; mux2 (out_dest ==:. 2) (masked_low osr.value out_n) y.value
      ; y.value
      ; y.value
      ; y.value
      ; y.value
      ]
  in
  let in_source_bus = mux in_src [ pin_read_bus; x.value; y.value; x.value ] in
  let in_masked = masked_low in_source_bus in_n in
  let isr_shifted_in = log_shift sll isr.value in_n |: in_masked in
  let next_isr =
    mux opcode [ isr.value; isr.value; isr.value; isr.value; isr_shifted_in; isr.value; isr.value; isr.value ]
  in
  let next_osr =
    mux
      opcode
      [ osr.value
      ; osr.value
      ; osr.value
      ; log_shift srl osr.value out_n (* out: consume n bits *)
      ; osr.value
      ; osr.value
      ; mux2 tx_valid.value tx_data.value osr.value (* pull: load if data present *)
      ; osr.value
      ]
  in
  (* pin outputs, one bit at a time: for each physical pin index, pick the
     contribution from whichever opcode is executing (default: hold) *)
  let pinvals_next =
    bits_of ~width:8 (fun k ->
      let hold = select pinvals.value k k in
      let via_set =
        if k < 5
        then mux2 ((set_dest ==:. 0) &: select pindirs.value k k) (select set_imm k k) hold
        else hold
      in
      let via_out = mux2 ((out_dest ==:. 0) &: lt out_n k &: select pindirs.value k k) (select osr.value k k) hold in
      mux opcode [ hold; hold; via_set; via_out; hold; hold; hold; hold ])
  in
  let pindirs_next =
    bits_of ~width:8 (fun k ->
      let hold = select pindirs.value k k in
      let via_set = if k < 5 then mux2 (set_dest ==:. 3) (select set_imm k k) hold else hold in
      let via_out = mux2 ((out_dest ==:. 5) &: lt out_n k) (select osr.value k k) hold in
      mux opcode [ hold; hold; via_set; via_out; hold; hold; hold; hold ])
  in
  let pull_commit = committed &: is_op 6 in
  let push_commit = committed &: is_op 5 in
  let next_tx_valid = mux2 pull_commit gnd (mux2 i.host_tx_valid vdd tx_valid.value) in
  let next_tx_data = mux2 i.host_tx_valid i.host_tx_data tx_data.value in
  let next_rx_valid = mux2 push_commit vdd (mux2 i.host_rx_ready gnd rx_valid.value) in
  let next_rx_data = mux2 push_commit isr.value rx_data.value in
  let next_stalling = mux2 stalling.value (stall_count.value >:. 1) (committed &: (delay_field <>:. 0)) in
  let next_stall_count = mux2 stalling.value (stall_count.value -:. 1) (mux2 committed delay_field stall_count.value) in
  let irq_set_out =
    bits_of ~width:num_irq (fun k -> committed &: is_op 7 &: irq_is_set &: (irq_idx ==:. k))
  in
  let irq_clr_out =
    bits_of ~width:num_irq (fun k ->
      (committed &: is_op 7 &: ~:irq_is_set &: (irq_idx ==:. k))
      |: (committed &: is_op 1 &: wait_src_is_irq &: (wait_idx ==:. k)))
  in
  let imem_write_stmts =
    List.init imem_depth (fun addr -> if_ (i.imem_we &: (i.imem_waddr ==:. addr)) [ imem.(addr) <-- i.imem_wdata ] [])
  in
  compile
    (imem_write_stmts
     @ [ if_
           committed
           [ pc <-- next_pc
           ; x <-- next_x
           ; y <-- next_y
           ; isr <-- next_isr
           ; osr <-- next_osr
           ; pindirs <-- pindirs_next
           ; pinvals <-- pinvals_next
           ]
           []
       ; stalling <-- next_stalling
       ; stall_count <-- next_stall_count
       ; tx_valid <-- next_tx_valid
       ; tx_data <-- next_tx_data
       ; rx_valid <-- next_rx_valid
       ; rx_data <-- next_rx_data
       ]);
  { O.pins_out = pinvals.value
  ; pindirs_out = mux2 i.run pindirs.value (of_int ~width:pincount 0)
  ; irq_set = irq_set_out
  ; irq_clr = irq_clr_out
  ; host_tx_ready = ~:(tx_valid.value)
  ; host_rx_valid = rx_valid.value
  ; host_rx_data = rx_data.value
  ; pc_debug = pc.value
  ; x_debug = x.value
  ; y_debug = y.value
  ; isr_debug = isr.value
  ; osr_debug = osr.value
  }
;;
