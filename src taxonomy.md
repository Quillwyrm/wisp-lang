Yes, the split is sane. Do it. Same Odin package, multiple files, no fake package boundary. Odin explicitly supports all `.odin` files in one directory sharing the same package declaration, and your own Odin notes already use that exact shape for VM projects. 

But I’d adjust the split slightly.

Your proposed split:

```text
reader
compiler
runtime
host
core
```

is close. The weak word is **runtime**. It is too broad. In your implementation record, “Runtime” currently covers values, maps, native calls, display, arithmetic behavior, builtins-ish behavior, opcodes, and VM execution. That is too many concepts under one bucket. 

My recommended split:

```text
src/
  main.odin

  rite/
    value.odin
    reader.odin
    compiler.odin
    vm.odin
    core.odin
    host.odin
```

## `value.odin`

Owns runtime value/data representation.

Put here:

```text
ObjectKind
Object
StringObject
SymbolObject
ListObject
VectorObject
MapEntry
MapObject
Value
NativeProc
NativeFunctionObject

intern_symbol
new_string_object
new_list_object
new_vector_object
new_map_object

string_hash
map_key_hash
map_init
map_find_slot
map_get
map_set
map_delete
map_grow

append_value_text
value_display_text
print_value
```

Reason: maps, strings, symbols, object construction, equality-ish identity, display, and `Value` are not “VM execution.” They are the value substrate. Reader, compiler, core builtins, and VM all touch this.

## `reader.odin`

Owns source text to reader tree.

Put here:

```text
Reader

is_digit
is_whitespace
is_delimiter
skip_trivia

read_atom
read_string
read_name_string
read_list
read_vector
read_map
read_form
read_all_forms
read_source

debug_print_value_tree
debug_print_source_tree
```

The debug tree printer can live here for now because it prints reader tree shape. If it grows into general diagnostics later, split it then.

## `compiler.odin`

Owns reader tree to bytecode.

Put here:

```text
Compiler
LocalBinding
MAX_FRAME_SLOTS

Active_Code
begin_code
end_code
const_value
record_slots
emit_*
patch_jump_target

claim_slot
reserve_slots_until
find_local
form_is_definition

compile_*
```

Bytecode emission belongs with the compiler for now. It is code construction, not VM execution. Your implementation record says compiler fast-paths known builtins into bytecode for arithmetic/comparison/not/len/push/pop, so keeping lowering and emission together is honest right now. 

If emission grows large later, then maybe split:

```text
code.odin
compiler.odin
```

But not yet.

## `vm.odin`

Owns bytecode format and execution.

Put here:

```text
Opcode
InstABC
InstABx
InstAx
Code
GlobalBinding
VM
Active_VM

run_code
value_is_falsey
```

Maybe also:

```text
clear_error
set_error
reader_error
compile_error
runtime_error
```

I’d probably keep errors in `vm.odin` for now because `VM.error_string` is the current diagnostic owner, and the implementation record says the VM owns globals, symbols, slots, and current diagnostic. 

Do **not** make a separate `error.odin` yet unless diagnostics become a real subsystem. Right now it is a few procs plus one VM string.

## `core.odin`

Owns builtins/core operations.

Put here:

```text
core_add
core_sub
core_mul
core_div
core_mod
core_equal
core_less
core_less_equal
core_greater
core_greater_equal
core_not
core_len
core_push
core_pop

native_*
install_builtins
```

This is the right file for builtins and future core modules.

I’d keep `core_*` and `native_*` together because `native_*` is mostly public call wrapper around actual operation semantics. Splitting them now would make reading worse.

## `host.odin`

Owns embedding/public run surface.

Put here:

```text
make_vm
run_source
run_string
run_file
```

The implementation record lists the host surface as `make_vm`, `run_string`, `run_file`, and `print_value`; I’d keep `print_value` in `value.odin` because it is value display, but it remains public package surface. 

`host.odin` should stay thin. It should not become a lifecycle manager.

## So: `runtime` or `vm`?

Use **`vm.odin`**, not `runtime.odin`.

`runtime` is vague. In this project it can mean:

```text
values
heap objects
native calls
builtins
VM execution
host execution
diagnostics
```

`vm` is sharper:

```text
bytecode format + VM state + bytecode execution
```

Then `value.odin` carries the value model cleanly.

## Final call

Do this:

```text
rite/
  value.odin      value model, heap objects, map storage, display
  reader.odin     source reader and reader-tree debug printer
  compiler.odin   lowering, slot allocation, bytecode emission
  vm.odin         opcodes, Code, VM, errors, run_code
  core.odin       core operations, native builtins, install_builtins
  host.odin       make_vm, run_source, run_string, run_file
```

This split is earned. Your single file is already 3.6k lines with clear internal section headings. You are not inventing architecture; you are turning existing section boundaries into files.
