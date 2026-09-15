(* WARD lane instruction set: encode/decode + a cycle-accurate reference
   interpreter.

   16-bit instruction word, uniform layout for every opcode class:

     [15:13] opcode (3 bits, 8 classes)
     [12:5]  operand (8 bits, meaning depends on opcode -- see [encode_operand]/[decode_operand])
     [4:0]   delay (5 bits, 0..31 extra stall cycles after the instruction
             commits -- this is how "counting cycles" for protocol timing is
             expressed without burning instruction slots on NOPs)

   This module is the single source of truth for the encoding: the
   Hardcaml decoder in [Sequencer] and the assembler both target it, and
   [Interp] is used as a cycle-accurate software oracle that the Hardcaml
   RTL is checked against in the test suite. *)

let imem_depth = 32 (* words per lane; PC/addr is 5 bits *)
let max_pincount = 8 (* max GPIOs a single lane can be windowed onto *)

type cond =
  | Always
  | X_dec (* jump if X <> 0, then X <- X - 1 *)
  | Y_dec (* jump if Y <> 0, then Y <- Y - 1 *)
  | Pin (* jump if the lane's configured jmp_pin reads 1 (see [Lane_config.jmp_pin]) *)
  | Not_pin
  | X_zero
  | Y_zero

type set_dest =
  | Set_pins
  | Set_x
  | Set_y
  | Set_pindirs

type out_dest =
  | Out_pins
  | Out_x
  | Out_y
  | Out_pc (* computed jump: load PC from the low bits shifted out of OSR *)
  | Out_null (* discard -- just consumes bits from OSR *)
  | Out_pindirs
  (* SET PINDIRS only has a 5-bit immediate (shares the 8-bit operand with a
     2-bit dest field), so it can only address pins 0..4 in one shot. OUT
     PINDIRS shifts up to 8 bits out of OSR instead, giving full-width
     dynamic direction control (e.g. loaded via PULL from an 8-bit host
     byte) for lanes windowed onto all 8 pins -- needed for I2C/USB-style
     open-drain/turnaround behavior across the whole window. *)

type in_src =
  | In_pins
  | In_x
  | In_y

type wait_src =
  | Wait_pin
  | Wait_irq

type op =
  | Jmp of cond * int (* addr, 0..imem_depth-1 *)
  | Wait of bool * wait_src * int (* polarity, source, index (pin 0..7 or irq 0..15) *)
  | Set of set_dest * int (* immediate, 0..31 *)
  | Out of out_dest * int (* bit count, 1..8 *)
  | In of in_src * int (* bit count, 1..8 *)
  | Push of bool (* blocking *)
  | Pull of bool (* blocking *)
  | Irq of bool * int (* set (true) / clear (false), index 0..15 *)

type instr =
  { op : op
  ; delay : int (* 0..31 *)
  }

let mk ?(delay = 0) op =
  if delay < 0 || delay > 31 then invalid_arg "Isa.mk: delay out of range 0..31";
  { op; delay }

(* --- opcode class numbers --- *)
let opc_jmp = 0
let opc_wait = 1
let opc_set = 2
let opc_out = 3
let opc_in = 4
let opc_push = 5
let opc_pull = 6
let opc_irq = 7

let cond_code = function
  | Always -> 0
  | X_dec -> 1
  | Y_dec -> 2
  | Pin -> 3
  | Not_pin -> 4
  | X_zero -> 5
  | Y_zero -> 6

let cond_of_code = function
  | 0 -> Always
  | 1 -> X_dec
  | 2 -> Y_dec
  | 3 -> Pin
  | 4 -> Not_pin
  | 5 -> X_zero
  | _ -> Y_zero

let set_dest_code = function
  | Set_pins -> 0
  | Set_x -> 1
  | Set_y -> 2
  | Set_pindirs -> 3

let set_dest_of_code = function
  | 0 -> Set_pins
  | 1 -> Set_x
  | 2 -> Set_y
  | _ -> Set_pindirs

let out_dest_code = function
  | Out_pins -> 0
  | Out_x -> 1
  | Out_y -> 2
  | Out_pc -> 3
  | Out_null -> 4
  | Out_pindirs -> 5

let out_dest_of_code = function
  | 0 -> Out_pins
  | 1 -> Out_x
  | 2 -> Out_y
  | 3 -> Out_pc
  | 4 -> Out_null
  | _ -> Out_pindirs

let in_src_code = function
  | In_pins -> 0
  | In_x -> 1
  | In_y -> 2

let in_src_of_code = function
  | 0 -> In_pins
  | 1 -> In_x
  | _ -> In_y

let bool_to_bit b = if b then 1 else 0
let bit_to_bool b = b land 1 = 1

(* pack/unpack the 8-bit operand field for each class *)
let encode_operand = function
  | Jmp (cond, addr) ->
    if addr < 0 || addr >= imem_depth then invalid_arg "Isa: jmp addr out of range";
    (cond_code cond lsl 5) lor addr
  | Wait (pol, src, idx) ->
    if idx < 0 || idx > 15 then invalid_arg "Isa: wait idx out of range";
    let src_bit = match src with Wait_pin -> 0 | Wait_irq -> 1 in
    (bool_to_bit pol lsl 7) lor (src_bit lsl 6) lor (idx lsl 2)
  | Set (dest, imm) ->
    if imm < 0 || imm > 31 then invalid_arg "Isa: set imm out of range";
    (set_dest_code dest lsl 6) lor (imm lsl 1)
  | Out (dest, n) ->
    if n < 1 || n > 8 then invalid_arg "Isa: out bit count out of range 1..8";
    (out_dest_code dest lsl 5) lor ((n - 1) lsl 2)
  | In (src, n) ->
    if n < 1 || n > 8 then invalid_arg "Isa: in bit count out of range 1..8";
    (in_src_code src lsl 6) lor ((n - 1) lsl 3)
  | Push blocking -> bool_to_bit blocking lsl 7
  | Pull blocking -> bool_to_bit blocking lsl 7
  | Irq (set, idx) ->
    if idx < 0 || idx > 15 then invalid_arg "Isa: irq idx out of range";
    (bool_to_bit set lsl 7) lor (idx lsl 2)

let opcode_of = function
  | Jmp _ -> opc_jmp
  | Wait _ -> opc_wait
  | Set _ -> opc_set
  | Out _ -> opc_out
  | In _ -> opc_in
  | Push _ -> opc_push
  | Pull _ -> opc_pull
  | Irq _ -> opc_irq

let encode (i : instr) : int =
  if i.delay < 0 || i.delay > 31 then invalid_arg "Isa.encode: delay out of range";
  ((opcode_of i.op land 0x7) lsl 13) lor ((encode_operand i.op land 0xff) lsl 5) lor (i.delay land 0x1f)

let decode_operand ~opcode operand : op =
  if opcode = opc_jmp
  then Jmp (cond_of_code ((operand lsr 5) land 0x7), operand land 0x1f)
  else if opcode = opc_wait
  then (
    let pol = bit_to_bool (operand lsr 7) in
    let src = if bit_to_bool (operand lsr 6) then Wait_irq else Wait_pin in
    let idx = (operand lsr 2) land 0xf in
    Wait (pol, src, idx))
  else if opcode = opc_set
  then Set (set_dest_of_code ((operand lsr 6) land 0x3), (operand lsr 1) land 0x1f)
  else if opcode = opc_out
  then Out (out_dest_of_code ((operand lsr 5) land 0x7), ((operand lsr 2) land 0x7) + 1)
  else if opcode = opc_in
  then In (in_src_of_code ((operand lsr 6) land 0x3), ((operand lsr 3) land 0x7) + 1)
  else if opcode = opc_push
  then Push (bit_to_bool (operand lsr 7))
  else if opcode = opc_pull
  then Pull (bit_to_bool (operand lsr 7))
  else Irq (bit_to_bool (operand lsr 7), (operand lsr 2) land 0xf)

let decode (word : int) : instr =
  let opcode = (word lsr 13) land 0x7 in
  let operand = (word lsr 5) land 0xff in
  let delay = word land 0x1f in
  { op = decode_operand ~opcode operand; delay }

(* ------------------------------------------------------------------ *)
(* Reference interpreter: a cycle-accurate software model of one lane,
   used as the golden oracle for the Hardcaml RTL in tests. One call to
   [step] advances the lane by exactly one clock cycle, mirroring how the
   hardware FSM behaves (fetch/execute in one cycle, then park for
   [delay] cycles, or park indefinitely on a blocking WAIT/PUSH/PULL that
   hasn't been satisfied yet). *)
module Interp = struct
  type phase =
    | Fetch
    | Stalling of int (* cycles remaining *)

  type t =
    { mutable pc : int
    ; mutable x : int
    ; mutable y : int
    ; mutable isr : int
    ; mutable osr : int
    ; mutable tx_fifo : int option (* host writes here; PULL drains it into OSR *)
    ; mutable rx_fifo : int option (* PUSH fills it from ISR; host reads drain it *)
    ; pindirs : bool array (* length = pincount, true = this lane drives the pin *)
    ; pinvals : int array (* driven value for pins this lane owns as output *)
    ; mutable phase : phase
    ; program : instr array
    ; pincount : int
    ; jmp_pin : int (* config-time: which local pin JMP PIN/NOT_PIN tests *)
    }

  let create ~program ~pincount ?(jmp_pin = 0) () =
    { pc = 0
    ; x = 0
    ; y = 0
    ; isr = 0
    ; osr = 0
    ; tx_fifo = None
    ; rx_fifo = None
    ; pindirs = Array.make pincount false
    ; pinvals = Array.make pincount 0
    ; phase = Fetch
    ; program = Array.of_list program
    ; pincount
    ; jmp_pin
    }

  let mask8 v = v land 0xff

  let read_pin (t : t) ~pins_in idx =
    if idx >= t.pincount
    then false
    else if t.pindirs.(idx)
    then t.pinvals.(idx) <> 0
    else pins_in.(idx) <> 0
  ;;

  (* Execute the combinational effect of [instr] for one cycle, given this
     cycle's pin inputs and the shared IRQ flag array (mutated in place for
     IRQ/WAIT-on-IRQ). Returns [`Retry] if a blocking condition isn't
     satisfied yet (no state change, instruction re-attempted next cycle),
     or [`Committed delay] once it has taken effect. *)
  let exec (t : t) ~(pins_in : int array) ~(irq : bool array) (instr : instr) =
    match instr.op with
    | Jmp (cond, addr) ->
      let take =
        match cond with
        | Always -> true
        | X_dec ->
          let r = t.x <> 0 in
          if r then t.x <- mask8 (t.x - 1);
          r
        | Y_dec ->
          let r = t.y <> 0 in
          if r then t.y <- mask8 (t.y - 1);
          r
        | Pin -> read_pin t ~pins_in t.jmp_pin
        | Not_pin -> not (read_pin t ~pins_in t.jmp_pin)
        | X_zero -> t.x = 0
        | Y_zero -> t.y = 0
      in
      t.pc <- (if take then addr else t.pc + 1);
      `Committed instr.delay
    | Wait (pol, src, idx) ->
      let level =
        match src with
        | Wait_pin -> read_pin t ~pins_in idx
        | Wait_irq -> idx < Array.length irq && irq.(idx)
      in
      if level = pol
      then (
        (match src with
         | Wait_irq when idx < Array.length irq -> irq.(idx) <- false (* auto-clear on wake *)
         | _ -> ());
        t.pc <- t.pc + 1;
        `Committed instr.delay)
      else `Retry
    | Set (dest, imm) ->
      (match dest with
       | Set_pins ->
         for i = 0 to t.pincount - 1 do
           if t.pindirs.(i) then t.pinvals.(i) <- (imm lsr i) land 1
         done
       | Set_x -> t.x <- imm
       | Set_y -> t.y <- imm
       | Set_pindirs ->
         for i = 0 to t.pincount - 1 do
           t.pindirs.(i) <- (imm lsr i) land 1 = 1
         done);
      t.pc <- t.pc + 1;
      `Committed instr.delay
    | Out (dest, n) ->
      let bits = t.osr land ((1 lsl n) - 1) in
      t.osr <- t.osr lsr n;
      (match dest with
       | Out_pins ->
         for i = 0 to n - 1 do
           if i < t.pincount && t.pindirs.(i) then t.pinvals.(i) <- (bits lsr i) land 1
         done;
         t.pc <- t.pc + 1
       | Out_x ->
         t.x <- bits;
         t.pc <- t.pc + 1
       | Out_y ->
         t.y <- bits;
         t.pc <- t.pc + 1
       | Out_pc -> t.pc <- bits
       | Out_null -> t.pc <- t.pc + 1
       | Out_pindirs ->
         for i = 0 to n - 1 do
           if i < t.pincount then t.pindirs.(i) <- bits lsr i land 1 = 1
         done;
         t.pc <- t.pc + 1);
      `Committed instr.delay
    | In (src, n) ->
      let bits =
        match src with
        | In_pins ->
          let v = ref 0 in
          for i = 0 to n - 1 do
            if read_pin t ~pins_in i then v := !v lor (1 lsl i)
          done;
          !v
        | In_x -> t.x land ((1 lsl n) - 1)
        | In_y -> t.y land ((1 lsl n) - 1)
      in
      (* ISR is real 8-bit shift-register hardware: mask8, don't let it grow
         unboundedly the way a naive OCaml `lsl` accumulation would. Caught
         by tracing through the Hardcaml design (fixed 8-bit register,
         truncates every shift) before it caused a silent interpreter/RTL
         mismatch in tests. *)
      t.isr <- mask8 ((t.isr lsl n) lor bits);
      t.pc <- t.pc + 1;
      `Committed instr.delay
    | Push blocking ->
      let ready = Option.is_none t.rx_fifo in
      if (not ready) && blocking
      then `Retry
      else (
        t.rx_fifo <- Some (mask8 t.isr);
        t.pc <- t.pc + 1;
        `Committed instr.delay)
    | Pull blocking ->
      let ready = Option.is_some t.tx_fifo in
      if (not ready) && blocking
      then `Retry
      else (
        (match t.tx_fifo with
         | Some v ->
           t.osr <- v;
           t.tx_fifo <- None
         | None -> ());
        t.pc <- t.pc + 1;
        `Committed instr.delay)
    | Irq (set, idx) ->
      if idx < Array.length irq then irq.(idx) <- set;
      t.pc <- t.pc + 1;
      `Committed instr.delay
  ;;

  (* Advance the lane by exactly one clock cycle. *)
  let step (t : t) ~(pins_in : int array) ~(irq : bool array) =
    match t.phase with
    | Stalling n -> t.phase <- (if n <= 1 then Fetch else Stalling (n - 1))
    | Fetch ->
      let instr = t.program.(t.pc mod Array.length t.program) in
      (match exec t ~pins_in ~irq instr with
       | `Retry -> ()
       | `Committed delay -> t.phase <- (if delay > 0 then Stalling delay else Fetch))
  ;;

  (* Host-facing helpers, used by the testbench to feed bytes in / drain
     bytes out, mirroring the chip's config-port handshake. *)
  let host_write_tx (t : t) byte = t.tx_fifo <- Some (byte land 0xff)
  let host_tx_ready (t : t) = Option.is_none t.tx_fifo
  let host_read_rx (t : t) =
    match t.rx_fifo with
    | Some v ->
      t.rx_fifo <- None;
      Some v
    | None -> None
  ;;
end
