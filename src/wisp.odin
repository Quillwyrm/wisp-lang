package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"


// Value model ====================================================================================

ObjectKind :: enum u8 {
	STRING,
	SYMBOL,
	LIST,
	VECTOR,
	NATIVE_FUNCTION,
}

// Every heap object starts with this header so ^Object can dispatch by kind.
Object :: struct {
	kind: ObjectKind,
}

StringObject :: struct {
	header: Object,
	text:   string,
}

SymbolObject :: struct {
	header: Object,
	text:   string,
}

ListObject :: struct {
	header: Object,

	// Lists are immutable Wisp values. This storage is built once and is not mutated by language operations.
	items: [dynamic]Value,
}

VectorObject :: struct {
	header: Object,
	items:  [dynamic]Value,
}

// The zero value of this union represents Wisp nil.
Value :: union {
	bool,
	i64,
	f64,
	^Object,
}

// args borrows a contiguous VM slot range for the duration of the call.
// Native procs must not retain the slice.
NativeProc :: proc(vm: ^VM, args: []Value) -> Value

NativeFunctionObject :: struct {
	header: Object,
	native: NativeProc,
}


// VM data ========================================================================================

Opcode :: enum u8 {
	LOAD_NIL,   // ABx: A=dst
	LOAD_TRUE,  // ABx: A=dst
	LOAD_FALSE, // ABx: A=dst
	LOAD_CONST, // ABx: A=dst, Bx=constant index

	MOVE, // ABC: A=dst, B=src

	GET_GLOBAL, // ABx: A=dst, Bx=global index

	ADD, // ABC: A=dst, B=first operand, C=operand count
	SUB, // ABC: A=dst, B=first operand, C=operand count
	MUL, // ABC: A=dst, B=first operand, C=operand count
	DIV, // ABC: A=dst, B=first operand, C=operand count

	CALL, // ABC: A=callee, B=argument count -> result replaces A; arguments start at A+1

	NEW_VECTOR,  // ABx: A=dst, Bx=initial capacity hint
	VECTOR_PUSH, // ABC: A=vector, B=value -> A remains the vector
	VECTOR_POP,  // ABC: A=dst, B=vector -> removed value goes to A
	SET_VECTOR,  // ABC: A=vector, B=index, C=value -> expression result remains in C

	RETURN, // ABx: A=src
}

InstABC :: bit_field u32 {
	op: Opcode | 8,
	a:  u8     | 8,
	b:  u8     | 8,
	c:  u8     | 8,
}

InstABx :: bit_field u32 {
	op: Opcode | 8,
	a:  u8     | 8,
	b:  u16    | 16,
}

// Finished executable chunk owning its bytecode and constants.
Code :: struct {
	bytecode:         [dynamic]u32,
	constants:        [dynamic]Value,
	frame_slot_count: int,
}

// Append-only globals keep stable indexes embedded in bytecode.
GlobalBinding :: struct {
	symbol:  ^SymbolObject,
	value:   Value,
	mutable: bool,
}

// Mutable one-code build state transferred by end_code.
Active_Code: Code

// One host-owned execution world; globals persist while slots reset per run.
VM :: struct {
	slots:        [dynamic]Value,
	globals:      [dynamic]GlobalBinding,
	symbols:      [dynamic]^SymbolObject,
	// Current host-operation diagnostic; empty means no error.
	error_string: string,
}

// Compiler and runtime entry procs select the VM used by internal helpers.
Active_VM: ^VM


// Compiler data ==================================================================================

MAX_FRAME_SLOTS :: int(max(u8)) + 1

LocalBinding :: struct {
	symbol: ^SymbolObject,
	slot:   int,
}

// Visible binding entries occupy 0..<local_count; explicit slots may sit above
// live outer expressions. next_slot is the first unreserved frame slot.
Compiler := struct {
	// A failed build is disposable; its diagnostic lives in Active_VM.error_string.
	failed: bool,

	local_bindings: [MAX_FRAME_SLOTS]LocalBinding,
	local_count:    int,

	// Begins duplicate-definition checks for the current lexical scope.
	current_scope_local_start: int,
	next_slot:                 int,
}{}

// Single-active reader; failed poisons the current read until read_source resets it.
Reader := struct {
	source: string,
	index:  int,
	failed: bool,
}{}


// Errors =========================================================================================

// error_string is either empty or cloned storage owned by the VM.
clear_error :: proc(vm: ^VM) {
	if vm.error_string != "" {
		delete(vm.error_string)
		vm.error_string = ""
	}
}

set_error :: proc(text: string) {
	assert(text != "", "set_error requires non-empty text")
	assert(Active_VM.error_string == "", "set_error called while an error is already active")
	Active_VM.error_string = strings.clone(text)
}

reader_error :: proc(message: string) {
	if Reader.failed { return }

	Reader.failed = true
	set_error(fmt.tprintf("read error at byte %d: %s", Reader.index, message))
}

compile_error :: proc(message: string) {
	if Compiler.failed { return }

	Compiler.failed = true
	set_error(fmt.tprintf("compile error: %s", message))
}

runtime_error :: proc(message: string) {
	set_error(fmt.tprintf("runtime error: %s", message))
}


// Symbol interning ===============================================================================

// Symbols currently represent source atoms used as names.
// User-visible symbol values remain deferred.
// Equal symbol text always returns the same SymbolObject pointer.
intern_symbol :: proc(vm: ^VM, text: string) -> ^SymbolObject {
	for symbol in vm.symbols {
		if symbol.text == text { return symbol }
	}

	symbol := new(SymbolObject)
	symbol.header.kind = .SYMBOL
	// Copy text because interned symbols outlive Reader.source.
	symbol.text = strings.clone(text)

	append(&vm.symbols, symbol)
	return symbol
}


// Object construction ============================================================================

new_string_object :: proc(text: string) -> ^StringObject {
	object := new(StringObject)
	object.header.kind = .STRING
	// Copy text because the returned object may outlive Reader.source.
	object.text = strings.clone(text)
	return object
}

// Aggregate constructors take ownership of the dynamic item array.
new_list_object :: proc(items: [dynamic]Value) -> ^ListObject {
	object := new(ListObject)
	object.header.kind = .LIST
	object.items = items
	return object
}

new_vector_object :: proc(items: [dynamic]Value) -> ^VectorObject {
	object := new(VectorObject)
	object.header.kind = .VECTOR
	object.items = items
	return object
}


// Reader character utilities =====================================================================

is_digit :: proc(ch: u8) -> bool {
	return ch >= '0' && ch <= '9'
}

is_whitespace :: proc(ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n'
}

is_delimiter :: proc(ch: u8) -> bool {
	return is_whitespace(ch) ||
	       ch == '(' ||
	       ch == ')' ||
	       ch == '"' ||
	       ch == '\'' ||
	       ch == ';' ||
	       ch == '[' ||
	       ch == ']'
}

// Leaves Reader.index at the next form byte or the end of source.
skip_trivia :: proc() {
	for Reader.index < len(Reader.source) {
		ch := Reader.source[Reader.index]

		if is_whitespace(ch) {
			Reader.index += 1
			continue
		}

		if ch == ';' {
			for Reader.index < len(Reader.source) && Reader.source[Reader.index] != '\n' {
				Reader.index += 1
			}
			continue
		}

		break
	}
}


// Reader scans ===================================================================================

read_atom :: proc() -> Value {
	// The caller positions Reader.index at the first byte of an atom.
	token_start := Reader.index

	// Stop before the delimiter so the enclosing reader can consume it.
	for Reader.index < len(Reader.source) && !is_delimiter(Reader.source[Reader.index]) {
		Reader.index += 1
	}

	text := Reader.source[token_start:Reader.index]
	if text == "nil" { return Value{} }
	if text == "true" { return Value(bool(true)) }
	if text == "false" { return Value(bool(false)) }

	// Numeric-looking atoms start with a digit, .digit, -digit, or - followed by a dot.
	looks_numeric :=
		is_digit(text[0]) ||
		(len(text) > 1 && text[0] == '.' && is_digit(text[1])) ||
		(len(text) > 1 && text[0] == '-' &&
			(is_digit(text[1]) || text[1] == '.'))

	// Malformed numeric-looking atoms are errors; other atoms become symbols.
	if looks_numeric {
		number_index := 0
		is_negative := false

		if text[number_index] == '-' {
			is_negative = true
			number_index += 1
		}

		// Scan decimal digits on either side of an optional decimal point.
		digit_count := 0
		for number_index < len(text) && is_digit(text[number_index]) {
			digit_count += 1
			number_index += 1
		}

		is_float := number_index < len(text) && text[number_index] == '.'
		if is_float {
			number_index += 1

			for number_index < len(text) && is_digit(text[number_index]) {
				digit_count += 1
				number_index += 1
			}
		}

		// Valid numbers contain a digit and consume the entire atom.
		if digit_count == 0 || number_index != len(text) {
			reader_error("invalid number literal")
			return Value{}
		}

		// Odin converts the value only after Wisp accepts its spelling.
		if is_float {
			float_value, float_ok := strconv.parse_f64(text)
			if !float_ok {
				reader_error("float literal out of range")
				return Value{}
			}

			return Value(float_value)
		}

		// Unsigned magnitude handles the extra negative i64 value without overflow.
		magnitude_limit := u64(max(i64))
		if is_negative {
			magnitude_limit += 1
		}

		magnitude: u64
		digit_index := 1 if is_negative else 0

		for digit_index < len(text) {
			digit := u64(text[digit_index] - '0')

			if magnitude > (magnitude_limit - digit) / 10 {
				reader_error("integer literal out of range")
				return Value{}
			}

			magnitude = magnitude * 10 + digit
			digit_index += 1
		}

		if is_negative {
			if magnitude == magnitude_limit { return Value(min(i64)) }
			return Value(-i64(magnitude))
		}

		return Value(i64(magnitude))
	}

	return Value(cast(^Object)intern_symbol(Active_VM, text))
}

read_string :: proc() -> Value {
	Reader.index += 1
	start := Reader.index

	for Reader.index < len(Reader.source) {
		ch := Reader.source[Reader.index]

		if ch == '\n' || ch == '\r' {
			reader_error("unterminated string")
			return Value{}
		}

		if ch == '\\' {
			reader_error("string escapes not implemented")
			return Value{}
		}

		if ch == '"' {
			text := Reader.source[start:Reader.index]
			Reader.index += 1
			return Value(cast(^Object)new_string_object(text))
		}

		Reader.index += 1
	}

	reader_error("unterminated string")
	return Value{}
}

read_list :: proc() -> Value {
	Reader.index += 1

	// Build locally; the ListObject takes ownership only after the closing ')'.
	items := make([dynamic]Value)

	for {
		skip_trivia()

		if Reader.index >= len(Reader.source) {
			reader_error("unterminated list")
			delete(items)
			return Value{}
		}

		if Reader.source[Reader.index] == ')' {
			Reader.index += 1
			return Value(cast(^Object)new_list_object(items))
		}

		item := read_form()
		if Reader.failed {
			delete(items)
			return Value{}
		}

		append(&items, item)
	}
}

read_vector :: proc() -> Value {
	Reader.index += 1

	// Build locally; the VectorObject takes ownership only after the closing ']'.
	items := make([dynamic]Value)

	for {
		skip_trivia()

		if Reader.index >= len(Reader.source) {
			reader_error("unterminated vector")
			delete(items)
			return Value{}
		}

		if Reader.source[Reader.index] == ']' {
			Reader.index += 1
			return Value(cast(^Object)new_vector_object(items))
		}

		item := read_form()
		if Reader.failed {
			delete(items)
			return Value{}
		}

		append(&items, item)
	}
}

read_form :: proc() -> Value {
	// Whitespace is already skipped; this proc only dispatches the current form.
	ch := Reader.source[Reader.index]

	switch ch {
	case '(':
		return read_list()

	case ')':
		reader_error("unexpected ')'")
		return Value{}

	case '"':
		return read_string()

	case '\'':
		reader_error("quote not implemented")
		return Value{}

	case '[':
		return read_vector()

	case ']':
		reader_error("unexpected ']'")
		return Value{}

	case:
		return read_atom()
	}
}

read_all_forms :: proc() -> [dynamic]Value {
	// This loop owns whitespace between top-level forms.
	forms := make([dynamic]Value)

	for {
		skip_trivia()

		if Reader.index >= len(Reader.source) {
			break
		}

		form := read_form()
		if Reader.failed {
			return forms
		}

		append(&forms, form)
	}

	return forms
}

read_source :: proc(source: string) -> [dynamic]Value {
	Reader.source = source
	Reader.index = 0
	Reader.failed = false

	forms := read_all_forms()
	Reader.source = ""

	if Reader.failed {
		delete(forms)
		return nil
	}

	return forms
}


// Debug tree printer =============================================================================

// Each entry says whether that ancestor has another sibling below it.
debug_print_value_tree :: proc(value: Value, continuations: ^[dynamic]bool) {
	for i := 0; i + 1 < len(continuations); i += 1 {
		if continuations[i] {
			fmt.print("│  ")
		} else {
			fmt.print("   ")
		}
	}

	if len(continuations) > 0 {
		if continuations[len(continuations) - 1] {
			fmt.print("├─ ")
		} else {
			fmt.print("└─ ")
		}
	}

	if value == nil {
		fmt.println("Nil")
		return
	}

	switch v in value {
	case bool:
		fmt.printf("Bool(%v)\n", v)

	case i64:
		fmt.printf("Int(%d)\n", v)

	case f64:
		fmt.printf("Float(%.15g)\n", v)

	case ^Object:
		switch v.kind {
		case .STRING:
			object := cast(^StringObject)v
			fmt.printf("String(\"%s\")\n", object.text)

		case .SYMBOL:
			object := cast(^SymbolObject)v
			fmt.printf("Symbol(`%s`)\n", object.text)

		case .LIST:
			object := cast(^ListObject)v
			fmt.printf("List(%d)\n", len(object.items))

			for i := 0; i < len(object.items); i += 1 {
				append(continuations, i + 1 < len(object.items))
				debug_print_value_tree(object.items[i], continuations)
				pop(continuations)
			}

		case .VECTOR:
			object := cast(^VectorObject)v
			fmt.printf("Vector(%d)\n", len(object.items))

			for i := 0; i < len(object.items); i += 1 {
				append(continuations, i + 1 < len(object.items))
				debug_print_value_tree(object.items[i], continuations)
				pop(continuations)
			}

		case .NATIVE_FUNCTION:
			assert(false, "function in source tree")
		}
	}
}

debug_print_source_tree :: proc(forms: [dynamic]Value) {
	continuations := make([dynamic]bool)

	for i := 0; i < len(forms); i += 1 {
		debug_print_value_tree(forms[i], &continuations)

		if i + 1 < len(forms) {
			fmt.println()
		}
	}

	delete(continuations)
}


// Runtime display ================================================================================

// parents contains only composite objects currently above this value.
print_value_inner :: proc(value: Value, parents: ^[dynamic]^Object) {
	if value == nil {
		fmt.print("nil")
		return
	}

	switch v in value {
	case bool:
		fmt.print(v)

	case i64:
		fmt.print(v)

	case f64:
		text := fmt.tprintf("%.15g", v)
		fmt.print(text)

		whole_number_text := true
		for i := 0; i < len(text); i += 1 {
			if i == 0 && text[i] == '-' {
				continue
			}
			if !is_digit(text[i]) {
				whole_number_text = false
				break
			}
		}

		if whole_number_text {
			fmt.print(".0")
		}

	case ^Object:
		switch v.kind {
		case .STRING:
			object := cast(^StringObject)v
			fmt.print(object.text)

		case .SYMBOL:
			object := cast(^SymbolObject)v
			fmt.printf("<symbol %s>", object.text)

		case .LIST:
			for parent in parents {
				if parent == v {
					fmt.print("(...)")
					return
				}
			}
			append(parents, v)

			object := cast(^ListObject)v
			fmt.print("(")
			for i := 0; i < len(object.items); i += 1 {
				if i > 0 {
					fmt.print(" ")
				}
				print_value_inner(object.items[i], parents)
			}
			fmt.print(")")

			pop(parents)

		case .VECTOR:
			for parent in parents {
				if parent == v {
					fmt.print("[...]")
					return
				}
			}
			append(parents, v)

			object := cast(^VectorObject)v
			fmt.print("[")
			for i := 0; i < len(object.items); i += 1 {
				if i > 0 {
					fmt.print(" ")
				}
				print_value_inner(object.items[i], parents)
			}
			fmt.print("]")

			pop(parents)

		case .NATIVE_FUNCTION:
			fmt.print("<function>")

		case:
			assert(false, "invalid object tag")
		}
	}
}

print_value :: proc(value: Value) {
	parents := make([dynamic]^Object)
	print_value_inner(value, &parents)
	delete(parents)
}


// Globals ========================================================================================

find_global :: proc(vm: ^VM, symbol: ^SymbolObject) -> (int, bool) {
	for i := 0; i < len(vm.globals); i += 1 {
		if vm.globals[i].symbol == symbol {
			return i, true
		}
	}

	return -1, false
}

// Supplied native globals are immutable but may be shadowed by user bindings.
bind_native_global :: proc(vm: ^VM, name: string, native: NativeProc) -> int {
	symbol := intern_symbol(vm, name)
	_, found := find_global(vm, symbol)
	assert(!found, "duplicate supplied global binding")

	function := new(NativeFunctionObject)
	function.header.kind = .NATIVE_FUNCTION
	function.native = native

	append(&vm.globals, GlobalBinding{
		symbol  = symbol,
		value   = Value(cast(^Object)function),
		mutable = false,
	})
	return len(vm.globals) - 1
}


// Code construction ==============================================================================

begin_code :: proc() {
	Active_Code = Code{
		bytecode         = make([dynamic]u32),
		constants        = make([dynamic]Value),
		frame_slot_count = 0,
	}
}

// The returned Code takes ownership of the active dynamic arrays.
end_code :: proc() -> Code {
	code := Active_Code
	Active_Code = Code{}
	return code
}


// Constants ======================================================================================

const_value :: proc(value: Value) -> int {
	append(&Active_Code.constants, value)
	return len(Active_Code.constants) - 1
}


// Bytecode emission ==============================================================================

// frame_slot_count is the highest touched frame slot plus one.
record_slots :: proc(slots: ..int) {
	for slot in slots {
		assert(slot >= 0 && slot <= int(max(u8)), "frame slot does not fit u8")

		needed_slot_count := slot + 1
		if needed_slot_count > Active_Code.frame_slot_count {
			Active_Code.frame_slot_count = needed_slot_count
		}
	}
}

emit_ABC :: proc(op: Opcode, a, b, c: int) {
	append(&Active_Code.bytecode, u32(InstABC{
		op = op,
		a  = u8(a),
		b  = u8(b),
		c  = u8(c),
	}))
}

emit_ABx :: proc(op: Opcode, a, b: int) {
	append(&Active_Code.bytecode, u32(InstABx{
		op = op,
		a  = u8(a),
		b  = u16(b),
	}))
}

emit_load_nil :: proc(dst: int) {
	record_slots(dst)
	emit_ABx(.LOAD_NIL, dst, 0)
}

emit_load_true :: proc(dst: int) {
	record_slots(dst)
	emit_ABx(.LOAD_TRUE, dst, 0)
}

emit_load_false :: proc(dst: int) {
	record_slots(dst)
	emit_ABx(.LOAD_FALSE, dst, 0)
}

emit_load_const :: proc(dst, constant_index: int) {
	record_slots(dst)
	emit_ABx(.LOAD_CONST, dst, constant_index)
}

emit_move :: proc(dst, src: int) {
	record_slots(dst, src)
	emit_ABC(.MOVE, dst, src, 0)
}

emit_get_global :: proc(dst, global_index: int) {
	record_slots(dst)
	emit_ABx(.GET_GLOBAL, dst, global_index)
}

emit_add :: proc(dst, first_slot, count: int) {
	assert(count >= 0 && count <= int(max(u8)), "ADD argument count does not fit u8")
	record_slots(dst)
	if count > 0 {
		record_slots(first_slot, first_slot + count - 1)
	}
	emit_ABC(.ADD, dst, first_slot, count)
}

emit_sub :: proc(dst, first_slot, count: int) {
	assert(count >= 0 && count <= int(max(u8)), "SUB argument count does not fit u8")
	record_slots(dst)
	if count > 0 {
		record_slots(first_slot, first_slot + count - 1)
	}
	emit_ABC(.SUB, dst, first_slot, count)
}

emit_mul :: proc(dst, first_slot, count: int) {
	assert(count >= 0 && count <= int(max(u8)), "MUL argument count does not fit u8")
	record_slots(dst)
	if count > 0 {
		record_slots(first_slot, first_slot + count - 1)
	}
	emit_ABC(.MUL, dst, first_slot, count)
}

emit_div :: proc(dst, first_slot, count: int) {
	assert(count >= 0 && count <= int(max(u8)), "DIV argument count does not fit u8")
	record_slots(dst)
	if count > 0 {
		record_slots(first_slot, first_slot + count - 1)
	}
	emit_ABC(.DIV, dst, first_slot, count)
}

emit_call :: proc(base, argument_count: int) {
	assert(argument_count >= 0 && argument_count <= int(max(u8)), "call argument count does not fit u8")

	record_slots(base)
	if argument_count > 0 {
		record_slots(base + argument_count)
	}
	emit_ABC(.CALL, base, argument_count, 0)
}

emit_new_vector :: proc(dst, capacity: int) {
	assert(capacity >= 0 && capacity <= int(max(u16)), "vector capacity does not fit u16")
	record_slots(dst)
	emit_ABx(.NEW_VECTOR, dst, capacity)
}

emit_vector_push :: proc(vector_slot, value_slot: int) {
	record_slots(vector_slot, value_slot)
	emit_ABC(.VECTOR_PUSH, vector_slot, value_slot, 0)
}

emit_vector_pop :: proc(dst, vector_slot: int) {
	record_slots(dst, vector_slot)
	emit_ABC(.VECTOR_POP, dst, vector_slot, 0)
}

emit_set_vector :: proc(vector_slot, index_slot, value_slot: int) {
	record_slots(vector_slot, index_slot, value_slot)
	emit_ABC(.SET_VECTOR, vector_slot, index_slot, value_slot)
}

emit_return :: proc(src: int) {
	record_slots(src)
	emit_ABx(.RETURN, src, 0)
}


// Compiler =======================================================================================

// Claims one frame slot above every value and binding that is currently live.
claim_slot :: proc() -> int {
	if Compiler.next_slot >= MAX_FRAME_SLOTS {
		compile_error("code uses too many frame slots")
		return 0
	}

	slot := Compiler.next_slot
	Compiler.next_slot += 1
	return slot
}

// Reserves a contiguous slot range ending immediately before slot_after_last.
reserve_slots_until :: proc(slot_after_last: int) {
	if slot_after_last > MAX_FRAME_SLOTS {
		compile_error("code uses too many frame slots")
		return
	}

	if Compiler.next_slot < slot_after_last {
		Compiler.next_slot = slot_after_last
	}
}

// Searches visible bindings from newest to oldest.
find_local :: proc(symbol: ^SymbolObject) -> (int, bool) {
	for i := Compiler.local_count - 1; i >= 0; i -= 1 {
		if Compiler.local_bindings[i].symbol == symbol {
			return Compiler.local_bindings[i].slot, true
		}
	}

	return -1, false
}

form_is_definition :: proc(value: Value) -> bool {
	object, is_object := value.(^Object)
	if !is_object || object.kind != .LIST {
		return false
	}

	list := cast(^ListObject)object
	if len(list.items) == 0 {
		return false
	}

	head, head_is_object := list.items[0].(^Object)
	if !head_is_object || head.kind != .SYMBOL {
		return false
	}

	return (cast(^SymbolObject)head).text == "def"
}

compile_constant :: proc(value: Value, dst: int) {
	if len(Active_Code.constants) > int(max(u16)) {
		compile_error("code uses too many constants")
		return
	}

	constant_index := const_value(value)
	emit_load_const(dst, constant_index)
}

compile_name_expr :: proc(symbol: ^SymbolObject, dst: int) {
	local_slot, local_found := find_local(symbol)
	if local_found {
		emit_move(dst, local_slot)
		return
	}

	global_index, global_found := find_global(Active_VM, symbol)
	if global_found {
		if global_index > int(max(u16)) {
			compile_error("global binding index does not fit bytecode")
			return
		}

		emit_get_global(dst, global_index)
		return
	}

	compile_error(fmt.tprintf("undefined name `%s`", symbol.text))
}

compile_vector_expr :: proc(vector: ^VectorObject, dst: int) {
	// Pushes determine length; this only avoids backing-storage growth.
	capacity_hint := len(vector.items)
	if capacity_hint > int(max(u16)) {
		capacity_hint = int(max(u16))
	}

	emit_new_vector(dst, capacity_hint)

	if len(vector.items) == 0 {
		return
	}

	item_slot := claim_slot()
	if Compiler.failed { return }

	for item in vector.items {
		compile_expr(item, item_slot)
		if Compiler.failed { return }

		emit_vector_push(dst, item_slot)
	}
}

compile_def :: proc(form: Value) {
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
	if name.text == "def" ||
	   name.text == "set" ||
	   name.text == "do" ||
	   name.text == "if" ||
	   name.text == "while" ||
	   name.text == "fn" {
		compile_error(fmt.tprintf("cannot define reserved name `%s`", name.text))
		return
	}

	for i := Compiler.current_scope_local_start; i < Compiler.local_count; i += 1 {
		if Compiler.local_bindings[i].symbol == name {
			compile_error(fmt.tprintf("duplicate definition `%s` in the same scope", name.text))
			return
		}
	}

	binding_slot := claim_slot()
	if Compiler.failed { return }

	// The binding becomes visible only after its value has been compiled.
	compile_expr(list.items[2], binding_slot)
	if Compiler.failed { return }

	Compiler.local_bindings[Compiler.local_count] = LocalBinding{
		symbol = name,
		slot   = binding_slot,
	}
	Compiler.local_count += 1
}

// Definitions persist through the body; the final form supplies dst.
// Empty bodies produce nil, and non-final expression results are discarded.
compile_body :: proc(forms: []Value, dst: int) {
	if len(forms) == 0 {
		emit_load_nil(dst)
		return
	}

	for i := 0; i < len(forms); i += 1 {
		form := forms[i]
		is_last := i + 1 == len(forms)

		if form_is_definition(form) {
			if is_last {
				compile_error("body cannot end with a definition")
				return
			}

			compile_def(form)
			if Compiler.failed { return }
			continue
		}

		if is_last {
			compile_expr(form, dst)
			return
		}

		slot_mark := Compiler.next_slot
		discard_slot := claim_slot()
		if Compiler.failed { return }

		compile_expr(form, discard_slot)
		if Compiler.failed { return }

		Compiler.next_slot = slot_mark
	}
}

compile_do :: proc(list: ^ListObject, dst: int) {
	// A do body owns its bindings and restores the outer live-slot boundary.
	local_mark := Compiler.local_count
	slot_mark := Compiler.next_slot
	outer_scope_start := Compiler.current_scope_local_start

	Compiler.current_scope_local_start = local_mark
	compile_body(list.items[1:], dst)

	Compiler.local_count = local_mark
	Compiler.next_slot = slot_mark
	Compiler.current_scope_local_start = outer_scope_start
}

compile_set :: proc(list: ^ListObject, dst: int) {
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

		binding_slot, local_found := find_local(symbol)
		if local_found {
			// Visible binding slots are not general expression destinations.
			// Compile the complete RHS into dst before updating the binding.
			compile_expr(value, dst)
			if Compiler.failed { return }

			emit_move(binding_slot, dst)
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

		receiver_slot := claim_slot()
		index_slot := claim_slot()
		if Compiler.failed { return }

		compile_expr(target_list.items[0], receiver_slot)
		if Compiler.failed { return }

		compile_expr(target_list.items[1], index_slot)
		if Compiler.failed { return }

		compile_expr(value, dst)
		if Compiler.failed { return }

		emit_set_vector(receiver_slot, index_slot, dst)
		return
	}

	compile_error("invalid `set` target")
}

compile_ordinary_call :: proc(list: ^ListObject, dst: int) {
	argument_count := len(list.items) - 1
	if argument_count > int(max(u8)) {
		compile_error("call has too many arguments")
		return
	}

	// CALL needs a contiguous callee/result and argument window above live slots.
	base := Compiler.next_slot
	reserve_slots_until(base + argument_count + 1)
	if Compiler.failed { return }

	compile_expr(list.items[0], base)
	if Compiler.failed { return }

	for i := 0; i < argument_count; i += 1 {
		compile_expr(list.items[i + 1], base + 1 + i)
		if Compiler.failed { return }
	}

	emit_call(base, argument_count)
	emit_move(dst, base)
}

compile_builtin_opcode :: proc(symbol: ^SymbolObject, args: []Value, dst: int) {
	// The caller has already resolved an unshadowed supplied builtin.
	if symbol.text == "+" ||
	   symbol.text == "-" ||
	   symbol.text == "*" ||
	   symbol.text == "/" {
		operand_count := len(args)
		if operand_count > int(max(u8)) {
			compile_error(fmt.tprintf("`%s` has too many arguments", symbol.text))
			return
		}

		operand_base := dst
		if operand_count > 0 {
			operand_base = Compiler.next_slot
			reserve_slots_until(operand_base + operand_count)
			if Compiler.failed { return }
		}

		for i := 0; i < operand_count; i += 1 {
			compile_expr(args[i], operand_base + i)
			if Compiler.failed { return }
		}

		if symbol.text == "+" {
			emit_add(dst, operand_base, operand_count)
		} else if symbol.text == "-" {
			emit_sub(dst, operand_base, operand_count)
		} else if symbol.text == "*" {
			emit_mul(dst, operand_base, operand_count)
		} else {
			emit_div(dst, operand_base, operand_count)
		}
		return
	}

	if symbol.text == "push" {
		assert(len(args) >= 2, "push opcode requires a vector and at least one value")
		if len(args) > int(max(u8)) {
			compile_error("`push` has too many arguments")
			return
		}

		value_count := len(args) - 1
		value_base := Compiler.next_slot
		reserve_slots_until(value_base + value_count)
		if Compiler.failed { return }

		compile_expr(args[0], dst)
		if Compiler.failed { return }

		for i := 0; i < value_count; i += 1 {
			compile_expr(args[i + 1], value_base + i)
			if Compiler.failed { return }
		}

		for i := 0; i < value_count; i += 1 {
			emit_vector_push(dst, value_base + i)
		}
		return
	}

	if symbol.text == "pop" {
		assert(len(args) == 1, "pop opcode requires one argument")

		compile_expr(args[0], dst)
		if Compiler.failed { return }

		emit_vector_pop(dst, dst)
		return
	}

	assert(false, "compile_builtin_opcode expected opcode-backed builtin")
}

// Bare heads resolve as special forms, then ordinary bindings.
// Direct calls to supplied arithmetic and vector builtins may use dedicated opcodes.
// Non-symbol heads are ordinary calls.
compile_list_expr :: proc(list: ^ListObject, dst: int) {
	if len(list.items) == 0 {
		compile_error("empty list is not an expression")
		return
	}

	head_object, head_is_object := list.items[0].(^Object)
	if !head_is_object || head_object.kind != .SYMBOL {
		compile_ordinary_call(list, dst)
		return
	}

	head := cast(^SymbolObject)head_object

	if head.text == "def" {
		compile_error("`def` is not valid in expression position")
		return
	}
	if head.text == "set" {
		compile_set(list, dst)
		return
	}
	if head.text == "do" {
		compile_do(list, dst)
		return
	}
	if head.text == "if" ||
	   head.text == "while" ||
	   head.text == "fn" {
		compile_error(fmt.tprintf("`%s` is not implemented", head.text))
		return
	}

	_, local_found := find_local(head)
	if local_found {
		compile_ordinary_call(list, dst)
		return
	}

	_, global_found := find_global(Active_VM, head)
	if global_found {
		argument_count := len(list.items) - 1

		if head.text == "+" ||
		   head.text == "-" ||
		   head.text == "*" ||
		   head.text == "/" {
			compile_builtin_opcode(head, list.items[1:], dst)
			return
		}

		if (head.text == "push" && argument_count >= 2) ||
		   (head.text == "pop" && argument_count == 1) {
			compile_builtin_opcode(head, list.items[1:], dst)
			return
		}

		compile_ordinary_call(list, dst)
		return
	}

	compile_error(fmt.tprintf("undefined name `%s`", head.text))
}

// The caller reserves dst. Expression compilation may use higher scratch slots
// but restores the live slot boundary it received.
compile_expr :: proc(value: Value, dst: int) {
	slot_mark := Compiler.next_slot

	if value == nil {
		emit_load_nil(dst)
		Compiler.next_slot = slot_mark
		return
	}

	switch v in value {
	case bool:
		if v {
			emit_load_true(dst)
		} else {
			emit_load_false(dst)
		}

	case i64, f64:
		compile_constant(value, dst)

	case ^Object:
		switch v.kind {
		case .STRING:
			compile_constant(value, dst)

		case .SYMBOL:
			compile_name_expr(cast(^SymbolObject)v, dst)

		case .LIST:
			compile_list_expr(cast(^ListObject)v, dst)

		case .VECTOR:
			compile_vector_expr(cast(^VectorObject)v, dst)

		case .NATIVE_FUNCTION:
			compile_error("native function object cannot appear in source")
		}
	}

	Compiler.next_slot = slot_mark
}

// Returns the final expression, or nil when empty or ending in a definition.
// Non-final expression results are discarded.
compile_file_forms :: proc(forms: []Value) -> int {
	if len(forms) == 0 {
		result_slot := claim_slot()
		if Compiler.failed { return 0 }

		emit_load_nil(result_slot)
		return result_slot
	}

	result_slot := 0

	for i := 0; i < len(forms); i += 1 {
		form := forms[i]
		is_last := i + 1 == len(forms)

		if form_is_definition(form) {
			compile_def(form)
			if Compiler.failed { return 0 }

			if is_last {
				result_slot = claim_slot()
				if Compiler.failed { return 0 }
				emit_load_nil(result_slot)
			}
			continue
		}

		slot_mark := Compiler.next_slot
		result_slot = claim_slot()
		if Compiler.failed { return 0 }

		compile_expr(form, result_slot)
		if Compiler.failed { return 0 }

		if !is_last {
			Compiler.next_slot = slot_mark
		}
	}

	return result_slot
}

compile_forms :: proc(forms: []Value) -> Code {
	Compiler.failed = false
	Compiler.local_count = 0
	Compiler.current_scope_local_start = 0
	Compiler.next_slot = 0

	begin_code()

	return_slot := compile_file_forms(forms)
	if Compiler.failed {
		delete(Active_Code.bytecode)
		delete(Active_Code.constants)
		Active_Code = Code{}
		return Code{}
	}

	emit_return(return_slot)
	return end_code()
}


// Core operations ================================================================================

// +, -, and * stay int while all operands are ints; / always returns float.

core_add :: proc(args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("+ expects two or more arguments")
		return Value{}
	}

	all_int := true
	int_result: i64
	float_result: f64

	for arg in args {
		int_value, is_int := arg.(i64)
		if is_int {
			if all_int {
				next_result := i128(int_result) + i128(int_value)
				if next_result < i128(min(i64)) || next_result > i128(max(i64)) {
					runtime_error("+ integer overflow")
					return Value{}
				}
				int_result = i64(next_result)
			} else {
				float_result += f64(int_value)
			}
			continue
		}

		float_value, is_float := arg.(f64)
		if is_float {
			if all_int {
				float_result = f64(int_result)
				all_int = false
			}
			float_result += float_value
			continue
		}

		runtime_error("+ expects numbers")
		return Value{}
	}

	if all_int {
		return Value(int_result)
	}
	return Value(float_result)
}

core_sub :: proc(args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("- expects two or more arguments")
		return Value{}
	}

	int_result, first_is_int := args[0].(i64)
	float_result, first_is_float := args[0].(f64)
	if !first_is_int && !first_is_float {
		runtime_error("- expects numbers")
		return Value{}
	}

	all_int := first_is_int

	for i := 1; i < len(args); i += 1 {
		int_value, is_int := args[i].(i64)
		if is_int {
			if all_int {
				next_result := i128(int_result) - i128(int_value)
				if next_result < i128(min(i64)) || next_result > i128(max(i64)) {
					runtime_error("- integer overflow")
					return Value{}
				}
				int_result = i64(next_result)
			} else {
				float_result -= f64(int_value)
			}
			continue
		}

		float_value, is_float := args[i].(f64)
		if is_float {
			if all_int {
				float_result = f64(int_result)
				all_int = false
			}
			float_result -= float_value
			continue
		}

		runtime_error("- expects numbers")
		return Value{}
	}

	if all_int {
		return Value(int_result)
	}
	return Value(float_result)
}

core_mul :: proc(args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("* expects two or more arguments")
		return Value{}
	}

	all_int := true
	int_result: i64 = 1
	float_result: f64 = 1

	for arg in args {
		int_value, is_int := arg.(i64)
		if is_int {
			if all_int {
				next_result := i128(int_result) * i128(int_value)
				if next_result < i128(min(i64)) || next_result > i128(max(i64)) {
					runtime_error("* integer overflow")
					return Value{}
				}
				int_result = i64(next_result)
			} else {
				float_result *= f64(int_value)
			}
			continue
		}

		float_value, is_float := arg.(f64)
		if is_float {
			if all_int {
				float_result = f64(int_result)
				all_int = false
			}
			float_result *= float_value
			continue
		}

		runtime_error("* expects numbers")
		return Value{}
	}

	if all_int {
		return Value(int_result)
	}
	return Value(float_result)
}

core_div :: proc(args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("/ expects two or more arguments")
		return Value{}
	}

	int_value, first_is_int := args[0].(i64)
	float_result, first_is_float := args[0].(f64)
	if first_is_int {
		float_result = f64(int_value)
	} else if !first_is_float {
		runtime_error("/ expects numbers")
		return Value{}
	}

	for i := 1; i < len(args); i += 1 {
		int_divisor, is_int := args[i].(i64)
		if is_int {
			if int_divisor == 0 {
				runtime_error("/ divisor cannot be zero")
				return Value{}
			}

			float_result /= f64(int_divisor)
			continue
		}

		float_divisor, is_float := args[i].(f64)
		if is_float {
			if float_divisor == 0 {
				runtime_error("/ divisor cannot be zero")
				return Value{}
			}

			float_result /= float_divisor
			continue
		}

		runtime_error("/ expects numbers")
		return Value{}
	}

	return Value(float_result)
}

core_push :: proc(vector_value, item: Value) -> Value {
	vector_object, vector_is_object := vector_value.(^Object)
	if !vector_is_object || vector_object.kind != .VECTOR {
		runtime_error("push expects a vector as its first argument")
		return Value{}
	}

	vector := cast(^VectorObject)vector_object
	append(&vector.items, item)
	return vector_value
}

core_pop :: proc(vector_value: Value) -> Value {
	vector_object, vector_is_object := vector_value.(^Object)
	if !vector_is_object || vector_object.kind != .VECTOR {
		runtime_error("pop expects a vector")
		return Value{}
	}

	vector := cast(^VectorObject)vector_object
	if len(vector.items) == 0 {
		runtime_error("cannot pop empty vector")
		return Value{}
	}

	return pop(&vector.items)
}


// Native builtins ================================================================================

native_add :: proc(vm: ^VM, args: []Value) -> Value {
	return core_add(args)
}

native_sub :: proc(vm: ^VM, args: []Value) -> Value {
	return core_sub(args)
}

native_mul :: proc(vm: ^VM, args: []Value) -> Value {
	return core_mul(args)
}

native_div :: proc(vm: ^VM, args: []Value) -> Value {
	return core_div(args)
}

native_push :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("push expects a vector and one or more values")
		return Value{}
	}

	vector_value := args[0]
	for i := 1; i < len(args); i += 1 {
		core_push(vector_value, args[i])
		if vm.error_string != "" { return Value{} }
	}

	return vector_value
}

native_pop :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("pop expects one argument")
		return Value{}
	}

	return core_pop(args[0])
}

native_print :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("print expects one argument")
		return Value{}
	}

	print_value(args[0])
	fmt.println()
	return Value{}
}

install_builtins :: proc(vm: ^VM) {
	// Supplied globals are immutable; install them exactly once per VM.
	bind_native_global(vm, "+", native_add)
	bind_native_global(vm, "-", native_sub)
	bind_native_global(vm, "*", native_mul)
	bind_native_global(vm, "/", native_div)
	bind_native_global(vm, "push", native_push)
	bind_native_global(vm, "pop", native_pop)
	bind_native_global(vm, "print", native_print)
}


// VM execution ===================================================================================

// Executes trusted Code against the selected VM and replaces its slot window.
run_code :: proc(code: ^Code) -> Value {
	vm := Active_VM

	// Allocate the exact entry slot window recorded during emission.
	delete(vm.slots)
	vm.slots = make([dynamic]Value, code.frame_slot_count)

	ip := 0

	for {
		assert(ip < len(code.bytecode), "code ended without RETURN")

		word := code.bytecode[ip]
		ip += 1

		op := InstABC(word).op

		switch op {
		case .LOAD_NIL:
			inst := InstABx(word)
			vm.slots[int(inst.a)] = Value{}

		case .LOAD_TRUE:
			inst := InstABx(word)
			vm.slots[int(inst.a)] = Value(bool(true))

		case .LOAD_FALSE:
			inst := InstABx(word)
			vm.slots[int(inst.a)] = Value(bool(false))

		case .LOAD_CONST:
			inst := InstABx(word)
			constant_index := int(inst.b)
			assert(constant_index < len(code.constants), "constant index out of range")
			vm.slots[int(inst.a)] = code.constants[constant_index]

		case .MOVE:
			inst := InstABC(word)
			vm.slots[int(inst.a)] = vm.slots[int(inst.b)]

		case .GET_GLOBAL:
			inst := InstABx(word)
			global_index := int(inst.b)
			assert(global_index < len(vm.globals), "global index out of range")
			vm.slots[int(inst.a)] = vm.globals[global_index].value

		case .ADD, .SUB, .MUL, .DIV:
			inst := InstABC(word)
			dst := int(inst.a)
			first_slot := int(inst.b)
			argument_count := int(inst.c)
			args := vm.slots[first_slot:first_slot + argument_count]

			result: Value
			#partial switch op {
			case .ADD:
				result = core_add(args)
			case .SUB:
				result = core_sub(args)
			case .MUL:
				result = core_mul(args)
			case .DIV:
				result = core_div(args)
			}

			if vm.error_string != "" {
				return Value{}
			}
			vm.slots[dst] = result

		case .CALL:
			inst := InstABC(word)
			base := int(inst.a)
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

			case .VECTOR:
				if argument_count != 1 {
					runtime_error("vector call expects one index")
					return Value{}
				}

				index, index_is_int := vm.slots[base + 1].(i64)
				if !index_is_int {
					runtime_error("vector index must be int")
					return Value{}
				}

				vector := cast(^VectorObject)callee_object
				if index < 0 || index >= i64(len(vector.items)) {
					runtime_error("vector index out of range")
					return Value{}
				}

				vm.slots[base] = vector.items[int(index)]

			case .STRING, .SYMBOL, .LIST:
				runtime_error("value is not callable")
				return Value{}
			}

		case .NEW_VECTOR:
			inst := InstABx(word)
			dst := int(inst.a)
			capacity := int(inst.b)

			items := make([dynamic]Value)
			if capacity > 0 {
				reserve(&items, capacity)
			}

			vm.slots[dst] = Value(cast(^Object)new_vector_object(items))

		case .VECTOR_PUSH:
			inst := InstABC(word)
			core_push(vm.slots[int(inst.a)], vm.slots[int(inst.b)])
			if vm.error_string != "" { return Value{} }

		case .VECTOR_POP:
			inst := InstABC(word)
			result := core_pop(vm.slots[int(inst.b)])
			if vm.error_string != "" { return Value{} }
			vm.slots[int(inst.a)] = result

		case .SET_VECTOR:
			inst := InstABC(word)
			vector_value := vm.slots[int(inst.a)]
			index_value := vm.slots[int(inst.b)]
			new_value := vm.slots[int(inst.c)]

			vector_object, vector_is_object := vector_value.(^Object)
			if !vector_is_object || vector_object.kind != .VECTOR {
				runtime_error("vector set receiver must be vector")
				return Value{}
			}

			index, index_is_int := index_value.(i64)
			if !index_is_int {
				runtime_error("vector set index must be int")
				return Value{}
			}

			vector := cast(^VectorObject)vector_object
			if index < 0 || index >= i64(len(vector.items)) {
				runtime_error("vector index out of range")
				return Value{}
			}

			vector.items[int(index)] = new_value

		case .RETURN:
			inst := InstABx(word)
			return vm.slots[int(inst.a)]

		case:
			assert(false, "invalid opcode")
		}
	}
}


// Host operations ===============================================================================

// Owns one read, compile, and execute operation and its diagnostic lifetime.
run_string :: proc(vm: ^VM, source: string) -> Value {
	Active_VM = vm
	clear_error(vm)

	forms := read_source(source)
	if Reader.failed { return Value{} }
	defer delete(forms)

	code := compile_forms(forms[:])
	if Compiler.failed { return Value{} }
	defer delete(code.bytecode)
	defer delete(code.constants)

	return run_code(&code)
}

// Reads an exact path, then delegates the source pipeline to run_string.
run_file :: proc(vm: ^VM, path: string) -> Value {
	Active_VM = vm
	clear_error(vm)

	source_bytes, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		set_error(fmt.tprintf("read error: could not read file `%s`", path))
		return Value{}
	}
	defer delete(source_bytes)

	return run_string(vm, string(source_bytes))
}
