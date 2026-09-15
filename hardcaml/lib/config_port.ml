(* WARD config/data port: a 4-wire SPI slave exposing a flat 8-bit-address /
   16-bit-data register interface, used both to load lane instruction
   memories and lane config registers (programming) and to push/pull live
   protocol data bytes to/from each lane's host FIFO (operation) -- see
   ARCHITECTURE.md \167 5. [Core] owns the actual address decode (which
   address means "lane 2's imem word 7" vs "lane 0's tx_fifo"); this module
   only knows about SPI framing.

   Fixed 4-byte (32 SCLK cycle) transaction, MSB-first:
     byte0: rw       (bit0: 1 = write, 0 = read; other bits reserved/ignored)
     byte1: addr[7:0]
     byte2: wdata[15:8]
     byte3: wdata[7:0]
   On a read, [reg_rdata] (supplied by the caller, combinational on [addr])
   is latched as soon as byte1 completes and shifted out on [miso] during
   byte2/byte3.

   Simplification flagged for follow-up (see NOTES.md): SCLK/MOSI/CS_N are
   sampled directly (no input synchronizer -- fine for the same-PCB,
   same-ish-clock-domain bring-up this targets, but worth hardening before
   relying on it across a noisy cable), and MISO is updated on the same
   SCLK edge MOSI is sampled on, rather than the opposite edge a
   by-the-book SPI Mode 0 slave would use -- works with a test host that
   samples MISO on the following edge, but hasn't been checked against
   an arbitrary real-world SPI master's exact timing yet. *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; sclk : 'a
    ; mosi : 'a
    ; cs_n : 'a
    ; reg_rdata : 'a [@bits 16]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { miso : 'a
    ; we : 'a (* one-cycle pulse: a write transaction just completed *)
    ; re : 'a (* one-cycle pulse: a read transaction just completed -- lets
                 the caller implement read-consumes semantics (e.g. draining
                 a lane's RX fifo) at a well-defined instant rather than
                 continuously, since [reg_rdata] itself is live/combinational
                 for the whole data phase *)
    ; addr : 'a [@bits 8]
    ; wdata : 'a [@bits 16]
    }
  [@@deriving hardcaml]
end

let create (i : Signal.t I.t) : Signal.t O.t =
  let spec = Reg_spec.create () ~clock:i.clock ~clear:i.clear in
  let open Always in
  let sclk_prev = Variable.reg spec ~width:1 in
  let bitcnt = Variable.reg spec ~width:6 (* 0..32 *) in
  let shreg = Variable.reg spec ~width:8 (* current byte being shifted in *) in
  let rw_write = Variable.reg spec ~width:1 in
  let addr_reg = Variable.reg spec ~width:8 in
  let wdata_hi = Variable.reg spec ~width:8 in
  let miso_shift = Variable.reg spec ~width:16 in
  let we = Variable.reg spec ~width:1 in
  let re = Variable.reg spec ~width:1 in
  let wdata_out = Variable.reg spec ~width:16 in
  (* One-cycle-delayed "the address byte just landed" flag. [reg_rdata] is
     the caller's *combinational* function of [addr] (our own registered
     output, fed back in) -- so it isn't valid yet on the very edge that
     updates [addr_reg] (a register can't see its own not-yet-applied
     update from combinational logic downstream of it), only from the next
     cycle onward, once that update has actually taken effect and rippled
     through. Latching [miso_shift] one cycle later, gated by this flag
     rather than directly off [bitcnt_next], is what makes that valid.
     Caught via the Core integration test reading back a just-written
     register and getting the *previous* transaction's value instead. *)
  let just_got_addr = Variable.reg spec ~width:1 in
  let sclk_rise = i.sclk &: ~:(sclk_prev.value) in
  let active = ~:(i.cs_n) in
  let shreg_next = concat_msb [ select shreg.value 6 0; i.mosi ] in
  let bitcnt_next = bitcnt.value +:. 1 in
  compile
    [ sclk_prev <-- i.sclk
    ; we <-- gnd (* default: one-cycle pulse only on the cycle a write completes *)
    ; re <-- gnd
    ; just_got_addr <-- gnd
    ; if_ just_got_addr.value [ miso_shift <-- i.reg_rdata ] []
    ; if_
        (~:active)
        [ bitcnt <-- of_int ~width:6 0 ]
        [ if_
            sclk_rise
            [ shreg <-- shreg_next
            ; bitcnt <-- bitcnt_next
            ; miso_shift <-- sll miso_shift.value 1 (* default: keep presenting successive bits *)
            ; if_ (bitcnt_next ==:. 8) [ rw_write <-- select shreg_next 0 0 ] []
            ; if_ (bitcnt_next ==:. 16) [ addr_reg <-- shreg_next; just_got_addr <-- vdd ] []
            ; if_ (bitcnt_next ==:. 24) [ wdata_hi <-- shreg_next ] []
            ; if_
                (bitcnt_next ==:. 32)
                [ we <-- rw_write.value
                ; re <-- ~:(rw_write.value)
                ; wdata_out <-- concat_msb [ wdata_hi.value; shreg_next ]
                ]
                []
            ]
            []
        ]
    ];
  { O.miso = select miso_shift.value 15 15
  ; we = we.value
  ; re = re.value
  ; addr = addr_reg.value
  ; wdata = wdata_out.value
  }
;;
