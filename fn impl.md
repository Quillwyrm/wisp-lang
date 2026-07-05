Yes. Here is the corrected grounded plan for **only** this slice:

```text
Implement:
  fn expression
  file-as-root Code
  explicit CodeBuilder / finalized Code
  FunctionObject
  CallFrame
  Upvalue / UpvalueDesc
  closure capture/read/write/close
  root file locals

Do not implement:
  (def (name params...) ...)
  modules
  import/export
  REPL persistence
  map namespace sugar
  quote/eval/macros
```

This supersedes the previous bad plan. This version uses:

```text
explicit ^CodeBuilder threading
Kiln-style finalized slices
no global builder stack
no current_builder()
no ResolvedName/NameResolution type
no delayed def
no slot_initialized
```

# 0. Current Rite shape being replaced

Current relevant source facts from `rite0.odin`:

```odin
Code :: struct {
	bytecode:         [dynamic]u32,
	constants:        [dynamic]Value,
	frame_slot_count: int,
}

Active_Code: Code
```

```odin
Compiler := struct {
	failed: bool,

	local_bindings: [MAX_FRAME_SLOTS]LocalBinding,
	local_count:    int,

	current_scope_local_start: int,
	next_slot:                 int,
}{}
```

Emitters write to `Active_Code`.

Compiler procs read/write singleton `Compiler.local_count`, `Compiler.next_slot`, etc.

`run_code` has one `ip` and indexes `vm.slots` directly with bytecode operands.

The target is:

```text
CodeBuilder is mutable compile-time state for one unfinished body.
Code is finalized runtime-read executable data.
File compiles to root Code.
(fn ...) compiles to child Code.
FunctionObject pairs Code with runtime upvalues.
CallFrame runs Code.
VM slot operands are frame-relative.
```

# 1. Replace runtime data shapes

## 1.1 Add `FUNCTION`

Current:

```odin
ObjectKind :: enum u8 {
	STRING,
	SYMBOL,
	LIST,
	VECTOR,
	MAP,
	NATIVE_FUNCTION,
}
```

Replace with:

```odin
ObjectKind :: enum u8 {
	STRING,
	SYMBOL,
	LIST,
	VECTOR,
	MAP,
	NATIVE_FUNCTION,
	FUNCTION,
}
```

`NATIVE_FUNCTION` stays. Native functions and Rite functions are different object layouts.

## 1.2 Add function/closure/frame types

Replace current `Code` with finalized-slice `Code`.

Put these in the VM data section after instruction layouts:

```odin
UpvalueDesc :: struct {
	from_parent_local: bool,
	index:             int,
}

Upvalue :: struct {
	// slot_index >= 0 means this upvalue indexes a live VM slot.
	// slot_index < 0 means this upvalue owns closed.
	slot_index: int,
	closed:     Value,
}

// Finished executable body.
//
// Code is runtime-read data. It owns exact slices.
// Root file code and fn body code use the same representation.
Code :: struct {
	bytecode:    []u32,
	constants:   []Value,
	child_codes: []^Code,

	frame_slot_count: int,
	param_count:      int,

	upvalue_descs: []UpvalueDesc,
}

FunctionObject :: struct {
	header: Object,
	code:   ^Code,

	upvalues: []^Upvalue,
}

CallFrame :: struct {
	code:     ^Code,
	upvalues: []^Upvalue,

	instruction_index: int,

	slot_base:         int,
	caller_slot_count: int,
}
```

Delete:

```odin
Active_Code: Code
```

That global active code buffer is gone.

## 1.3 Replace `VM`

Current:

```odin
VM :: struct {
	slots:        [dynamic]Value,
	globals:      [dynamic]GlobalBinding,
	symbols:      [dynamic]^SymbolObject,
	error_string: string,
}
```

Replace with:

```odin
VM :: struct {
	slots:      [dynamic]Value,
	slot_count: int,

	frames: [dynamic]CallFrame,

	open_upvalues: [dynamic]^Upvalue,

	globals: [dynamic]GlobalBinding,
	symbols: [dynamic]^SymbolObject,

	error_string: string,
}
```

`slot_count` is the active high-water mark. `len(vm.slots)` is backing storage.

## 1.4 Add function constructor

Near other object constructors:

```odin
new_function_object :: proc(code: ^Code) -> ^FunctionObject {
	function := new(FunctionObject)
	function.header.kind = .FUNCTION
	function.code = code
	function.upvalues = make([]^Upvalue, len(code.upvalue_descs))
	return function
}
```

This is not a lifecycle wrapper. It owns object initialization.

# 2. Replace compiler state

## 2.1 Add `CodeBuilder`

Put this near `LocalBinding`.

```odin
CodeBuilder :: struct {
	bytecode:    [dynamic]u32,
	constants:   [dynamic]Value,
	child_codes: [dynamic]^Code,

	frame_slot_count: int,
	param_count:      int,

	local_bindings: [MAX_FRAME_SLOTS]LocalBinding,
	local_count:    int,

	current_scope_local_start: int,
	next_slot:                 int,

	upvalue_descs:   [dynamic]UpvalueDesc,
	upvalue_symbols: [dynamic]^SymbolObject,

	parent: ^CodeBuilder,
}
```

`parent` is compile-time only. It lets nested function compilation resolve outer names.

## 2.2 Shrink `Compiler`

Replace current `Compiler` with:

```odin
Compiler := struct {
	failed: bool,
}{}
```

Do not move locals into another global structure. Locals belong to the active `CodeBuilder`.

No:

```text
Compiler.builders
current_builder()
NameResolution
ResolvedName
```

# 3. CodeBuilder lifetime

## 3.1 `begin_code`

Replace current `begin_code` with:

```odin
begin_code :: proc(parent: ^CodeBuilder, param_count: int) -> CodeBuilder {
	assert(param_count >= 0 && param_count <= MAX_FRAME_SLOTS, "param count out of range")

	return CodeBuilder{
		bytecode    = make([dynamic]u32),
		constants   = make([dynamic]Value),
		child_codes = make([dynamic]^Code),

		frame_slot_count = param_count,
		param_count      = param_count,

		local_count = 0,

		current_scope_local_start = 0,
		next_slot                 = param_count,

		upvalue_descs   = make([dynamic]UpvalueDesc),
		upvalue_symbols = make([dynamic]^SymbolObject),

		parent = parent,
	}
}
```

Parameters occupy slots `0..<param_count`, so `next_slot` starts at `param_count`.

## 3.2 `end_code`

Replace current `end_code` with Kiln-style finalization:

```odin
end_code :: proc(builder: ^CodeBuilder) -> ^Code {
	bytecode := make([]u32, len(builder.bytecode))
	copy(bytecode, builder.bytecode[:])

	constants := make([]Value, len(builder.constants))
	copy(constants, builder.constants[:])

	child_codes := make([]^Code, len(builder.child_codes))
	copy(child_codes, builder.child_codes[:])

	upvalue_descs := make([]UpvalueDesc, len(builder.upvalue_descs))
	copy(upvalue_descs, builder.upvalue_descs[:])

	delete(builder.bytecode)
	delete(builder.constants)
	delete(builder.child_codes)
	delete(builder.upvalue_descs)
	delete(builder.upvalue_symbols)

	code := new(Code)
	code^ = Code{
		bytecode         = bytecode,
		constants        = constants,
		child_codes      = child_codes,
		frame_slot_count = builder.frame_slot_count,
		param_count      = builder.param_count,
		upvalue_descs    = upvalue_descs,
	}

	return code
}
```

Successful `end_code` transfers dynamic builder storage into exact slices.

`upvalue_symbols` is compile-only and is not copied.

## 3.3 Finished Code cleanup

Add:

```odin
delete_code :: proc(code: ^Code) {
	for child in code.child_codes {
		delete_code(child)
	}

	delete(code.bytecode)
	delete(code.constants)
	delete(code.child_codes)
	delete(code.upvalue_descs)
	delete(code)
}
```

Finished `Code` owns its child `Code` tree.

## 3.4 Failed builder cleanup

Add:

```odin
delete_code_builder :: proc(builder: ^CodeBuilder) {
	for child in builder.child_codes {
		delete_code(child)
	}

	delete(builder.bytecode)
	delete(builder.constants)
	delete(builder.child_codes)
	delete(builder.upvalue_descs)
	delete(builder.upvalue_symbols)
}
```

This is only for abandoned unfinished builders.

No:

```text
discard_current_builder
discard_all_builders
```

Those were artifacts of the bad global-builder-stack model.

# 4. Thread `^CodeBuilder` through bytecode construction

This is a mechanical refactor. Every compile and emit proc that currently touches `Active_Code` or compiler locals should take `builder: ^CodeBuilder`.

## 4.1 Constants

Replace:

```odin
const_value :: proc(value: Value) -> int
compile_constant :: proc(value: Value, dst: int)
```

with:

```odin
const_value :: proc(builder: ^CodeBuilder, value: Value) -> int {
	append(&builder.constants, value)
	return len(builder.constants) - 1
}

compile_constant :: proc(builder: ^CodeBuilder, value: Value, dst: int) {
	if len(builder.constants) > int(max(u16)) {
		compile_error("code uses too many constants")
		return
	}

	constant_index := const_value(builder, value)
	emit_load_const(builder, dst, constant_index)
}
```

## 4.2 Slot tracking

Replace:

```odin
record_slots :: proc(slots: ..int)
```

with:

```odin
record_slots :: proc(builder: ^CodeBuilder, slots: ..int) {
	for slot in slots {
		assert(slot >= 0 && slot <= int(max(u8)), "frame slot does not fit u8")

		needed_slot_count := slot + 1
		if needed_slot_count > builder.frame_slot_count {
			builder.frame_slot_count = needed_slot_count
		}
	}
}
```

## 4.3 Emitters

All emitters take `builder`.

Example replacements:

```odin
emit_ABC :: proc(builder: ^CodeBuilder, op: Opcode, a, b, c: int) {
	append(&builder.bytecode, u32(InstABC{
		op = op,
		a  = u8(a),
		b  = u8(b),
		c  = u8(c),
	}))
}

emit_ABx :: proc(builder: ^CodeBuilder, op: Opcode, a, b: int) {
	append(&builder.bytecode, u32(InstABx{
		op = op,
		a  = u8(a),
		b  = u16(b),
	}))
}
```

Then:

```odin
emit_move :: proc(builder: ^CodeBuilder, dst, src: int) {
	record_slots(builder, dst, src)
	emit_ABC(builder, .MOVE, dst, src, 0)
}
```

Do this mechanically for every existing emitter:

```text
emit_load_nil
emit_load_true
emit_load_false
emit_load_const
emit_move
emit_get_global
emit_add/sub/mul/div
emit_mod
emit_equal
emit_less
emit_less_equal
emit_greater
emit_greater_equal
emit_not
emit_len
emit_call
emit_new_vector
emit_new_map
emit_vector_push
emit_vector_pop
emit_set_index
emit_return
emit_Ax
emit_jump
emit_jump_if_falsey
patch_jump_target
```

`patch_jump_target` becomes:

```odin
patch_jump_target :: proc(builder: ^CodeBuilder, jump_index, target_index: int) {
	op := Opcode(u8(builder.bytecode[jump_index] & 0xff))

	if op == .JUMP {
		assert(target_index >= 0 && target_index <= 0xffffff, "jump target does not fit u24")
		builder.bytecode[jump_index] = u32(InstAx{op = .JUMP, a = u32(target_index)})
		return
	}

	if op == .JUMP_IF_FALSEY {
		assert(target_index >= 0 && target_index <= int(max(u16)), "jump target does not fit u16")
		old := InstABx(builder.bytecode[jump_index])
		builder.bytecode[jump_index] = u32(InstABx{op = .JUMP_IF_FALSEY, a = old.a, b = u16(target_index)})
		return
	}

	panic("patch_jump_target expected JUMP or JUMP_IF_FALSEY")
}
```

# 5. Add closure opcodes and emitters

## 5.1 Opcode additions

Current `Opcode` gets:

```odin
	LOAD_FUNCTION,  // ABx: A=dst, Bx=child code index
	GET_UPVALUE,   // ABx: A=dst, Bx=upvalue index
	SET_UPVALUE,   // ABx: A=src, Bx=upvalue index
	CLOSE_UPVALUES, // ABx: A=first slot to close
```

Put them after `GET_GLOBAL` or before arithmetic.

## 5.2 Emitters

Add:

```odin
emit_load_function :: proc(builder: ^CodeBuilder, dst, child_code_index: int) {
	assert(child_code_index >= 0 && child_code_index <= int(max(u16)), "child code index does not fit u16")
	record_slots(builder, dst)
	emit_ABx(builder, .LOAD_FUNCTION, dst, child_code_index)
}

emit_get_upvalue :: proc(builder: ^CodeBuilder, dst, upvalue_index: int) {
	assert(upvalue_index >= 0 && upvalue_index <= int(max(u16)), "upvalue index does not fit u16")
	record_slots(builder, dst)
	emit_ABx(builder, .GET_UPVALUE, dst, upvalue_index)
}

emit_set_upvalue :: proc(builder: ^CodeBuilder, upvalue_index, src: int) {
	assert(upvalue_index >= 0 && upvalue_index <= int(max(u16)), "upvalue index does not fit u16")
	record_slots(builder, src)
	emit_ABx(builder, .SET_UPVALUE, src, upvalue_index)
}

emit_close_upvalues :: proc(builder: ^CodeBuilder, first_slot: int) {
	assert(first_slot >= 0 && first_slot <= int(max(u8)), "close slot does not fit u8")
	emit_ABx(builder, .CLOSE_UPVALUES, first_slot, 0)
}
```

`SET_UPVALUE` uses `A=src`, `Bx=upvalue index`.

# 6. Thread `^CodeBuilder` through compiler functions

## 6.1 Slot helpers

Replace:

```odin
claim_slot :: proc() -> int
reserve_slots_until :: proc(slot_after_last: int)
find_local :: proc(symbol: ^SymbolObject) -> (int, bool)
```

with:

```odin
claim_slot :: proc(builder: ^CodeBuilder) -> int {
	if builder.next_slot >= MAX_FRAME_SLOTS {
		compile_error("code uses too many frame slots")
		return 0
	}

	slot := builder.next_slot
	builder.next_slot += 1
	return slot
}

reserve_slots_until :: proc(builder: ^CodeBuilder, slot_after_last: int) {
	if slot_after_last > MAX_FRAME_SLOTS {
		compile_error("code uses too many frame slots")
		return
	}

	if builder.next_slot < slot_after_last {
		builder.next_slot = slot_after_last
	}
}

find_local :: proc(builder: ^CodeBuilder, symbol: ^SymbolObject) -> (int, bool) {
	for i := builder.local_count - 1; i >= 0; i -= 1 {
		if builder.local_bindings[i].symbol == symbol {
			return builder.local_bindings[i].slot, true
		}
	}

	return -1, false
}
```

## 6.2 Reserved names

Current `compile_def` has the reserved-name list inline. Since params need the same rule, use one helper:

```odin
symbol_is_reserved_name :: proc(symbol: ^SymbolObject) -> bool {
	return symbol.text == "def" ||
	       symbol.text == "set" ||
	       symbol.text == "do" ||
	       symbol.text == "if" ||
	       symbol.text == "while" ||
	       symbol.text == "fn"
}
```

This helper owns the reserved-name list. That is worth one name.

# 7. Add upvalue compile helpers

These are real because they own the closure-capture invariant.

## 7.1 Dedupe upvalues per builder

```odin
find_upvalue :: proc(builder: ^CodeBuilder, symbol: ^SymbolObject) -> (int, bool) {
	for i := 0; i < len(builder.upvalue_symbols); i += 1 {
		if builder.upvalue_symbols[i] == symbol {
			return i, true
		}
	}

	return -1, false
}

add_upvalue :: proc(builder: ^CodeBuilder, symbol: ^SymbolObject, desc: UpvalueDesc) -> int {
	existing_index, found := find_upvalue(builder, symbol)
	if found {
		return existing_index
	}

	append(&builder.upvalue_symbols, symbol)
	append(&builder.upvalue_descs, desc)

	return len(builder.upvalue_descs) - 1
}
```

`upvalue_symbols[i]` corresponds to `upvalue_descs[i]`.

## 7.2 Recursive capture/forwarding

```odin
resolve_upvalue :: proc(builder: ^CodeBuilder, symbol: ^SymbolObject) -> (int, bool) {
	if builder.parent == nil {
		return -1, false
	}

	parent_slot, parent_has_local := find_local(builder.parent, symbol)
	if parent_has_local {
		index := add_upvalue(builder, symbol, UpvalueDesc{
			from_parent_local = true,
			index             = parent_slot,
		})
		return index, true
	}

	parent_upvalue, parent_has_upvalue := resolve_upvalue(builder.parent, symbol)
	if parent_has_upvalue {
		index := add_upvalue(builder, symbol, UpvalueDesc{
			from_parent_local = false,
			index             = parent_upvalue,
		})
		return index, true
	}

	return -1, false
}
```

This is the key closure compiler operation.

For:

```scheme
(fn ()
  (def x 1)
  (fn ()
    (fn () x)))
```

the middle function gets an upvalue for `x`, and the inner function captures the middle function’s upvalue.

## 7.3 Lexical visibility helper for call-head optimization

Current `compile_list_expr` uses fast opcode lowering for unshadowed builtins. With closures, an outer lexical binding must also shadow builtin opcode lowering.

Add:

```odin
lexical_name_visible :: proc(builder: ^CodeBuilder, symbol: ^SymbolObject) -> bool {
	current := builder
	for current != nil {
		_, found := find_local(current, symbol)
		if found {
			return true
		}

		current = current.parent
	}

	return false
}
```

This does not record an upvalue. It only answers: “Would a lexical binding shadow a global/core op here?”

Actual capture still happens in `compile_name_expr`.

# 8. Update name reads

Replace current:

```odin
compile_name_expr :: proc(symbol: ^SymbolObject, dst: int)
```

with:

```odin
compile_name_expr :: proc(builder: ^CodeBuilder, symbol: ^SymbolObject, dst: int) {
	local_slot, local_found := find_local(builder, symbol)
	if local_found {
		emit_move(builder, dst, local_slot)
		return
	}

	upvalue_index, upvalue_found := resolve_upvalue(builder, symbol)
	if upvalue_found {
		emit_get_upvalue(builder, dst, upvalue_index)
		return
	}

	global_index, global_found := find_global(Active_VM, symbol)
	if global_found {
		if global_index > int(max(u16)) {
			compile_error("global binding index does not fit bytecode")
			return
		}

		emit_get_global(builder, dst, global_index)
		return
	}

	compile_error(fmt.tprintf("undefined name `%s`", symbol.text))
}
```

No `ResolvedName` type.

# 9. Update `def`

Replace:

```odin
compile_def :: proc(form: Value)
```

with:

```odin
compile_def :: proc(builder: ^CodeBuilder, form: Value) {
	object, is_object := form.(^Object)
	assert(is_object && object.kind == .LIST, "compile_def expected list form")

	list := cast(^ListObject)object
	if len(list.items) != 3 {
		compile_error("`def` expects a name and value")
		return
	}

	name_object, name_is_object := list.items[1].(^Object)
	if !name_is_object || name_object.kind != .SYMBOL {
		compile_error("`def` name must be a name")
		return
	}

	name := cast(^SymbolObject)name_object
	if symbol_is_reserved_name(name) {
		compile_error(fmt.tprintf("cannot define reserved name `%s`", name.text))
		return
	}

	for i := builder.current_scope_local_start; i < builder.local_count; i += 1 {
		if builder.local_bindings[i].symbol == name {
			compile_error(fmt.tprintf("duplicate definition `%s` in the same scope", name.text))
			return
		}
	}

	binding_slot := claim_slot(builder)
	if Compiler.failed { return }

	// Ordered def: the binding is not visible while compiling its RHS.
	compile_expr(builder, list.items[2], binding_slot)
	if Compiler.failed { return }

	builder.local_bindings[builder.local_count] = LocalBinding{
		symbol = name,
		slot   = binding_slot,
	}
	builder.local_count += 1
}
```

This preserves current ordered `def`.

# 10. Update `body`, `do`, `if`, `while`

## 10.1 `compile_body`

Signature:

```odin
compile_body :: proc(builder: ^CodeBuilder, forms: []Value, dst: int)
```

Mechanical changes:

```text
Compiler.next_slot      -> builder.next_slot
compile_def(form)       -> compile_def(builder, form)
compile_expr(form, dst) -> compile_expr(builder, form, dst)
claim_slot()            -> claim_slot(builder)
emit_load_nil(dst)      -> emit_load_nil(builder, dst)
```

Keep the current body rule: empty body returns nil, final definition is error.

## 10.2 `compile_do`

Replace with:

```odin
compile_do :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	local_mark := builder.local_count
	slot_mark := builder.next_slot
	outer_scope_start := builder.current_scope_local_start

	builder.current_scope_local_start = local_mark

	compile_body(builder, list.items[1:], dst)
	if Compiler.failed { return }

	emit_close_upvalues(builder, slot_mark)

	builder.local_count = local_mark
	builder.next_slot = slot_mark
	builder.current_scope_local_start = outer_scope_start
}
```

`CLOSE_UPVALUES` before restoring slots is required for:

```scheme
(def f
  (do
    (def x 10)
    (fn () x)))
```

## 10.3 `compile_if`

Signature:

```odin
compile_if :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int)
```

Change only builder plumbing:

```odin
false_jump := len(builder.bytecode)
...
patch_jump_target(builder, false_jump, len(builder.bytecode))
```

No new scope behavior.

## 10.4 `compile_while`

Use this shape:

```odin
compile_while :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	if len(list.items) < 2 {
		compile_error("`while` expects a condition")
		return
	}

	local_mark := builder.local_count
	slot_mark := builder.next_slot
	outer_scope_start := builder.current_scope_local_start

	discard_slot := claim_slot(builder)
	if Compiler.failed { return }

	loop_start := len(builder.bytecode)

	compile_expr(builder, list.items[1], discard_slot)
	if Compiler.failed { return }

	exit_jump := len(builder.bytecode)
	emit_jump_if_falsey(builder, discard_slot, 0)
	if Compiler.failed { return }

	builder.current_scope_local_start = builder.local_count

	body_slot_mark := builder.next_slot
	body_discard_slot := claim_slot(builder)
	if Compiler.failed { return }

	compile_body(builder, list.items[2:], body_discard_slot)
	if Compiler.failed { return }

	emit_close_upvalues(builder, body_slot_mark)

	builder.local_count = local_mark
	builder.next_slot = slot_mark
	builder.current_scope_local_start = outer_scope_start

	emit_jump(builder, loop_start)

	patch_jump_target(builder, exit_jump, len(builder.bytecode))
	if Compiler.failed { return }

	emit_load_nil(builder, dst)
}
```

The body scope dies before the next iteration, so close body locals before jumping back.

# 11. Update `set`

Replace:

```odin
compile_set :: proc(list: ^ListObject, dst: int)
```

with builder-threaded direct resolution:

```odin
compile_set :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	if len(list.items) != 3 {
		compile_error("`set` expects a target and value")
		return
	}

	target := list.items[1]
	value := list.items[2]

	target_object, target_is_object := target.(^Object)
	if !target_is_object {
		compile_error("invalid `set` target")
		return
	}

	if target_object.kind == .SYMBOL {
		symbol := cast(^SymbolObject)target_object

		binding_slot, local_found := find_local(builder, symbol)
		if local_found {
			compile_expr(builder, value, dst)
			if Compiler.failed { return }

			emit_move(builder, binding_slot, dst)
			return
		}

		upvalue_index, upvalue_found := resolve_upvalue(builder, symbol)
		if upvalue_found {
			compile_expr(builder, value, dst)
			if Compiler.failed { return }

			emit_set_upvalue(builder, upvalue_index, dst)
			return
		}

		global_index, global_found := find_global(Active_VM, symbol)
		if global_found {
			if !Active_VM.globals[global_index].mutable {
				compile_error(fmt.tprintf("cannot set immutable binding `%s`", symbol.text))
				return
			}

			compile_error("setting mutable global bindings is not implemented")
			return
		}

		compile_error(fmt.tprintf("cannot set undefined binding `%s`", symbol.text))
		return
	}

	if target_object.kind == .LIST {
		target_list := cast(^ListObject)target_object
		if len(target_list.items) != 2 {
			compile_error("indexed `set` target expects a receiver and index")
			return
		}

		receiver_slot := claim_slot(builder)
		index_slot := claim_slot(builder)
		if Compiler.failed { return }

		compile_expr(builder, target_list.items[0], receiver_slot)
		if Compiler.failed { return }

		compile_expr(builder, target_list.items[1], index_slot)
		if Compiler.failed { return }

		compile_expr(builder, value, dst)
		if Compiler.failed { return }

		emit_set_index(builder, receiver_slot, index_slot, dst)
		return
	}

	compile_error("invalid `set` target")
}
```

This keeps your current direct style. No resolution object.

# 12. Implement `fn`

Add:

```odin
compile_fn :: proc(parent: ^CodeBuilder, list: ^ListObject, dst: int) {
	if len(list.items) < 2 {
		compile_error("`fn` expects a parameter list")
		return
	}

	params_object, params_is_object := list.items[1].(^Object)
	if !params_is_object || params_object.kind != .LIST {
		compile_error("`fn` parameters must be a list")
		return
	}

	params := cast(^ListObject)params_object
	if len(params.items) > int(max(u8)) {
		compile_error("function has too many parameters")
		return
	}

	child := begin_code(parent, len(params.items))

	for i := 0; i < len(params.items); i += 1 {
		param_object, param_is_object := params.items[i].(^Object)
		if !param_is_object || param_object.kind != .SYMBOL {
			compile_error("function parameter must be a name")
			delete_code_builder(&child)
			return
		}

		param := cast(^SymbolObject)param_object
		if symbol_is_reserved_name(param) {
			compile_error(fmt.tprintf("cannot use reserved name `%s` as parameter", param.text))
			delete_code_builder(&child)
			return
		}

		for j := 0; j < i; j += 1 {
			previous_object := params.items[j].(^Object)
			assert(previous_object.kind == .SYMBOL, "previous parameter was already validated")

			previous := cast(^SymbolObject)previous_object
			if previous == param {
				compile_error(fmt.tprintf("duplicate parameter `%s`", param.text))
				delete_code_builder(&child)
				return
			}
		}

		child.local_bindings[child.local_count] = LocalBinding{
			symbol = param,
			slot   = i,
		}
		child.local_count += 1
	}

	return_slot := claim_slot(&child)
	if Compiler.failed {
		delete_code_builder(&child)
		return
	}

	compile_body(&child, list.items[2:], return_slot)
	if Compiler.failed {
		delete_code_builder(&child)
		return
	}

	emit_return(&child, return_slot)

	child_code := end_code(&child)

	append(&parent.child_codes, child_code)
	child_index := len(parent.child_codes) - 1

	emit_load_function(parent, dst, child_index)
}
```

This compiles the body now and executes it later.

It also makes parameters ordinary locals in slots `0..<param_count`.

# 13. Update calls and builtin opcode lowering

## 13.1 `compile_ordinary_call`

Signature:

```odin
compile_ordinary_call :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int)
```

Mechanical changes:

```text
Compiler.next_slot -> builder.next_slot
reserve_slots_until(...) -> reserve_slots_until(builder, ...)
compile_expr(...) -> compile_expr(builder, ...)
emit_call(...) -> emit_call(builder, ...)
emit_move(...) -> emit_move(builder, ...)
```

Core body stays:

```odin
base := builder.next_slot
reserve_slots_until(builder, base + argument_count + 1)
...
emit_call(builder, base, argument_count)
emit_move(builder, dst, base)
```

## 13.2 `compile_builtin_opcode`

Signature:

```odin
compile_builtin_opcode :: proc(builder: ^CodeBuilder, symbol: ^SymbolObject, args: []Value, dst: int)
```

Mechanical changes:

```text
Compiler.next_slot -> builder.next_slot
claim/reserve/emit/compile all take builder
```

No semantic change.

## 13.3 `compile_list_expr`

Signature:

```odin
compile_list_expr :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int)
```

Change special forms:

```odin
if head.text == "set" {
	compile_set(builder, list, dst)
	return
}
if head.text == "do" {
	compile_do(builder, list, dst)
	return
}
if head.text == "if" {
	compile_if(builder, list, dst)
	return
}
if head.text == "while" {
	compile_while(builder, list, dst)
	return
}
if head.text == "fn" {
	compile_fn(builder, list, dst)
	return
}
```

Then replace current local/global head logic with:

```odin
if lexical_name_visible(builder, head) {
	compile_ordinary_call(builder, list, dst)
	return
}

_, global_found := find_global(Active_VM, head)
if global_found {
	argument_count := len(list.items) - 1

	if head.text == "+" ||
	   head.text == "-" ||
	   head.text == "*" ||
	   head.text == "/" {
		compile_builtin_opcode(builder, head, list.items[1:], dst)
		return
	}

	if (head.text == "%" ||
	    head.text == "=" ||
	    head.text == "!=" ||
	    head.text == "<" ||
	    head.text == "<=" ||
	    head.text == ">" ||
	    head.text == ">=") &&
	   argument_count == 2 {
		compile_builtin_opcode(builder, head, list.items[1:], dst)
		return
	}

	if (head.text == "not" ||
	    head.text == "len") &&
	   argument_count == 1 {
		compile_builtin_opcode(builder, head, list.items[1:], dst)
		return
	}

	if (head.text == "push" && argument_count >= 2) ||
	   (head.text == "pop" && argument_count == 1) {
		compile_builtin_opcode(builder, head, list.items[1:], dst)
		return
	}

	compile_ordinary_call(builder, list, dst)
	return
}

compile_error(fmt.tprintf("undefined name `%s`", head.text))
```

This keeps opcode lowering only for unshadowed globals.

# 14. Update `compile_expr`

Signature:

```odin
compile_expr :: proc(builder: ^CodeBuilder, value: Value, dst: int)
```

Current slot restoration stays, but through builder:

```odin
slot_mark := builder.next_slot
...
builder.next_slot = slot_mark
```

Update cases:

```odin
case .SYMBOL:
	compile_name_expr(builder, cast(^SymbolObject)v, dst)

case .LIST:
	compile_list_expr(builder, cast(^ListObject)v, dst)

case .VECTOR:
	compile_vector_expr(builder, cast(^VectorObject)v, dst)

case .MAP:
	compile_map_expr(builder, cast(^MapObject)v, dst)

case .NATIVE_FUNCTION, .FUNCTION:
	compile_error("runtime function object cannot appear as a literal form")
```

The `.FUNCTION` case is not saying functions are unusable. `(fn ...)` produces a function at runtime. This only says the reader-produced input tree should not already contain a runtime function object literal.

# 15. Update file compilation

## 15.1 `compile_file_forms`

Signature:

```odin
compile_file_forms :: proc(builder: ^CodeBuilder, forms: []Value) -> int
```

Mechanical changes:

```text
claim_slot() -> claim_slot(builder)
compile_def(form) -> compile_def(builder, form)
compile_expr(form, result_slot) -> compile_expr(builder, form, result_slot)
Compiler.next_slot -> builder.next_slot
emit_load_nil(result_slot) -> emit_load_nil(builder, result_slot)
```

Root file defs remain root locals.

## 15.2 `compile_forms`

Replace current `compile_forms :: proc(forms: []Value) -> Code` with:

```odin
compile_forms :: proc(forms: []Value) -> ^Code {
	Compiler.failed = false

	root := begin_code(nil, 0)

	return_slot := compile_file_forms(&root, forms)
	if Compiler.failed {
		delete_code_builder(&root)
		return nil
	}

	emit_return(&root, return_slot)

	return end_code(&root)
}
```

## 15.3 `run_source`

Current:

```odin
code := compile_forms(forms[:])
if Compiler.failed { return Value{} }
defer delete(code.bytecode)
defer delete(code.constants)

return run_code(&code)
```

Replace with:

```odin
code := compile_forms(forms[:])
if Compiler.failed { return Value{} }
defer delete_code(code)

return run_code(code)
```

# 16. Runtime upvalue helpers

Add before `run_code`.

```odin
ensure_slot_count :: proc(vm: ^VM, wanted: int) {
	for len(vm.slots) < wanted {
		append(&vm.slots, Value{})
	}

	if vm.slot_count < wanted {
		vm.slot_count = wanted
	}
}

find_or_create_open_upvalue :: proc(vm: ^VM, absolute_slot: int) -> ^Upvalue {
	for upvalue in vm.open_upvalues {
		if upvalue.slot_index == absolute_slot {
			return upvalue
		}
	}

	upvalue := new(Upvalue)
	upvalue.slot_index = absolute_slot

	append(&vm.open_upvalues, upvalue)
	return upvalue
}

close_upvalues_from :: proc(vm: ^VM, absolute_start: int) {
	for i := 0; i < len(vm.open_upvalues); {
		upvalue := vm.open_upvalues[i]

		if upvalue.slot_index >= absolute_start {
			upvalue.closed = vm.slots[upvalue.slot_index]
			upvalue.slot_index = -1
			ordered_remove(&vm.open_upvalues, i)
			continue
		}

		i += 1
	}
}
```

These helpers are earned:

```text
ensure_slot_count: VM slot storage/high-water rule
find_or_create_open_upvalue: one open upvalue per live slot
close_upvalues_from: open-to-closed lifetime transition
```

# 17. Replace `run_code` with frame execution

Do not bridge the old one-`ip` model. Replace it.

## 17.1 Entry setup

```odin
run_code :: proc(code: ^Code) -> Value {
	vm := Active_VM

	delete(vm.slots)
	vm.slots = make([dynamic]Value)
	vm.slot_count = 0

	clear(&vm.frames)
	clear(&vm.open_upvalues)

	ensure_slot_count(vm, code.frame_slot_count)

	append(&vm.frames, CallFrame{
		code               = code,
		upvalues           = nil,
		instruction_index  = 0,
		slot_base          = 0,
		caller_slot_count  = 0,
	})

	for {
		assert(len(vm.frames) > 0, "VM has no active frame")

		frame := &vm.frames[len(vm.frames) - 1]
		assert(frame.instruction_index < len(frame.code.bytecode), "code ended without RETURN")

		word := frame.code.bytecode[frame.instruction_index]
		frame.instruction_index += 1

		op := InstABC(word).op

		switch op {
		// cases
		}
	}
}
```

Every slot operand is now frame-relative:

```odin
absolute := frame.slot_base + int(inst.a)
```

Constants, globals, jumps, child-code indexes, and upvalue indexes are not frame-relative.

## 17.2 Existing opcode conversion rule

Examples:

```odin
case .LOAD_CONST:
	inst := InstABx(word)
	constant_index := int(inst.b)
	assert(constant_index < len(frame.code.constants), "constant index out of range")
	vm.slots[frame.slot_base + int(inst.a)] = frame.code.constants[constant_index]
```

```odin
case .MOVE:
	inst := InstABC(word)
	vm.slots[frame.slot_base + int(inst.a)] = vm.slots[frame.slot_base + int(inst.b)]
```

Arithmetic window:

```odin
case .ADD, .SUB, .MUL, .DIV:
	inst := InstABC(word)
	dst := frame.slot_base + int(inst.a)
	first_slot := frame.slot_base + int(inst.b)
	argument_count := int(inst.c)
	args := vm.slots[first_slot:first_slot + argument_count]
```

Binary ops:

```odin
dst := frame.slot_base + int(inst.a)
lhs := vm.slots[frame.slot_base + int(inst.b)]
rhs := vm.slots[frame.slot_base + int(inst.c)]
```

`JUMP`:

```odin
frame.instruction_index = int(inst.a)
```

`JUMP_IF_FALSEY`:

```odin
cond := vm.slots[frame.slot_base + int(inst.a)]
if value_is_falsey(cond) {
	frame.instruction_index = int(inst.b)
}
```

## 17.3 New `LOAD_FUNCTION`

```odin
case .LOAD_FUNCTION:
	inst := InstABx(word)
	dst := frame.slot_base + int(inst.a)
	child_index := int(inst.b)

	assert(child_index < len(frame.code.child_codes), "child code index out of range")

	child_code := frame.code.child_codes[child_index]
	function := new_function_object(child_code)

	for i := 0; i < len(child_code.upvalue_descs); i += 1 {
		desc := child_code.upvalue_descs[i]

		if desc.from_parent_local {
			absolute_slot := frame.slot_base + desc.index
			function.upvalues[i] = find_or_create_open_upvalue(vm, absolute_slot)
		} else {
			assert(desc.index < len(frame.upvalues), "parent upvalue index out of range")
			function.upvalues[i] = frame.upvalues[desc.index]
		}
	}

	vm.slots[dst] = Value(cast(^Object)function)
```

## 17.4 New `GET_UPVALUE`

```odin
case .GET_UPVALUE:
	inst := InstABx(word)
	dst := frame.slot_base + int(inst.a)
	upvalue_index := int(inst.b)

	assert(upvalue_index < len(frame.upvalues), "upvalue index out of range")

	upvalue := frame.upvalues[upvalue_index]
	if upvalue.slot_index >= 0 {
		vm.slots[dst] = vm.slots[upvalue.slot_index]
	} else {
		vm.slots[dst] = upvalue.closed
	}
```

## 17.5 New `SET_UPVALUE`

```odin
case .SET_UPVALUE:
	inst := InstABx(word)
	src := frame.slot_base + int(inst.a)
	upvalue_index := int(inst.b)

	assert(upvalue_index < len(frame.upvalues), "upvalue index out of range")

	upvalue := frame.upvalues[upvalue_index]
	if upvalue.slot_index >= 0 {
		vm.slots[upvalue.slot_index] = vm.slots[src]
	} else {
		upvalue.closed = vm.slots[src]
	}
```

## 17.6 New `CLOSE_UPVALUES`

```odin
case .CLOSE_UPVALUES:
	inst := InstABx(word)
	absolute_start := frame.slot_base + int(inst.a)
	close_upvalues_from(vm, absolute_start)
```

## 17.7 Rewrite `CALL`

Keep native/vector/map behavior, but convert to absolute `base`.

Add `.FUNCTION`.

Skeleton:

```odin
case .CALL:
	inst := InstABC(word)
	base := frame.slot_base + int(inst.a)
	argument_count := int(inst.b)
	callee := vm.slots[base]

	callee_object, callee_is_object := callee.(^Object)
	if !callee_is_object {
		runtime_error("value is not callable")
		return Value{}
	}

	args := vm.slots[base + 1:base + 1 + argument_count]

	switch callee_object.kind {
	case .NATIVE_FUNCTION:
		function := cast(^NativeFunctionObject)callee_object

		result := function.native(vm, args)
		if vm.error_string != "" {
			return Value{}
		}

		vm.slots[base] = result

	case .FUNCTION:
		function := cast(^FunctionObject)callee_object

		if argument_count != function.code.param_count {
			runtime_error("function called with wrong number of arguments")
			return Value{}
		}

		callee_slot_base := base + 1
		caller_slot_count := vm.slot_count

		ensure_slot_count(vm, callee_slot_base + function.code.frame_slot_count)

		append(&vm.frames, CallFrame{
			code               = function.code,
			upvalues           = function.upvalues,
			instruction_index  = 0,
			slot_base          = callee_slot_base,
			caller_slot_count  = caller_slot_count,
		})

		continue

	case .VECTOR:
		// same as current, but use absolute base

	case .MAP:
		// same as current, but use absolute base

	case .STRING, .SYMBOL, .LIST:
		runtime_error("value is not callable")
		return Value{}
	}
```

For vector/map cases, replace raw `base` slot math with absolute `base`.

## 17.8 Rewrite `RETURN`

Replace current `RETURN` with:

```odin
case .RETURN:
	inst := InstABx(word)
	result := vm.slots[frame.slot_base + int(inst.a)]

	close_upvalues_from(vm, frame.slot_base)

	if len(vm.frames) == 1 {
		return result
	}

	return_slot := frame.slot_base - 1
	caller_slot_count := frame.caller_slot_count

	pop(&vm.frames)

	vm.slots[return_slot] = result
	vm.slot_count = caller_slot_count
```

Function call layout remains:

```text
caller:
  callee/result slot = base
  arg0 = base + 1
  arg1 = base + 2

callee:
  slot_base = base + 1
  local slot 0 = arg0
  local slot 1 = arg1

return:
  result goes to slot_base - 1
```

# 18. Update object-kind switch sites

After adding `.FUNCTION`, update all `ObjectKind` switches.

## `map_key_hash`

Change:

```odin
case .LIST, .VECTOR, .MAP, .NATIVE_FUNCTION:
```

to:

```odin
case .LIST, .VECTOR, .MAP, .NATIVE_FUNCTION, .FUNCTION:
```

Functions hash by identity.

## `debug_print_value_tree`

Change:

```odin
case .NATIVE_FUNCTION:
	assert(false, "function in source tree")
```

to:

```odin
case .NATIVE_FUNCTION, .FUNCTION:
	assert(false, "runtime function object in reader tree")
```

## `append_value_text`

Change:

```odin
case .NATIVE_FUNCTION:
	append(parts, "<function>")
```

to:

```odin
case .NATIVE_FUNCTION, .FUNCTION:
	append(parts, "<function>")
```

## `core_len`

Change invalid kinds:

```odin
case .SYMBOL, .LIST, .NATIVE_FUNCTION:
```

to:

```odin
case .SYMBOL, .LIST, .NATIVE_FUNCTION, .FUNCTION:
```

## `native_function_predicate`

Change:

```odin
return Value(bool(is_object && object.kind == .NATIVE_FUNCTION))
```

to:

```odin
return Value(bool(is_object && (object.kind == .NATIVE_FUNCTION || object.kind == .FUNCTION)))
```

## `native_copy` and `native_clear`

Add `.FUNCTION` to invalid cases:

```odin
case .STRING, .SYMBOL, .LIST, .NATIVE_FUNCTION, .FUNCTION:
```

## `native_type`

Change:

```odin
case .NATIVE_FUNCTION:
	type_name = "function"
```

to:

```odin
case .NATIVE_FUNCTION, .FUNCTION:
	type_name = "function"
```

## `SET_INDEX`

Change invalid receiver case:

```odin
case .STRING, .SYMBOL, .LIST, .NATIVE_FUNCTION:
```

to:

```odin
case .STRING, .SYMBOL, .LIST, .NATIVE_FUNCTION, .FUNCTION:
```

## `values_equal`

No special change required if it already does:

```odin
if left_object.kind == .STRING {
	...
}

return left_object == right_object
```

Function values compare by object identity.

# 19. Update `make_vm`

Current VM construction should add arrays:

```odin
vm := VM{
	slots         = make([dynamic]Value),
	frames        = make([dynamic]CallFrame),
	open_upvalues = make([dynamic]^Upvalue),

	globals = make([dynamic]GlobalBinding),
	symbols = make([dynamic]^SymbolObject),
}
```

Keep native globals as-is.

# 20. Mechanical replacement checklist

After the refactor, these should be gone:

```text
Active_Code
Compiler.local_bindings
Compiler.local_count
Compiler.current_scope_local_start
Compiler.next_slot
current_builder
Compiler.builders
ResolvedName
NameResolution
```

These should remain:

```text
Compiler.failed
CodeBuilder.local_bindings
CodeBuilder.local_count
CodeBuilder.current_scope_local_start
CodeBuilder.next_slot
```

Every compiler proc should thread `builder`.

Expected signatures:

```odin
const_value(builder: ^CodeBuilder, value: Value) -> int
record_slots(builder: ^CodeBuilder, slots: ..int)

claim_slot(builder: ^CodeBuilder) -> int
reserve_slots_until(builder: ^CodeBuilder, slot_after_last: int)
find_local(builder: ^CodeBuilder, symbol: ^SymbolObject) -> (int, bool)

compile_constant(builder: ^CodeBuilder, value: Value, dst: int)
compile_name_expr(builder: ^CodeBuilder, symbol: ^SymbolObject, dst: int)
compile_vector_expr(builder: ^CodeBuilder, vector: ^VectorObject, dst: int)
compile_map_expr(builder: ^CodeBuilder, map_object: ^MapObject, dst: int)
compile_def(builder: ^CodeBuilder, form: Value)
compile_body(builder: ^CodeBuilder, forms: []Value, dst: int)
compile_do(builder: ^CodeBuilder, list: ^ListObject, dst: int)
compile_if(builder: ^CodeBuilder, list: ^ListObject, dst: int)
compile_while(builder: ^CodeBuilder, list: ^ListObject, dst: int)
compile_set(builder: ^CodeBuilder, list: ^ListObject, dst: int)
compile_fn(parent: ^CodeBuilder, list: ^ListObject, dst: int)
compile_ordinary_call(builder: ^CodeBuilder, list: ^ListObject, dst: int)
compile_builtin_opcode(builder: ^CodeBuilder, symbol: ^SymbolObject, args: []Value, dst: int)
compile_list_expr(builder: ^CodeBuilder, list: ^ListObject, dst: int)
compile_expr(builder: ^CodeBuilder, value: Value, dst: int)
compile_file_forms(builder: ^CodeBuilder, forms: []Value) -> int
compile_forms(forms: []Value) -> ^Code
```

# 21. Recommended implementation order

Do it in this order.

## Step 1: Data model only

Add:

```text
ObjectKind.FUNCTION
UpvalueDesc
Upvalue
Code with slices
FunctionObject
CallFrame
CodeBuilder
VM.frames / slot_count / open_upvalues
```

Do not touch compiler yet except to make the file compile toward new structs.

## Step 2: CodeBuilder threading

Refactor emitters and compiler functions to take `^CodeBuilder`.

At this point, `fn` can still be unimplemented.

Goal: old non-function programs compile and run under the old `run_code` only temporarily if you want an intermediate checkpoint, but do not keep this as final architecture.

## Step 3: finalized Code lifetime

Implement:

```text
begin_code
end_code
delete_code
delete_code_builder
compile_forms -> ^Code
run_source defer delete_code(code)
```

## Step 4: frame VM

Rewrite `run_code` to use `CallFrame`.

Before adding `fn`, make existing programs pass:

```scheme
(+ 1 2)
```

```scheme
(do
  (def x 10)
  (+ x 1))
```

```scheme
(def v [10 20])
(push v 30)
(v 2)
```

If these fail, the bug is probably missing `frame.slot_base +`.

## Step 5: zero-capture `fn`

Add:

```text
FunctionObject
LOAD_FUNCTION
CALL .FUNCTION
compile_fn
```

Test:

```scheme
(def inc
  (fn (x)
    (+ x 1)))

(inc 10)
```

Expected:

```text
11
```

Also:

```scheme
((fn (x) (+ x 1)) 10)
```

Expected:

```text
11
```

## Step 6: upvalue read

Add:

```text
find_upvalue
add_upvalue
resolve_upvalue
GET_UPVALUE
LOAD_FUNCTION upvalue wiring
compile_name_expr upvalue branch
```

Test:

```scheme
(def make-adder
  (fn (n)
    (fn (x)
      (+ x n))))

(def add10 (make-adder 10))
(add10 5)
```

Expected:

```text
15
```

## Step 7: upvalue write

Add:

```text
SET_UPVALUE
compile_set upvalue branch
```

Test:

```scheme
(def make-counter
  (fn ()
    (def n 0)

    (fn ()
      (set n (+ n 1))
      n)))

(def c (make-counter))

(print (c))
(print (c))
```

Expected:

```text
1
2
```

## Step 8: open upvalue sharing

Make sure `find_or_create_open_upvalue` is used by `LOAD_FUNCTION`.

Test:

```scheme
(def make-pair
  (fn ()
    (def x 0)

    [(fn ()
       (set x (+ x 1))
       x)

     (fn ()
       x)]))

(def pair (make-pair))
(def inc (pair 0))
(def get (pair 1))

(print (inc))
(print (get))
```

Expected:

```text
1
1
```

If this prints `1` then `0`, open upvalue sharing is broken.

## Step 9: deep forwarding

Test:

```scheme
(def outer
  (fn ()
    (def x 10)

    (fn ()
      (fn ()
        x))))

(def middle (outer))
(def inner (middle))

(inner)
```

Expected:

```text
10
```

If this fails at compile time, `resolve_upvalue` forwarding is wrong.

If this fails at runtime, `LOAD_FUNCTION` handling of `from_parent_local = false` is wrong.

## Step 10: lexical scope close

Add/verify:

```text
CLOSE_UPVALUES emitted in do scope exit
CLOSE_UPVALUES emitted in while body scope exit
RETURN closes frame
```

Test:

```scheme
(def f
  (do
    (def x 10)
    (fn () x)))

(f)
```

Expected:

```text
10
```

# 22. Tests for semantics we explicitly want

## Ordinary function-valued `def` is not self-recursive

```scheme
(def fact
  (fn (n)
    (fact (- n 1))))
```

Expected:

```text
compile error: undefined name `fact`
```

That is correct.

## Manual recursion works

```scheme
(def fact nil)

(set fact
  (fn (n)
    (if (= n 0)
      1
      (* n (fact (- n 1))))))

(fact 5)
```

Expected:

```text
120
```

Because `fact` exists before the `fn` body is compiled.

## Top-level capture and mutation

```scheme
(def x 10)

(def f
  (fn ()
    x))

(print (f))

(set x 20)

(print (f))
```

Expected:

```text
10
20
```

Root file locals are just frame locals, and closures capture them like any other outer binding.

# 23. Do not add these

Do not add:

```text
slot_initialized
GET_LOCAL
STORE_LOCAL
BEGIN_DEF
INIT_LOCAL
BindingStorage
runtime Binding object
cell stack
location ^Value in Upvalue
ResolvedName
NameResolution
Compiler.builders
current_builder()
named function def
```

If one of those seems necessary, the implementation has drifted from the chosen model.

# 24. The sharp edges

## Frame-relative slots

Every bytecode operand that names a slot must be offset:

```odin
absolute := frame.slot_base + int(inst.a)
```

Do not offset:

```text
constant indexes
global indexes
jump targets
child code indexes
upvalue indexes
```

## Lexical shadowing of builtin opcodes

Do not optimize a call head to a core opcode if any lexical binding exists for that symbol.

This must compile as an ordinary call:

```scheme
(def + (fn (a b) 999))
(+ 1 2)
```

This must also compile as ordinary call through an upvalue:

```scheme
(do
  (def + (fn (a b) 999))
  (fn ()
    (+ 1 2)))
```

That is why `lexical_name_visible` exists.

## Upvalue closing in `do` / `while`

Returning from a function is not enough. Rite has lexical scopes inside a frame.

This must work:

```scheme
(def f
  (do
    (def x 10)
    (fn () x)))
```

So `compile_do` must emit `CLOSE_UPVALUES slot_mark`.

`compile_while` must close the body-scope slots before jumping back.

## Finished Code owns child Code

After `end_code`, parent `Code` owns child `Code` pointers.

After compile failure, unfinished `CodeBuilder` owns any child `Code` already appended to it.

That is the whole reason for both:

```text
delete_code
delete_code_builder
```

No extra cleanup stack is needed.
