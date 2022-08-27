open CompilerCommon
open CompilerEnv
open Common.TypesCommon
open Llvm
open IrMir


let unary (op:unOp) (t,v) : llbuilder -> llvalue = 
  let f = 
    match t,op with
    | Float,Neg -> build_fneg
    | Int,Neg -> build_neg
    | _,Not  -> build_not
    | _ -> Printf.sprintf "bad unary operand type : '%s'. Only double and int are supported" (string_of_sailtype (Some t)) |> failwith
  in f v ""


let binary (op:binOp) (t:sailtype) (l1:llvalue) (l2:llvalue) : llbuilder -> llvalue = 
    let operators = [
      (Int, 
        [
          (Minus, build_sub) ; (Plus, build_add) ; (Rem, build_srem) ;
          (Mul,build_mul) ; (Div, build_sdiv) ; 
          (Eq, build_icmp Icmp.Eq) ; (NEq, build_icmp Icmp.Ne) ;
          (Lt, build_icmp Icmp.Slt) ; (Gt, build_icmp Icmp.Sgt) ; 
          (Le, build_icmp Icmp.Sle) ; (Ge, build_icmp Icmp.Sge) ;
          (And, build_and) ; (Or, build_or) ;
        ]
      ) ;
      (Float,
        [
          (Minus, build_fsub) ; (Plus, build_fadd) ; (Rem, build_frem) ;
          (Mul,build_fmul) ; (Div, build_fdiv) ; 
          (Eq, build_fcmp Fcmp.Oeq) ; (NEq, build_fcmp Fcmp.One) ;
          (Lt, build_fcmp Fcmp.Olt) ; (Gt, build_fcmp Fcmp.Ogt) ; 
          (Le, build_fcmp Fcmp.Ole) ; (Ge, build_fcmp Fcmp.Oge) ;
          (And, build_and) ; (Or, build_or) ;
        ]
      )
    ] in

    let l = List.assoc_opt t operators in
    let open Common.Monad.MonadOperator(Common.MonadOption.M) in
    match l >>| List.assoc op with
    | Some oper -> oper l1 l2 ""
    | None ->  Printf.sprintf "bad binary operand type : '%s'. Only doubles and ints are supported" (string_of_sailtype (Some t)) |> failwith


let rec eval_l (env:SailEnv.t) (llvm:llvm_args) (x: AstMir.expression) : sailtype * llvalue = 
  match x with
  | Variable ((_,t), x) -> let _,v = SailEnv.get_var env x |> Option.get |> snd in t,v
  | Deref (_, x) -> eval_r env llvm x
  | ArrayRead (_, array_exp, index_exp) -> 
    let array_t,array_val = eval_l env llvm array_exp in
    let t =
    match array_t with
    | ArrayType (t,_s) -> t
    | t ->  Printf.sprintf "typechecker is broken : 'array' type for %s is %s" (value_name array_val) (string_of_sailtype (Some t)) |> failwith
    in
    let _,index = eval_r env llvm index_exp in
    let llvm_array = build_in_bounds_gep array_val [|(const_int (i64_type llvm.c) 0 ); index|] "" llvm.b in 
    RefType (t,true),llvm_array
  | StructRead _ -> failwith "struct assign unimplemented"
  | StructAlloc (_, _, _) -> failwith "struct allocation unimplemented"
  | EnumAlloc (_, _, _) -> failwith "enum allocation unimplemented"
  | _  -> failwith "problem with thir"

and eval_r (env:SailEnv.t) (llvm:llvm_args) (x:AstMir.expression) : sailtype * llvalue = 
  match x with
  | Variable _ ->  let t,v = eval_l env llvm x in t,build_load v "" llvm.b
  | Literal ((_,t), l) ->  t,getLLVMLiteral l llvm
  | UnOp (_, op,e) -> let t,l = eval_r env llvm e in t,unary op (t,l) llvm.b
  | BinOp (_, op,e1, e2) -> 
      let t,l1 = eval_r env llvm e1
      and _,l2 = eval_r env llvm e2
      in t,binary op t l1 l2 llvm.b
  | StructRead (_, _, _) -> failwith "struct read undefined"
  | ArrayRead _ -> let v_t,v = eval_l env llvm x in
    begin
    match v_t with
    | RefType (t,_) -> t,(build_load v "" llvm.b)
    | _ -> failwith "type system is broken"
    end
  | Ref (_, _,e) -> eval_l env llvm e
  | Deref (_, e) -> 
    begin
      match eval_l env llvm e with
      | RefType (t,_),l -> t,build_load l "" llvm.b
      | _ -> failwith "type system is broken"
      end
  | ArrayStatic (_, elements) -> 
    begin
    let array_types,array_values = List.map (fun e -> eval_r env llvm e) elements |> List.split in
    let ty = List.hd array_values |> type_of in
    let array_values = Array.of_list array_values in
    let array_type = array_type ty (List.length elements) in 
    let array = const_array array_type array_values in
    let array = define_global "const_array" array llvm.m in
    set_linkage Linkage.Private array;
    set_unnamed_addr true array;
    set_global_constant true array;
    (ArrayType (List.hd array_types, List.length elements)),build_load array "" llvm.b
    end
  | _ -> failwith "problem with thir"
and construct_call (name:string) (args:AstMir.expression list) (env:SailEnv.t) (llvm:llvm_args) : llvalue = 
  let args_type,args = List.map (fun arg -> eval_r env llvm arg) args |> List.split
  in
  let mname = mangle_method_name name args_type in 
  let args = Array.of_list args in
  Logs.info (fun m -> m "constructing call to %s" mname);
  match SailEnv.get_method env name  with 
  | None ->  Printf.sprintf "method %s not found" name |> failwith
  | Some (_,m) -> build_call m args "" llvm.b

  
open AstMir
  
let cfgToIR (proto:llvalue) (decls,cfg: Mir.Pass.out_body) (llvm:llvm_args) (env :SailEnv.t) : unit = 
  let declare_var (mut:bool) (name:string) (ty:sailtype) (exp:AstMir.expression option) (env:SailEnv.t) : SailEnv.t =
    let _ = mut in (* todo manage mutable types *)
    let entry_b = entry_block proto |> instr_begin |> builder_at llvm.c in
    let _,v =  
      match exp with
      | Some e -> 
          let t,v = eval_r env llvm e in
          let x = build_alloca (getLLVMType t llvm.c llvm.m) name entry_b in 
          build_store v x llvm.b |> ignore; t,x  
      | None ->
        let t' = getLLVMType ty llvm.c llvm.m in
        ty,build_alloca t' name entry_b
    in
    (* Logs.debug (fun m -> m "declared %s with type %s " name (string_of_sailtype (Some t))) ; *)
    SailEnv.declare_var env name  (dummy_pos,(mut,v)) |> Result.get_ok

  and assign_var (target:expression) (exp:expression) (env:SailEnv.t) = 
    let lvalue = eval_l env llvm target |> snd
    and rvalue = eval_r env llvm exp |> snd in
    build_store rvalue lvalue llvm.b |> ignore
    in

  let rec aux (lbl:label) (llvm_bbs : llbasicblock BlockMap.t) (env:SailEnv.t) : llbasicblock BlockMap.t = 
    match BlockMap.find_opt lbl llvm_bbs with
    | None -> 
      begin
        let bb = BlockMap.find lbl cfg.blocks
        and bb_name = (Printf.sprintf "lbl%i" lbl) in
        let llvm_bb = append_block llvm.c bb_name proto in
        let llvm_bbs = BlockMap.add lbl llvm_bb llvm_bbs in
        position_at_end llvm_bb llvm.b;
        List.iter (fun x -> assign_var x.target x.expression env) bb.assignments;
        match bb.terminator with
        | Some (Return e) ->  
            let ret = match e with
              | Some r ->  let v = eval_r env llvm r |> snd in build_ret v
              | None ->  build_ret_void
            in ret llvm.b |> ignore; llvm_bbs

        | Some (Goto lbl) -> 
          let llvm_bbs = aux lbl llvm_bbs env in
          position_at_end llvm_bb llvm.b;
          build_br (BlockMap.find lbl llvm_bbs) llvm.b |> ignore;
          llvm_bbs
          

        | Some (Invoke f) ->    
          let c = construct_call f.id f.params env llvm  in
          begin
            match f.target with
            | Some id -> build_store c (let _,v = SailEnv.get_var env id |> Option.get |> snd in v) llvm.b |> ignore
            | None -> ()
          end;
          let llvm_bbs = aux f.next llvm_bbs env in
          position_at_end llvm_bb llvm.b;
          build_br (BlockMap.find f.next llvm_bbs) llvm.b |> ignore;
          llvm_bbs
        | Some (SwitchInt (e,cases,default)) -> 
            let sw_val = eval_r env llvm e |> snd in
            let sw_val = build_intcast sw_val (i32_type llvm.c) "" llvm.b (* for condition, expression val will be bool *)
            and llvm_bbs = aux default llvm_bbs env in
            position_at_end llvm_bb llvm.b;
            let sw = build_switch sw_val (BlockMap.find default llvm_bbs) (List.length cases) llvm.b in
            List.fold_left (
              fun bm (n,lbl) -> 
                let n = const_int (i32_type llvm.c) n 
                and bm = aux lbl bm env 
                in add_case sw n (BlockMap.find lbl bm);
                bm
            ) llvm_bbs cases

        | None -> failwith "no terminator : mir is broken" (* can't happen *)
      end

    | Some _ -> llvm_bbs (* already treated, nothing to do *)
  in
  let env = List.fold_left (fun e (d:declaration) -> declare_var d.mut d.id d.varType None e) env decls
  in
  let init_bb = insertion_block llvm.b
  and llvm_bbs = aux cfg.input BlockMap.empty env in
  position_at_end init_bb llvm.b;
  build_br (BlockMap.find cfg.input llvm_bbs) llvm.b |> ignore


let toLLVMArgs (args: param list ) (llvm:llvm_args) : (bool * sailtype * llvalue) array = 
  let llvalue_list = List.map (
    fun {id;mut;ty=t;_} -> 
      let ty = getLLVMType t llvm.c llvm.m in 
      mut,t,build_alloca ty id llvm.b
  ) args in
  Array.of_list llvalue_list

let methodToIR (llc:llcontext) (llm:llmodule) ((m,proto):Declarations.method_decl) (env:SailEnv.t) (name : string) : llvalue =

  match Either.find_right m.m_body with 
  | None -> proto (* extern method *)
  | Some b -> 
    Logs.info (fun m -> m "codegen of %s" name);
    let builder = builder llc in
    let llvm = {b=builder; c=llc ; m = llm} in

    if block_begin proto <> At_end proto then failwith ("redefinition of function " ^  name);

    let bb = append_block llvm.c "" proto in
    position_at_end bb llvm.b;

    let args = toLLVMArgs m.m_proto.params llvm in

    let new_env,args = Array.fold_left_map (
      fun env (m,_,v) -> 
        let new_env = SailEnv.declare_var env (value_name v) (dummy_pos,(m,v)) |> Result.get_ok in 
        (new_env, v)
      ) env args 

    in Array.iteri (fun i arg -> build_store (param proto i) arg llvm.b |> ignore ) args;

    cfgToIR proto b llvm new_env;
    proto

