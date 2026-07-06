package rite

import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem"
import "core:os"
import filepath "core:path/filepath"
import "core:strconv"
import "core:strings"


// Value model ====================================================================================

ObjectKind :: enum u8 {
	STRING,
	SYMBOL,
	LIST,
	VECTOR,
	MAP,
	NATIVE_FUNCTION,
	FUNCTION,
}

// Every heap object starts with this header so ^Object can dispatch by kind.
Object :: struct {
	kind: ObjectKind,
}

StringObject :: struct {
	header: Object,
	text:   string,
	hash:   u64,
}

SymbolObject :: struct {
	header: Object,
	text:   string,
}

ListObject :: struct {
	header: Object,

	// Reader lists hold source forms. Rite does not expose a runtime list literal.
	items: [dynamic]Value,
}

VectorObject :: struct {
	header: Object,
	items:  [dynamic]Value,
}

MapEntry :: struct {
	key:       Value,
	hash:      u64,
	value:     Value,
	tombstone: bool,
}

// Reader maps store linear source pairs in entries. Runtime maps use entries
// as open-addressed buckets and maintain count/tombstone_count.
MapObject :: struct {
	header:          Object,
	entries:         [dynamic]MapEntry,
	count:           int,
	tombstone_count: int,
}

// The zero value of this union represents Rite nil.
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

	GET_BUILTIN, // ABx: A=dst, Bx=builtin index
	LOAD_FUNCTION, // ABx: A=dst, Bx=child code index
	GET_UPVALUE,   // ABx: A=dst, Bx=upvalue index
	SET_UPVALUE,   // ABx: A=src, Bx=upvalue index
	CLOSE_UPVALUES, // ABx: A=first slot to close

	ADD, // ABC: A=dst, B=first operand, C=operand count
	SUB, // ABC: A=dst, B=first operand, C=operand count
	MUL, // ABC: A=dst, B=first operand, C=operand count
	DIV, // ABC: A=dst, B=first operand, C=operand count

	MOD,           // ABC: A=dst, B=lhs, C=rhs
	EQUAL,         // ABC: A=dst, B=lhs, C=rhs
	LESS,          // ABC: A=dst, B=lhs, C=rhs
	LESS_EQUAL,    // ABC: A=dst, B=lhs, C=rhs
	GREATER,       // ABC: A=dst, B=lhs, C=rhs
	GREATER_EQUAL, // ABC: A=dst, B=lhs, C=rhs
	NOT,           // ABC: A=dst, B=src
	LEN,           // ABC: A=dst, B=src

	CALL, // ABC: A=callee, B=argument count -> result replaces A; arguments start at A+1

	NEW_VECTOR,  // ABx: A=dst, Bx=initial capacity hint
	NEW_MAP,     // ABx: A=dst, Bx=initial pair-count hint
	VECTOR_PUSH, // ABC: A=vector, B=value -> A remains the vector
	VECTOR_POP,  // ABC: A=dst, B=vector -> removed value goes to A
	UNPACK_VECTOR, // ABC: A=source vector, B=first dst, C=count
	SET_INDEX,   // ABC: A=receiver, B=index/key, C=value -> expression result remains in C

	RETURN, // ABx: A=src

	JUMP,           // Ax: A=target instruction index
	JUMP_IF_FALSEY, // ABx: A=cond_slot, Bx=target instruction index
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

InstAx :: bit_field u32 {
	op: Opcode | 8,
	a:  u32    | 24,
}

UpvalueDesc :: struct {
	from_parent_local: bool,
	index:             int,
	mutable:           bool,
}

Upvalue :: struct {
	// slot_index >= 0 means this upvalue still aliases a live VM slot.
	// slot_index < 0 means closed owns the captured value.
	slot_index: int,
	closed:     Value,
}

// Finished executable body. Root file code and fn body code share this exact shape.
Code :: struct {
	bytecode:    []u32,
	constants:   []Value,
	child_codes: []^Code,

	frame_slot_count: int,
	param_count:      int,

	upvalue_descs: []UpvalueDesc,
	exports:       []LocalBinding,
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

	slot_base: int,
}

// Runtime name -> value binding. Builtins and module exports share this shape.
Binding :: struct {
	symbol:  ^SymbolObject,
	value:   Value,
	mutable: bool,
}

Module :: struct {
	id:      string,
	loading: bool,

	code:    ^Code,
	exports: []Binding,
}

// One host-owned execution world; builtins/modules persist while slots reset per run.
VM :: struct {
	slots: [dynamic]Value,

	frames: [dynamic]CallFrame,

	open_upvalues: [dynamic]^Upvalue,

	builtins: [dynamic]Binding,
	modules:  [dynamic]Module,
	symbols:  [dynamic]^SymbolObject,

	// Current host-operation diagnostic; empty means no error.
	error_string: string,
}

// Compiler and runtime entry procs select the VM used by internal helpers.
Active_VM: ^VM


// Compiler data ==================================================================================

MAX_FRAME_SLOTS :: int(max(u8)) + 1

LocalBinding :: struct {
	symbol:  ^SymbolObject,
	slot:    int,
	mutable: bool,
}

CodeBuilder :: struct {
	bytecode:    [dynamic]u32,
	constants:   [dynamic]Value,
	child_codes: [dynamic]^Code,

	frame_slot_count: int,
	param_count:      int,

	local_bindings: [MAX_FRAME_SLOTS]LocalBinding,
	local_count:    int,

	// Begins duplicate-definition checks for the current lexical scope.
	current_scope_local_start: int,
	next_slot:                 int,

	upvalue_descs:   [dynamic]UpvalueDesc,
	upvalue_symbols: [dynamic]^SymbolObject,

	file_bindings: [dynamic]LocalBinding,
	exports:       [dynamic]LocalBinding,

	source_name: string,
	parent:      ^CodeBuilder,
}

Compiler := struct {
	// A failed build is disposable; its diagnostic lives in Active_VM.error_string.
	failed: bool,
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


// VM binding lookup ===============================================================================

// Finds a supplied builtin binding by interned symbol.
find_builtin :: proc(vm: ^VM, symbol: ^SymbolObject) -> (int, bool) {
	for i := 0; i < len(vm.builtins); i += 1 {
		if vm.builtins[i].symbol == symbol {
			return i, true
		}
	}

	return -1, false
}

find_module :: proc(vm: ^VM, id: string) -> (int, bool) {
	for i := 0; i < len(vm.modules); i += 1 {
		if vm.modules[i].id == id {
			return i, true
		}
	}

	return -1, false
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

new_map_object :: proc() -> ^MapObject {
	object := new(MapObject)
	object.header.kind = .MAP
	return object
}

new_function_object :: proc(code: ^Code) -> ^FunctionObject {
	function := new(FunctionObject)
	function.header.kind = .FUNCTION
	function.code = code
	function.upvalues = make([]^Upvalue, len(code.upvalue_descs))
	return function
}


// Map storage ====================================================================================

string_hash :: proc(object: ^StringObject) -> u64 {
	if object.hash == 0 {
		object.hash = hash.fnv64a(transmute([]byte)object.text)
	}
	return object.hash
}

// Hashes one legal runtime map key. Numeric hashing mirrors Rite's current
// mixed comparison rule by first converting ints to f64.
map_key_hash :: proc(key: Value) -> (u64, bool) {
	if key == nil {
		runtime_error("map key cannot be nil")
		return 0, false
	}

	switch value in key {
	case bool:
		bits := u64(1) if value else u64(0)
		return hash.fnv64a(mem.ptr_to_bytes(&bits)), true

	case i64:
		number := f64(value)
		bits := transmute(u64)number
		return hash.fnv64a(mem.ptr_to_bytes(&bits)), true

	case f64:
		if value != value {
			runtime_error("map key cannot be NaN")
			return 0, false
		}

		number := value
		if number == 0 {
			number = 0
		}

		bits := transmute(u64)number
		return hash.fnv64a(mem.ptr_to_bytes(&bits)), true

	case ^Object:
		switch value.kind {
		case .STRING:
			return string_hash(cast(^StringObject)value), true

		case .SYMBOL:
			assert(false, "symbol is not a Rite runtime value")
			return 0, false

		case .LIST, .VECTOR, .MAP, .NATIVE_FUNCTION, .FUNCTION:
			bits := u64(uintptr(value))
			return hash.fnv64a(mem.ptr_to_bytes(&bits)), true
		}
	}

	assert(false, "invalid map key value")
	return 0, false
}

// Non-empty bucket arrays always have power-of-two length.
// nil key + false tombstone is empty; nil key + true tombstone is deleted.
map_init :: proc(map_object: ^MapObject, entry_capacity: int) {
	map_object.count = 0
	map_object.tombstone_count = 0

	if entry_capacity <= 0 {
		map_object.entries = make([dynamic]MapEntry)
		return
	}

	wanted := max(entry_capacity * 2, 8)
	bucket_count := 1
	for bucket_count < wanted {
		bucket_count <<= 1
	}

	map_object.entries = make([dynamic]MapEntry, bucket_count)
}

map_find_slot :: proc(map_object: ^MapObject, key: Value, key_hash: u64) -> (index: int, found: bool) {
	bucket_count := len(map_object.entries)
	mask := bucket_count - 1
	start := int(key_hash & u64(mask))
	first_tombstone := -1

	for probe_offset := 0; probe_offset < bucket_count; probe_offset += 1 {
		index := (start + probe_offset) & mask
		entry := &map_object.entries[index]

		if entry.key == nil {
			if entry.tombstone {
				if first_tombstone < 0 {
					first_tombstone = index
				}
				continue
			}

			if first_tombstone >= 0 {
				return first_tombstone, false
			}
			return index, false
		}

		if entry.hash == key_hash && values_equal(entry.key, key) {
			return index, true
		}
	}

	if first_tombstone >= 0 {
		return first_tombstone, false
	}

	panic("map_find_slot reached full table")
}

map_get :: proc(map_object: ^MapObject, key: Value) -> Value {
	key_hash, valid_key := map_key_hash(key)
	if !valid_key { return Value{} }

	if len(map_object.entries) == 0 {
		return Value{}
	}

	index, found := map_find_slot(map_object, key, key_hash)
	if !found {
		return Value{}
	}

	return map_object.entries[index].value
}

map_set :: proc(map_object: ^MapObject, key, value: Value) {
	if value == nil {
		map_delete(map_object, key)
		return
	}

	key_hash, valid_key := map_key_hash(key)
	if !valid_key { return }

	if len(map_object.entries) == 0 {
		map_init(map_object, 4)
	}

	index, found := map_find_slot(map_object, key, key_hash)
	if found {
		map_object.entries[index].value = value
		return
	}

	if (map_object.count + map_object.tombstone_count + 1) * 4 >= len(map_object.entries) * 3 {
		map_grow(map_object)
		index, found = map_find_slot(map_object, key, key_hash)
	}

	entry := &map_object.entries[index]
	if entry.tombstone {
		map_object.tombstone_count -= 1
	}

	entry.key = key
	entry.hash = key_hash
	entry.value = value
	entry.tombstone = false
	map_object.count += 1
}

map_delete :: proc(map_object: ^MapObject, key: Value) {
	key_hash, valid_key := map_key_hash(key)
	if !valid_key { return }

	if len(map_object.entries) == 0 {
		return
	}

	index, found := map_find_slot(map_object, key, key_hash)
	if !found {
		return
	}

	entry := &map_object.entries[index]
	entry.key = nil
	entry.hash = 0
	entry.value = Value{}
	entry.tombstone = true
	map_object.count -= 1
	map_object.tombstone_count += 1
}

map_grow :: proc(map_object: ^MapObject) {
	old_entries := map_object.entries
	bucket_count := max(len(old_entries) * 2, 8)

	map_object.entries = make([dynamic]MapEntry, bucket_count)
	map_object.count = 0
	map_object.tombstone_count = 0

	for entry in old_entries {
		if entry.key == nil {
			continue
		}

		index, _ := map_find_slot(map_object, entry.key, entry.hash)
		map_object.entries[index] = MapEntry{
			key       = entry.key,
			hash      = entry.hash,
			value     = entry.value,
			tombstone = false,
		}
		map_object.count += 1
	}

	delete(old_entries)
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
	       ch == ']' ||
	       ch == '{' ||
	       ch == '}' ||
	       ch == ':'
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

		// Odin converts the value only after Rite accepts its spelling.
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
	has_escapes := false
	decoded: [dynamic]u8

	for Reader.index < len(Reader.source) {
		ch := Reader.source[Reader.index]

		if ch == '\n' || ch == '\r' {
			if has_escapes {
				delete(decoded)
			}
			reader_error("unterminated string")
			return Value{}
		}

		if ch == '\\' {
			if !has_escapes {
				has_escapes = true
				decoded = make([dynamic]u8)

				for i := start; i < Reader.index; i += 1 {
					append(&decoded, Reader.source[i])
				}
			}

			Reader.index += 1

			if Reader.index >= len(Reader.source) {
				delete(decoded)
				reader_error("unterminated string")
				return Value{}
			}

			escaped := Reader.source[Reader.index]
			Reader.index += 1

			if escaped == '\n' || escaped == '\r' {
				delete(decoded)
				reader_error("unterminated string")
				return Value{}
			}

			switch escaped {
			case 'n':
				append(&decoded, '\n')
			case 't':
				append(&decoded, '\t')
			case 'r':
				append(&decoded, '\r')
			case '\\':
				append(&decoded, '\\')
			case '"':
				append(&decoded, '"')
			case:
				delete(decoded)
				reader_error(fmt.tprintf("invalid escape sequence '\\%c'", escaped))
				return Value{}
			}

			continue
		}

		if ch == '"' {
			if has_escapes {
				Reader.index += 1
				text := string(decoded[:])
				object := new_string_object(text)
				delete(decoded)
				return Value(cast(^Object)object)
			}

			text := Reader.source[start:Reader.index]
			Reader.index += 1
			return Value(cast(^Object)new_string_object(text))
		}

		if has_escapes {
			append(&decoded, ch)
		}

		Reader.index += 1
	}

	if has_escapes {
		delete(decoded)
	}

	reader_error("unterminated string")
	return Value{}
}

read_name_string :: proc() -> Value {
	Reader.index += 1
	start := Reader.index

	for Reader.index < len(Reader.source) && !is_delimiter(Reader.source[Reader.index]) {
		Reader.index += 1
	}

	if Reader.index == start {
		reader_error("name string requires a name")
		return Value{}
	}

	return Value(cast(^Object)new_string_object(Reader.source[start:Reader.index]))
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

read_map :: proc() -> Value {
	Reader.index += 1

	// Source maps keep linear key/value forms. The compiler creates the runtime table.
	entries := make([dynamic]MapEntry)

	for {
		skip_trivia()

		if Reader.index >= len(Reader.source) {
			reader_error("unterminated map")
			delete(entries)
			return Value{}
		}

		if Reader.source[Reader.index] == '}' {
			Reader.index += 1
			object := new_map_object()
			object.entries = entries
			return Value(cast(^Object)object)
		}

		key := read_form()
		if Reader.failed {
			delete(entries)
			return Value{}
		}

		skip_trivia()
		if Reader.index >= len(Reader.source) {
			reader_error("unterminated map")
			delete(entries)
			return Value{}
		}
		if Reader.source[Reader.index] == '}' {
			reader_error("map literal expects key/value pairs")
			delete(entries)
			return Value{}
		}

		value := read_form()
		if Reader.failed {
			delete(entries)
			return Value{}
		}

		append(&entries, MapEntry{
			key   = key,
			value = value,
		})
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

	case ':':
		return read_name_string()

	case '\'':
		reader_error("quote not implemented")
		return Value{}

	case '[':
		return read_vector()

	case ']':
		reader_error("unexpected ']'")
		return Value{}

	case '{':
		return read_map()

	case '}':
		reader_error("unexpected '}'")
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

		case .MAP:
			object := cast(^MapObject)v
			fmt.printf("Map(%d)\n", len(object.entries))

			for i := 0; i < len(object.entries); i += 1 {
				entry := object.entries[i]

				append(continuations, true)
				debug_print_value_tree(entry.key, continuations)
				pop(continuations)

				append(continuations, i + 1 < len(object.entries))
				debug_print_value_tree(entry.value, continuations)
				pop(continuations)
			}

		case .NATIVE_FUNCTION, .FUNCTION:
			assert(false, "runtime function object in reader tree")
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
append_value_text :: proc(parts: ^[dynamic]string, value: Value, parents: ^[dynamic]^Object) {
	if value == nil {
		append(parts, "nil")
		return
	}

	switch v in value {
	case bool:
		append(parts, fmt.tprint(v))

	case i64:
		append(parts, fmt.tprint(v))

	case f64:
		text := fmt.tprintf("%.15g", v)
		append(parts, text)

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
			append(parts, ".0")
		}

	case ^Object:
		switch v.kind {
		case .STRING:
			object := cast(^StringObject)v
			append(parts, object.text)

		case .SYMBOL:
			object := cast(^SymbolObject)v
			append(parts, fmt.tprintf("<symbol %s>", object.text))

		case .LIST:
			for parent in parents {
				if parent == v {
					append(parts, "(...)")
					return
				}
			}
			append(parents, v)

			object := cast(^ListObject)v
			append(parts, "(")
			for i := 0; i < len(object.items); i += 1 {
				if i > 0 {
					append(parts, " ")
				}
				append_value_text(parts, object.items[i], parents)
			}
			append(parts, ")")

			pop(parents)

		case .VECTOR:
			for parent in parents {
				if parent == v {
					append(parts, "[...]")
					return
				}
			}
			append(parents, v)

			object := cast(^VectorObject)v
			append(parts, "[")
			for i := 0; i < len(object.items); i += 1 {
				if i > 0 {
					append(parts, " ")
				}
				append_value_text(parts, object.items[i], parents)
			}
			append(parts, "]")

			pop(parents)

		case .MAP:
			for parent in parents {
				if parent == v {
					append(parts, "{...}")
					return
				}
			}
			append(parents, v)

			object := cast(^MapObject)v
			append(parts, "{")

			wrote_entry := false
			for entry in object.entries {
				if entry.key == nil {
					continue
				}

				if wrote_entry {
					append(parts, " ")
				}
				append_value_text(parts, entry.key, parents)
				append(parts, " ")
				append_value_text(parts, entry.value, parents)
				wrote_entry = true
			}

			append(parts, "}")
			pop(parents)

		case .NATIVE_FUNCTION, .FUNCTION:
			append(parts, "<function>")

		case:
			assert(false, "invalid object tag")
		}
	}
}

// Returns owned display text; the caller deletes it.
value_display_text :: proc(value: Value) -> string {
	parts := make([dynamic]string)
	parents := make([dynamic]^Object)

	append_value_text(&parts, value, &parents)
	text := strings.concatenate(parts[:])

	delete(parts)
	delete(parents)
	return text
}

print_value :: proc(value: Value) {
	text := value_display_text(value)
	fmt.print(text)
	delete(text)
}


// Modules ========================================================================================

resolve_import_path :: proc(importer_source_name, import_path: string) -> (string, bool) {
	path := import_path
	if filepath.ext(path) == "" {
		path = fmt.tprintf("%s.rite", import_path)
	}

	joined_path := ""
	if !filepath.is_abs(path) && importer_source_name != "" {
		importer_dir := filepath.dir(importer_source_name)
		defer delete(importer_dir)

		joined, join_error := filepath.join({importer_dir, path}, context.allocator)
		if join_error != nil {
			compile_error(fmt.tprintf("could not resolve import path `%s`", import_path))
			return "", false
		}
		joined_path = joined
		path = joined_path
	}

	resolved_path, resolve_error := filepath.abs(path, context.allocator)
	if joined_path != "" {
		delete(joined_path)
	}
	if resolve_error != nil {
		compile_error(fmt.tprintf("could not resolve import path `%s`", import_path))
		return "", false
	}

	return resolved_path, true
}

load_module :: proc(vm: ^VM, importer_source_name, import_path: string) -> ^Module {
	id, resolved := resolve_import_path(importer_source_name, import_path)
	if !resolved { return nil }

	existing_index, found := find_module(vm, id)
	if found {
		if vm.modules[existing_index].loading {
			compile_error(fmt.tprintf("cyclic import `%s`", import_path))
			delete(id)
			return nil
		}

		delete(id)
		return &vm.modules[existing_index]
	}

	if !os.exists(id) {
		delete(id)

		host_index, host_found := find_module(vm, import_path)
		if host_found {
			return &vm.modules[host_index]
		}

		compile_error(fmt.tprintf("module `%s` not found", import_path))
		return nil
	}

	append(&vm.modules, Module{
		id      = id,
		loading = true,
		code    = nil,
		exports = nil,
	})
	module_index := len(vm.modules) - 1

	source_bytes, read_error := os.read_entire_file(id, context.allocator)
	if read_error != nil {
		compile_error(fmt.tprintf("could not read module `%s`", import_path))
		return nil
	}
	defer delete(source_bytes)

	forms := read_source(string(source_bytes))
	if Reader.failed {
		Compiler.failed = true
		return nil
	}
	defer delete(forms)

	code := compile_forms(forms[:], id)
	if Compiler.failed { return nil }

	_ = run_code(code)
	if vm.error_string != "" {
		Compiler.failed = true
		return nil
	}

	exports := make([]Binding, len(code.exports))
	for export, i in code.exports {
		exports[i] = Binding{
			symbol  = export.symbol,
			value   = vm.slots[export.slot],
			mutable = export.mutable,
		}
	}

	vm.modules[module_index].code = code
	vm.modules[module_index].exports = exports
	vm.modules[module_index].loading = false

	return &vm.modules[module_index]
}


// Code construction ==============================================================================

begin_code :: proc(parent: ^CodeBuilder, param_count: int, source_name: string) -> CodeBuilder {
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

		file_bindings = make([dynamic]LocalBinding),
		exports       = make([dynamic]LocalBinding),

		source_name = source_name,
		parent      = parent,
	}
}

end_code :: proc(builder: ^CodeBuilder) -> ^Code {
	bytecode := make([]u32, len(builder.bytecode))
	copy(bytecode, builder.bytecode[:])

	constants := make([]Value, len(builder.constants))
	copy(constants, builder.constants[:])

	child_codes := make([]^Code, len(builder.child_codes))
	copy(child_codes, builder.child_codes[:])

	upvalue_descs := make([]UpvalueDesc, len(builder.upvalue_descs))
	copy(upvalue_descs, builder.upvalue_descs[:])

	exports := make([]LocalBinding, len(builder.exports))
	copy(exports, builder.exports[:])

	delete(builder.bytecode)
	delete(builder.constants)
	delete(builder.child_codes)
	delete(builder.upvalue_descs)
	delete(builder.upvalue_symbols)
	delete(builder.file_bindings)
	delete(builder.exports)

	code := new(Code)
	code^ = Code{
		bytecode         = bytecode,
		constants        = constants,
		child_codes      = child_codes,
		frame_slot_count = builder.frame_slot_count,
		param_count      = builder.param_count,
		upvalue_descs    = upvalue_descs,
		exports          = exports,
	}
	return code
}

delete_code :: proc(code: ^Code) {
	for child in code.child_codes {
		delete_code(child)
	}

	delete(code.bytecode)
	delete(code.constants)
	delete(code.child_codes)
	delete(code.upvalue_descs)
	delete(code.exports)
	free(code)
}

delete_code_builder :: proc(builder: ^CodeBuilder) {
	for child in builder.child_codes {
		delete_code(child)
	}

	delete(builder.bytecode)
	delete(builder.constants)
	delete(builder.child_codes)
	delete(builder.upvalue_descs)
	delete(builder.upvalue_symbols)
	delete(builder.file_bindings)
	delete(builder.exports)
}


// Constants ======================================================================================

const_value :: proc(builder: ^CodeBuilder, value: Value) -> int {
	append(&builder.constants, value)
	return len(builder.constants) - 1
}


// Bytecode emission ==============================================================================

// frame_slot_count is the highest touched frame slot plus one.
record_slots :: proc(builder: ^CodeBuilder, slots: ..int) {
	for slot in slots {
		assert(slot >= 0 && slot <= int(max(u8)), "frame slot does not fit u8")

		needed_slot_count := slot + 1
		if needed_slot_count > builder.frame_slot_count {
			builder.frame_slot_count = needed_slot_count
		}
	}
}

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

emit_load_nil :: proc(builder: ^CodeBuilder, dst: int) {
	record_slots(builder, dst)
	emit_ABx(builder, .LOAD_NIL, dst, 0)
}

emit_load_true :: proc(builder: ^CodeBuilder, dst: int) {
	record_slots(builder, dst)
	emit_ABx(builder, .LOAD_TRUE, dst, 0)
}

emit_load_false :: proc(builder: ^CodeBuilder, dst: int) {
	record_slots(builder, dst)
	emit_ABx(builder, .LOAD_FALSE, dst, 0)
}

emit_load_const :: proc(builder: ^CodeBuilder, dst, constant_index: int) {
	record_slots(builder, dst)
	emit_ABx(builder, .LOAD_CONST, dst, constant_index)
}

emit_move :: proc(builder: ^CodeBuilder, dst, src: int) {
	record_slots(builder, dst, src)
	emit_ABC(builder, .MOVE, dst, src, 0)
}

emit_get_builtin :: proc(builder: ^CodeBuilder, dst, builtin_index: int) {
	record_slots(builder, dst)
	emit_ABx(builder, .GET_BUILTIN, dst, builtin_index)
}

emit_add :: proc(builder: ^CodeBuilder, dst, first_slot, count: int) {
	assert(count >= 0 && count <= int(max(u8)), "ADD argument count does not fit u8")
	record_slots(builder, dst)
	if count > 0 {
		record_slots(builder, first_slot, first_slot + count - 1)
	}
	emit_ABC(builder, .ADD, dst, first_slot, count)
}

emit_sub :: proc(builder: ^CodeBuilder, dst, first_slot, count: int) {
	assert(count >= 0 && count <= int(max(u8)), "SUB argument count does not fit u8")
	record_slots(builder, dst)
	if count > 0 {
		record_slots(builder, first_slot, first_slot + count - 1)
	}
	emit_ABC(builder, .SUB, dst, first_slot, count)
}

emit_mul :: proc(builder: ^CodeBuilder, dst, first_slot, count: int) {
	assert(count >= 0 && count <= int(max(u8)), "MUL argument count does not fit u8")
	record_slots(builder, dst)
	if count > 0 {
		record_slots(builder, first_slot, first_slot + count - 1)
	}
	emit_ABC(builder, .MUL, dst, first_slot, count)
}

emit_div :: proc(builder: ^CodeBuilder, dst, first_slot, count: int) {
	assert(count >= 0 && count <= int(max(u8)), "DIV argument count does not fit u8")
	record_slots(builder, dst)
	if count > 0 {
		record_slots(builder, first_slot, first_slot + count - 1)
	}
	emit_ABC(builder, .DIV, dst, first_slot, count)
}

emit_mod :: proc(builder: ^CodeBuilder, dst, lhs, rhs: int) {
	record_slots(builder, dst, lhs, rhs)
	emit_ABC(builder, .MOD, dst, lhs, rhs)
}

emit_equal :: proc(builder: ^CodeBuilder, dst, lhs, rhs: int) {
	record_slots(builder, dst, lhs, rhs)
	emit_ABC(builder, .EQUAL, dst, lhs, rhs)
}

emit_less :: proc(builder: ^CodeBuilder, dst, lhs, rhs: int) {
	record_slots(builder, dst, lhs, rhs)
	emit_ABC(builder, .LESS, dst, lhs, rhs)
}

emit_less_equal :: proc(builder: ^CodeBuilder, dst, lhs, rhs: int) {
	record_slots(builder, dst, lhs, rhs)
	emit_ABC(builder, .LESS_EQUAL, dst, lhs, rhs)
}

emit_greater :: proc(builder: ^CodeBuilder, dst, lhs, rhs: int) {
	record_slots(builder, dst, lhs, rhs)
	emit_ABC(builder, .GREATER, dst, lhs, rhs)
}

emit_greater_equal :: proc(builder: ^CodeBuilder, dst, lhs, rhs: int) {
	record_slots(builder, dst, lhs, rhs)
	emit_ABC(builder, .GREATER_EQUAL, dst, lhs, rhs)
}

emit_not :: proc(builder: ^CodeBuilder, dst, src: int) {
	record_slots(builder, dst, src)
	emit_ABC(builder, .NOT, dst, src, 0)
}

emit_len :: proc(builder: ^CodeBuilder, dst, src: int) {
	record_slots(builder, dst, src)
	emit_ABC(builder, .LEN, dst, src, 0)
}

emit_call :: proc(builder: ^CodeBuilder, base, argument_count: int) {
	assert(argument_count >= 0 && argument_count <= int(max(u8)), "call argument count does not fit u8")

	record_slots(builder, base)
	if argument_count > 0 {
		record_slots(builder, base + argument_count)
	}
	emit_ABC(builder, .CALL, base, argument_count, 0)
}

emit_new_vector :: proc(builder: ^CodeBuilder, dst, capacity: int) {
	assert(capacity >= 0 && capacity <= int(max(u16)), "vector capacity does not fit u16")
	record_slots(builder, dst)
	emit_ABx(builder, .NEW_VECTOR, dst, capacity)
}

emit_new_map :: proc(builder: ^CodeBuilder, dst, capacity: int) {
	assert(capacity >= 0 && capacity <= int(max(u16)), "map capacity does not fit u16")
	record_slots(builder, dst)
	emit_ABx(builder, .NEW_MAP, dst, capacity)
}

emit_vector_push :: proc(builder: ^CodeBuilder, vector_slot, value_slot: int) {
	record_slots(builder, vector_slot, value_slot)
	emit_ABC(builder, .VECTOR_PUSH, vector_slot, value_slot, 0)
}

emit_vector_pop :: proc(builder: ^CodeBuilder, dst, vector_slot: int) {
	record_slots(builder, dst, vector_slot)
	emit_ABC(builder, .VECTOR_POP, dst, vector_slot, 0)
}

emit_unpack_vector :: proc(builder: ^CodeBuilder, source_slot, first_dst, count: int) {
	assert(count > 0 && count <= int(max(u8)), "vector destructuring count does not fit u8")
	record_slots(builder, source_slot, first_dst, first_dst + count - 1)
	emit_ABC(builder, .UNPACK_VECTOR, source_slot, first_dst, count)
}

emit_set_index :: proc(builder: ^CodeBuilder, receiver_slot, index_slot, value_slot: int) {
	record_slots(builder, receiver_slot, index_slot, value_slot)
	emit_ABC(builder, .SET_INDEX, receiver_slot, index_slot, value_slot)
}

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

emit_return :: proc(builder: ^CodeBuilder, src: int) {
	record_slots(builder, src)
	emit_ABx(builder, .RETURN, src, 0)
}

emit_Ax :: proc(builder: ^CodeBuilder, op: Opcode, a: int) {
	assert(a >= 0 && a <= 0xffffff, "Ax operand does not fit u24")
	append(&builder.bytecode, u32(InstAx{
		op = op,
		a  = u32(a),
	}))
}

emit_jump :: proc(builder: ^CodeBuilder, target_index: int) {
	emit_Ax(builder, .JUMP, target_index)
}

emit_jump_if_falsey :: proc(builder: ^CodeBuilder, cond_slot, target_index: int) {
	assert(target_index >= 0 && target_index <= int(max(u16)), "jump target does not fit u16")
	record_slots(builder, cond_slot)
	emit_ABx(builder, .JUMP_IF_FALSEY, cond_slot, target_index)
}

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


// Compiler =======================================================================================

// Claims one frame slot above every value and binding that is currently live.
claim_slot :: proc(builder: ^CodeBuilder) -> int {
	if builder.next_slot >= MAX_FRAME_SLOTS {
		compile_error("code uses too many frame slots")
		return 0
	}

	slot := builder.next_slot
	builder.next_slot += 1
	return slot
}

// Reserves a contiguous slot range ending immediately before slot_after_last.
reserve_slots_until :: proc(builder: ^CodeBuilder, slot_after_last: int) {
	if slot_after_last > MAX_FRAME_SLOTS {
		compile_error("code uses too many frame slots")
		return
	}

	if builder.next_slot < slot_after_last {
		builder.next_slot = slot_after_last
	}
}

// Searches visible bindings from newest to oldest.
find_local :: proc(builder: ^CodeBuilder, symbol: ^SymbolObject) -> (LocalBinding, bool) {
	for i := builder.local_count - 1; i >= 0; i -= 1 {
		if builder.local_bindings[i].symbol == symbol {
			return builder.local_bindings[i], true
		}
	}

	return LocalBinding{}, false
}

symbol_is_reserved_word :: proc(symbol: ^SymbolObject) -> bool {
	return symbol.text == "def" ||
	       symbol.text == "const" ||
	       symbol.text == "set" ||
	       symbol.text == "do" ||
	       symbol.text == "if" ||
	       symbol.text == "while" ||
	       symbol.text == "fn" ||
	       symbol.text == "import" ||
	       symbol.text == "export"
}

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

resolve_upvalue :: proc(builder: ^CodeBuilder, symbol: ^SymbolObject) -> (int, bool) {
	if builder.parent == nil {
		return -1, false
	}

	parent_binding, parent_has_local := find_local(builder.parent, symbol)
	if parent_has_local {
		index := add_upvalue(builder, symbol, UpvalueDesc{
			from_parent_local = true,
			index             = parent_binding.slot,
			mutable           = parent_binding.mutable,
		})
		return index, true
	}

	parent_upvalue, parent_has_upvalue := resolve_upvalue(builder.parent, symbol)
	if parent_has_upvalue {
		index := add_upvalue(builder, symbol, UpvalueDesc{
			from_parent_local = false,
			index             = parent_upvalue,
			mutable           = builder.parent.upvalue_descs[parent_upvalue].mutable,
		})
		return index, true
	}

	return -1, false
}

compile_constant :: proc(builder: ^CodeBuilder, value: Value, dst: int) {
	if len(builder.constants) > int(max(u16)) {
		compile_error("code uses too many constants")
		return
	}

	constant_index := const_value(builder, value)
	emit_load_const(builder, dst, constant_index)
}

compile_symbol_expr :: proc(builder: ^CodeBuilder, symbol: ^SymbolObject, dst: int) {
	local_binding, local_found := find_local(builder, symbol)
	if local_found {
		emit_move(builder, dst, local_binding.slot)
		return
	}

	upvalue_index, upvalue_found := resolve_upvalue(builder, symbol)
	if upvalue_found {
		emit_get_upvalue(builder, dst, upvalue_index)
		return
	}

	builtin_index, builtin_found := find_builtin(Active_VM, symbol)
	if builtin_found {
		if builtin_index > int(max(u16)) {
			compile_error("builtin binding index does not fit bytecode")
			return
		}

		emit_get_builtin(builder, dst, builtin_index)
		return
	}

	compile_error(fmt.tprintf("undefined name `%s`", symbol.text))
}

compile_vector_expr :: proc(builder: ^CodeBuilder, vector: ^VectorObject, dst: int) {
	// Pushes determine length; this only avoids backing-storage growth.
	capacity_hint := len(vector.items)
	if capacity_hint > int(max(u16)) {
		capacity_hint = int(max(u16))
	}

	emit_new_vector(builder, dst, capacity_hint)

	if len(vector.items) == 0 {
		return
	}

	item_slot := claim_slot(builder)
	if Compiler.failed { return }

	for item in vector.items {
		compile_expr(builder, item, item_slot)
		if Compiler.failed { return }

		emit_vector_push(builder, dst, item_slot)
	}
}

compile_map_expr :: proc(builder: ^CodeBuilder, map_object: ^MapObject, dst: int) {
	// Source entries are linear pairs; runtime table capacity is only a hint.
	capacity_hint := len(map_object.entries)
	if capacity_hint > int(max(u16)) {
		capacity_hint = int(max(u16))
	}

	emit_new_map(builder, dst, capacity_hint)

	if len(map_object.entries) == 0 {
		return
	}

	key_slot := claim_slot(builder)
	value_slot := claim_slot(builder)
	if Compiler.failed { return }

	for entry in map_object.entries {
		compile_expr(builder, entry.key, key_slot)
		if Compiler.failed { return }

		compile_expr(builder, entry.value, value_slot)
		if Compiler.failed { return }

		emit_set_index(builder, dst, key_slot, value_slot)
	}
}

compile_binding :: proc(builder: ^CodeBuilder, form: Value, mutable: bool, form_name: string) {
	object, _ := form.(^Object)
	list := cast(^ListObject)object
	if len(list.items) < 2 {
		compile_error(fmt.tprintf("`%s` expects a binding", form_name))
		return
	}

	binding_object, binding_is_object := list.items[1].(^Object)
	if !binding_is_object {
		compile_error(fmt.tprintf("`%s` binding must be a name, function signature, or vector destructuring pattern", form_name))
		return
	}

	if binding_object.kind == .SYMBOL {
		if len(list.items) != 3 {
			compile_error(fmt.tprintf("value `%s` expects a name and value", form_name))
			return
		}

		name := cast(^SymbolObject)binding_object
		if symbol_is_reserved_word(name) {
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

		// Ordered binding: the name is not visible while its RHS compiles.
		compile_expr(builder, list.items[2], binding_slot)
		if Compiler.failed { return }

		binding := LocalBinding{
			symbol  = name,
			slot    = binding_slot,
			mutable = mutable,
		}

		builder.local_bindings[builder.local_count] = binding
		builder.local_count += 1

		if builder.parent == nil {
			append(&builder.file_bindings, binding)
		}
		return
	}

	if binding_object.kind == .VECTOR {
		if len(list.items) != 3 {
			compile_error(fmt.tprintf("vector destructuring `%s` expects a pattern and value", form_name))
			return
		}

		pattern := cast(^VectorObject)binding_object
		count := len(pattern.items)
		if count == 0 {
			compile_error("vector destructuring pattern cannot be empty")
			return
		}

		if count > int(max(u8)) {
			compile_error("vector destructuring supports at most 255 bindings")
			return
		}

		for i := 0; i < count; i += 1 {
			item_object, item_is_object := pattern.items[i].(^Object)
			if !item_is_object || item_object.kind != .SYMBOL {
				compile_error("vector destructuring binding must be a name")
				return
			}

			name := cast(^SymbolObject)item_object
			if symbol_is_reserved_word(name) {
				compile_error(fmt.tprintf("cannot define reserved name `%s`", name.text))
				return
			}

			for j := 0; j < i; j += 1 {
				previous_object, _ := pattern.items[j].(^Object)
				previous := cast(^SymbolObject)previous_object
				if previous == name {
					compile_error(fmt.tprintf("duplicate definition `%s` in vector destructuring pattern", name.text))
					return
				}
			}

			for j := builder.current_scope_local_start; j < builder.local_count; j += 1 {
				if builder.local_bindings[j].symbol == name {
					compile_error(fmt.tprintf("duplicate definition `%s` in the same scope", name.text))
					return
				}
			}
		}

		source_slot := claim_slot(builder)
		if Compiler.failed { return }

		// Ordered binding: destructured names are not visible while RHS compiles.
		compile_expr(builder, list.items[2], source_slot)
		if Compiler.failed { return }

		first_binding_slot := source_slot
		reserve_slots_until(builder, first_binding_slot + count)
		if Compiler.failed { return }

		emit_unpack_vector(builder, source_slot, first_binding_slot, count)

		for i := 0; i < count; i += 1 {
			item_object, _ := pattern.items[i].(^Object)
			name := cast(^SymbolObject)item_object

			binding := LocalBinding{
				symbol  = name,
				slot    = first_binding_slot + i,
				mutable = mutable,
			}

			builder.local_bindings[builder.local_count] = binding
			builder.local_count += 1

			if builder.parent == nil {
				append(&builder.file_bindings, binding)
			}
		}
		return
	}

	if binding_object.kind == .LIST {
		signature := cast(^ListObject)binding_object
		if len(signature.items) == 0 {
			compile_error(fmt.tprintf("function `%s` signature must start with a name", form_name))
			return
		}

		name_object, name_is_object := signature.items[0].(^Object)
		if !name_is_object || name_object.kind != .SYMBOL {
			compile_error(fmt.tprintf("function `%s` name must be a name", form_name))
			return
		}

		name := cast(^SymbolObject)name_object
		if symbol_is_reserved_word(name) {
			compile_error(fmt.tprintf("cannot define reserved name `%s`", name.text))
			return
		}

		for i := builder.current_scope_local_start; i < builder.local_count; i += 1 {
			if builder.local_bindings[i].symbol == name {
				compile_error(fmt.tprintf("duplicate definition `%s` in the same scope", name.text))
				return
			}
		}

		param_count := len(signature.items) - 1
		if param_count > int(max(u8)) {
			compile_error("function has too many parameters")
			return
		}

		for i := 0; i < param_count; i += 1 {
			param_value := signature.items[i + 1]

			param_object, param_is_object := param_value.(^Object)
			if !param_is_object || param_object.kind != .SYMBOL {
				compile_error("function parameter must be a name")
				return
			}

			param := cast(^SymbolObject)param_object
			if symbol_is_reserved_word(param) {
				compile_error(fmt.tprintf("cannot use reserved name `%s` as parameter", param.text))
				return
			}

			if param == name {
				compile_error(fmt.tprintf("parameter `%s` duplicates function name", param.text))
				return
			}

			for j := 0; j < i; j += 1 {
				previous_object, _ := signature.items[j + 1].(^Object)
				previous := cast(^SymbolObject)previous_object
				if previous == param {
					compile_error(fmt.tprintf("duplicate parameter `%s`", param.text))
					return
				}
			}
		}

		binding_slot := claim_slot(builder)
		if Compiler.failed { return }

		// Recursive named binding: publish the name before compiling the body.
		binding := LocalBinding{
			symbol  = name,
			slot    = binding_slot,
			mutable = mutable,
		}

		builder.local_bindings[builder.local_count] = binding
		builder.local_count += 1

		if builder.parent == nil {
			append(&builder.file_bindings, binding)
		}

		child := begin_code(builder, param_count, builder.source_name)

		for i := 0; i < param_count; i += 1 {
			param_object, _ := signature.items[i + 1].(^Object)
			param := cast(^SymbolObject)param_object

			child.local_bindings[child.local_count] = LocalBinding{
				symbol  = param,
				slot    = i,
				mutable = true,
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

		if len(builder.child_codes) > int(max(u16)) {
			compile_error("too many function literals in one body")
			delete_code(child_code)
			return
		}

		append(&builder.child_codes, child_code)
		child_index := len(builder.child_codes) - 1

		emit_load_function(builder, binding_slot, child_index)
		return
	}

	compile_error(fmt.tprintf("`%s` binding must be a name, function signature, or vector destructuring pattern", form_name))
}

compile_def :: proc(builder: ^CodeBuilder, form: Value) {
	compile_binding(builder, form, true, "def")
}

compile_const :: proc(builder: ^CodeBuilder, form: Value) {
	compile_binding(builder, form, false, "const")
}

compile_import :: proc(builder: ^CodeBuilder, list: ^ListObject) {
	if len(list.items) != 2 && len(list.items) != 3 {
		compile_error("`import` expects a path or namespace and path")
		return
	}

	namespace_text: string
	path_value: Value

	if len(list.items) == 2 {
		path_value = list.items[1]
	} else {
		alias_object, alias_is_object := list.items[1].(^Object)
		if !alias_is_object || alias_object.kind != .SYMBOL {
			compile_error("`import` namespace must be a name")
			return
		}

		alias := cast(^SymbolObject)alias_object
		if symbol_is_reserved_word(alias) {
			compile_error(fmt.tprintf("cannot use reserved name `%s` as import namespace", alias.text))
			return
		}

		namespace_text = alias.text
		path_value = list.items[2]
	}

	path_object, path_is_object := path_value.(^Object)
	if !path_is_object || path_object.kind != .STRING {
		compile_error("`import` path must be a string")
		return
	}

	import_path := (cast(^StringObject)path_object).text
	if namespace_text == "" {
		namespace_text = filepath.stem(import_path)
	}

	if namespace_text == "" {
		compile_error("`import` namespace cannot be empty")
		return
	}

	for i := 0; i < len(namespace_text); i += 1 {
		if namespace_text[i] == '/' || namespace_text[i] == '\\' {
			compile_error("`import` namespace cannot contain a path separator")
			return
		}
	}

	module := load_module(Active_VM, builder.source_name, import_path)
	if Compiler.failed { return }
	assert(module != nil, "load_module returned nil without failing")

	for export in module.exports {
		qualified_text := fmt.tprintf("%s/%s", namespace_text, export.symbol.text)
		qualified_symbol := intern_symbol(Active_VM, qualified_text)

		for i := builder.current_scope_local_start; i < builder.local_count; i += 1 {
			if builder.local_bindings[i].symbol == qualified_symbol {
				compile_error(fmt.tprintf("duplicate imported binding `%s`", qualified_text))
				return
			}
		}

		binding_slot := claim_slot(builder)
		if Compiler.failed { return }

		compile_constant(builder, export.value, binding_slot)
		if Compiler.failed { return }

		builder.local_bindings[builder.local_count] = LocalBinding{
			symbol  = qualified_symbol,
			slot    = binding_slot,
			mutable = export.mutable,
		}
		builder.local_count += 1
	}
}

compile_export :: proc(builder: ^CodeBuilder, list: ^ListObject) {
	if len(list.items) == 1 {
		for binding in builder.file_bindings {
			append(&builder.exports, binding)
		}
		return
	}

	for i := 1; i < len(list.items); i += 1 {
		name_object, name_is_object := list.items[i].(^Object)
		if !name_is_object || name_object.kind != .SYMBOL {
			compile_error("`export` names must be names")
			return
		}

		name := cast(^SymbolObject)name_object

		for existing in builder.exports {
			if existing.symbol == name {
				compile_error(fmt.tprintf("duplicate export `%s`", name.text))
				return
			}
		}

		found := false
		for binding in builder.file_bindings {
			if binding.symbol == name {
				append(&builder.exports, binding)
				found = true
				break
			}
		}

		if !found {
			compile_error(fmt.tprintf("exported name `%s` is not a file binding", name.text))
			return
		}
	}
}

// Definitions mutate the local environment and do not become the body result.
// The last expression result wins; defs-only and empty bodies return nil.
compile_body :: proc(builder: ^CodeBuilder, forms: []Value, dst: int) {
	had_result_expr := false

	for form in forms {
		object, is_object := form.(^Object)
		if is_object && object.kind == .LIST {
			list := cast(^ListObject)object

			if len(list.items) > 0 {
				head_object, head_is_object := list.items[0].(^Object)
				if head_is_object && head_object.kind == .SYMBOL {
					head := cast(^SymbolObject)head_object
					if head.text == "def" {
						compile_def(builder, form)
						if Compiler.failed { return }
						continue
					}
					if head.text == "const" {
						compile_const(builder, form)
						if Compiler.failed { return }
						continue
					}
				}
			}
		}

		compile_expr(builder, form, dst)
		if Compiler.failed { return }
		had_result_expr = true
	}

	if !had_result_expr {
		emit_load_nil(builder, dst)
	}
}

compile_root_forms :: proc(builder: ^CodeBuilder, forms: []Value, dst: int) {
	had_result_expr := false
	seen_non_import := false

	for form, form_index in forms {
		object, is_object := form.(^Object)
		if is_object && object.kind == .LIST {
			list := cast(^ListObject)object

			if len(list.items) > 0 {
				head_object, head_is_object := list.items[0].(^Object)
				if head_is_object && head_object.kind == .SYMBOL {
					head := cast(^SymbolObject)head_object

					if head.text == "import" {
						if seen_non_import {
							compile_error("`import` forms must appear before other root forms")
							return
						}

						compile_import(builder, list)
						if Compiler.failed { return }
						continue
					}

					if head.text == "export" {
						compile_export(builder, list)
						if Compiler.failed { return }

						if form_index + 1 < len(forms) {
							compile_error("`export` must be the final root form")
							return
						}

						if !had_result_expr {
							emit_load_nil(builder, dst)
						}
						return
					}

					seen_non_import = true

					if head.text == "def" {
						compile_def(builder, form)
						if Compiler.failed { return }
						continue
					}
					if head.text == "const" {
						compile_const(builder, form)
						if Compiler.failed { return }
						continue
					}
				}
			}
		}

		seen_non_import = true

		compile_expr(builder, form, dst)
		if Compiler.failed { return }
		had_result_expr = true
	}

	if !had_result_expr {
		emit_load_nil(builder, dst)
	}
}

compile_do :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	// A do body owns its bindings and restores the outer live-slot boundary.
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

compile_if :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	if len(list.items) < 3 || len(list.items) > 4 {
		compile_error("`if` expects a condition, then-branch, and optional else-branch")
		return
	}

	compile_expr(builder, list.items[1], dst)
	if Compiler.failed { return }

	false_jump := len(builder.bytecode)
	emit_jump_if_falsey(builder, dst, 0)
	if Compiler.failed { return }

	compile_expr(builder, list.items[2], dst)
	if Compiler.failed { return }

	end_jump := len(builder.bytecode)
	emit_jump(builder, 0)
	if Compiler.failed { return }

	patch_jump_target(builder, false_jump, len(builder.bytecode))

	if len(list.items) == 4 {
		compile_expr(builder, list.items[3], dst)
	} else {
		emit_load_nil(builder, dst)
	}
	if Compiler.failed { return }

	patch_jump_target(builder, end_jump, len(builder.bytecode))
}

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

		binding, local_found := find_local(builder, symbol)
		if local_found {
			if !binding.mutable {
				compile_error(fmt.tprintf("cannot set immutable binding `%s`", symbol.text))
				return
			}

			// Visible binding slots are not general expression destinations.
			// Compile the complete RHS into dst before updating the binding.
			compile_expr(builder, value, dst)
			if Compiler.failed { return }

			emit_move(builder, binding.slot, dst)
			return
		}

		upvalue_index, upvalue_found := resolve_upvalue(builder, symbol)
		if upvalue_found {
			if !builder.upvalue_descs[upvalue_index].mutable {
				compile_error(fmt.tprintf("cannot set immutable binding `%s`", symbol.text))
				return
			}

			compile_expr(builder, value, dst)
			if Compiler.failed { return }

			emit_set_upvalue(builder, upvalue_index, dst)
			return
		}

		builtin_index, builtin_found := find_builtin(Active_VM, symbol)
		if builtin_found {
			if !Active_VM.builtins[builtin_index].mutable {
				compile_error(fmt.tprintf("cannot set immutable binding `%s`", symbol.text))
				return
			}

			compile_error("setting mutable builtin bindings is not implemented")
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

compile_call :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	argument_count := len(list.items) - 1
	if argument_count > int(max(u8)) {
		compile_error("call has too many arguments")
		return
	}

	// CALL needs a contiguous callee/result and argument window above live slots.
	base := builder.next_slot
	reserve_slots_until(builder, base + argument_count + 1)
	if Compiler.failed { return }

	compile_expr(builder, list.items[0], base)
	if Compiler.failed { return }

	for i := 0; i < argument_count; i += 1 {
		compile_expr(builder, list.items[i + 1], base + 1 + i)
		if Compiler.failed { return }
	}

	emit_call(builder, base, argument_count)
	emit_move(builder, dst, base)
}

compile_builtin_fast_path :: proc(builder: ^CodeBuilder, symbol: ^SymbolObject, args: []Value, dst: int) {
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
			operand_base = builder.next_slot
			reserve_slots_until(builder, operand_base + operand_count)
			if Compiler.failed { return }
		}

		for i := 0; i < operand_count; i += 1 {
			compile_expr(builder, args[i], operand_base + i)
			if Compiler.failed { return }
		}

		if symbol.text == "+" {
			emit_add(builder, dst, operand_base, operand_count)
		} else if symbol.text == "-" {
			emit_sub(builder, dst, operand_base, operand_count)
		} else if symbol.text == "*" {
			emit_mul(builder, dst, operand_base, operand_count)
		} else {
			emit_div(builder, dst, operand_base, operand_count)
		}
		return
	}

	if symbol.text == "%" ||
	   symbol.text == "=" ||
	   symbol.text == "!=" ||
	   symbol.text == "<" ||
	   symbol.text == "<=" ||
	   symbol.text == ">" ||
	   symbol.text == ">=" {
		operand_base := builder.next_slot
		reserve_slots_until(builder, operand_base + 2)
		if Compiler.failed { return }

		compile_expr(builder, args[0], operand_base)
		if Compiler.failed { return }

		compile_expr(builder, args[1], operand_base + 1)
		if Compiler.failed { return }

		if symbol.text == "%" {
			emit_mod(builder, dst, operand_base, operand_base + 1)
		} else if symbol.text == "=" {
			emit_equal(builder, dst, operand_base, operand_base + 1)
		} else if symbol.text == "!=" {
			emit_equal(builder, dst, operand_base, operand_base + 1)
			emit_not(builder, dst, dst)
		} else if symbol.text == "<" {
			emit_less(builder, dst, operand_base, operand_base + 1)
		} else if symbol.text == "<=" {
			emit_less_equal(builder, dst, operand_base, operand_base + 1)
		} else if symbol.text == ">" {
			emit_greater(builder, dst, operand_base, operand_base + 1)
		} else {
			emit_greater_equal(builder, dst, operand_base, operand_base + 1)
		}
		return
	}

	if symbol.text == "not" ||
	   symbol.text == "len" {
		compile_expr(builder, args[0], dst)
		if Compiler.failed { return }

		if symbol.text == "not" {
			emit_not(builder, dst, dst)
		} else {
			emit_len(builder, dst, dst)
		}
		return
	}

	if symbol.text == "push" {
		if len(args) > int(max(u8)) {
			compile_error("`push` has too many arguments")
			return
		}

		value_count := len(args) - 1
		value_base := builder.next_slot
		reserve_slots_until(builder, value_base + value_count)
		if Compiler.failed { return }

		compile_expr(builder, args[0], dst)
		if Compiler.failed { return }

		for i := 0; i < value_count; i += 1 {
			compile_expr(builder, args[i + 1], value_base + i)
			if Compiler.failed { return }
		}

		for i := 0; i < value_count; i += 1 {
			emit_vector_push(builder, dst, value_base + i)
		}
		return
	}

	if symbol.text == "pop" {
		compile_expr(builder, args[0], dst)
		if Compiler.failed { return }

		emit_vector_pop(builder, dst, dst)
		return
	}

	assert(false, "compile_builtin_fast_path expected opcode-backed builtin")
}

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

	for i := 0; i < len(params.items); i += 1 {
		param_object, param_is_object := params.items[i].(^Object)
		if !param_is_object || param_object.kind != .SYMBOL {
			compile_error("function parameter must be a name")
			return
		}

		param := cast(^SymbolObject)param_object
		if symbol_is_reserved_word(param) {
			compile_error(fmt.tprintf("cannot use reserved name `%s` as parameter", param.text))
			return
		}

		for j := 0; j < i; j += 1 {
			previous_object, _ := params.items[j].(^Object)
			previous := cast(^SymbolObject)previous_object
			if previous == param {
				compile_error(fmt.tprintf("duplicate parameter `%s`", param.text))
				return
			}
		}
	}

	child := begin_code(parent, len(params.items), parent.source_name)

	for i := 0; i < len(params.items); i += 1 {
		param_object, _ := params.items[i].(^Object)
		param := cast(^SymbolObject)param_object
		child.local_bindings[child.local_count] = LocalBinding{
			symbol  = param,
			slot    = i,
			mutable = true,
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

	if len(parent.child_codes) > int(max(u16)) {
		compile_error("too many function literals in one body")
		delete_code(child_code)
		return
	}

	append(&parent.child_codes, child_code)
	child_index := len(parent.child_codes) - 1

	emit_load_function(parent, dst, child_index)
}

// Bare heads resolve as special forms, then ordinary bindings.
// Direct calls to supplied arithmetic and vector builtins may use dedicated opcodes.
// Non-symbol heads are ordinary calls.
compile_list_expr :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	if len(list.items) == 0 {
		compile_error("empty list is not an expression")
		return
	}

	head_object, head_is_object := list.items[0].(^Object)
	if !head_is_object || head_object.kind != .SYMBOL {
		compile_call(builder, list, dst)
		return
	}

	head := cast(^SymbolObject)head_object

	if head.text == "def" {
		compile_error("`def` is not valid in expression position")
		return
	}
	if head.text == "const" {
		compile_error("`const` is not valid in expression position")
		return
	}
	if head.text == "import" {
		compile_error("`import` is only valid at file root")
		return
	}
	if head.text == "export" {
		compile_error("`export` is only valid at file root")
		return
	}
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

	// Do not lower builtin-looking heads to opcodes if a lexical binding with
	// the same name is visible. This scan must not call resolve_upvalue,
	// because resolve_upvalue records captures and this check is only asking
	// whether builtin fast-path lowering is shadowed.
	builtin_shadowed := false
	for current := builder; current != nil; current = current.parent {
		_, found := find_local(current, head)
		if found {
			builtin_shadowed = true
			break
		}
	}

	if builtin_shadowed {
		compile_call(builder, list, dst)
		return
	}

	_, builtin_found := find_builtin(Active_VM, head)
	if builtin_found {
		argument_count := len(list.items) - 1

		if head.text == "+" ||
		   head.text == "-" ||
		   head.text == "*" ||
		   head.text == "/" {
			compile_builtin_fast_path(builder, head, list.items[1:], dst)
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
			compile_builtin_fast_path(builder, head, list.items[1:], dst)
			return
		}

		if (head.text == "not" ||
		    head.text == "len") &&
		   argument_count == 1 {
			compile_builtin_fast_path(builder, head, list.items[1:], dst)
			return
		}

		if (head.text == "push" && argument_count >= 2) ||
		   (head.text == "pop" && argument_count == 1) {
			compile_builtin_fast_path(builder, head, list.items[1:], dst)
			return
		}

		compile_call(builder, list, dst)
		return
	}

	compile_error(fmt.tprintf("undefined name `%s`", head.text))
}

// The caller reserves dst. Expression compilation may use higher scratch slots
// but restores the live slot boundary it received.
compile_expr :: proc(builder: ^CodeBuilder, value: Value, dst: int) {
	slot_mark := builder.next_slot

	if value == nil {
		emit_load_nil(builder, dst)
		builder.next_slot = slot_mark
		return
	}

	switch v in value {
	case bool:
		if v {
			emit_load_true(builder, dst)
		} else {
			emit_load_false(builder, dst)
		}

	case i64, f64:
		compile_constant(builder, value, dst)

	case ^Object:
		switch v.kind {
		case .STRING:
			compile_constant(builder, value, dst)

		case .SYMBOL:
			compile_symbol_expr(builder, cast(^SymbolObject)v, dst)

		case .LIST:
			compile_list_expr(builder, cast(^ListObject)v, dst)

		case .VECTOR:
			compile_vector_expr(builder, cast(^VectorObject)v, dst)

		case .MAP:
			compile_map_expr(builder, cast(^MapObject)v, dst)

		case .NATIVE_FUNCTION, .FUNCTION:
			compile_error("runtime function object cannot appear as a literal form")
		}
	}

	builder.next_slot = slot_mark
}

compile_forms :: proc(forms: []Value, source_name: string) -> ^Code {
	Compiler.failed = false
	root := begin_code(nil, 0, source_name)

	return_slot := claim_slot(&root)
	if Compiler.failed {
		delete_code_builder(&root)
		return nil
	}

	compile_root_forms(&root, forms, return_slot)
	if Compiler.failed {
		delete_code_builder(&root)
		return nil
	}

	emit_return(&root, return_slot)
	return end_code(&root)
}


make_vm :: proc() -> VM {
	vm := VM{
		slots         = make([dynamic]Value),
		frames        = make([dynamic]CallFrame),
		open_upvalues = make([dynamic]^Upvalue),
		builtins      = make([dynamic]Binding),
		modules       = make([dynamic]Module),
		symbols       = make([dynamic]^SymbolObject),
	}

	install_builtins(&vm)
	install_core_modules(&vm)
	return vm
}

// VM execution ===================================================================================

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

// Executes trusted Code against the selected VM using frame-relative slot operands.
run_code :: proc(code: ^Code) -> Value {
	vm := Active_VM

	delete(vm.slots)
	vm.slots = make([dynamic]Value)

	clear(&vm.frames)
	clear(&vm.open_upvalues)

	for len(vm.slots) < code.frame_slot_count {
		append(&vm.slots, Value{})
	}

	append(&vm.frames, CallFrame{
		code              = code,
		upvalues          = nil,
		instruction_index = 0,
		slot_base         = 0,
	})

	for {
		assert(len(vm.frames) > 0, "VM has no active frame")
		frame := &vm.frames[len(vm.frames) - 1]
		assert(frame.instruction_index < len(frame.code.bytecode), "code ended without RETURN")

		word := frame.code.bytecode[frame.instruction_index]
		frame.instruction_index += 1

		op := InstABC(word).op

		switch op {
		case .LOAD_NIL:
			inst := InstABx(word)
			vm.slots[frame.slot_base + int(inst.a)] = Value{}

		case .LOAD_TRUE:
			inst := InstABx(word)
			vm.slots[frame.slot_base + int(inst.a)] = Value(bool(true))

		case .LOAD_FALSE:
			inst := InstABx(word)
			vm.slots[frame.slot_base + int(inst.a)] = Value(bool(false))

		case .LOAD_CONST:
			inst := InstABx(word)
			constant_index := int(inst.b)
			assert(constant_index < len(frame.code.constants), "constant index out of range")
			vm.slots[frame.slot_base + int(inst.a)] = frame.code.constants[constant_index]

		case .MOVE:
			inst := InstABC(word)
			vm.slots[frame.slot_base + int(inst.a)] = vm.slots[frame.slot_base + int(inst.b)]

		case .GET_BUILTIN:
			inst := InstABx(word)
			builtin_index := int(inst.b)
			assert(builtin_index < len(vm.builtins), "builtin index out of range")
			vm.slots[frame.slot_base + int(inst.a)] = vm.builtins[builtin_index].value

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

		case .CLOSE_UPVALUES:
			inst := InstABx(word)
			absolute_start := frame.slot_base + int(inst.a)
			close_upvalues_from(vm, absolute_start)

		case .ADD, .SUB, .MUL, .DIV:
			inst := InstABC(word)
			dst := frame.slot_base + int(inst.a)
			first_slot := frame.slot_base + int(inst.b)
			argument_count := int(inst.c)
			args := vm.slots[first_slot:first_slot + argument_count]

			result: Value
			#partial switch op {
			case .ADD:
				result = op_add(args)
			case .SUB:
				result = op_sub(args)
			case .MUL:
				result = op_mul(args)
			case .DIV:
				result = op_div(args)
			}

			// Error returns are disposable and must not be stored in dst.
			if vm.error_string != "" {
				return Value{}
			}
			vm.slots[dst] = result

		case .MOD, .EQUAL, .LESS, .LESS_EQUAL, .GREATER, .GREATER_EQUAL:
			// These binary operations share A=dst, B=lhs, C=rhs.
			inst := InstABC(word)
			dst := frame.slot_base + int(inst.a)
			lhs := vm.slots[frame.slot_base + int(inst.b)]
			rhs := vm.slots[frame.slot_base + int(inst.c)]

			result: Value
			#partial switch op {
			case .MOD:
				result = op_mod(lhs, rhs)
			case .EQUAL:
				result = op_equal(lhs, rhs)
			case .LESS:
				result = op_less(lhs, rhs)
			case .LESS_EQUAL:
				result = op_less_equal(lhs, rhs)
			case .GREATER:
				result = op_greater(lhs, rhs)
			case .GREATER_EQUAL:
				result = op_greater_equal(lhs, rhs)
			}

			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = result

		case .NOT, .LEN:
			// These unary operations share A=dst, B=src; LEN may fail.
			inst := InstABC(word)
			dst := frame.slot_base + int(inst.a)
			src := vm.slots[frame.slot_base + int(inst.b)]

			result: Value
			#partial switch op {
			case .NOT:
				result = op_not(src)
			case .LEN:
				result = op_len(src)
			}

			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = result

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

			// Arguments occupy the contiguous slots immediately after A.
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

				wanted_slots := callee_slot_base + function.code.frame_slot_count
				for len(vm.slots) < wanted_slots {
					append(&vm.slots, Value{})
				}

				append(&vm.frames, CallFrame{
					code              = function.code,
					upvalues          = function.upvalues,
					instruction_index = 0,
					slot_base         = callee_slot_base,
				})

				continue

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

			case .MAP:
				if argument_count != 1 {
					runtime_error("map call expects one key")
					return Value{}
				}

				result := map_get(cast(^MapObject)callee_object, vm.slots[base + 1])
				if vm.error_string != "" { return Value{} }
				vm.slots[base] = result

			case .STRING, .SYMBOL, .LIST:
				runtime_error("value is not callable")
				return Value{}
			}

		case .NEW_VECTOR:
			// Capacity reserves backing storage; the new vector length is zero.
			inst := InstABx(word)
			dst := frame.slot_base + int(inst.a)
			capacity := int(inst.b)

			items := make([dynamic]Value)
			if capacity > 0 {
				reserve(&items, capacity)
			}

			vm.slots[dst] = Value(cast(^Object)new_vector_object(items))

		case .NEW_MAP:
			// Capacity is a pair-count hint; map_init chooses the bucket count.
			inst := InstABx(word)
			dst := frame.slot_base + int(inst.a)

			object := new_map_object()
			map_init(object, int(inst.b))
			vm.slots[dst] = Value(cast(^Object)object)

		case .VECTOR_PUSH:
			// A already holds the vector and remains the result after mutation.
			inst := InstABC(word)
			op_push(vm.slots[frame.slot_base + int(inst.a)], vm.slots[frame.slot_base + int(inst.b)])
			if vm.error_string != "" { return Value{} }

		case .VECTOR_POP:
			// Validate the pop before replacing A with the removed value.
			inst := InstABC(word)
			result := op_pop(vm.slots[frame.slot_base + int(inst.b)])
			if vm.error_string != "" { return Value{} }
			vm.slots[frame.slot_base + int(inst.a)] = result

		case .UNPACK_VECTOR:
			inst := InstABC(word)
			source_slot := frame.slot_base + int(inst.a)
			first_dst := frame.slot_base + int(inst.b)
			count := int(inst.c)

			source_object, source_is_object := vm.slots[source_slot].(^Object)
			if !source_is_object || source_object.kind != .VECTOR {
				runtime_error("vector destructuring expects vector")
				return Value{}
			}

			vector := cast(^VectorObject)source_object
			if len(vector.items) < count {
				runtime_error(fmt.tprintf("vector destructuring expected at least %d values, got %d", count, len(vector.items)))
				return Value{}
			}

			for i := 0; i < count; i += 1 {
				vm.slots[first_dst + i] = vector.items[i]
			}

		case .SET_INDEX:
			// C remains the set-expression result; this opcode only mutates A.
			inst := InstABC(word)
			receiver_value := vm.slots[frame.slot_base + int(inst.a)]
			index_value := vm.slots[frame.slot_base + int(inst.b)]
			new_value := vm.slots[frame.slot_base + int(inst.c)]

			receiver_object, receiver_is_object := receiver_value.(^Object)
			if !receiver_is_object {
				runtime_error("indexed set receiver must be vector or map")
				return Value{}
			}

			switch receiver_object.kind {
			case .VECTOR:
				index, index_is_int := index_value.(i64)
				if !index_is_int {
					runtime_error("vector set index must be int")
					return Value{}
				}

				vector := cast(^VectorObject)receiver_object
				if index < 0 || index >= i64(len(vector.items)) {
					runtime_error("vector index out of range")
					return Value{}
				}

				vector.items[int(index)] = new_value

			case .MAP:
				map_set(cast(^MapObject)receiver_object, index_value, new_value)
				if vm.error_string != "" { return Value{} }

			case .STRING, .SYMBOL, .LIST, .NATIVE_FUNCTION, .FUNCTION:
				runtime_error("indexed set receiver must be vector or map")
				return Value{}
			}

		case .JUMP:
			inst := InstAx(word)
			frame.instruction_index = int(inst.a)

		case .JUMP_IF_FALSEY:
			inst := InstABx(word)
			cond := vm.slots[frame.slot_base + int(inst.a)]
			if value_is_falsey(cond) {
				frame.instruction_index = int(inst.b)
			}

		case .RETURN:
			inst := InstABx(word)
			result := vm.slots[frame.slot_base + int(inst.a)]

			close_upvalues_from(vm, frame.slot_base)

			if len(vm.frames) == 1 {
				return result
			}

			return_slot := frame.slot_base - 1

			pop(&vm.frames)

			vm.slots[return_slot] = result

		case:
			assert(false, "invalid opcode")
		}
	}
}


// Host operations ===============================================================================

run_source :: proc(source, source_name: string) -> Value {
	forms := read_source(source)
	if Reader.failed { return Value{} }
	defer delete(forms)

	code := compile_forms(forms[:], source_name)
	if Compiler.failed { return Value{} }

	return run_code(code)
}

// Owns one read, compile, and execute operation and its diagnostic lifetime.
run_string :: proc(vm: ^VM, source: string) -> Value {
	Active_VM = vm
	clear_error(vm)
	return run_source(source, "")
}

// Reads an exact path, then runs the shared source pipeline using its resolved path.
run_file :: proc(vm: ^VM, path: string) -> Value {
	Active_VM = vm
	clear_error(vm)

	resolved_path, resolve_error := filepath.abs(path, context.allocator)
	if resolve_error != nil {
		set_error(fmt.tprintf("read error: could not resolve file `%s`", path))
		return Value{}
	}
	defer delete(resolved_path)

	source_bytes, read_error := os.read_entire_file(resolved_path, context.allocator)
	if read_error != nil {
		set_error(fmt.tprintf("read error: could not read file `%s`", path))
		return Value{}
	}
	defer delete(source_bytes)

	return run_source(string(source_bytes), resolved_path)
}
