(* Elaborates [Ward.Core] and writes the Verilog Tiny Tapeout's flow
   actually hardens. Run via `dune exec bin/generate_rtl.exe` from
   hardcaml/ (the ../src/generated directory must already exist); writes
   ../src/generated/core.v (checked in -- see ARCHITECTURE.md \167 8 for
   why: the TT CI hardens straight from checked-in Verilog, it doesn't run
   our OCaml build). *)
open Hardcaml
open Ward

let () =
  let circuit = Circuit.create_with_interface ~name:"ward_core" (module Core.I) (module Core.O) Core.create in
  let out_path = "../src/generated/core.v" in
  let oc = open_out out_path in
  Rtl.output ~output_mode:(Rtl.Output_mode.To_channel oc) Verilog circuit;
  close_out oc;
  Printf.printf "wrote %s\n" out_path
;;
