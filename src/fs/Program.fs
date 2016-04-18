﻿// Revs -- Reversible circuit synthesis from higher-level F# code
// ==============================================================
// 
// Forked from the RevLang library written by A. Parent (MSR, 2014)

open System.IO
open System
open Util
open Circuit
open AncillaHeap
open GenOp
open ExprTypes
open TypeCheck
open Interpreter
open Examples
open Equiv

type mode = 
  | Default
  | SpaceSave

let info = true
let verify = false

let isToff = function
  | RTOFF _ -> true
  | _       -> false

let run program mode cleanupStrategy = 
  // Parsing
  let (top, gexp) = parseAST program
  if info then printf "gExp:\n%s\n" (show gexp)
  // Type inference
  let (top', eqs, bnds, typ) = inferTypes top [] gexp
  let eqs =
    let f c = match c with
      | TCons (x, y) -> not (x = y)
      | ICons (x, y) -> not (x = y)
    List.filter f eqs
  let res = unify_eq top' eqs bnds []
  match res with
    | None -> printf "Error: could not infer types\n"
              printf "Equality constraints:\n%A\n" eqs
              printf "Ordered constraints:\n%A\n" bnds
    | Some subs -> 
        let gexp' = applySubs subs gexp
        if info then printf "Annotated gExp:\n%s\n" (show gexp');
        // Verification
        if verify then ignore <| compileBDD (gexp', bddInit)
        // Compilation
        let res = match mode with 
          | Default   -> compileCirc (gexp', circInit)
          | SpaceSave -> compile     (gexp', bexpInit) cleanupStrategy
        match res with
          | Err s -> printf "%s\n" s
          | Val (_, circ) -> 
              if info then 
                printf "Bits used: %d\n" (Set.count (uses circ))
                printf "Gates: %d\n" (List.length circ)
                printf "Toffolis: %d\n" (List.length (List.filter isToff circ))
              printf "%s" (printQCV circ (Set.count (uses circ)))

[<EntryPoint>]
let __main _ = 
  (*
  printf "Carry-Ripple 32:\n"
  ignore <| run (carryRippleAdder 32) Default Pebbled
  Console.Out.Flush()

  printf "\nModular adder 32:\n"
  ignore <| run (addMod 32) Default Pebbled
  Console.Out.Flush()

  printf "\nCucarro adder 32:\n"
  ignore <| run (cucarro 32) Default Pebbled
  Console.Out.Flush()

  printf "\nMult 32:\n"
  ignore <| run (mult 32) Default Pebbled
  Console.Out.Flush()

  printf "\nCarry-Lookahead 32:\n"
  ignore <| run (carryLookaheadAdder 32) Default Pebbled
  Console.Out.Flush()

  printf "\nma4:\n"
  ignore <| run (ma4) Default Pebbled
  Console.Out.Flush()

  printf "\nSHA (64 rounds):\n"
  ignore <| run (SHA2 2) Default Pebbled
  Console.Out.Flush()

  printf "\nSHA (64 rounds) -- manual cleanup:\n"
  ignore <| run (SHA2Efficient 2) Default Pebbled
  Console.Out.Flush()

  printf "\nMD5 (64 rounds):\n"
  ignore <| run (MD5 2) Default Pebbled
  Console.Out.Flush()
*)
  printf "\nKeccak (64 bit lanes):\n"
  ignore <| run (keccakf 4) Default Pebbled
  Console.Out.Flush()

  printf "\nKeccak (64 bit lanes) -- in place:\n"
  ignore <| run (keccakfInPlace 4) Default Pebbled
  Console.Out.Flush()
  0