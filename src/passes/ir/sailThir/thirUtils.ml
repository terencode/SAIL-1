open Common
open TypesCommon
open ThirMonad
open Monad
open IrHir
module D = SailModule.Declarations

open MonadSyntax(ES)
open MonadOperator(ES)
open MonadFunctions(ES)

type expression = (loc * sailtype, l_str) AstHir.expression
type statement = (loc,l_str,expression) AstHir.statement

let rec resolve_alias loc : sailtype -> (sailtype,string) Either.t ES.t = function 
| CompoundType {origin;name=(_,name);decl_ty=Some (T ());_} -> 
  let* (_,mname) =  ES.throw_if_none (Error.make loc @@ "unknown type '" ^ name ^ "' , all types must have an origin (problem with HIR)") origin in
  let* ty_t = ES.get_decl name (Specific (mname,Type))  
              >>= ES.throw_if_none (Error.make loc @@ Fmt.str "declaration '%s' requires importing module '%s'" name mname) in 
  begin
  match ty_t.ty with
  | Some (CompoundType _ as ct) -> resolve_alias loc ct
  | Some t -> return (Either.left t)
  | None -> return (Either.right name) (* abstract type, only look at name *)
  end
| t -> return (Either.left t)
  
let string_of_sailtype_thir (t : sailtype option) : string ES.t = 
  let+ res = 
    match t with
    | Some CompoundType {origin; name=(loc,x); _} -> 
        let* (_,mname) = ES.throw_if_none (Error.make loc "no origin in THIR (problem with HIR)") origin in
        let+ decl = ES.(get_decl x (Specific (mname,Filter [E (); S (); T()])) 
                      >>=  throw_if_none (Error.make loc "decl is null (problem with HIR)")) in
        begin
          match decl with 
          | T ty_def -> 
          begin
            match ty_def.ty with
            | Some t -> Fmt.str " (= %s)" @@ string_of_sailtype (Some t) 
            | None -> "(abstract)"
          end
          | S (_,s) -> Fmt.str " (= struct <%s>)" (List.map (fun (n,(_,t,_)) -> Fmt.str "%s:%s" n @@ string_of_sailtype (Some t) ) s.fields |> String.concat ", ")
          | _ -> failwith "can't happen"
        end
    |  _ -> ES.pure ""
    in (string_of_sailtype t) ^ res


let matchArgParam (l,arg: loc * sailtype) (m_param : sailtype) : sailtype  ES.t =
  let open MonadSyntax(ES) in

  let rec aux (a:sailtype) (m:sailtype) = 
    let* lt = resolve_alias l a in
    let* rt = resolve_alias l m in

    match lt,rt with
    | Left Bool,Left Bool -> return Bool
    | Left (Int i1), Left (Int i2) when i1 = i2 ->  return (Int  i1) 
    | Left Float,Left Float -> return Float
    | Left Char,Left Char -> return Char
    | Left String,Left String -> return String
    | Left ArrayType (at,s),Left ArrayType (mt,s') -> 
      if s = s' then
        let+ t = aux at mt in ArrayType (t,s)
      else
        ES.throw @@ Error.make l (Printf.sprintf "array length mismatch : wants %i but %i provided" s' s)
    
    | Right name, Right name' -> 
      let+ () = ES.throw_if (Error.make l @@ Fmt.str "want abstract type %s but abstract type %s provided" name name') (name <> name') in
      arg


  | Left Box _at, Left Box _mt -> ES.throw (Error.make l "todo box")
  | Left RefType (at,am), Left RefType (mt,mm) -> if am <> mm then ES.throw (Error.make l "different mutability") else aux at mt
  | Left at,Left GenericType _ |Left GenericType _,Left at  -> return at
  | Left CompoundType {name=(_,name1);origin=_;_}, Left CompoundType {name=(_,name2);_} when name1 = name2 ->
    return arg

  | _ -> let* param = string_of_sailtype_thir (Some m_param) 
          and* arg = string_of_sailtype_thir (Some arg) in 
    ES.throw @@ Error.make l @@ Printf.sprintf "wants %s but %s provided" param arg                                      
                              
  in aux arg m_param 


let check_binop op l r : sailtype ES.t = 
  let open MonadSyntax(ES) in
  match op with
  | Lt | Le | Gt | Ge | Eq | NEq ->
    let+ _ = matchArgParam r (snd l)   in Bool
  | And | Or -> 
    let+ _ = matchArgParam l Bool  
    and* _ = matchArgParam r Bool  in Bool
  | Plus | Mul | Div | Minus | Rem ->
    let+ _ = matchArgParam r (snd l) in snd l


let check_call (name:string) (f : method_proto) (args: expression list) loc : unit ES.t =
    (* if variadic, we just make sure there is at least minimum number of arguments needed *)
    let args = if f.variadic then List.filteri (fun i _ -> i < (List.length f.args)) args else args in
    let nb_args = List.length args and nb_params = List.length f.args in
    ES.throw_if (Error.make loc (Printf.sprintf "unexpected number of arguments passed to %s : expected %i but got %i" name nb_params nb_args))
                (nb_args <> nb_params)
    >>= fun () -> 
    ListM.iter2 
    (
      fun (ca:expression) ({ty=a;_}:param) ->
        let+ _ = matchArgParam ca.info a in ()
    ) args f.args
    




let find_function_source (fun_loc:loc) (_var: string option) (name : l_str) (import:l_str option) (el: expression list) : (l_str * D.method_decl)  ES.t =
  let* _,env = ES.get in 
  let* mname,def = HirUtils.find_symbol_source ~filt:[M ()] name import env |> ES.lift in
  match def with 
  | M decl ->  
    let _x = fun_loc and _y = el in 
    let+ _ = check_call (snd name) (snd decl) el fun_loc in mname,decl
    (* return (mname,decl) *)

  | _ -> failwith "non method returned" (* cannot happen because we only requested methods *)

        (* ES.throw 
                      @@ Error.make fun_loc ~hint:(Some (None,"specify one with '::' annotation")) 
                      @@ Fmt.str "multiple definitions for function %s : \n\t%s" id 
                        (List.map (
                          fun (i,((_,_,m):SailModule.Declarations.method_decl)) -> 
                            Fmt.str "from %s : %s(%s) : %s" i.mname id
                            (List.map (fun a -> Fmt.str "%s:%s" a.id (string_of_sailtype (Some a.ty))) m.args |> String.concat ", ") 
                            (string_of_sailtype m.ret)
                        ) choice |> String.concat "\n\t") *)
                        
let find_struct_source (name: l_str) (import : l_str option) : (l_str * D.struct_decl) ES.t =
  let* _,env = ES.get in 
  let+ origin,def = HirUtils.find_symbol_source ~filt:[S()] name import env |> ES.lift in
  begin
    match def with 
    | S decl -> origin,decl
    | _ -> failwith "non struct returned"
  end
