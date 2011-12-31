(** "Values", as manipulated by SAML. *)

open Utils.Stdlib
open Lang_values

module B = Saml_backend
module V = Lang_values
module T = Lang_types

type t = V.term

let builtin_prefix = "#saml_"
let builtin_prefix_re = Str.regexp ("^"^builtin_prefix)
let is_builtin_var x = Str.string_match builtin_prefix_re x 0
let remove_builtin_prefix x =
  let bpl = String.length builtin_prefix in
  String.sub x bpl (String.length x - bpl)

let meta_vars = ["period"]

let keep_vars = ref []

let make_term ?t tm =
  let t =
    match t with
      | Some t -> t
      | None -> T.fresh_evar ~level:(-1) ~pos:None
  in
  { term = tm; t = t }

let make_let x v t =
  let l =
    {
      doc = (Doc.none (), []);
      var = x;
      gen = [];
      def = v;
      body = t;
    }
  in
  make_term ~t:t.t (Let l)

let make_field ?t ?opt r x =
  let t =
    match t with
      | Some _ -> t
      | None ->
        match (T.deref r.t).T.descr with
          | T.Record r -> Some (snd (fst (T.Fields.find x r.T.fields)))
          | _ -> None
  in
  make_term ?t (Field (r, x, opt))

let make_var ?t x =
  make_term ?t (Var x)

(** Generate a fresh reference name. *)
let fresh_ref =
  let n = ref 0 in
  fun () ->
    incr n;
    Printf.sprintf "saml_ref%d" !n

let fresh_event =
  let n = ref 0 in
  fun () ->
    incr n;
    Printf.sprintf "saml_event%d" !n

let fresh_var =
  let n = ref 0 in
  fun () ->
    incr n;
    Printf.sprintf "saml_x%d" !n

let rec free_vars tm =
  (* Printf.printf "free_vars: %s\n%!" (print_term tm); *)
  let fv = free_vars in
  let u v1 v2 = v1@v2 in
  let r xx v = List.diff v xx in
  match tm.term with
    | Var x -> [x]
    | Unit | Bool _ | Int _ | String _ | Float _ -> []
    | Seq (a,b) -> u (fv a) (fv b)
    | Ref r | Get r -> fv r
    | Set (r,v) -> u (fv r) (fv v)
    | Record r -> T.Fields.fold (fun _ v f -> u (fv v.rval) f) r []
    | Field (r,x,o) ->
      let o = match o with Some o -> fv o | None -> [] in
      u (fv r) o
    | Let l -> u (fv l.def) (r [l.var] (fv l.body))
    | Fun (_, p, v) ->
      let o = List.fold_left (fun f (_,_,_,o) -> match o with None -> f | Some o -> u (fv o) f) [] p in
      let p = List.map (fun (_,x,_,_) -> x) p in
      u o (r p (fv v))
    | App (f,a) ->
      let a = List.fold_left (fun f (_,v) -> u f (fv v)) [] a in
      u (fv f) a
    | Event_channel l ->
      List.fold_left (fun f v -> u f (fv v)) [] l
    | Event_handle (c,e) | Event_emit (c,e) -> u (fv c) (fv e)

let occurences x tm =
  let ans = ref 0 in
  List.iter (fun y -> if y = x then incr ans) (free_vars tm);
  !ans

(** Is a term pure (ie does not contain side effects)? *)
let rec is_pure ~env tm =
  (* Printf.printf "is_pure: %s\n%!" (print_term tm); *)
  let is_pure ?(env=env) = is_pure ~env in
  match tm.term with
    (* TODO: use env for vars *)
    | Var _ | Unit | Bool _ | Int _ | String _ | Float _ -> true
    (* | App ({ term = Var x }, args) when is_builtin_var x -> *)
    (* TODO: we suppose for now that all builtins are pure, we should actually
       specify this somewhere for each external. *)
    (* List.for_all (fun (_,v) -> is_pure v) args *)
    | Get _ | Set _ -> false
    (* TODO: handle more cases *)
    | _ -> false

let rec fresh_let fv l =
  if List.mem l.var fv then
    let var = fresh_var () in
    var, subst l.var (make_term ~t:l.def.t (Var var)) l.body
  else
    l.var, l.body

(** Apply a list of substitutions to a term. *)
and substs ?(pure=false) ss tm =
  let substs = substs ~pure in
  let subs = subst ~pure in
  (* Printf.printf "substs: %s\n%!" (print_term tm); *)
  let s ?(ss=ss) = substs ss in
  let fv ss = List.fold_left (fun fv (_,v) -> (free_vars v)@fv) [] ss in
  let term =
    match tm.term with
      | Var x ->
        let rec aux = function
          | (x',v)::ss when x' = x ->
            let tm = substs ss v in
            (* TODO... *)
            (* if pure then assert (is_pure ~env:[] tm); *)
            tm.term
          | _::ss -> aux ss
          | [] -> tm.term
        in
        aux ss
      | Unit | Bool _ | Int _ | String _ | Float _ -> tm.term
      | Seq (a,b) -> Seq (s a, s b)
      | Ref r -> Ref (s r)
      | Get r -> Get (s r)
      | Set (r,v) -> Set (s r, s v)
      | Record r ->
        let r = T.Fields.map (fun v -> { v with rval = s v.rval }) r in
        Record r
      | Field (r,x,d) -> Field (s r, x, Utils.may s d)
      | Replace_field (r,x,v) ->
        let v = { v with rval = s v.rval } in
        Replace_field (s r, x, v)
      | Let l ->
        let def = s l.def in
        let ss = List.remove_all_assoc l.var ss in
        let s = s ~ss in
        let var, body = if not (List.mem l.var (meta_vars @ !keep_vars)) then fresh_let (fv ss) l else l.var, l.body in
        let body = s body in
        let l = { l with var = var; def = def; body = body } in
        Let l
      | Fun (vars,p,v) ->
        let ss = ref ss in
        let sp = ref [] in
        let p =
          List.map
            (fun (l,x,t,v) ->
              let x' = if List.mem x (fv !ss) then fresh_var () else x in
              ss := List.remove_all_assoc x !ss;
              sp := (x, make_term (Var x')) :: !sp;
              l,x',t,Utils.may s v
            ) p
        in
        let v = substs !sp v in
        let ss = !ss in
        let v = s ~ss v in
        (* TODO: alpha-convert vars too? *)
        Fun (vars,p,v)
      | App (a,l) ->
        let a = s a in
        let l = List.map (fun (l,v) -> l, s v) l in
        App (a,l)
      | Event_channel l -> Event_channel (List.map s l)
      | Event_handle (c,e) -> Event_handle (s c, s e)
      | Event_emit (c,e) -> Event_emit (s c, s e)
  in
  make_term ~t:tm.t term

and subst ?pure x v tm = substs ?pure [x,v] tm

(* Convert values to terms. This is a hack necessary becausse FFI are values and
   not terms (we should change this someday...). *)
let rec term_of_value v =
  (* Printf.printf "term_of_value: %s\n%!" (V.V.print_value v); *)
  let term =
    match v.V.V.value with
      | V.V.Record r ->
        let r =
          let ans = ref T.Fields.empty in
          T.Fields.iter
            (fun x v ->
              try
                ans := T.Fields.add x { V.rgen = v.V.V.v_gen; V.rval = term_of_value v.V.V.v_value } !ans
              with
                | Failure _ -> ()
                | e ->
                  Printf.printf "term_of_value: ignoring %s = %s (%s).\n" x (V.V.print_value v.V.V.v_value) (Printexc.to_string e);
                  ()
            ) r;
          !ans
        in
        Record r
      | V.V.FFI ffi ->
        (
          match ffi.V.V.ffi_external with
            | Some x ->
              (
                match x with
                  | "event_channel" -> Fun (Vars.empty, [], make_term (Event_channel []))
                  | "event_handle" ->
                    let t = T.fresh_evar ~level:(-1) ~pos:None in
                    Fun
                      (Vars.empty,
                       [
                         "", "c", Lang.event_t t, None;
                         "", "h", Lang.fun_t [false,"",t] Lang.unit_t, None
                       ],
                       make_term (Event_handle (make_term (Var "c"), make_term (Var "h")))
                      )
                  | "event_emit" ->
                    let t = T.fresh_evar ~level:(-1) ~pos:None in
                    Fun
                      (Vars.empty,
                       [
                         "", "c", Lang.event_t t, None;
                         "", "v", t, None
                       ],
                       make_term (Event_emit (make_term (Var "c"), make_term (Var "v")))
                      )
                  | _ -> Var (builtin_prefix^x)
              )
            | None -> failwith "TODO: don't know how to emit code for this operation"
        )
      | V.V.Fun (params, applied, venv, t) ->
        let params = List.map (fun (l,x,v) -> l,x,T.fresh_evar ~level:(-1) ~pos:None,Utils.may term_of_value v) params in
        let applied = List.may_map (fun (x,(_,v)) -> try Some (x,term_of_value v) with _ -> None) applied in
        let venv = List.may_map (fun (x,(_,v)) -> try Some (x,term_of_value v) with _ -> None) venv in
        let venv = applied@venv in
        let t = substs venv t in
        (* TODO: fill vars? *)
        Fun (V.Vars.empty, params, t)
      | V.V.Int n -> Int n
      | V.V.Float f -> Float f
      | V.V.Bool b -> Bool b
      | V.V.String s -> String s
      | V.V.Event_channel l -> Event_channel (List.map term_of_value l)
  in
  make_term term

let rec is_value ~env tm =
  (* Printf.printf "is_value: %s\n%!" (print_term tm); *)
  let is_value ?(env=env) = is_value ~env in
  match tm.term with
    | Var _ | Unit | Bool _ | Int _ | String _ | Float _ -> true
    (* TODO: handle more cases, for instance: let x = ... in 3 *)
    | _ ->  false

type state =
    {
      refs : (string * term) list;
      events : (string * (term list)) list
    }

let empty_state = { refs = [] ; events = [] }

(** Raised by "Liquidsoap" implementations of functions when no reduction is
    possible. *)
exception Cannot_reduce

(** Functions to reduce builtins. *)
let builtin_reducers = ref
  [
    "add",
    (fun args ->
      match args.(0).term, args.(1).term with
        | Float x, Float y -> make_term (Float (x+.y))
        | Float 0., _ -> args.(1)
        | _, Float 0. -> args.(0)
        | _ -> raise Cannot_reduce
    );
    "sub",
    (fun args ->
      match args.(0).term, args.(1).term with
        | Float x, Float y -> make_term (Float (x-.y))
        | _, Float 0. -> args.(0)
        | _ -> raise Cannot_reduce
    );
    "mul",
    (fun args ->
      match args.(0).term, args.(1).term with
        | Float x, Float y -> make_term (Float (x*.y))
        | Float 1., _ -> args.(1)
        | _, Float 1. -> args.(0)
        | _ -> raise Cannot_reduce
    )
  ]

(* Notice that it is important to mk at the end in order to preserve types. *)
let rec reduce ?(env=[]) ?(bound_vars=[]) ?(event_vars=[]) tm =
  (* Printf.printf "reduce: %s\n%!" (V.print_term tm); *)
  let reduce ?(env=env) ?(bound_vars=bound_vars) ?(event_vars=event_vars) = reduce ~env ~bound_vars ~event_vars in
  let merge s1 s2 =
    let events =
      let l1 = List.map fst s1.events in
      let l2 = List.map fst s2.events in
      let l1 = List.filter (fun x -> not (List.mem x l2)) l1 in
      let l = l1@l2 in
      let a x l =
        try
          List.assoc x l
        with
          | Not_found -> []
      in
      List.map (fun x -> x, (a x s1.events)@(a x s2.events)) l
    in
    {
      refs = s1.refs@s2.refs;
      events = events;
    }
  in
  let mk ?(t=tm.t) = make_term ~t in
  let reduce_list l =
    let st = ref empty_state in
    let l = List.map (fun v -> let s, v = reduce v in st := merge !st s; v) l in
    !st, l
  in
  let s, term =
    match tm.term with
      | Var _ | Unit | Bool _ | Int _ | String _ | Float _ -> empty_state, tm.term
      | Let l ->
        let sdef, def = reduce l.def in
        if (
          (match (T.deref def.t).T.descr with
            | T.Arrow _ | T.Record _ -> true
            | T.Constr { T.name = "event" } -> true
            | _ -> is_value ~env def
          ) || (
            let o = occurences l.var l.body in
            o = 0 || (o = 1 && is_pure ~env def)
           )
        )
        (* We can rename meta-variables here because we are in weak-head
           reduction, so we know that any value using the meta-variable below
           will already be inlined. *)
        (* However, we have to keep the variables defined by lets that we want to
           keep, which are also in meta_vars. *)
          && not (List.mem l.var !keep_vars)
        then
          let env = (l.var,def)::env in
          let event_vars = (List.map fst sdef.events)@event_vars in
          let body = subst l.var def l.body in
          let sbody, body = reduce ~env ~event_vars body in
          merge sdef sbody, body.term
        else
          let var, body = fresh_let bound_vars l in
          let env = (l.var,def)::env in
          let event_vars = (List.map fst sdef.events)@event_vars in
          let sbody, body = reduce ~bound_vars:(var::bound_vars) ~env ~event_vars body in
          let l = { l with var = var; def = def; body = body } in
          merge sdef sbody, Let l
      | Ref v ->
        let sv, v = reduce v in
        let x = fresh_ref () in
        merge { empty_state with refs = [x,v] } sv, Var x
      | Get r ->
        let sr, r = reduce r in
        sr, Get r
      | Set (r,v) ->
        let sr, r = reduce r in
        let sv, v = reduce v in
        merge sr sv, Set (r, v)
      | Seq (a, b) ->
        let sa, a = reduce a in
        let sb, b = reduce b in
        let tm =
          let rec aux a =
            match a.term with
              | Unit -> b
              | Let l ->
                let var, body = fresh_let (free_vars b) l in
                mk (Let { l with var = var; body = aux body })
              | _ -> mk (Seq (a, b))
          in
          (aux a).term
        in
        merge sa sb, tm
      | Record r ->
        (* Records get lazily evaluated in order not to generate variables for
           the whole standard library. *)
        empty_state, tm.term
      (*
        let sr = ref [] in
        let r =
        T.Fields.map
        (fun v ->
        let s, v' = reduce v.rval in
        sr := merge !sr s;
        { v with rval = v' }
        ) r
        in
        !sr, Record r
      *)
      | Field (r,x,o) ->
        let sr, r = reduce r in
        let sr = ref sr in
        let rec aux r =
          (* Printf.printf "aux field (%s): %s\n%!" x (print_term r); *)
          match r.term with
            | Record r ->
              (* TODO: use o *)
              let s, v = reduce (try T.Fields.find x r with Not_found -> failwith (Printf.sprintf "Field %s not found" x)).rval in
              sr := merge s !sr;
              v
            | Let l ->
              let fv = match o with Some o -> free_vars o | None -> [] in
              let var, body = fresh_let fv l in
              mk (Let { l with var = var ; body = aux body })
            | Seq (a, b) ->
              assert false (* TODO *)
        in
        !sr, (aux r).term
      | Fun (vars, args, v) ->
        (* We have to use weak head reduction because some refs or events might
           use the arguments, e.g. fun (x) -> ref x. However, we need to reduce
           toplevel declarations... *)
        (* let bound_vars = (List.map (fun (_,x,_,_) -> x) args)@bound_vars in *)
        (* let sv, v = reduce ~bound_vars v in *)
        (* sv, Fun (vars, args, v) *)
        (* TODO: we should extrude variables in order to be able to handle
           handle(c,fun(x)->emit(c',x)). *)
        (* TODO: instead of this, we should see when variables are not used in
           impure positions (in argument of refs or events). *)
        let fv = free_vars v in
        let args_vars = List.map (fun (_,x,_,_) -> x) args in
        if args_vars = [] || not (List.included args_vars fv) then
          let s, v = reduce v in
          s, Fun (vars, args, v)
        else
          empty_state, Fun (vars, args, v)
      | App (f,a) ->
        let sf, f = reduce f in
        let sa, a =
          let sa = ref empty_state in
          let ans = ref [] in
          List.iter
            (fun (l,v) ->
              let sv, v = reduce v in
              sa := merge !sa sv;
              ans := (l,v) :: !ans
            ) a;
          !sa, List.rev !ans
        in
        let s = ref (merge sf sa) in
        let rec aux f =
          (* Printf.printf "aux app: %s\n\n%!" (print_term f); *)
          match f.term with
            | Fun (vars, args, v) ->
              let args = List.map (fun (l,x,t,v) -> l,(x,t,v)) args in
              let args = ref args in
              let v = ref v in
              let reduce_args a =
                List.iter
                  (fun (l,va) ->
                    let x,_,_ = List.assoc l !args in
                    args := List.remove_assoc l !args;
                    v := subst x va !v
                  ) a
              in
              reduce_args a;
              let args = List.map (fun (l,(x,t,v)) -> l,x,t,v) !args in
              if args = [] then
                let sv, v = reduce !v in
                s := merge sv !s;
                v
              else if List.for_all (fun (_,_,_,v) -> v <> None) args then
                let a = List.map (fun (l,_,_,v) -> l, Utils.get_some v) args in
                reduce_args a;
                let sv, v = reduce !v in
                s := merge sv !s;
                v
              else
                mk (Fun (vars, args, !v))
            | Let l ->
              let fv = List.fold_left (fun fv (_,v) -> (free_vars v)@fv) [] a in
              let var, body = fresh_let fv l in
              mk (Let { l with var = var ; body = aux body })
            | Var x ->
              (
                try
                  if is_builtin_var x then
                    let x = remove_builtin_prefix x in
                    let r = List.assoc x !builtin_reducers in
                    let a = List.map (fun (l,v) -> assert (l = ""); v) a in
                    let a = Array.of_list a in
                    r a
                  else
                    mk (App (f, a))
                with
                  | Not_found
                  | Cannot_reduce -> mk (App (f, a))
              )
        in
        !s, (aux f).term
      | Event_channel l ->
        let s, l = reduce_list l in
        let c = fresh_event () in
        merge { empty_state with events = [c,l] } s, Var c
      | Event_handle ({term = Event_channel _}, v) ->
        empty_state, Unit
      | Event_handle (c,h) ->
        let s, c = reduce c in
        (* We have to apply the substitution because we want h to be a closed
           value: in let r = ref (0.) in handle(c, fun (x) -> r := !r + x), we
           want r to be substituted by the global variable representing the
           reference. *)
        (* TODO: we should only substitute effect-free values! *)
        (* Printf.printf "env: %s\n%!" (String.concat " " (List.map fst env)); *)
        let h = substs ~pure:true env h in
        let s',h = reduce h in
        let s = merge s s' in
        let rec aux c =
          (* Printf.printf "event_handle aux: %s\n%!" (print_term c); *)
          match c.term with
            | Var x ->
              if List.mem x event_vars then
                merge { empty_state with events = [x,[h]] } s, mk Unit
              else
                (* Printf.printf "unhandled var: %s\n%!" x; *)
                s, mk (Event_handle (c,h))
            (* This should be handled by the previous matching case and never
               occurs here because the reduce will replace the channel by a fresh
               variable... *)
            | Event_channel _ ->
              s, mk Unit
        in
        let s, t = aux c in
        s, t.term
      (* This special case should never occur for terms coming from SAML
         code. It only occurs after channels are substituted by the handler they
         can have. *)
      | Event_emit ({term = Event_channel l}, v) ->
        let l = List.map (fun f -> mk (App(f,["",v]))) l in
        let f = List.fold_left (fun s f -> mk (Seq (s,f))) (mk Unit) l in
        let s, f = reduce f in
        s, f.term
      | Event_emit (c,v) ->
        let s, c = reduce c in
        let s',v = reduce v in
        (* let rec aux c = *)
        (* match c.term with *)
        (* | Var _ -> *)
        (* mk (Event_emit (c, v)) *)
        (* | Event_channel l -> *)
        (* let l = List.map (fun f -> mk (App(f,["",v]))) l in *)
        (* let f = List.fold_left (fun s f -> mk (Seq (s,f))) (mk Unit) l in *)
        (* beta_reduce f *)
        (* in *)
        merge s s', Event_emit (c, v)
  in
  (* Printf.printf "events: %s\n%!" (String.concat " " event_vars); *)
  (* Printf.printf "reduce: %s => %s\n%!" (print_term tm) (print_term (mk term)); *)
  s, { term = term ; t = tm.t }

and beta_reduce tm =
  (* Printf.printf "beta_reduce: %s\n%!" (print_term tm); *)
  let r, tm = reduce tm in
  assert (r = empty_state);
  tm

let rec emit_type t =
  (* Printf.printf "emit_type: %s\n%!" (T.print t); *)
  match (T.deref t).T.descr with
    | T.Ground T.Unit -> B.T.Void
    | T.Ground T.Bool -> B.T.Bool
    | T.Ground T.Float -> B.T.Float
    | T.Ground T.Int -> B.T.Int
    | T.Constr { T.name = "ref"; params = [_,t] } -> B.T.Ptr (emit_type t)
    | T.Arrow (args, t) ->
      let args = List.map (fun (o,l,t) -> assert (not o); assert (l = ""); emit_type t) args in
      B.T.Arr (args, emit_type t)
    | T.EVar _ -> assert false; failwith "Cannot emit programs with universal types"

let rec emit_prog tm =
  (* Printf.printf "emit_prog: %s\n%!" (V.print_term tm); *)
  let rec focalize_app tm =
    match tm.term with
      | App (x,l2) ->
        let x, l1 = focalize_app x in
        x, l1@l2
      | x -> x,[]
  in
  match tm.term with
    | Bool b -> [B.Bool b]
    | Float f -> [B.Float f]
    | Var x -> [B.Ident x]
    | Ref r ->
      let tmp = fresh_ref () in
      [B.Let (tmp, [B.Alloc (emit_type r.t)]); B.Store ([B.Ident tmp], emit_prog r); B.Ident tmp]
    | Get r -> [B.Load (emit_prog r)]
    | Set (r,v) -> [B.Store (emit_prog r, emit_prog v)]
    | Seq (a,b) -> (emit_prog a)@(emit_prog b)
    | App _ ->
      let x, l = focalize_app tm in
      (
        (* Printf.printf "emit_prog app: %s\n%!" (print_term (make_term x)); *)
        match x with
          | Var x when is_builtin_var x ->
            let x = remove_builtin_prefix x in
            (
              match x with
                | "if_then_else" ->
                  let br v = beta_reduce (make_term (App (v, []))) in
                  let p = List.assoc "" l in
                  let p1 = br (List.assoc "then" l) in
                  let p2 = br (List.assoc "else" l) in
                  let p, p1, p2 = emit_prog p, emit_prog p1, emit_prog p2 in
                  [ B.If (p, p1, p2)]
                | _ ->
                  let l = List.map (fun (l,v) -> assert (l = ""); emit_prog v) l in
                  let l = Array.of_list l in
                  let op =
                    match x with
                      (* TODO: handle integer operations *)
                      | "add" -> B.FAdd
                      | "sub" -> B.FSub
                      | "mul" -> B.FMul
                      | "div" -> B.FDiv
                      | "mod" -> B.FMod
                      | "eq" -> B.FEq
                      | "lt" -> B.FLt
                      | "ge" -> B.FGe
                      | "and" -> B.BAnd
                      | "or" -> B.BOr
                      | _ -> B.Call x
                  in
                  [B.Op (op, l)]
            )
          | _ -> Printf.printf "unhandled app: %s(...)\n%!" (print_term (make_term x)); assert false
      )
    | Field (r,x,_) ->
      (* Records are always passed by reference. *)
      [B.Field ([B.Load (emit_prog r)], x)]
    | Let l ->
      (B.Let (l.var, emit_prog l.def))::(emit_prog l.body)
    | Unit -> []
    | Int n -> [B.Int n]
    | Fun _ -> assert false
    | Record _ ->
      (* We should not emit records since they are lazily evaluated (or
         evaluation should be forced somehow). *)
      assert false
    | Replace_field _ | Open _ -> assert false
    | Event_channel _ -> assert false
    | Event_handle _ -> assert false
    | Event_emit _ -> assert false

(** Emit a prog which might start by decls (toplevel lets). *)
let rec emit_decl_prog tm =
  (* Printf.printf "emit_decl_prog: %s\n%!" (print_term tm); *)
  match tm.term with
    (* Hack to keep top-level declarations that we might need. We should
       explicitly flag them instead of keeping them all... *)
    | Let l when (match (T.deref l.def.t).T.descr with T.Arrow _ -> true | _ -> false) ->
      Printf.printf "def: %s = %s : %s\n%!" l.var (print_term l.def) (T.print l.def.t);
      let t = emit_type l.def.t in
      (
        match t with
          | B.T.Arr (args, t) ->
            let args =
              let n = ref 0 in
              List.map (fun t -> incr n; Printf.sprintf "x%d" !n, t) args
            in
            let proto = l.var, args, t in
            let def =
              let args = List.map (fun (x, _) -> "", make_term (Var x)) args in
              let def = make_term (App (l.def, args)) in
              beta_reduce def
            in
            let d = B.Decl (proto, emit_prog def) in
            let dd, p = emit_decl_prog l.body in
            d::dd, p
          | _ ->
            let dd, p = emit_decl_prog l.body in
            let e =
              match emit_prog l.def with
                | [e] -> e
                | _ -> assert false
            in
            (B.Decl_cst (l.var, e))::dd, p
      )
    | _ -> [], emit_prog tm

let emit name ?(keep_let=[]) ~env ~venv tm =
  keep_vars := keep_let;
  Printf.printf "emit: %s : %s\n\n%!" (V.print_term tm) (T.print tm.t);
  (* Inline the environment. *)
  let venv =
    List.may_map
      (fun (x,v) ->
        try
          Some (x, term_of_value v)
        with
          | e ->
            (* Printf.printf "venv: ignoring %s = %s (%s).\n" x (V.V.print_value v) (Printexc.to_string e); *)
            None
      ) venv
  in
  let env = env@venv in
  (* Printf.printf "env: %s\n%!" (String.concat " " (List.map fst env)); *)
  let prog = substs env tm in
  Printf.printf "closed term: %s\n\n%!" (print_term prog);
  (* Reduce the term and compute references and events. *)
  let state, prog = reduce prog in
  (* (\* Reduce once more so that handlers get emitted. *\) *)
  (* let state, prog = reduce ~state:{state with bound_vars=[]} prog in *)
  Printf.printf "reduced: %s\n\n%!" (print_term prog);
  (* Emit the events. *)
  let prog =
    let e = List.map (fun (x,h) -> x, make_term (Event_channel h)) state.events in
    (* TODO: this only handles one level of events, we should do more fancy
       things such as sorting them according to the free event variables,
       etc. *)
    let e = List.map (fun (x,c) -> x, substs e c) e in
    (* List.iter (fun (x,_) -> Printf.printf "subst event %s\n%!" x) e; *)
    let prog = substs e prog in
    Printf.printf "subst events: %s\n\n%!" (print_term prog);
    (* ( *)
    (* let s, prog = reduce prog in *)
    (* Printf.printf "before evented: %s\n\n%!" (print_term prog); *)
    (* let refs = String.concat " " (List.map fst s.refs) in *)
    (* let events = String.concat " " (List.map fst s.events) in *)
    (* Printf.printf "refs: %s\nevents: %s\n\n%!" refs events *)
    (* ); *)
    beta_reduce prog
  in
  Printf.printf "evented: %s\n\n%!" (print_term prog);

  (* Compute the state. *)
  let refs = state.refs in
  let refs = refs in
  let refs_t = List.map (fun (x,v) -> x, emit_type v.V.t) refs in
  let refs_t = ("period", B.T.Float)::refs_t in
  let refs = List.map (fun (x,v) -> x, emit_prog v) refs in
  let state_t = B.T.Struct refs_t in
  let state_decl = B.Decl_type ("saml_state", state_t) in

  (* Emit the program. *)
  let decls, prog = emit_decl_prog prog in
  let prog = B.Decl ((name, [], emit_type tm.t), prog) in
  let decls = decls@[prog] in

  (* Add state to emitted functions. *)
  let decls =
    let alias_state =
      let f x =
        let s = [B.Load [B.Ident "state"]] in
        let r = [B.Field(s,x)] in
        let r = [B.Address_of r] in
        B.Let (x, r)
      in
      List.map (fun (x,_) -> f x) refs
    in
    let alias_period =
      let s = [B.Load [B.Ident "state"]] in
      let r = [B.Field(s,"period")] in
      B.Let ("period", r)
    in
    let alias_state = alias_period::alias_state in
    List.map
      (function
        | B.Decl ((name, args, t), prog) ->
          B.Decl ((name, ("state", B.T.Ptr state_t)::args, t), alias_state@prog)
        | decl -> decl
      ) decls
  in

  (* Declare generic functions for manipulating state. *)
  let reset =
    List.map
      (fun (x,p) ->
        let s = [B.Load [B.Ident "state"]] in
        let r = [B.Field (s, x)] in
        let r = [B.Address_of r] in
        B.Store (r, p)
      ) refs
  in
  let reset = B.Decl ((name^"_reset", ["state", B.T.Ptr state_t], B.T.Void), reset) in
  let alloc =
    [
      B.Let ("state", [B.Alloc state_t]);
      B.Op (B.Call (name^"_reset"), [|[B.Ident "state"]|]);
      B.Ident "state"
    ]
  in
  let alloc = B.Decl ((name^"_alloc", [], B.T.Ptr state_t), alloc) in
  let free = [B.Free [B.Ident "state"]] in
  let free = B.Decl ((name^"_free", ["state", B.T.Ptr state_t], B.T.Void), free) in

  let ans = state_decl::reset::alloc::free::decls in
  Printf.printf "emitted:\n%s\n\n%!" (B.print_decls ans);
  ans