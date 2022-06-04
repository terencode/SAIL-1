open Common 
(*let e_box = {m_name="box"; m_generics=["A"]; m_params=[("x", GenericType "A")];m_rtype=Some(RefType(GenericType "A", true));m_body=()}*)
let e_print_string = {m_name="print_string"; m_generics=[];m_params=[("x", String)];m_rtype=None;m_body=()}
let e_print_int = {m_name="print_int"; m_generics=[];m_params=[("x", Int)];m_rtype=None;m_body=()}

let e_print_new_line = {m_name="print_newline"; m_generics=[];m_params=[];m_rtype=None;m_body=()}

let drop = {m_name="drop"; m_generics=["A"]; m_params=[("x",Box (GenericType "A"))];m_rtype=None;m_body=()}
let exSig = {
  name = "_External"; 
  structs = [];
  enums =[];
  methods = [(*e_box;*) e_print_string; e_print_new_line; e_print_new_line];
  processes = []
}