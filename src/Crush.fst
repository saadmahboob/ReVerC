(** Program transformation/compiler based on minimal ESOP forms *)
module Crush

open Utils
open Total
open BoolExp
open ExprTypes
open Interpreter

(* Boolean expression interpretation -- for generating the fully
   inlined classical circuit of the Revs program *)
type bExpState = int * (Total.t int boolExp)

val bexpInit   : bExpState
val bexpAlloc  : bExpState -> Tot (int * bExpState)
val bexpAssign : bExpState -> int -> boolExp -> Tot bExpState
val bexpEval   : bExpState -> state -> int -> Tot bool

let bexpInit = (0, constMap BFalse)
let bexpAlloc (top, st) = (top, (top + 1, update st top BFalse))
let bexpAssign (top, st) l bexp = (top, update st l (substBexp bexp st))
let bexpEval (top, st) ivals i = evalBexp (lookup st i) ivals

let bexpInterp = {
  alloc = bexpAlloc;
  assign = bexpAssign;
  eval = bexpEval
}

type cleanupStrat =
  | Pebbled : cleanupStrat
  | Boundaries : cleanupStrat
  | Bennett : cleanupStrat

val simps : boolExp -> Tot boolExp
let simps bexp = simplify (toXDNF bexp)

val allocN : list gExpr * bExpState -> i:int ->
  Tot (list gExpr * bExpState) (decreases i)
let rec allocN (locs, (top, st)) i =
  if i <= 0 then (FStar.List.Tot.rev locs, (top, st))
  else allocN (((LOC top)::locs), (top+1, update st top (BVar top))) (i-1)

val allocTy : gType -> bExpState -> Tot (result (gExpr * bExpState))
let allocTy ty (top, st) = match ty with
  | GBool -> Val (LOC top, (top + 1, update st top (BVar top)))
  | GArray n ->
    let (locs, st') = allocN ([], (top, st)) n in
      Val (ARRAY locs, st')
  | _ -> Err "Invalid parameter type for circuit generation"

val lookupLst : lst:(list gExpr){isVal_lst lst} -> st:bExpState -> Tot (list boolExp)
let rec lookupLst lst st = match lst with
  | [] -> []
  | (LOC l)::xs -> (lookup (snd st) l)::(lookupLst xs st)

open AncillaHeap
open Circuit

val foldPebble : (ancHeap * list int * list int * list gate) ->
  boolExp -> Tot (ancHeap * list int * list int * list gate)
let foldPebble (ah, outs, anc, circ) bexp =
  let (ah', res, anc', circ') = compileBexpPebbled_oop ah (simps bexp) in
    (ah', res::outs, anc'@anc, circ@circ')

val foldClean : (ancHeap * list int * list int * list gate) ->
  boolExp -> Tot (ancHeap * list int * list int * list gate)
let foldClean (ah, outs, anc, circ) bexp =
  let (ah', res, anc', circ') = compileBexpClean_oop ah (simps bexp) in
    (ah', res::outs, anc'@anc, circ@circ')

val foldBennett : (ancHeap * list int * list int * list gate * list gate) ->
  boolExp -> Tot (ancHeap * list int * list int * list gate * list gate)
let foldBennett (ah, outs, anc, circ, ucirc) bexp =
  let (ah', res, anc', circ') = compileBexp_oop ah (simps bexp) in
    (ah', res::outs, anc'@anc, circ@circ', (FStar.List.Tot.rev (uncompute circ' res))@ucirc)

(* Compilation wrapper. The main point of interest is its action when the
   program is a function. In that case it allocates some new free variables
   corresponding to the inputs of the function, then evaluates the function
   body. Note also that this wrapper is not verified currently. Eventually this
   should be done. *)
val compile : config bExpState -> cleanupStrat -> Dv (result (list int * list gate))
let rec compile (gexp, st) strategy =
  if isVal gexp then match gexp with
    | UNIT -> Val ([], [])
    | LAMBDA (x, ty, t) ->
      begin match allocTy ty st with
        | Err s -> Err s
        | Val (v, st') -> compile (substgExpr t x v, st') strategy
      end
    | LOC l ->
      let bexp = lookup (snd st) l in
      let max = varMax bexp in
      let (ah, res, anc, circ) = match strategy with
        | Pebbled -> compileBexpPebbled_oop (above (max+1)) (simps bexp)
        | Boundaries -> compileBexpClean_oop (above (max+1)) (simps bexp)
        | Bennett -> compileBexpClean_oop (above (max+1)) (simps bexp)
      in
        Val ([res], circ)
    | ARRAY lst ->
      let cmp x y = 
	let xd = andDepth x in
	let yd = andDepth y in
	  if xd < yd then 1 else if xd = yd then 0 else -1
      in
      let blst = FStar.List.Tot.sortWith cmp (lookupLst lst st) in
      let max = listMax (FStar.List.Tot.map varMax blst) in
      let (ah, outs, anc, circ) = match strategy with
        | Pebbled ->
          let (ah, outs, anc, circ) =
            FStar.List.Tot.fold_left foldPebble (above (max+1), [], [], []) blst
          in
            (ah, FStar.List.Tot.rev outs, FStar.List.Tot.rev anc, circ)
        | Boundaries ->
          let (ah, outs, anc, circ) =
            FStar.List.Tot.fold_left foldClean (above (max+1), [], [], []) blst
          in
            (ah, FStar.List.Tot.rev outs, FStar.List.Tot.rev anc, circ)
        | Bennett ->
          let (ah, outs, anc, circ, ucirc) =
            FStar.List.Tot.fold_left foldBennett (above (max+1), [], [], [], []) blst
          in
            (ah, FStar.List.Tot.rev outs, FStar.List.Tot.rev anc, circ@ucirc)
      in
        Val (outs, circ)
  else match (step (gexp, st) bexpInterp) with
    | Err s -> Err s
    | Val c' -> compile c' strategy

(** Verification utilities *)
(* Originally this was done polymorphically (using a general notion of
   equivalence of states and a proof that the interpreter preserves equivalence
   if alloc and assign do). Eventually this should be refactored that way, but
   this was faster for the time being. *)
type state_equiv (st:boolState) (st':bExpState) (init:state) =
  fst st = fst st' /\ (forall i. boolEval st init i = bexpEval st' init i)

val state_equiv_impl : st:boolState -> st':bExpState -> init:state -> i:int ->
  Lemma (requires (state_equiv st st' init))
        (ensures  (boolEval st init i = bexpEval st' init i))
let state_equiv_impl st st' init i = ()

val eval_bexp_swap : st:boolState -> st':bExpState -> bexp:boolExp -> init:state ->
  Lemma (requires (state_equiv st st' init))
        (ensures  (evalBexp (substBexp bexp (snd st')) init =
                   evalBexp bexp (snd st)))
let rec eval_bexp_swap st st' bexp init = match bexp with
  | BFalse -> ()
  | BVar i -> ()
  | BNot x -> (); eval_bexp_swap st st' x init
  | BXor (x, y) | BAnd (x, y) -> ();
    eval_bexp_swap st st' x init;
    eval_bexp_swap st st' y init

val state_equiv_alloc : st:boolState -> st':bExpState -> init:state ->
  Lemma (requires (state_equiv st st' init))
        (ensures  (state_equiv (snd (boolAlloc st)) (snd (bexpAlloc st')) init))
let state_equiv_alloc st st' init = ()

val state_equiv_assign : st:boolState -> st':bExpState -> init:state -> l:int -> bexp:boolExp ->
  Lemma (requires (state_equiv st st' init))
        (ensures  (state_equiv (boolAssign st l bexp) (bexpAssign st' l bexp) init))
let state_equiv_assign st st' init l bexp = eval_bexp_swap st st' bexp init

val step_pres_state_equiv : st:boolState -> st':bExpState -> gexp:gExpr -> init:state ->
  Lemma (requires (state_equiv st st' init))
        (ensures  ((is_Err (step (gexp, st) boolInterp) /\ is_Err (step (gexp, st') bexpInterp)) \/
                   (is_Val (step (gexp, st) boolInterp) /\ is_Val (step (gexp, st') bexpInterp) /\
		    state_equiv (snd (getVal (step (gexp, st) boolInterp))) 
		                (snd (getVal (step (gexp, st') bexpInterp)))
			        init)))
  (decreases %[gexp;1])
val step_lst_pres_state_equiv : st:boolState -> st':bExpState -> lst:list gExpr -> init:state ->
  Lemma (requires (state_equiv st st' init))
        (ensures  ((is_Err (step_lst (lst, st) boolInterp) /\ is_Err (step_lst (lst, st') bexpInterp)) \/
                   (is_Val (step_lst (lst, st) boolInterp) /\ is_Val (step_lst (lst, st') bexpInterp) /\
		    state_equiv (snd (getVal (step_lst (lst, st) boolInterp))) 
		                (snd (getVal (step_lst (lst, st') bexpInterp)))
			        init)))
  (decreases %[lst;0])
let rec step_pres_state_equiv st st' gexp init = match gexp with
  | LET (x, t1, t2) -> step_pres_state_equiv st st' t1 init
  | APPLY (t1, t2) ->
    step_pres_state_equiv st st' t1 init;
    step_pres_state_equiv st st' t2 init
  | SEQUENCE (t1, t2) ->
    step_pres_state_equiv st st' t1 init;
    step_pres_state_equiv st st' t2 init
  | ASSIGN (t1, t2) ->
    step_pres_state_equiv st st' t1 init;
    step_pres_state_equiv st st' t2 init;
    if (isVal t1 && isBexp t2) then
      begin match t1 with
        | LOC l -> 
	  state_equiv_assign st st' init l (get_bexp t2)
        | _ -> ()
      end 
  | XOR (t1, t2) ->
    step_pres_state_equiv st st' t1 init;
    step_pres_state_equiv st st' t2 init
  | AND (t1, t2) ->
    step_pres_state_equiv st st' t1 init;
    step_pres_state_equiv st st' t2 init
  | BOOL b -> ()
  | APPEND (t1, t2) ->
    step_pres_state_equiv st st' t1 init;
    step_pres_state_equiv st st' t2 init
  | ROT (i, t) ->
    step_pres_state_equiv st st' t init
  | SLICE (t, i, j) ->
    step_pres_state_equiv st st' t init
  | ARRAY lst -> 
    admit() // See note in Interpreter.fst, mutual recursion here no longer works due to new equality types
    //step_lst_pres_equiv cs bs lst init
  | GET_ARRAY (t, i) ->
    step_pres_state_equiv st st' t init
  | ASSERT t ->
    step_pres_state_equiv st st' t init
  | BEXP bexp ->
    let (l, st'') = boolAlloc st in
    let (l', st''') = bexpAlloc st' in
      state_equiv_alloc st st' init;
      state_equiv_assign st'' st''' init l (BXor (BVar l, bexp))
  | _ -> ()
and step_lst_pres_state_equiv st st' lst init = match lst with
  | [] -> ()
  | x::xs -> admit() // Mutual recursion again
    //step_pres_state_equiv st st' x init
    //step_lst_pres_state_equiv st st' xs init
