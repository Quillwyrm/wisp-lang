package obel

import "base:intrinsics"
import "core:fmt"
import "core:hash"
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

	// Reader lists hold source forms. Obel does not expose a runtime list literal.
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

	active_iteration_count: int,
}

// The zero value of this union represents Obel nil.
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

	ADD_CONST, // ABC: A=dst, B=lhs, C=constant index
	SUB_CONST, // ABC: A=dst, B=lhs, C=constant index
	MUL_CONST, // ABC: A=dst, B=lhs, C=constant index
	DIV_CONST, // ABC: A=dst, B=lhs, C=constant index
	MOD_CONST, // ABC: A=dst, B=lhs, C=constant index

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
	VECTOR_GET,       // ABC: A=dst, B=vector, C=index
	VECTOR_GET_CONST, // ABC: A=dst, B=vector, C=constant index
	VECTOR_SET,       // ABC: A=vector, B=index, C=value -> expression result remains in C
	VECTOR_SET_CONST, // ABC: A=vector, B=constant index, C=value -> expression result remains in C
	MAP_GET,       // ABC: A=dst, B=map, C=key
	MAP_GET_CONST, // ABC: A=dst, B=map, C=constant key
	MAP_SET,       // ABC: A=map, B=key, C=value -> expression result remains in C
	MAP_SET_CONST, // ABC: A=map, B=constant key, C=value -> expression result remains in C
	EACH_INIT,     // ABC: A=state base, B=collection, C=map target ok
	EACH_NEXT,     // ABC: A=state base, B=collection
	EACH_END,      // ABC: A=state base, B=collection

	RETURN, // ABx: A=src

	JUMP,           // Ax: A=target instruction index
	JUMP_IF_FALSEY, // ABx: A=cond_slot, Bx=target instruction index
	JUMP_IF_NIL,    // ABx: A=slot, Bx=target instruction index
	JUMP_IF_NOT_LESS,          // ABC + target word: A=lhs, B=rhs
	JUMP_IF_NOT_LESS_EQUAL,    // ABC + target word: A=lhs, B=rhs
	JUMP_IF_NOT_GREATER,       // ABC + target word: A=lhs, B=rhs
	JUMP_IF_NOT_GREATER_EQUAL, // ABC + target word: A=lhs, B=rhs
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

	frame_slot_count:  int,
	fixed_param_count: int,
	has_rest_param:   bool,

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

MAX_VM_SLOTS :: 4096
MAX_CALL_FRAMES :: 256

// One host-owned execution world; builtins/modules persist while slots reset per run.
// Slots and frames are fixed-size VM storage, not heap-owned per-call arrays.
VM :: struct {
	slots: [MAX_VM_SLOTS]Value,

	frames: [MAX_CALL_FRAMES]CallFrame,
	frame_count: int,

	open_upvalues: [dynamic]^Upvalue,
	call_slot_top: int,

	builtins: [dynamic]Binding,
	modules:  [dynamic]Module,
	symbols:  [dynamic]^SymbolObject,

	argv:       []string,
	args_start: int,

	// Current host-operation diagnostic; empty means no error.
	error_string: string,
}

// Compiler and runtime entry procs select the VM used by internal helpers.
Active_VM: ^VM

set_argv :: proc(vm: ^VM, argv: []string, args_start: int) {
	vm.argv = argv
	vm.args_start = args_start
}


// Compiler data ==================================================================================

MAX_FRAME_SLOTS :: int(max(u8)) + 1

LocalBinding :: struct {
	symbol:  ^SymbolObject,
	slot:    int,
	mutable: bool,
}

ActiveLoop :: struct {
	// First break jump fixup owned by this loop.
	break_base: int,

	// First slot to close when break exits this loop body.
	close_slot: int,
}

ConstCacheEntry :: struct {
	hash:  u64,
	index: int,
}

CodeBuilder :: struct {
	bytecode:    [dynamic]u32,
	constants:   [dynamic]Value,
	const_cache: [dynamic]ConstCacheEntry,
	child_codes: [dynamic]^Code,

	frame_slot_count:  int,
	fixed_param_count: int,
	has_rest_param:   bool,

	local_bindings: [MAX_FRAME_SLOTS]LocalBinding,
	local_count:    int,

	// Begins duplicate-definition checks for the current lexical scope.
	current_scope_local_start: int,
	next_slot:                 int,

	upvalue_descs:   [dynamic]UpvalueDesc,
	upvalue_symbols: [dynamic]^SymbolObject,

	active_loops:       [dynamic]ActiveLoop,
	break_jump_fixups:  [dynamic]int,

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

// Interned symbols provide name identity for reader/compiler bindings.
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

value_is_function :: proc(value: Value) -> bool {
	object, is_object := value.(^Object)
	return is_object && (object.kind == .NATIVE_FUNCTION || object.kind == .FUNCTION)
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
	// hash == 0 means "not cached"; a real zero hash only recomputes.
	if object.hash == 0 {
		object.hash = hash.fnv64a(transmute([]byte)object.text)
	}
	return object.hash
}

// Hashes one legal runtime map key. Numeric hashing mirrors Obel's current
// mixed comparison rule by first converting ints to f64.
map_key_hash :: proc(key: Value) -> (u64, bool) {
	if key == nil {
		runtime_error("map key cannot be nil.")
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
			runtime_error("map key cannot be NaN.")
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
			assert(false, "symbol is not an Obel runtime value")
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

// String keys avoid generic Value hashing and equality dispatch.
map_find_slot_string :: proc(map_object: ^MapObject, key: ^StringObject, key_hash: u64) -> (index: int, found: bool) {
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

		if entry.hash == key_hash {
			entry_object, entry_is_object := entry.key.(^Object)
			if entry_is_object && entry_object.kind == .STRING {
				entry_string := cast(^StringObject)entry_object
				if entry_string == key || entry_string.text == key.text {
					return index, true
				}
			}
		}
	}

	if first_tombstone >= 0 {
		return first_tombstone, false
	}

	panic("map_find_slot_string reached full table")
}

map_get :: proc(map_object: ^MapObject, key: Value) -> Value {
	key_object, key_is_object := key.(^Object)
	if key_is_object && key_object.kind == .STRING {
		if len(map_object.entries) == 0 {
			return Value{}
		}

		key_string := cast(^StringObject)key_object
		key_hash := string_hash(key_string)
		index, found := map_find_slot_string(map_object, key_string, key_hash)
		if !found {
			return Value{}
		}

		return map_object.entries[index].value
	}

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

// map_set is the insertion/update/delete boundary for maps.
// Live map each allows updates and deletes, but forbids adding new keys.
map_set :: proc(map_object: ^MapObject, key, value: Value) {
	key_object, key_is_object := key.(^Object)
	if key_is_object && key_object.kind == .STRING {
		key_string := cast(^StringObject)key_object
		key_hash := string_hash(key_string)

		if value == nil {
			if len(map_object.entries) == 0 {
				return
			}

			index, found := map_find_slot_string(map_object, key_string, key_hash)
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
			return
		}

		index := 0
		found := false
		if len(map_object.entries) != 0 {
			index, found = map_find_slot_string(map_object, key_string, key_hash)
			if found {
				map_object.entries[index].value = value
				return
			}
		}

		if map_object.active_iteration_count > 0 {
			runtime_error("cannot add key to map during active `each`.")
			return
		}

		if len(map_object.entries) == 0 {
			map_init(map_object, 4)
			index, found = map_find_slot_string(map_object, key_string, key_hash)
		} else if (map_object.count + map_object.tombstone_count + 1) * 4 >= len(map_object.entries) * 3 {
			map_grow(map_object)
			index, found = map_find_slot_string(map_object, key_string, key_hash)
		}

		entry := &map_object.entries[index]
		if entry.tombstone {
			map_object.tombstone_count -= 1
		}

		entry.key = Value(cast(^Object)key_string)
		entry.hash = key_hash
		entry.value = value
		entry.tombstone = false
		map_object.count += 1
		return
	}

	key_hash, valid_key := map_key_hash(key)
	if !valid_key { return }

	if value == nil {
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
		return
	}

	index := 0
	found := false
	if len(map_object.entries) != 0 {
		index, found = map_find_slot(map_object, key, key_hash)
		if found {
			map_object.entries[index].value = value
			return
		}
	}

	if map_object.active_iteration_count > 0 {
		runtime_error("cannot add key to map during active `each`.")
		return
	}

	if len(map_object.entries) == 0 {
		map_init(map_object, 4)
		index, found = map_find_slot(map_object, key, key_hash)
	} else if (map_object.count + map_object.tombstone_count + 1) * 4 >= len(map_object.entries) * 3 {
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

number_from_text :: proc(text: string, report_reader_errors: bool) -> (Value, bool) {
	if len(text) == 0 {
		if report_reader_errors { reader_error("invalid number literal.") }
		return Value{}, false
	}

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

	// Valid numbers contain a digit and consume the entire text.
	if digit_count == 0 || number_index != len(text) {
		if report_reader_errors { reader_error("invalid number literal.") }
		return Value{}, false
	}

	// Odin converts the value only after Obel accepts its spelling.
	if is_float {
		float_value, float_ok := strconv.parse_f64(text)
		if !float_ok {
			if report_reader_errors { reader_error("float literal out of range.") }
			return Value{}, false
		}

		return Value(float_value), true
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
			if report_reader_errors { reader_error("integer literal out of range.") }
			return Value{}, false
		}

		magnitude = magnitude * 10 + digit
		digit_index += 1
	}

	if is_negative {
		if magnitude == magnitude_limit { return Value(min(i64)), true }
		return Value(-i64(magnitude)), true
	}

	return Value(i64(magnitude)), true
}

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
		number, number_ok := number_from_text(text, true)
		if !number_ok { return Value{} }
		return number
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
			reader_error("unterminated string.")
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
				reader_error("unterminated string.")
				return Value{}
			}

			escaped := Reader.source[Reader.index]
			Reader.index += 1

			if escaped == '\n' || escaped == '\r' {
				delete(decoded)
				reader_error("unterminated string.")
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
				reader_error(fmt.tprintf("invalid escape sequence `\\%c`.", escaped))
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

	reader_error("unterminated string.")
	return Value{}
}

read_name_string :: proc() -> Value {
	Reader.index += 1
	start := Reader.index

	for Reader.index < len(Reader.source) && !is_delimiter(Reader.source[Reader.index]) {
		Reader.index += 1
	}

	if Reader.index == start {
		reader_error("colon string literal requires text after `:`.")
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
			reader_error("unterminated list.")
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
			reader_error("unterminated vector.")
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
			reader_error("unterminated map.")
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
			reader_error("unterminated map.")
			delete(entries)
			return Value{}
		}
		if Reader.source[Reader.index] == '}' {
			reader_error("map literal expects key/value pairs.")
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
		reader_error("unexpected `)`.")
		return Value{}

	case '"':
		return read_string()

	case ':':
		return read_name_string()

	case '\'':
		reader_error("quote is not implemented.")
		return Value{}

	case '[':
		return read_vector()

	case ']':
		reader_error("unexpected `]`.")
		return Value{}

	case '{':
		return read_map()

	case '}':
		reader_error("unexpected `}`.")
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
		path = fmt.tprintf("%s.obel", import_path)
	}

	joined_path := ""
	if !filepath.is_abs(path) && importer_source_name != "" {
		importer_dir := filepath.dir(importer_source_name)
		defer delete(importer_dir)

		joined, join_error := filepath.join({importer_dir, path}, context.allocator)
		if join_error != nil {
			compile_error(fmt.tprintf("could not resolve import path `%s`.", import_path))
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
		compile_error(fmt.tprintf("could not resolve import path `%s`.", import_path))
		return "", false
	}

	return resolved_path, true
}

load_module :: proc(importer_source_name, import_path: string) -> ^Module {
	vm := Active_VM

	id, resolved := resolve_import_path(importer_source_name, import_path)
	if !resolved { return nil }

	existing_index, found := find_module(vm, id)
	if found {
		if vm.modules[existing_index].loading {
			compile_error(fmt.tprintf("cyclic import `%s`.", import_path))
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

		compile_error(fmt.tprintf("module `%s` not found.", import_path))
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
		compile_error(fmt.tprintf("could not read module `%s`.", import_path))
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

begin_code :: proc(parent: ^CodeBuilder, fixed_param_count: int, has_rest_param: bool, source_name: string) -> CodeBuilder {
	assert(fixed_param_count >= 0 && fixed_param_count <= MAX_FRAME_SLOTS, "fixed param count out of range")

	param_slot_count := fixed_param_count
	if has_rest_param {
		param_slot_count += 1
	}
	assert(param_slot_count <= MAX_FRAME_SLOTS, "param slot count out of range")

	return CodeBuilder{
		bytecode    = make([dynamic]u32),
		constants   = make([dynamic]Value),
		const_cache = make([dynamic]ConstCacheEntry),
		child_codes = make([dynamic]^Code),

		frame_slot_count  = param_slot_count,
		fixed_param_count = fixed_param_count,
		has_rest_param   = has_rest_param,

		local_count = 0,

		current_scope_local_start = 0,
		next_slot                 = param_slot_count,

		upvalue_descs   = make([dynamic]UpvalueDesc),
		upvalue_symbols = make([dynamic]^SymbolObject),

		active_loops      = make([dynamic]ActiveLoop),
		break_jump_fixups = make([dynamic]int),

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
	delete(builder.const_cache)
	delete(builder.child_codes)
	delete(builder.upvalue_descs)
	delete(builder.upvalue_symbols)
	delete(builder.active_loops)
	delete(builder.break_jump_fixups)
	delete(builder.file_bindings)
	delete(builder.exports)

	code := new(Code)
	code^ = Code{
		bytecode         = bytecode,
		constants        = constants,
		child_codes      = child_codes,
		frame_slot_count  = builder.frame_slot_count,
		fixed_param_count = builder.fixed_param_count,
		has_rest_param   = builder.has_rest_param,
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
	delete(builder.const_cache)
	delete(builder.child_codes)
	delete(builder.upvalue_descs)
	delete(builder.upvalue_symbols)
	delete(builder.active_loops)
	delete(builder.break_jump_fixups)
	delete(builder.file_bindings)
	delete(builder.exports)
}


// Constants ======================================================================================

CONST_CACHE_MIN_BUCKETS :: 32

// Hashes place constants into the compiler cache. Hash collisions only add probing;
// intern_constant still checks compiler constant identity before reusing an index.
constant_hash :: proc(value: Value) -> u64 {
	if value == nil {
		bits := u64(0)
		return hash.fnv64a(mem.ptr_to_bytes(&bits))
	}

	switch v in value {
	case bool:
		bits := u64(1) if v else u64(0)
		return hash.fnv64a(mem.ptr_to_bytes(&bits))

	case i64:
		bits := transmute(u64)v
		return hash.fnv64a(mem.ptr_to_bytes(&bits))

	case f64:
		bits := transmute(u64)v
		return hash.fnv64a(mem.ptr_to_bytes(&bits))

	case ^Object:
		if v.kind == .STRING {
			return string_hash(cast(^StringObject)v)
		}

		bits := u64(uintptr(v))
		return hash.fnv64a(mem.ptr_to_bytes(&bits))
	}

	assert(false, "invalid constant value")
	return 0
}

// Open-addressed cache for the current builder only. Finished Code keeps constants, not this index.
rebuild_const_cache :: proc(builder: ^CodeBuilder, bucket_count: int) {
	old_cache := builder.const_cache
	builder.const_cache = make([dynamic]ConstCacheEntry, bucket_count)

	for i := 0; i < len(builder.const_cache); i += 1 {
		builder.const_cache[i].index = -1
	}

	for constant, constant_index in builder.constants {
		hash_value := constant_hash(constant)
		slot := int(hash_value % u64(len(builder.const_cache)))

		for builder.const_cache[slot].index >= 0 {
			slot = (slot + 1) % len(builder.const_cache)
		}

		builder.const_cache[slot] = ConstCacheEntry{
			hash  = hash_value,
			index = constant_index,
		}
	}

	delete(old_cache)
}

intern_constant :: proc(builder: ^CodeBuilder, value: Value) -> int {
	if len(builder.const_cache) == 0 {
		rebuild_const_cache(builder, CONST_CACHE_MIN_BUCKETS)
	}

	if (len(builder.constants) + 1) * 4 >= len(builder.const_cache) * 3 {
		rebuild_const_cache(builder, len(builder.const_cache) * 2)
	}

	hash_value := constant_hash(value)
	slot := int(hash_value % u64(len(builder.const_cache)))

	for {
		entry := builder.const_cache[slot]
		if entry.index < 0 {
			if len(builder.constants) > int(max(u16)) {
				compile_error("a body has too many constants.")
				return 0
			}

			constant_index := len(builder.constants)
			append(&builder.constants, value)
			builder.const_cache[slot] = ConstCacheEntry{
				hash  = hash_value,
				index = constant_index,
			}
			return constant_index
		}

		if entry.hash == hash_value {
			existing := builder.constants[entry.index]

			// Constant identity preserves literal type and object identity.
			// Do not use runtime `=`, which intentionally collapses some numeric values.
			if existing == nil || value == nil {
				if existing == nil && value == nil {
					return entry.index
				}
			} else {
				switch existing_value in existing {
				case bool:
					value_bool, value_is_bool := value.(bool)
					if value_is_bool && existing_value == value_bool {
						return entry.index
					}

				case i64:
					value_int, value_is_int := value.(i64)
					if value_is_int && existing_value == value_int {
						return entry.index
					}

				case f64:
					value_float, value_is_float := value.(f64)
					if value_is_float {
						existing_bits := transmute(u64)existing_value
						value_bits := transmute(u64)value_float
						if existing_bits == value_bits {
							return entry.index
						}
					}

				case ^Object:
					value_object, value_is_object := value.(^Object)
					if value_is_object && existing_value.kind == value_object.kind {
						if existing_value.kind == .STRING {
							existing_string := cast(^StringObject)existing_value
							value_string := cast(^StringObject)value_object
							if existing_string.text == value_string.text {
								return entry.index
							}
						} else if existing_value == value_object {
							return entry.index
						}
					}

				}
			}
		}

		slot = (slot + 1) % len(builder.const_cache)
	}
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
	assert(count >= 2 && count <= int(max(u8)), "ADD argument count does not fit u8")
	record_slots(builder, dst, first_slot, first_slot + count - 1)
	emit_ABC(builder, .ADD, dst, first_slot, count)
}

emit_sub :: proc(builder: ^CodeBuilder, dst, first_slot, count: int) {
	assert(count >= 2 && count <= int(max(u8)), "SUB argument count does not fit u8")
	record_slots(builder, dst, first_slot, first_slot + count - 1)
	emit_ABC(builder, .SUB, dst, first_slot, count)
}

emit_mul :: proc(builder: ^CodeBuilder, dst, first_slot, count: int) {
	assert(count >= 2 && count <= int(max(u8)), "MUL argument count does not fit u8")
	record_slots(builder, dst, first_slot, first_slot + count - 1)
	emit_ABC(builder, .MUL, dst, first_slot, count)
}

emit_div :: proc(builder: ^CodeBuilder, dst, first_slot, count: int) {
	assert(count >= 2 && count <= int(max(u8)), "DIV argument count does not fit u8")
	record_slots(builder, dst, first_slot, first_slot + count - 1)
	emit_ABC(builder, .DIV, dst, first_slot, count)
}

emit_add_const :: proc(builder: ^CodeBuilder, dst, lhs, constant_index: int) {
	assert(constant_index >= 0 && constant_index <= int(max(u8)), "ADD_CONST constant index does not fit u8")
	record_slots(builder, dst, lhs)
	emit_ABC(builder, .ADD_CONST, dst, lhs, constant_index)
}

emit_sub_const :: proc(builder: ^CodeBuilder, dst, lhs, constant_index: int) {
	assert(constant_index >= 0 && constant_index <= int(max(u8)), "SUB_CONST constant index does not fit u8")
	record_slots(builder, dst, lhs)
	emit_ABC(builder, .SUB_CONST, dst, lhs, constant_index)
}

emit_mul_const :: proc(builder: ^CodeBuilder, dst, lhs, constant_index: int) {
	assert(constant_index >= 0 && constant_index <= int(max(u8)), "MUL_CONST constant index does not fit u8")
	record_slots(builder, dst, lhs)
	emit_ABC(builder, .MUL_CONST, dst, lhs, constant_index)
}

emit_div_const :: proc(builder: ^CodeBuilder, dst, lhs, constant_index: int) {
	assert(constant_index >= 0 && constant_index <= int(max(u8)), "DIV_CONST constant index does not fit u8")
	record_slots(builder, dst, lhs)
	emit_ABC(builder, .DIV_CONST, dst, lhs, constant_index)
}

emit_mod_const :: proc(builder: ^CodeBuilder, dst, lhs, constant_index: int) {
	assert(constant_index >= 0 && constant_index <= int(max(u8)), "MOD_CONST constant index does not fit u8")
	record_slots(builder, dst, lhs)
	emit_ABC(builder, .MOD_CONST, dst, lhs, constant_index)
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

emit_vector_get :: proc(builder: ^CodeBuilder, dst, vector_slot, index_slot: int) {
	record_slots(builder, dst, vector_slot, index_slot)
	emit_ABC(builder, .VECTOR_GET, dst, vector_slot, index_slot)
}

emit_vector_get_const :: proc(builder: ^CodeBuilder, dst, vector_slot, constant_index: int) {
	assert(constant_index >= 0 && constant_index <= int(max(u8)), "VECTOR_GET_CONST constant index does not fit u8")
	record_slots(builder, dst, vector_slot)
	emit_ABC(builder, .VECTOR_GET_CONST, dst, vector_slot, constant_index)
}

emit_vector_set :: proc(builder: ^CodeBuilder, vector_slot, index_slot, value_slot: int) {
	record_slots(builder, vector_slot, index_slot, value_slot)
	emit_ABC(builder, .VECTOR_SET, vector_slot, index_slot, value_slot)
}

emit_vector_set_const :: proc(builder: ^CodeBuilder, vector_slot, constant_index, value_slot: int) {
	assert(constant_index >= 0 && constant_index <= int(max(u8)), "VECTOR_SET_CONST constant index does not fit u8")
	record_slots(builder, vector_slot, value_slot)
	emit_ABC(builder, .VECTOR_SET_CONST, vector_slot, constant_index, value_slot)
}

emit_map_get :: proc(builder: ^CodeBuilder, dst, map_slot, key_slot: int) {
	record_slots(builder, dst, map_slot, key_slot)
	emit_ABC(builder, .MAP_GET, dst, map_slot, key_slot)
}

emit_map_get_const :: proc(builder: ^CodeBuilder, dst, map_slot, constant_index: int) {
	assert(constant_index >= 0 && constant_index <= int(max(u8)), "MAP_GET_CONST constant index does not fit u8")
	record_slots(builder, dst, map_slot)
	emit_ABC(builder, .MAP_GET_CONST, dst, map_slot, constant_index)
}

emit_map_set :: proc(builder: ^CodeBuilder, map_slot, key_slot, value_slot: int) {
	record_slots(builder, map_slot, key_slot, value_slot)
	emit_ABC(builder, .MAP_SET, map_slot, key_slot, value_slot)
}

emit_map_set_const :: proc(builder: ^CodeBuilder, map_slot, constant_index, value_slot: int) {
	assert(constant_index >= 0 && constant_index <= int(max(u8)), "MAP_SET_CONST constant index does not fit u8")
	record_slots(builder, map_slot, value_slot)
	emit_ABC(builder, .MAP_SET_CONST, map_slot, constant_index, value_slot)
}

// EACH opcodes use a fixed state slot block:
// base+0 kind: false = vector, true = map
// base+1 cursor: vector index or map bucket index
// base+2 limit: captured vector length or map bucket count
// base+3 present: bool result from EACH_NEXT
// base+4 item: vector item
// base+5 key: map entry key
// base+6 value: map entry value
EACH_KIND_SLOT         :: 0
EACH_CURSOR_SLOT       :: 1
EACH_LIMIT_SLOT        :: 2
EACH_PRESENT_SLOT      :: 3
EACH_ITEM_SLOT         :: 4
EACH_KEY_SLOT          :: 5
EACH_VALUE_SLOT        :: 6
EACH_STATE_SLOT_COUNT  :: 7

emit_each_init :: proc(builder: ^CodeBuilder, state_base, collection_slot: int, map_target_ok: bool) {
	flag := 0
	if map_target_ok {
		flag = 1
	}

	record_slots(builder, state_base, state_base + EACH_STATE_SLOT_COUNT - 1, collection_slot)
	emit_ABC(builder, .EACH_INIT, state_base, collection_slot, flag)
}

emit_each_next :: proc(builder: ^CodeBuilder, state_base, collection_slot: int) {
	record_slots(builder, state_base, state_base + EACH_STATE_SLOT_COUNT - 1, collection_slot)
	emit_ABC(builder, .EACH_NEXT, state_base, collection_slot, 0)
}

emit_each_end :: proc(builder: ^CodeBuilder, state_base, collection_slot: int) {
	record_slots(builder, state_base, collection_slot)
	emit_ABC(builder, .EACH_END, state_base, collection_slot, 0)
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

emit_jump_if_nil :: proc(builder: ^CodeBuilder, slot, target_index: int) {
	assert(target_index >= 0 && target_index <= int(max(u16)), "jump target does not fit u16")
	record_slots(builder, slot)
	emit_ABx(builder, .JUMP_IF_NIL, slot, target_index)
}

emit_compare_jump :: proc(builder: ^CodeBuilder, op: Opcode, lhs_slot, rhs_slot, target_index: int) {
	assert(op == .JUMP_IF_NOT_LESS ||
	       op == .JUMP_IF_NOT_LESS_EQUAL ||
	       op == .JUMP_IF_NOT_GREATER ||
	       op == .JUMP_IF_NOT_GREATER_EQUAL,
	       "emit_compare_jump expected fused comparison jump")
	record_slots(builder, lhs_slot, rhs_slot)
	// Fused compare jumps use a raw second word so the target is not squeezed into ABC.
	emit_ABC(builder, op, lhs_slot, rhs_slot, 0)
	append(&builder.bytecode, u32(target_index))
}

patch_jump_target :: proc(builder: ^CodeBuilder, jump_index, target_index: int) {
	op := Opcode(u8(builder.bytecode[jump_index] & 0xff))

	if op == .JUMP {
		assert(target_index >= 0 && target_index <= 0xffffff, "jump target does not fit u24")
		builder.bytecode[jump_index] = u32(InstAx{op = .JUMP, a = u32(target_index)})
		return
	}

	if op == .JUMP_IF_FALSEY || op == .JUMP_IF_NIL {
		assert(target_index >= 0 && target_index <= int(max(u16)), "jump target does not fit u16")
		old := InstABx(builder.bytecode[jump_index])
		builder.bytecode[jump_index] = u32(InstABx{op = op, a = old.a, b = u16(target_index)})
		return
	}

	if op == .JUMP_IF_NOT_LESS ||
	   op == .JUMP_IF_NOT_LESS_EQUAL ||
	   op == .JUMP_IF_NOT_GREATER ||
	   op == .JUMP_IF_NOT_GREATER_EQUAL {
		assert(target_index >= 0 && target_index <= int(max(u32)), "jump target does not fit u32")
		builder.bytecode[jump_index + 1] = u32(target_index)
		return
	}

	panic("patch_jump_target expected jump")
}

patch_loop_breaks :: proc(builder: ^CodeBuilder, loop: ActiveLoop, target_index: int) {
	for i := loop.break_base; i < len(builder.break_jump_fixups); i += 1 {
		patch_jump_target(builder, builder.break_jump_fixups[i], target_index)
	}

	resize(&builder.break_jump_fixups, loop.break_base)
}


// Compiler =======================================================================================

// Claims one frame slot above every value and binding that is currently live.
claim_slot :: proc(builder: ^CodeBuilder) -> int {
	if builder.next_slot >= MAX_FRAME_SLOTS {
		compile_error("a body uses too many local bindings or temporary values.")
		return 0
	}

	slot := builder.next_slot
	builder.next_slot += 1
	return slot
}

// Reserves a contiguous slot range ending immediately before slot_after_last.
reserve_slots_until :: proc(builder: ^CodeBuilder, slot_after_last: int) {
	if slot_after_last > MAX_FRAME_SLOTS {
		compile_error("a body uses too many local bindings or temporary values.")
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
	       symbol.text == "var" ||
	       symbol.text == "set" ||
	       symbol.text == "do" ||
	       symbol.text == "if" ||
	       symbol.text == "cond" ||
	       symbol.text == "case" ||
	       symbol.text == "while" ||
	       symbol.text == "each" ||
	       symbol.text == "break" ||
	       symbol.text == "and" ||
	       symbol.text == "or" ||
	       symbol.text == "??" ||
	       symbol.text == "fn" ||
	       symbol.text == "import" ||
	       symbol.text == "export" ||
	       symbol.text == "idx" ||
	       symbol.text == "key" ||
	       symbol.text == "."
}

scan_param_list :: proc(items: []Value, function_name: ^SymbolObject, params: []^SymbolObject, fixed_param_count: ^int, has_rest_param: ^bool) {
	fixed_param_count^ = 0
	has_rest_param^ = false

	for i := 0; i < len(items); i += 1 {
		param_object, param_is_object := items[i].(^Object)
		if !param_is_object || param_object.kind != .SYMBOL {
			compile_error("function parameter must be a symbol.")
			return
		}

		param := cast(^SymbolObject)param_object
		if param.text == "." {
			if i + 1 >= len(items) {
				compile_error("rest parameter marker `.` must be followed by a parameter symbol.")
				return
			}
			if i + 2 != len(items) {
				compile_error("rest parameter must be final.")
				return
			}

			rest_object, rest_is_object := items[i + 1].(^Object)
			if !rest_is_object || rest_object.kind != .SYMBOL {
				compile_error("rest parameter must be a symbol.")
				return
			}

			rest_param := cast(^SymbolObject)rest_object
			if symbol_is_reserved_word(rest_param) {
				compile_error(fmt.tprintf("cannot use reserved symbol `%s` as parameter.", rest_param.text))
				return
			}

			if function_name != nil && rest_param == function_name {
				compile_error(fmt.tprintf("parameter `%s` duplicates the function binding symbol.", rest_param.text))
				return
			}

			for j := 0; j < fixed_param_count^; j += 1 {
				if params[j] == rest_param {
					compile_error(fmt.tprintf("duplicate parameter `%s`.", rest_param.text))
					return
				}
			}

			if fixed_param_count^ + 1 > int(max(u8)) {
				compile_error("function has too many parameters.")
				return
			}

			params[fixed_param_count^] = rest_param
			has_rest_param^ = true
			return
		}

		if symbol_is_reserved_word(param) {
			compile_error(fmt.tprintf("cannot use reserved symbol `%s` as parameter.", param.text))
			return
		}

		if function_name != nil && param == function_name {
			compile_error(fmt.tprintf("parameter `%s` duplicates the function binding symbol.", param.text))
			return
		}

		for j := 0; j < fixed_param_count^; j += 1 {
			if params[j] == param {
				compile_error(fmt.tprintf("duplicate parameter `%s`.", param.text))
				return
			}
		}

		if fixed_param_count^ >= int(max(u8)) {
			compile_error("function has too many parameters.")
			return
		}

		params[fixed_param_count^] = param
		fixed_param_count^ = fixed_param_count^ + 1
	}
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
	constant_index := intern_constant(builder, value)
	if Compiler.failed { return }
	emit_load_const(builder, dst, constant_index)
}

constant_from_form :: proc(form: Value) -> (Value, bool) {
	// These reader forms can be embedded directly as bytecode constants.
	if form == nil {
		return form, true
	}

	switch v in form {
	case bool, i64, f64:
		return form, true

	case ^Object:
		if v.kind == .STRING {
			return form, true
		}
	}

	return Value{}, false
}

local_symbol_slot :: proc(builder: ^CodeBuilder, value: Value) -> (int, bool) {
	object, is_object := value.(^Object)
	if !is_object || object.kind != .SYMBOL {
		return -1, false
	}

	binding, found := find_local(builder, cast(^SymbolObject)object)
	if !found {
		return -1, false
	}

	return binding.slot, true
}

builtin_is_shadowed :: proc(builder: ^CodeBuilder, symbol: ^SymbolObject) -> bool {
	// Do not call resolve_upvalue here; fast-path checks must not record captures.
	for current := builder; current != nil; current = current.parent {
		_, found := find_local(current, symbol)
		if found { return true }
	}

	return false
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
			compile_error("internal compiler limit exceeded for built-in bindings.")
			return
		}

		emit_get_builtin(builder, dst, builtin_index)
		return
	}

	compile_error(fmt.tprintf("symbol `%s` has no visible binding.", symbol.text))
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
		// Literal keys use MAP_SET_CONST; values still evaluate left-to-right before insertion.
		key_value, key_is_literal := constant_from_form(entry.key)
		if key_is_literal {
			constant_index := intern_constant(builder, key_value)
			if Compiler.failed { return }
			if constant_index <= int(max(u8)) {
				compile_expr(builder, entry.value, value_slot)
				if Compiler.failed { return }

				emit_map_set_const(builder, dst, constant_index, value_slot)
				continue
			}
		}

		compile_expr(builder, entry.key, key_slot)
		if Compiler.failed { return }

		compile_expr(builder, entry.value, value_slot)
		if Compiler.failed { return }

		emit_map_set(builder, dst, key_slot, value_slot)
	}
}

// Validates one recursive def/var target before RHS compilation.
// This keeps target names invisible while the RHS compiles.
validate_binding_target :: proc(builder: ^CodeBuilder, target: Value, introduced_symbols: []^SymbolObject, introduced_symbol_count: ^int) {
	target_object, target_is_object := target.(^Object)
	if !target_is_object {
		compile_error("binding target must be a symbol, vector pattern, or map pattern.")
		return
	}

	switch target_object.kind {
	case .SYMBOL:
		name := cast(^SymbolObject)target_object
		if symbol_is_reserved_word(name) {
			compile_error(fmt.tprintf("cannot define reserved symbol `%s`.", name.text))
			return
		}

		for i := 0; i < introduced_symbol_count^; i += 1 {
			if introduced_symbols[i] == name {
				compile_error(fmt.tprintf("duplicate binding for symbol `%s` in binding target.", name.text))
				return
			}
		}

		for i := builder.current_scope_local_start; i < builder.local_count; i += 1 {
			if builder.local_bindings[i].symbol == name {
				compile_error(fmt.tprintf("duplicate binding for symbol `%s` in this scope.", name.text))
				return
			}
		}

		if introduced_symbol_count^ >= len(introduced_symbols) {
			compile_error("binding target introduces too many bindings.")
			return
		}

		introduced_symbols[introduced_symbol_count^] = name
		introduced_symbol_count^ = introduced_symbol_count^ + 1

	case .VECTOR:
		pattern := cast(^VectorObject)target_object
		count := len(pattern.items)
		if count == 0 {
			compile_error("vector pattern cannot be empty.")
			return
		}

		if count > int(max(u8)) {
			compile_error("vector pattern supports at most 255 items.")
			return
		}

		for item in pattern.items {
			validate_binding_target(builder, item, introduced_symbols, introduced_symbol_count)
			if Compiler.failed { return }
		}

	case .MAP:
		pattern := cast(^MapObject)target_object
		count := len(pattern.entries)
		if count == 0 {
			compile_error("map pattern cannot be empty.")
			return
		}

		for i := 0; i < count; i += 1 {
			entry := pattern.entries[i]
			key, key_is_literal := constant_from_form(entry.key)
			if !key_is_literal {
				compile_error("map pattern key must be a literal value.")
				return
			}

			if key == nil {
				compile_error("map pattern key cannot be nil.")
				return
			}

			float_key, key_is_float := key.(f64)
			if key_is_float && float_key != float_key {
				compile_error("map pattern key cannot be NaN.")
				return
			}

			for j := 0; j < i; j += 1 {
				previous_key, _ := constant_from_form(pattern.entries[j].key)
				if values_equal(previous_key, key) {
					compile_error("duplicate key in map pattern.")
					return
				}
			}

			validate_binding_target(builder, entry.value, introduced_symbols, introduced_symbol_count)
			if Compiler.failed { return }
		}

	case .STRING, .LIST, .NATIVE_FUNCTION, .FUNCTION:
		compile_error("binding target must be a symbol, vector pattern, or map pattern.")
		return
	}
}

reserve_binding_target_slots :: proc(builder: ^CodeBuilder, target: Value, mutable: bool, bindings: []LocalBinding, binding_count: ^int) {
	target_object := target.(^Object)

	switch target_object.kind {
	case .SYMBOL:
		if binding_count^ >= len(bindings) {
			compile_error("binding target introduces too many bindings.")
			return
		}

		slot := claim_slot(builder)
		if Compiler.failed { return }

		bindings[binding_count^] = LocalBinding{
			symbol  = cast(^SymbolObject)target_object,
			slot    = slot,
			mutable = mutable,
		}
		binding_count^ = binding_count^ + 1

	case .VECTOR:
		pattern := cast(^VectorObject)target_object
		for item in pattern.items {
			reserve_binding_target_slots(builder, item, mutable, bindings, binding_count)
			if Compiler.failed { return }
		}

	case .MAP:
		pattern := cast(^MapObject)target_object
		for entry in pattern.entries {
			reserve_binding_target_slots(builder, entry.value, mutable, bindings, binding_count)
			if Compiler.failed { return }
		}

	case .STRING, .LIST, .NATIVE_FUNCTION, .FUNCTION:
		compile_error("binding target must be a symbol, vector pattern, or map pattern.")
		return
	}
}

publish_bindings :: proc(builder: ^CodeBuilder, bindings: []LocalBinding, binding_count: int, record_file_bindings: bool) {
	for i := 0; i < binding_count; i += 1 {
		binding := bindings[i]

		builder.local_bindings[builder.local_count] = binding
		builder.local_count += 1

		if record_file_bindings {
			append(&builder.file_bindings, binding)
		}
	}
}

// Initializes already-published target bindings from source_slot.
// This must not create or publish bindings.
// Target forms evaluate no user expressions; map keys are compile-time values.
init_binding_target :: proc(builder: ^CodeBuilder, target: Value, source_slot: int, bindings: []LocalBinding, binding_count: int) {
	target_object := target.(^Object)

	switch target_object.kind {
	case .SYMBOL:
		symbol := cast(^SymbolObject)target_object

		for i := 0; i < binding_count; i += 1 {
			binding := bindings[i]
			if binding.symbol == symbol {
				if binding.slot != source_slot {
					emit_move(builder, binding.slot, source_slot)
				}
				return
			}
		}

		assert(false, "init_binding_target could not find target binding")
		return

	case .VECTOR:
		pattern := cast(^VectorObject)target_object
		count := len(pattern.items)
		slot_mark := builder.next_slot

		// Use a fresh item range so nested vector patterns cannot clobber sibling item slots.
		first_item_slot := claim_slot(builder)
		if Compiler.failed { return }

		reserve_slots_until(builder, first_item_slot + count)
		if Compiler.failed { return }

		emit_unpack_vector(builder, source_slot, first_item_slot, count)

		for i := 0; i < count; i += 1 {
			init_binding_target(builder, pattern.items[i], first_item_slot + i, bindings, binding_count)
			if Compiler.failed { return }
		}

		builder.next_slot = slot_mark

	case .MAP:
		pattern := cast(^MapObject)target_object
		slot_mark := builder.next_slot

		// Keep source_slot live for every key lookup in this map pattern.
		for entry in pattern.entries {
			child_source_slot := claim_slot(builder)
			if Compiler.failed { return }

			key, _ := constant_from_form(entry.key)
			constant_index := intern_constant(builder, key)
			if Compiler.failed { return }

			if constant_index <= int(max(u8)) {
				emit_map_get_const(builder, child_source_slot, source_slot, constant_index)
			} else {
				// MAP_GET reads the key before replacing dst with the lookup result.
				emit_load_const(builder, child_source_slot, constant_index)
				emit_map_get(builder, child_source_slot, source_slot, child_source_slot)
			}

			init_binding_target(builder, entry.value, child_source_slot, bindings, binding_count)
			if Compiler.failed { return }
		}

		builder.next_slot = slot_mark

	case .STRING, .LIST, .NATIVE_FUNCTION, .FUNCTION:
		compile_error("binding target must be a symbol, vector pattern, or map pattern.")
		return
	}
}

compile_def_or_var :: proc(builder: ^CodeBuilder, form: Value, mutable, record_file_bindings: bool) {
	form_name := "var" if mutable else "def"

	object := form.(^Object)
	list := cast(^ListObject)object
	if len(list.items) < 2 {
		compile_error(fmt.tprintf("`%s` expects a binding target.", form_name))
		return
	}

	first_object, first_is_object := list.items[1].(^Object)
	if first_is_object && first_object.kind == .LIST {
		signature := cast(^ListObject)first_object
		if len(signature.items) == 0 {
			compile_error(fmt.tprintf("`%s` function signature must start with a symbol.", form_name))
			return
		}

		name_object, name_is_object := signature.items[0].(^Object)
		if !name_is_object || name_object.kind != .SYMBOL {
			compile_error(fmt.tprintf("`%s` function binding target must be a symbol.", form_name))
			return
		}

		name := cast(^SymbolObject)name_object
		if symbol_is_reserved_word(name) {
			compile_error(fmt.tprintf("cannot define reserved symbol `%s`.", name.text))
			return
		}

		for i := builder.current_scope_local_start; i < builder.local_count; i += 1 {
			if builder.local_bindings[i].symbol == name {
				compile_error(fmt.tprintf("duplicate binding for symbol `%s` in this scope.", name.text))
				return
			}
		}

		params: [MAX_FRAME_SLOTS]^SymbolObject
		fixed_param_count := 0
		has_rest_param := false
		scan_param_list(signature.items[1:], name, params[:], &fixed_param_count, &has_rest_param)
		if Compiler.failed { return }

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

		if record_file_bindings {
			append(&builder.file_bindings, binding)
		}

		child := begin_code(builder, fixed_param_count, has_rest_param, builder.source_name)

		param_slot_count := fixed_param_count
		if has_rest_param {
			param_slot_count += 1
		}

		for i := 0; i < param_slot_count; i += 1 {
			param := params[i]
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
			compile_error("a body contains too many `fn` forms.")
			delete_code(child_code)
			return
		}

		append(&builder.child_codes, child_code)
		child_index := len(builder.child_codes) - 1

		emit_load_function(builder, binding_slot, child_index)
		return
	}

	if (len(list.items) - 1) % 2 != 0 {
		compile_error(fmt.tprintf("`%s` expects binding target/expression pairs.\nusage: (%s target expr target expr...)", form_name, form_name))
		return
	}

	for pair_index := 1; pair_index < len(list.items); pair_index += 2 {
		target := list.items[pair_index]
		expression := list.items[pair_index + 1]

		introduced_symbols: [MAX_FRAME_SLOTS]^SymbolObject
		introduced_symbol_count := 0

		validate_binding_target(builder, target, introduced_symbols[:], &introduced_symbol_count)
		if Compiler.failed { return }

		target_bindings: [MAX_FRAME_SLOTS]LocalBinding
		target_binding_count := 0

		reserve_binding_target_slots(builder, target, mutable, target_bindings[:], &target_binding_count)
		if Compiler.failed { return }

		target_slot_after := builder.next_slot
		source_slot := claim_slot(builder)
		if Compiler.failed { return }

		// Ordered binding: target names are not visible while the RHS compiles.
		compile_expr(builder, expression, source_slot)
		if Compiler.failed { return }

		publish_bindings(builder, target_bindings[:], target_binding_count, record_file_bindings)

		init_binding_target(builder, target, source_slot, target_bindings[:], target_binding_count)
		if Compiler.failed { return }

		builder.next_slot = target_slot_after
	}
}

compile_def :: proc(builder: ^CodeBuilder, form: Value, record_file_bindings: bool) {
	compile_def_or_var(builder, form, false, record_file_bindings)
}

compile_var :: proc(builder: ^CodeBuilder, form: Value, record_file_bindings: bool) {
	compile_def_or_var(builder, form, true, record_file_bindings)
}

compile_import :: proc(builder: ^CodeBuilder, list: ^ListObject) {
	if len(list.items) != 2 && len(list.items) != 3 {
		compile_error("`import` expects a path, or namespace and path.\nusage:\n  (import \"path\")\n  (import namespace \"path\")")
		return
	}

	namespace_text: string
	path_value: Value

	if len(list.items) == 2 {
		path_value = list.items[1]
	} else {
		alias_object, alias_is_object := list.items[1].(^Object)
		if !alias_is_object || alias_object.kind != .SYMBOL {
			compile_error("`import` namespace must be a symbol.")
			return
		}

		alias := cast(^SymbolObject)alias_object
		if symbol_is_reserved_word(alias) {
			compile_error(fmt.tprintf("cannot use reserved symbol `%s` as import namespace.", alias.text))
			return
		}

		namespace_text = alias.text
		path_value = list.items[2]
	}

	path_object, path_is_object := path_value.(^Object)
	if !path_is_object || path_object.kind != .STRING {
		compile_error("`import` path must be a string.")
		return
	}

	import_path := (cast(^StringObject)path_object).text
	if namespace_text == "" {
		namespace_text = filepath.stem(import_path)
	}

	if namespace_text == "" {
		compile_error("`import` namespace cannot be empty.")
		return
	}

	for i := 0; i < len(namespace_text); i += 1 {
		if namespace_text[i] == '/' || namespace_text[i] == '\\' {
			compile_error("`import` namespace cannot contain a path separator.")
			return
		}
	}

	module := load_module(builder.source_name, import_path)
	if Compiler.failed { return }
	assert(module != nil, "load_module returned nil without failing")

	for export in module.exports {
		qualified_text := fmt.tprintf("%s/%s", namespace_text, export.symbol.text)
		qualified_symbol := intern_symbol(Active_VM, qualified_text)

		for i := builder.current_scope_local_start; i < builder.local_count; i += 1 {
			if builder.local_bindings[i].symbol == qualified_symbol {
				compile_error(fmt.tprintf("duplicate imported binding `%s`.", qualified_text))
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
			compile_error("`export` entries must be symbols.")
			return
		}

		name := cast(^SymbolObject)name_object

		for existing in builder.exports {
			if existing.symbol == name {
				compile_error(fmt.tprintf("duplicate export for symbol `%s`.", name.text))
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
			compile_error(fmt.tprintf("exported symbol `%s` is not a file binding.", name.text))
			return
		}
	}
}

// Definitions mutate the local environment and do not become the body result.
// The last expression result wins; defs-only and empty bodies return nil.
compile_body :: proc(builder: ^CodeBuilder, forms: []Value, dst: int) {
	last_result_form := -1

	for form, form_index in forms {
		object, is_object := form.(^Object)
		if is_object && object.kind == .LIST {
			list := cast(^ListObject)object

			if len(list.items) > 0 {
				head_object, head_is_object := list.items[0].(^Object)
				if head_is_object && head_object.kind == .SYMBOL {
					head := cast(^SymbolObject)head_object
					if head.text == "def" || head.text == "var" {
						continue
					}
				}
			}
		}

		last_result_form = form_index
	}

	for form, form_index in forms {
		object, is_object := form.(^Object)
		if is_object && object.kind == .LIST {
			list := cast(^ListObject)object

			if len(list.items) > 0 {
				head_object, head_is_object := list.items[0].(^Object)
				if head_is_object && head_object.kind == .SYMBOL {
					head := cast(^SymbolObject)head_object
					if head.text == "def" {
						compile_def(builder, form, false)
						if Compiler.failed { return }
						continue
					}
					if head.text == "var" {
						compile_var(builder, form, false)
						if Compiler.failed { return }
						continue
					}
				}
			}
		}

		if form_index == last_result_form {
			compile_expr(builder, form, dst)
			if Compiler.failed { return }
		} else {
			compile_effect(builder, form)
			if Compiler.failed { return }
		}
	}

	if last_result_form < 0 {
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
							compile_error("`import` forms must appear before other top-level forms.")
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
							compile_error("`export` must be the final top-level form.")
							return
						}

						if !had_result_expr {
							emit_load_nil(builder, dst)
						}
						return
					}

					seen_non_import = true

					if head.text == "def" {
						compile_def(builder, form, true)
						if Compiler.failed { return }
						continue
					}
					if head.text == "var" {
						compile_var(builder, form, true)
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

compile_false_jump :: proc(builder: ^CodeBuilder, condition: Value) -> int {
	// Direct numeric comparisons can branch without materializing a boolean slot.
	object, is_object := condition.(^Object)
	if is_object && object.kind == .LIST {
		list := cast(^ListObject)object
		if len(list.items) == 3 {
			head_object, head_is_object := list.items[0].(^Object)
			if head_is_object && head_object.kind == .SYMBOL {
				head := cast(^SymbolObject)head_object

				jump_op: Opcode = .JUMP_IF_FALSEY
				if head.text == "<" {
					jump_op = .JUMP_IF_NOT_LESS
				} else if head.text == "<=" {
					jump_op = .JUMP_IF_NOT_LESS_EQUAL
				} else if head.text == ">" {
					jump_op = .JUMP_IF_NOT_GREATER
				} else if head.text == ">=" {
					jump_op = .JUMP_IF_NOT_GREATER_EQUAL
				}

				if jump_op != .JUMP_IF_FALSEY {
					_, builtin_found := find_builtin(Active_VM, head)
					if builtin_found && !builtin_is_shadowed(builder, head) {
						lhs_slot, lhs_is_local := local_symbol_slot(builder, list.items[1])
						if !lhs_is_local {
							lhs_slot = claim_slot(builder)
							if Compiler.failed { return -1 }

							compile_expr(builder, list.items[1], lhs_slot)
							if Compiler.failed { return -1 }
						}

						rhs_slot, rhs_is_local := local_symbol_slot(builder, list.items[2])
						if !rhs_is_local {
							rhs_slot = claim_slot(builder)
							if Compiler.failed { return -1 }

							compile_expr(builder, list.items[2], rhs_slot)
							if Compiler.failed { return -1 }
						}

						jump_index := len(builder.bytecode)
						emit_compare_jump(builder, jump_op, lhs_slot, rhs_slot, 0)
						return jump_index
					}
				}
			}
		}
	}

	condition_slot := claim_slot(builder)
	if Compiler.failed { return -1 }

	compile_expr(builder, condition, condition_slot)
	if Compiler.failed { return -1 }

	jump_index := len(builder.bytecode)
	emit_jump_if_falsey(builder, condition_slot, 0)
	return jump_index
}

compile_break :: proc(builder: ^CodeBuilder, list: ^ListObject) {
	if len(list.items) != 1 {
		compile_error("`break` accepts no arguments.")
		return
	}

	if len(builder.active_loops) == 0 {
		compile_error("`break` is only valid inside `while` or `each`.")
		return
	}

	loop := builder.active_loops[len(builder.active_loops) - 1]
	emit_close_upvalues(builder, loop.close_slot)

	append(&builder.break_jump_fixups, len(builder.bytecode))
	emit_jump(builder, 0)
}

compile_effect :: proc(builder: ^CodeBuilder, form: Value) {
	// Compile a form only for side effects, restoring temporary result slots afterward.
	slot_mark := builder.next_slot

	object, is_object := form.(^Object)
	if is_object && object.kind == .LIST {
		list := cast(^ListObject)object
		if len(list.items) > 0 {
			head_object, head_is_object := list.items[0].(^Object)
			if head_is_object && head_object.kind == .SYMBOL {
				head := cast(^SymbolObject)head_object

				if head.text == "def" {
					compile_error("`def` is not valid in expression position.")
					return
				}
				if head.text == "var" {
					compile_error("`var` is not valid in expression position.")
					return
				}
				if head.text == "import" {
					compile_error("`import` is only valid at file top level.")
					return
				}
				if head.text == "export" {
					compile_error("`export` is only valid at file top level.")
					return
				}
				if head.text == "set" {
					scratch := claim_slot(builder)
					if Compiler.failed { return }

					compile_set(builder, list, scratch, false)
					builder.next_slot = slot_mark
					return
				}
				if head.text == "do" {
					compile_do_effect(builder, list)
					builder.next_slot = slot_mark
					return
				}
				if head.text == "if" {
					compile_if_effect(builder, list)
					builder.next_slot = slot_mark
					return
				}
				if head.text == "while" {
					compile_while_effect(builder, list)
					builder.next_slot = slot_mark
					return
				}
				if head.text == "each" {
					compile_each(builder, list, 0, false)
					builder.next_slot = slot_mark
					return
				}
				if head.text == "break" {
					compile_break(builder, list)
					builder.next_slot = slot_mark
					return
				}
			}
		}
	}

	scratch := claim_slot(builder)
	if Compiler.failed { return }

	compile_expr(builder, form, scratch)
	builder.next_slot = slot_mark
}

compile_body_effect :: proc(builder: ^CodeBuilder, forms: []Value) {
	// Definitions still bind in effect position; only expression results are discarded.
	for form in forms {
		object, is_object := form.(^Object)
		if is_object && object.kind == .LIST {
			list := cast(^ListObject)object

			if len(list.items) > 0 {
				head_object, head_is_object := list.items[0].(^Object)
				if head_is_object && head_object.kind == .SYMBOL {
					head := cast(^SymbolObject)head_object
					if head.text == "def" {
						compile_def(builder, form, false)
						if Compiler.failed { return }
						continue
					}
					if head.text == "var" {
						compile_var(builder, form, false)
						if Compiler.failed { return }
						continue
					}
				}
			}
		}

		compile_effect(builder, form)
		if Compiler.failed { return }
	}
}

compile_do_effect :: proc(builder: ^CodeBuilder, list: ^ListObject) {
	local_mark := builder.local_count
	slot_mark := builder.next_slot
	outer_scope_start := builder.current_scope_local_start

	builder.current_scope_local_start = local_mark
	compile_body_effect(builder, list.items[1:])
	if Compiler.failed { return }

	if builder.local_count > local_mark {
		emit_close_upvalues(builder, slot_mark)
	}

	builder.local_count = local_mark
	builder.next_slot = slot_mark
	builder.current_scope_local_start = outer_scope_start
}

compile_if_effect :: proc(builder: ^CodeBuilder, list: ^ListObject) {
	if len(list.items) < 3 || len(list.items) > 4 {
		compile_error("`if` expects condition and branch expressions.\nusage: (if cond then else?)")
		return
	}

	slot_mark := builder.next_slot
	false_jump := compile_false_jump(builder, list.items[1])
	if Compiler.failed { return }

	compile_effect(builder, list.items[2])
	if Compiler.failed { return }

	end_jump := len(builder.bytecode)
	emit_jump(builder, 0)
	if Compiler.failed { return }

	patch_jump_target(builder, false_jump, len(builder.bytecode))

	if len(list.items) == 4 {
		compile_effect(builder, list.items[3])
		if Compiler.failed { return }
	}

	patch_jump_target(builder, end_jump, len(builder.bytecode))
	builder.next_slot = slot_mark
}

compile_while_effect :: proc(builder: ^CodeBuilder, list: ^ListObject) {
	if len(list.items) < 2 {
		compile_error("`while` expects a condition.\nusage:\n  (while cond\n    body-form...)")
		return
	}

	local_mark := builder.local_count
	slot_mark := builder.next_slot
	outer_scope_start := builder.current_scope_local_start

	loop_start := len(builder.bytecode)

	exit_jump := compile_false_jump(builder, list.items[1])
	if Compiler.failed { return }

	builder.current_scope_local_start = builder.local_count
	body_slot_mark := builder.next_slot

	loop := ActiveLoop{
		break_base = len(builder.break_jump_fixups),
		close_slot = body_slot_mark,
	}
	append(&builder.active_loops, loop)

	compile_body_effect(builder, list.items[2:])
	if Compiler.failed { return }

	loop = builder.active_loops[len(builder.active_loops) - 1]
	resize(&builder.active_loops, len(builder.active_loops) - 1)

	if builder.local_count > local_mark {
		emit_close_upvalues(builder, body_slot_mark)
	}

	builder.local_count = local_mark
	builder.next_slot = slot_mark
	builder.current_scope_local_start = outer_scope_start

	emit_jump(builder, loop_start)

	exit_label := len(builder.bytecode)
	patch_jump_target(builder, exit_jump, exit_label)
	patch_loop_breaks(builder, loop, exit_label)
}

compile_do :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	// A do body owns its bindings and restores the outer live-slot boundary.
	local_mark := builder.local_count
	slot_mark := builder.next_slot
	outer_scope_start := builder.current_scope_local_start

	builder.current_scope_local_start = local_mark
	compile_body(builder, list.items[1:], dst)
	if Compiler.failed { return }

	if builder.local_count > local_mark {
		emit_close_upvalues(builder, slot_mark)
	}

	builder.local_count = local_mark
	builder.next_slot = slot_mark
	builder.current_scope_local_start = outer_scope_start
}

compile_if :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	if len(list.items) < 3 || len(list.items) > 4 {
		compile_error("`if` expects condition and branch expressions.\nusage: (if cond then else?)")
		return
	}

	false_jump := compile_false_jump(builder, list.items[1])
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

compile_cond :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	if (len(list.items) - 1) % 2 != 0 {
		compile_error("`cond` expects test/expression pairs.\nusage:\n  (cond\n    test expr\n    test expr\n    ...)")
		return
	}

	if len(list.items) == 1 {
		emit_load_nil(builder, dst)
		return
	}

	end_jumps := make([dynamic]int)
	defer delete(end_jumps)

	for i := 1; i < len(list.items); i += 2 {
		false_jump := compile_false_jump(builder, list.items[i])
		if Compiler.failed { return }

		compile_expr(builder, list.items[i + 1], dst)
		if Compiler.failed { return }

		append(&end_jumps, len(builder.bytecode))
		emit_jump(builder, 0)
		if Compiler.failed { return }

		patch_jump_target(builder, false_jump, len(builder.bytecode))
	}

	emit_load_nil(builder, dst)

	for jump in end_jumps {
		patch_jump_target(builder, jump, len(builder.bytecode))
	}
}

compile_case :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	if len(list.items) < 2 {
		compile_error("`case` expects a subject.\nusage:\n  (case subject\n    label expr\n    label expr\n    default?)")
		return
	}

	slot_mark := builder.next_slot
	subject_slot := claim_slot(builder)
	if Compiler.failed { return }
	label_slot := claim_slot(builder)
	if Compiler.failed { return }
	match_slot := claim_slot(builder)
	if Compiler.failed { return }

	compile_expr(builder, list.items[1], subject_slot)
	if Compiler.failed { return }

	end_jumps := make([dynamic]int)
	defer delete(end_jumps)

	remaining_count := len(list.items) - 2
	has_default := remaining_count % 2 != 0
	pair_end := len(list.items)
	if has_default {
		pair_end -= 1
	}

	for i := 2; i < pair_end; i += 2 {
		label, label_is_literal := constant_from_form(list.items[i])
		if !label_is_literal {
			compile_error("`case` label must be a literal value.")
			return
		}

		for j := 2; j < i; j += 2 {
			previous_label, _ := constant_from_form(list.items[j])
			if values_equal(previous_label, label) {
				compile_error("duplicate `case` label.")
				return
			}
		}

		compile_expr(builder, list.items[i], label_slot)
		if Compiler.failed { return }

		emit_equal(builder, match_slot, subject_slot, label_slot)

		next_jump := len(builder.bytecode)
		emit_jump_if_falsey(builder, match_slot, 0)

		compile_expr(builder, list.items[i + 1], dst)
		if Compiler.failed { return }

		append(&end_jumps, len(builder.bytecode))
		emit_jump(builder, 0)

		patch_jump_target(builder, next_jump, len(builder.bytecode))
	}

	if has_default {
		compile_expr(builder, list.items[len(list.items) - 1], dst)
		if Compiler.failed { return }
	} else {
		emit_load_nil(builder, dst)
	}

	for jump in end_jumps {
		patch_jump_target(builder, jump, len(builder.bytecode))
	}

	builder.next_slot = slot_mark
}

compile_and :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	if len(list.items) == 1 {
		emit_load_true(builder, dst)
		return
	}

	false_jumps := make([dynamic]int)
	defer delete(false_jumps)

	for i := 1; i < len(list.items); i += 1 {
		compile_expr(builder, list.items[i], dst)
		if Compiler.failed { return }

		append(&false_jumps, len(builder.bytecode))
		emit_jump_if_falsey(builder, dst, 0)
	}

	emit_load_true(builder, dst)

	end_jump := len(builder.bytecode)
	emit_jump(builder, 0)

	false_label := len(builder.bytecode)
	for jump in false_jumps {
		patch_jump_target(builder, jump, false_label)
	}

	emit_load_false(builder, dst)
	patch_jump_target(builder, end_jump, len(builder.bytecode))
}

compile_or :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	if len(list.items) == 1 {
		emit_load_false(builder, dst)
		return
	}

	end_jumps := make([dynamic]int)
	defer delete(end_jumps)

	for i := 1; i < len(list.items); i += 1 {
		compile_expr(builder, list.items[i], dst)
		if Compiler.failed { return }

		false_jump := len(builder.bytecode)
		emit_jump_if_falsey(builder, dst, 0)

		emit_load_true(builder, dst)

		append(&end_jumps, len(builder.bytecode))
		emit_jump(builder, 0)

		patch_jump_target(builder, false_jump, len(builder.bytecode))
	}

	emit_load_false(builder, dst)

	for jump in end_jumps {
		patch_jump_target(builder, jump, len(builder.bytecode))
	}
}

compile_nil_fallback :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	if len(list.items) == 1 {
		emit_load_nil(builder, dst)
		return
	}

	end_jumps := make([dynamic]int)
	defer delete(end_jumps)

	for i := 1; i < len(list.items) - 1; i += 1 {
		compile_expr(builder, list.items[i], dst)
		if Compiler.failed { return }

		nil_jump := len(builder.bytecode)
		emit_jump_if_nil(builder, dst, 0)

		append(&end_jumps, len(builder.bytecode))
		emit_jump(builder, 0)

		patch_jump_target(builder, nil_jump, len(builder.bytecode))
	}

	compile_expr(builder, list.items[len(list.items) - 1], dst)
	if Compiler.failed { return }

	for jump in end_jumps {
		patch_jump_target(builder, jump, len(builder.bytecode))
	}
}

compile_while :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	if len(list.items) < 2 {
		compile_error("`while` expects a condition.\nusage:\n  (while cond\n    body-form...)")
		return
	}

	local_mark := builder.local_count
	slot_mark := builder.next_slot
	outer_scope_start := builder.current_scope_local_start

	loop_start := len(builder.bytecode)

	exit_jump := compile_false_jump(builder, list.items[1])
	if Compiler.failed { return }

	builder.current_scope_local_start = builder.local_count
	body_slot_mark := builder.next_slot

	loop := ActiveLoop{
		break_base = len(builder.break_jump_fixups),
		close_slot = body_slot_mark,
	}
	append(&builder.active_loops, loop)

	compile_body_effect(builder, list.items[2:])
	if Compiler.failed { return }

	loop = builder.active_loops[len(builder.active_loops) - 1]
	resize(&builder.active_loops, len(builder.active_loops) - 1)

	if builder.local_count > local_mark {
		emit_close_upvalues(builder, body_slot_mark)
	}

	builder.local_count = local_mark
	builder.next_slot = slot_mark
	builder.current_scope_local_start = outer_scope_start

	emit_jump(builder, loop_start)

	exit_label := len(builder.bytecode)
	patch_jump_target(builder, exit_jump, exit_label)
	patch_loop_breaks(builder, loop, exit_label)
	if Compiler.failed { return }

	emit_load_nil(builder, dst)
}

compile_each :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int, keep_result: bool) {
	if len(list.items) < 3 {
		compile_error("`each` expects target and collection expression.\nusage:\n  (each target collection\n    body-form...)")
		return
	}

	target := list.items[1]
	collection := list.items[2]

	local_mark := builder.local_count
	slot_mark := builder.next_slot
	outer_scope_start := builder.current_scope_local_start

	introduced_symbols: [MAX_FRAME_SLOTS]^SymbolObject
	introduced_symbol_count := 0

	builder.current_scope_local_start = local_mark
	validate_binding_target(builder, target, introduced_symbols[:], &introduced_symbol_count)
	builder.current_scope_local_start = outer_scope_start
	if Compiler.failed { return }

	target_object, target_is_object := target.(^Object)
	map_target_ok := false
	if target_is_object && target_object.kind == .VECTOR {
		target_vector := cast(^VectorObject)target_object
		map_target_ok = len(target_vector.items) == 2
	}

	collection_slot := claim_slot(builder)
	if Compiler.failed { return }

	compile_expr(builder, collection, collection_slot)
	if Compiler.failed { return }

	state_base := claim_slot(builder)
	if Compiler.failed { return }

	reserve_slots_until(builder, state_base + EACH_STATE_SLOT_COUNT)
	if Compiler.failed { return }

	target_bindings: [MAX_FRAME_SLOTS]LocalBinding
	target_binding_count := 0

	reserve_binding_target_slots(builder, target, false, target_bindings[:], &target_binding_count)
	if Compiler.failed { return }

	publish_bindings(builder, target_bindings[:], target_binding_count, false)
	builder.current_scope_local_start = local_mark

	emit_each_init(builder, state_base, collection_slot, map_target_ok)

	loop_start := len(builder.bytecode)
	emit_each_next(builder, state_base, collection_slot)

	present_slot := state_base + EACH_PRESENT_SLOT
	exit_jump := len(builder.bytecode)
	emit_jump_if_falsey(builder, present_slot, 0)

	loop := ActiveLoop{
		break_base = len(builder.break_jump_fixups),
		close_slot = state_base,
	}
	append(&builder.active_loops, loop)

	if map_target_ok {
		kind_slot := state_base + EACH_KIND_SLOT
		vector_bind_jump := len(builder.bytecode)
		emit_jump_if_falsey(builder, kind_slot, 0)

		target_vector := cast(^VectorObject)target_object
		init_binding_target(builder, target_vector.items[0], state_base + EACH_KEY_SLOT, target_bindings[:], target_binding_count)
		if Compiler.failed { return }
		init_binding_target(builder, target_vector.items[1], state_base + EACH_VALUE_SLOT, target_bindings[:], target_binding_count)
		if Compiler.failed { return }

		body_jump := len(builder.bytecode)
		emit_jump(builder, 0)

		patch_jump_target(builder, vector_bind_jump, len(builder.bytecode))
		init_binding_target(builder, target, state_base + EACH_ITEM_SLOT, target_bindings[:], target_binding_count)
		if Compiler.failed { return }

		patch_jump_target(builder, body_jump, len(builder.bytecode))
	} else {
		init_binding_target(builder, target, state_base + EACH_ITEM_SLOT, target_bindings[:], target_binding_count)
		if Compiler.failed { return }
	}

	compile_body_effect(builder, list.items[3:])
	if Compiler.failed { return }

	loop = builder.active_loops[len(builder.active_loops) - 1]
	resize(&builder.active_loops, len(builder.active_loops) - 1)

	if builder.local_count > local_mark {
		emit_close_upvalues(builder, state_base)
	}

	builder.local_count = local_mark
	builder.next_slot = slot_mark
	builder.current_scope_local_start = outer_scope_start

	emit_jump(builder, loop_start)

	each_end := len(builder.bytecode)
	patch_jump_target(builder, exit_jump, each_end)
	patch_loop_breaks(builder, loop, each_end)
	emit_each_end(builder, state_base, collection_slot)

	if keep_result {
		emit_load_nil(builder, dst)
	}
}

compile_set :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int, keep_result: bool) {
	if len(list.items) != 3 {
		compile_error("`set` expects an assignment target and value.\nusage: (set target expr)")
		return
	}

	target := list.items[1]
	value := list.items[2]

	target_object, target_is_object := target.(^Object)
	if !target_is_object {
		compile_error("invalid assignment target.")
		return
	}

	if target_object.kind == .SYMBOL {
		symbol := cast(^SymbolObject)target_object

		binding, local_found := find_local(builder, symbol)
		if local_found {
			if !binding.mutable {
				compile_error(fmt.tprintf("cannot mutate immutable binding `%s`.", symbol.text))
				return
			}

			// In-place arithmetic update is only safe for literal tail operands.
			// After the first opcode writes the binding slot, no later operand may observe the updated binding.
			value_object, value_is_object := value.(^Object)
			if value_is_object && value_object.kind == .LIST {
				value_list := cast(^ListObject)value_object
				if len(value_list.items) >= 3 {
					head_object, head_is_object := value_list.items[0].(^Object)
					first_object, first_is_object := value_list.items[1].(^Object)

					if head_is_object && head_object.kind == .SYMBOL &&
					   first_is_object && first_object.kind == .SYMBOL &&
					   cast(^SymbolObject)first_object == symbol {
						head := cast(^SymbolObject)head_object
						if head.text == "+" ||
						   head.text == "-" ||
						   head.text == "*" ||
						   head.text == "/" {
							_, builtin_found := find_builtin(Active_VM, head)
							if builtin_found && !builtin_is_shadowed(builder, head) {
								can_update := true

								for i := 2; i < len(value_list.items); i += 1 {
									operand := value_list.items[i]
									operand_object, operand_is_object := operand.(^Object)
									if operand_is_object && operand_object.kind == .SYMBOL {
										can_update = false
										break
									}

									_, operand_is_literal := constant_from_form(operand)
									if operand_is_literal {
										continue
									}

									can_update = false
									break
								}

								if can_update {
									const_indexes_fit := true
									for i := 2; i < len(value_list.items); i += 1 {
										operand_constant, _ := constant_from_form(value_list.items[i])
										constant_index := intern_constant(builder, operand_constant)
										if Compiler.failed { return }
										if constant_index > int(max(u8)) {
											const_indexes_fit = false
											break
										}
									}

									if const_indexes_fit {
										lhs_slot := binding.slot

										for i := 2; i < len(value_list.items); i += 1 {
											operand := value_list.items[i]
											operand_constant, _ := constant_from_form(operand)
											constant_index := intern_constant(builder, operand_constant)
											if Compiler.failed { return }

											if head.text == "+" {
												emit_add_const(builder, binding.slot, lhs_slot, constant_index)
											} else if head.text == "-" {
												emit_sub_const(builder, binding.slot, lhs_slot, constant_index)
											} else if head.text == "*" {
												emit_mul_const(builder, binding.slot, lhs_slot, constant_index)
											} else {
												emit_div_const(builder, binding.slot, lhs_slot, constant_index)
											}

											lhs_slot = binding.slot
										}

										if keep_result {
											emit_move(builder, dst, binding.slot)
										}
										return
									}
								}
							}
						}
					}
				}
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
				compile_error(fmt.tprintf("cannot mutate immutable binding `%s`.", symbol.text))
				return
			}

			compile_expr(builder, value, dst)
			if Compiler.failed { return }

			emit_set_upvalue(builder, upvalue_index, dst)
			return
		}

		_, builtin_found := find_builtin(Active_VM, symbol)
		if builtin_found {
			compile_error(fmt.tprintf("supplied binding `%s` is immutable.", symbol.text))
			return
		}

		compile_error(fmt.tprintf("cannot assign to symbol `%s`; no visible binding.", symbol.text))
		return
	}

	if target_object.kind == .LIST {
		target_list := cast(^ListObject)target_object

		if len(target_list.items) == 0 {
			compile_error("assignment target must be a symbol, `idx` place, or `key` place.")
			return
		}

		head_object, head_is_object := target_list.items[0].(^Object)
		if !head_is_object || head_object.kind != .SYMBOL {
			compile_error("assignment target must be a symbol, `idx` place, or `key` place.")
			return
		}

		head := cast(^SymbolObject)head_object
		if head.text != "idx" && head.text != "key" {
			compile_error("assignment target must be a symbol, `idx` place, or `key` place.")
			return
		}

		if len(target_list.items) != 3 {
			if head.text == "idx" {
				compile_error("`idx` place expects vector and index.\nusage: (set (idx vector index) value)")
			} else {
				compile_error("`key` place expects map and key.\nusage: (set (key map key) value)")
			}
			return
		}

		receiver_slot, receiver_is_local := local_symbol_slot(builder, target_list.items[1])
		if !receiver_is_local {
			receiver_slot = claim_slot(builder)
			if Compiler.failed { return }

			compile_expr(builder, target_list.items[1], receiver_slot)
			if Compiler.failed { return }
		}

		index_value, index_is_literal := constant_from_form(target_list.items[2])
		if index_is_literal {
			constant_index := intern_constant(builder, index_value)
			if Compiler.failed { return }
			if constant_index <= int(max(u8)) {
				compile_expr(builder, value, dst)
				if Compiler.failed { return }

				if head.text == "idx" {
					emit_vector_set_const(builder, receiver_slot, constant_index, dst)
				} else {
					emit_map_set_const(builder, receiver_slot, constant_index, dst)
				}
				return
			}
		}

		index_slot, index_is_local := local_symbol_slot(builder, target_list.items[2])
		if !index_is_local {
			index_slot = claim_slot(builder)
			if Compiler.failed { return }

			compile_expr(builder, target_list.items[2], index_slot)
			if Compiler.failed { return }
		}

		compile_expr(builder, value, dst)
		if Compiler.failed { return }

		if head.text == "idx" {
			emit_vector_set(builder, receiver_slot, index_slot, dst)
		} else {
			emit_map_set(builder, receiver_slot, index_slot, dst)
		}
		return
	}

	compile_error("invalid assignment target.")
}

compile_call :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	argument_count := len(list.items) - 1
	if argument_count > int(max(u8)) {
		compile_error("call has too many arguments.")
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
		assert(operand_count >= 2, "arithmetic fast path expects at least two operands")

		if operand_count > int(max(u8)) {
			compile_error("arithmetic call has too many arguments.")
			return
		}

		if operand_count == 2 {
			rhs_constant, rhs_is_constant := constant_from_form(args[1])
			constant_index := -1
			if rhs_is_constant {
				constant_index = intern_constant(builder, rhs_constant)
				if Compiler.failed { return }

				if constant_index > int(max(u8)) {
					rhs_is_constant = false
				}
			}

			if rhs_is_constant {
				lhs_slot, lhs_is_local := local_symbol_slot(builder, args[0])
				if !lhs_is_local {
					lhs_slot = claim_slot(builder)
					if Compiler.failed { return }

					compile_expr(builder, args[0], lhs_slot)
					if Compiler.failed { return }
				}

				if symbol.text == "+" {
					emit_add_const(builder, dst, lhs_slot, constant_index)
				} else if symbol.text == "-" {
					emit_sub_const(builder, dst, lhs_slot, constant_index)
				} else if symbol.text == "*" {
					emit_mul_const(builder, dst, lhs_slot, constant_index)
				} else {
					emit_div_const(builder, dst, lhs_slot, constant_index)
				}
				return
			}
		}

		operand_base := builder.next_slot
		reserve_slots_until(builder, operand_base + operand_count)
		if Compiler.failed { return }

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
		lhs_slot, lhs_is_local := local_symbol_slot(builder, args[0])
		if !lhs_is_local {
			lhs_slot = claim_slot(builder)
			if Compiler.failed { return }

			compile_expr(builder, args[0], lhs_slot)
			if Compiler.failed { return }
		}

		if symbol.text == "%" {
			rhs_constant, rhs_is_constant := constant_from_form(args[1])
			if rhs_is_constant {
				constant_index := intern_constant(builder, rhs_constant)
				if Compiler.failed { return }
				if constant_index <= int(max(u8)) {
					emit_mod_const(builder, dst, lhs_slot, constant_index)
					return
				}
			}
		}

		rhs_slot, rhs_is_local := local_symbol_slot(builder, args[1])
		if !rhs_is_local {
			rhs_slot = claim_slot(builder)
			if Compiler.failed { return }

			compile_expr(builder, args[1], rhs_slot)
			if Compiler.failed { return }
		}

		if symbol.text == "%" {
			emit_mod(builder, dst, lhs_slot, rhs_slot)
		} else if symbol.text == "=" {
			emit_equal(builder, dst, lhs_slot, rhs_slot)
		} else if symbol.text == "!=" {
			emit_equal(builder, dst, lhs_slot, rhs_slot)
			emit_not(builder, dst, dst)
		} else if symbol.text == "<" {
			emit_less(builder, dst, lhs_slot, rhs_slot)
		} else if symbol.text == "<=" {
			emit_less_equal(builder, dst, lhs_slot, rhs_slot)
		} else if symbol.text == ">" {
			emit_greater(builder, dst, lhs_slot, rhs_slot)
		} else {
			emit_greater_equal(builder, dst, lhs_slot, rhs_slot)
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
			compile_error("`push` has too many arguments.")
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
		compile_error("`fn` expects a parameter list.\nusage:\n  (fn (params...)\n    body-form...)")
		return
	}

	params_object, params_is_object := list.items[1].(^Object)
	if !params_is_object || params_object.kind != .LIST {
		compile_error("`fn` parameters must be a list.\nusage:\n  (fn (params...)\n    body-form...)")
		return
	}

	params := cast(^ListObject)params_object
	param_symbols: [MAX_FRAME_SLOTS]^SymbolObject
	fixed_param_count := 0
	has_rest_param := false
	scan_param_list(params.items[:], nil, param_symbols[:], &fixed_param_count, &has_rest_param)
	if Compiler.failed { return }

	child := begin_code(parent, fixed_param_count, has_rest_param, parent.source_name)

	param_slot_count := fixed_param_count
	if has_rest_param {
		param_slot_count += 1
	}

	for i := 0; i < param_slot_count; i += 1 {
		param := param_symbols[i]
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
		compile_error("a body contains too many `fn` forms.")
		delete_code(child_code)
		return
	}

	append(&parent.child_codes, child_code)
	child_index := len(parent.child_codes) - 1

	emit_load_function(parent, dst, child_index)
}

// Bare heads resolve as forms, access forms, then ordinary bindings.
// Direct calls to known supplied builtins may use dedicated opcodes.
// Non-symbol heads are ordinary calls.
compile_list_expr :: proc(builder: ^CodeBuilder, list: ^ListObject, dst: int) {
	if len(list.items) == 0 {
		compile_error("empty list is not an expression.")
		return
	}

	head_object, head_is_object := list.items[0].(^Object)
	if !head_is_object || head_object.kind != .SYMBOL {
		compile_call(builder, list, dst)
		return
	}

	head := cast(^SymbolObject)head_object

	if head.text == "def" {
		compile_error("`def` is not valid in expression position.")
		return
	}
	if head.text == "var" {
		compile_error("`var` is not valid in expression position.")
		return
	}
	if head.text == "import" {
		compile_error("`import` is only valid at file top level.")
		return
	}
	if head.text == "export" {
		compile_error("`export` is only valid at file top level.")
		return
	}
	if head.text == "set" {
		compile_set(builder, list, dst, true)
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
	if head.text == "cond" {
		compile_cond(builder, list, dst)
		return
	}
	if head.text == "case" {
		compile_case(builder, list, dst)
		return
	}
	if head.text == "while" {
		compile_while(builder, list, dst)
		return
	}
	if head.text == "each" {
		compile_each(builder, list, dst, true)
		return
	}
	if head.text == "break" {
		compile_break(builder, list)
		return
	}
	if head.text == "and" {
		compile_and(builder, list, dst)
		return
	}
	if head.text == "or" {
		compile_or(builder, list, dst)
		return
	}
	if head.text == "??" {
		compile_nil_fallback(builder, list, dst)
		return
	}
	if head.text == "fn" {
		compile_fn(builder, list, dst)
		return
	}

	if head.text == "idx" ||
	   head.text == "key" {
		if len(list.items) != 3 {
			if head.text == "idx" {
				compile_error("`idx` expects vector and index.\nusage: (idx vector index)")
			} else {
				compile_error("`key` expects map and key.\nusage: (key map key)")
			}
			return
		}

		receiver_slot, receiver_is_local := local_symbol_slot(builder, list.items[1])
		if !receiver_is_local {
			receiver_slot = claim_slot(builder)
			if Compiler.failed { return }

			compile_expr(builder, list.items[1], receiver_slot)
			if Compiler.failed { return }
		}

		key_value, key_is_literal := constant_from_form(list.items[2])
		if key_is_literal {
			constant_index := intern_constant(builder, key_value)
			if Compiler.failed { return }
			if constant_index <= int(max(u8)) {
				if head.text == "idx" {
					emit_vector_get_const(builder, dst, receiver_slot, constant_index)
				} else {
					emit_map_get_const(builder, dst, receiver_slot, constant_index)
				}
				return
			}
		}

		key_slot, key_is_local := local_symbol_slot(builder, list.items[2])
		if !key_is_local {
			key_slot = claim_slot(builder)
			if Compiler.failed { return }

			compile_expr(builder, list.items[2], key_slot)
			if Compiler.failed { return }
		}

		if head.text == "idx" {
			emit_vector_get(builder, dst, receiver_slot, key_slot)
		} else {
			emit_map_get(builder, dst, receiver_slot, key_slot)
		}
		return
	}

	if builtin_is_shadowed(builder, head) {
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
			if argument_count >= 2 {
				compile_builtin_fast_path(builder, head, list.items[1:], dst)
				return
			}
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

	compile_error(fmt.tprintf("symbol `%s` has no visible binding.", head.text))
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
			compile_error("function value cannot appear as a source literal.")
		}
	}

	builder.next_slot = slot_mark
}

compile_forms :: proc(forms: []Value, source_name: string) -> ^Code {
	Compiler.failed = false
	root := begin_code(nil, 0, false, source_name)

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

start_function_call :: proc(vm: ^VM, base, argument_count: int) -> (result: Value, frame_pushed: bool) {
	callee := vm.slots[base]

	callee_object, callee_is_object := callee.(^Object)
	if !callee_is_object {
		runtime_error("cannot call non-function value.")
		return Value{}, false
	}

	switch callee_object.kind {
	case .NATIVE_FUNCTION:
		function := cast(^NativeFunctionObject)callee_object
		args := vm.slots[base + 1:base + 1 + argument_count]

		result = function.native(vm, args)
		if vm.error_string != "" {
			return Value{}, false
		}

		return result, false

	case .FUNCTION:
		function := cast(^FunctionObject)callee_object
		fixed_count := function.code.fixed_param_count

		if !function.code.has_rest_param && argument_count > fixed_count {
			runtime_error(fmt.tprintf("function expected at most %d arguments, got %d.", fixed_count, argument_count))
			return Value{}, false
		}

		callee_slot_base := base + 1

		wanted_slots := callee_slot_base + function.code.frame_slot_count
		if wanted_slots > MAX_VM_SLOTS {
			runtime_error("runtime stack limit exceeded.")
			return Value{}, false
		}

		for i := argument_count; i < fixed_count; i += 1 {
			vm.slots[callee_slot_base + i] = Value{}
		}

		if function.code.has_rest_param {
			rest_count := argument_count - fixed_count
			if rest_count < 0 {
				rest_count = 0
			}

			items := make([dynamic]Value)
			if rest_count > 0 {
				reserve(&items, rest_count)
			}

			// Copy extras before replacing the first extra argument slot with the rest vector.
			for i := 0; i < rest_count; i += 1 {
				append(&items, vm.slots[callee_slot_base + fixed_count + i])
			}

			vm.slots[callee_slot_base + fixed_count] = Value(cast(^Object)new_vector_object(items))
		}

		if vm.frame_count >= MAX_CALL_FRAMES {
			runtime_error("call depth limit exceeded.")
			return Value{}, false
		}

		vm.frames[vm.frame_count] = CallFrame{
			code              = function.code,
			upvalues          = function.upvalues,
			instruction_index = 0,
			slot_base         = callee_slot_base,
		}
		vm.frame_count += 1

		return Value{}, true

	case .STRING, .SYMBOL, .LIST, .VECTOR, .MAP:
		runtime_error("cannot call non-function value.")
		return Value{}, false
	}

	assert(false, "invalid callable object kind")
	return Value{}, false
}

call_function_value :: proc(vm: ^VM, function: Value, args: []Value) -> Value {
	old_frame_count := vm.frame_count
	frame := &vm.frames[old_frame_count - 1]
	frame_top := frame.slot_base + frame.code.frame_slot_count
	base := max(frame_top, vm.call_slot_top)
	call_slot_top := base + 1 + len(args)

	if call_slot_top > MAX_VM_SLOTS {
		runtime_error("runtime stack limit exceeded.")
		return Value{}
	}

	old_call_slot_top := vm.call_slot_top
	vm.call_slot_top = call_slot_top

	vm.slots[base] = function
	for i := 0; i < len(args); i += 1 {
		vm.slots[base + 1 + i] = args[i]
	}

	result, frame_pushed := start_function_call(vm, base, len(args))
	if vm.error_string != "" { return Value{} }

	if frame_pushed {
		result = run_vm(vm, old_frame_count)
		if vm.error_string != "" { return Value{} }

		vm.call_slot_top = old_call_slot_top
		return result
	}

	vm.call_slot_top = old_call_slot_top
	return result
}

// Executes VM frames until the current call returns to stop_frame_count.
run_vm :: proc(vm: ^VM, stop_frame_count: int) -> Value {
	frame := &vm.frames[vm.frame_count - 1]
	active_code := frame.code
	bytecode := active_code.bytecode
	constants := active_code.constants
	child_codes := active_code.child_codes
	slot_base := frame.slot_base
	pc := frame.instruction_index

	for {
		assert(vm.frame_count > 0, "VM has no active frame")
		assert(pc < len(bytecode), "code ended without RETURN")

		word := bytecode[pc]
		pc += 1
		frame.instruction_index = pc

		op := InstABC(word).op

		switch op {
		case .LOAD_NIL:
			inst := InstABx(word)
			vm.slots[slot_base + int(inst.a)] = Value{}

		case .LOAD_TRUE:
			inst := InstABx(word)
			vm.slots[slot_base + int(inst.a)] = Value(bool(true))

		case .LOAD_FALSE:
			inst := InstABx(word)
			vm.slots[slot_base + int(inst.a)] = Value(bool(false))

		case .LOAD_CONST:
			inst := InstABx(word)
			constant_index := int(inst.b)
			assert(constant_index < len(constants), "constant index out of range")
			vm.slots[slot_base + int(inst.a)] = constants[constant_index]

		case .MOVE:
			inst := InstABC(word)
			vm.slots[slot_base + int(inst.a)] = vm.slots[slot_base + int(inst.b)]

		case .GET_BUILTIN:
			inst := InstABx(word)
			builtin_index := int(inst.b)
			assert(builtin_index < len(vm.builtins), "builtin index out of range")
			vm.slots[slot_base + int(inst.a)] = vm.builtins[builtin_index].value

		case .LOAD_FUNCTION:
			inst := InstABx(word)
			dst := slot_base + int(inst.a)
			child_index := int(inst.b)

			assert(child_index < len(child_codes), "child code index out of range")

			child_code := child_codes[child_index]
			function := new_function_object(child_code)

			for i := 0; i < len(child_code.upvalue_descs); i += 1 {
				desc := child_code.upvalue_descs[i]

				if desc.from_parent_local {
					absolute_slot := slot_base + desc.index
					function.upvalues[i] = find_or_create_open_upvalue(vm, absolute_slot)
				} else {
					assert(desc.index < len(frame.upvalues), "parent upvalue index out of range")
					function.upvalues[i] = frame.upvalues[desc.index]
				}
			}

			vm.slots[dst] = Value(cast(^Object)function)

		case .GET_UPVALUE:
			inst := InstABx(word)
			dst := slot_base + int(inst.a)
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
			src := slot_base + int(inst.a)
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
			absolute_start := slot_base + int(inst.a)
			close_upvalues_from(vm, absolute_start)

		// Hot numeric opcodes keep all-int cases inline; mixed/error cases use the shared ops.
		case .ADD:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			first_slot := slot_base + int(inst.b)
			operand_count := int(inst.c)

			int_result: i64
			all_int := true
			for i := 0; i < operand_count; i += 1 {
				value, is_int := vm.slots[first_slot + i].(i64)
				if !is_int {
					all_int = false
					break
				}
				int_result, _ = intrinsics.overflow_add(int_result, value)
			}
			if all_int {
				vm.slots[dst] = Value(int_result)
				continue
			}

			result := op_add(vm.slots[first_slot:first_slot + operand_count])
			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = result

		case .SUB:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			first_slot := slot_base + int(inst.b)
			operand_count := int(inst.c)

			int_result, first_is_int := vm.slots[first_slot].(i64)
			all_int := first_is_int
			if all_int {
				for i := 1; i < operand_count; i += 1 {
					value, is_int := vm.slots[first_slot + i].(i64)
					if !is_int {
						all_int = false
						break
					}
					int_result, _ = intrinsics.overflow_sub(int_result, value)
				}
			}
			if all_int {
				vm.slots[dst] = Value(int_result)
				continue
			}

			result := op_sub(vm.slots[first_slot:first_slot + operand_count])
			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = result

		case .MUL:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			first_slot := slot_base + int(inst.b)
			operand_count := int(inst.c)

			int_result: i64 = 1
			all_int := true
			for i := 0; i < operand_count; i += 1 {
				value, is_int := vm.slots[first_slot + i].(i64)
				if !is_int {
					all_int = false
					break
				}
				int_result, _ = intrinsics.overflow_mul(int_result, value)
			}
			if all_int {
				vm.slots[dst] = Value(int_result)
				continue
			}

			result := op_mul(vm.slots[first_slot:first_slot + operand_count])
			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = result

		case .DIV:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			first_slot := slot_base + int(inst.b)
			operand_count := int(inst.c)

			first_int, first_is_int := vm.slots[first_slot].(i64)
			float_result := f64(first_int)
			all_int := first_is_int
			if all_int {
				for i := 1; i < operand_count; i += 1 {
					divisor, is_int := vm.slots[first_slot + i].(i64)
					if !is_int {
						all_int = false
						break
					}
					if divisor == 0 {
						runtime_error("`/` divisor cannot be zero.")
						return Value{}
					}
					float_result /= f64(divisor)
				}
			}
			if all_int {
				vm.slots[dst] = Value(float_result)
				continue
			}

			result := op_div(vm.slots[first_slot:first_slot + operand_count])
			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = result

		// Constant-pool opcodes cover common local-update and binary constant lowering.
		case .ADD_CONST:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			lhs := vm.slots[slot_base + int(inst.b)]
			constant_index := int(inst.c)
			assert(constant_index < len(constants), "constant index out of range")
			rhs := constants[constant_index]

			lhs_int, lhs_is_int := lhs.(i64)
			rhs_int, rhs_is_int := rhs.(i64)
			if lhs_is_int && rhs_is_int {
				int_result, _ := intrinsics.overflow_add(lhs_int, rhs_int)
				vm.slots[dst] = Value(int_result)
				continue
			}

			result := op_add_binary(lhs, rhs)
			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = result

		case .SUB_CONST:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			lhs := vm.slots[slot_base + int(inst.b)]
			constant_index := int(inst.c)
			assert(constant_index < len(constants), "constant index out of range")
			rhs := constants[constant_index]

			lhs_int, lhs_is_int := lhs.(i64)
			rhs_int, rhs_is_int := rhs.(i64)
			if lhs_is_int && rhs_is_int {
				int_result, _ := intrinsics.overflow_sub(lhs_int, rhs_int)
				vm.slots[dst] = Value(int_result)
				continue
			}

			result := op_sub_binary(lhs, rhs)
			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = result

		case .MUL_CONST:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			lhs := vm.slots[slot_base + int(inst.b)]
			constant_index := int(inst.c)
			assert(constant_index < len(constants), "constant index out of range")
			rhs := constants[constant_index]

			lhs_int, lhs_is_int := lhs.(i64)
			rhs_int, rhs_is_int := rhs.(i64)
			if lhs_is_int && rhs_is_int {
				int_result, _ := intrinsics.overflow_mul(lhs_int, rhs_int)
				vm.slots[dst] = Value(int_result)
				continue
			}

			result := op_mul_binary(lhs, rhs)
			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = result

		case .DIV_CONST:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			lhs := vm.slots[slot_base + int(inst.b)]
			constant_index := int(inst.c)
			assert(constant_index < len(constants), "constant index out of range")
			rhs := constants[constant_index]

			lhs_int, lhs_is_int := lhs.(i64)
			rhs_int, rhs_is_int := rhs.(i64)
			if lhs_is_int && rhs_is_int {
				if rhs_int == 0 {
					runtime_error("`/` divisor cannot be zero.")
					return Value{}
				}
				vm.slots[dst] = Value(f64(lhs_int) / f64(rhs_int))
				continue
			}

			result := op_div_binary(lhs, rhs)
			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = result

		case .MOD_CONST:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			lhs := vm.slots[slot_base + int(inst.b)]
			constant_index := int(inst.c)
			assert(constant_index < len(constants), "constant index out of range")
			rhs := constants[constant_index]

			lhs_int, lhs_is_int := lhs.(i64)
			rhs_int, rhs_is_int := rhs.(i64)
			if lhs_is_int && rhs_is_int {
				if rhs_int == 0 {
					runtime_error("`%` divisor cannot be zero.")
					return Value{}
				}
				if lhs_int == min(i64) && rhs_int == -1 {
					vm.slots[dst] = Value(i64(0))
				} else {
					vm.slots[dst] = Value(lhs_int %% rhs_int)
				}
				continue
			}

			result := op_mod(lhs, rhs)
			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = result

		case .MOD:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			lhs := vm.slots[slot_base + int(inst.b)]
			rhs := vm.slots[slot_base + int(inst.c)]

			lhs_int, lhs_is_int := lhs.(i64)
			rhs_int, rhs_is_int := rhs.(i64)
			if lhs_is_int && rhs_is_int {
				if rhs_int == 0 {
					runtime_error("`%` divisor cannot be zero.")
					return Value{}
				}
				if lhs_int == min(i64) && rhs_int == -1 {
					vm.slots[dst] = Value(i64(0))
				} else {
					vm.slots[dst] = Value(lhs_int %% rhs_int)
				}
				continue
			}

			result := op_mod(lhs, rhs)
			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = result

		case .EQUAL:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			lhs := vm.slots[slot_base + int(inst.b)]
			rhs := vm.slots[slot_base + int(inst.c)]
			vm.slots[dst] = op_equal(lhs, rhs)

		case .LESS:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			lhs := vm.slots[slot_base + int(inst.b)]
			rhs := vm.slots[slot_base + int(inst.c)]
			condition := compare_numbers(lhs, rhs, .LESS)
			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = Value(bool(condition))

		case .LESS_EQUAL:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			lhs := vm.slots[slot_base + int(inst.b)]
			rhs := vm.slots[slot_base + int(inst.c)]
			condition := compare_numbers(lhs, rhs, .LESS_EQUAL)
			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = Value(bool(condition))

		case .GREATER:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			lhs := vm.slots[slot_base + int(inst.b)]
			rhs := vm.slots[slot_base + int(inst.c)]
			condition := compare_numbers(lhs, rhs, .GREATER)
			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = Value(bool(condition))

		case .GREATER_EQUAL:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			lhs := vm.slots[slot_base + int(inst.b)]
			rhs := vm.slots[slot_base + int(inst.c)]
			condition := compare_numbers(lhs, rhs, .GREATER_EQUAL)
			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = Value(bool(condition))

		case .NOT, .LEN:
			// These unary operations share A=dst, B=src; LEN may fail.
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			src := vm.slots[slot_base + int(inst.b)]

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
			base := slot_base + int(inst.a)
			argument_count := int(inst.b)
			result, frame_pushed := start_function_call(vm, base, argument_count)
			if vm.error_string != "" { return Value{} }

			if frame_pushed {
				frame = &vm.frames[vm.frame_count - 1]
				active_code = frame.code
				bytecode = active_code.bytecode
				constants = active_code.constants
				child_codes = active_code.child_codes
				slot_base = frame.slot_base
				pc = frame.instruction_index
				continue
			}

			vm.slots[base] = result

		case .NEW_VECTOR:
			// Capacity reserves backing storage; the new vector length is zero.
			inst := InstABx(word)
			dst := slot_base + int(inst.a)
			capacity := int(inst.b)

			items := make([dynamic]Value)
			if capacity > 0 {
				reserve(&items, capacity)
			}

			vm.slots[dst] = Value(cast(^Object)new_vector_object(items))

		case .NEW_MAP:
			// Capacity is a pair-count hint; map_init chooses the bucket count.
			inst := InstABx(word)
			dst := slot_base + int(inst.a)

			object := new_map_object()
			map_init(object, int(inst.b))
			vm.slots[dst] = Value(cast(^Object)object)

		case .VECTOR_PUSH:
			// A already holds the vector and remains the result after mutation.
			inst := InstABC(word)
			op_push(vm.slots[slot_base + int(inst.a)], vm.slots[slot_base + int(inst.b)])
			if vm.error_string != "" { return Value{} }

		case .VECTOR_POP:
			// Validate the pop before replacing A with the removed value.
			inst := InstABC(word)
			result := op_pop(vm.slots[slot_base + int(inst.b)])
			if vm.error_string != "" { return Value{} }
			vm.slots[slot_base + int(inst.a)] = result

		case .VECTOR_GET, .VECTOR_GET_CONST:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			vector_value := vm.slots[slot_base + int(inst.b)]

			index_value: Value
			if op == .VECTOR_GET {
				index_value = vm.slots[slot_base + int(inst.c)]
			} else {
				constant_index := int(inst.c)
				assert(constant_index < len(constants), "constant index out of range")
				index_value = constants[constant_index]
			}

			vector_object, vector_is_object := vector_value.(^Object)
			if !vector_is_object || vector_object.kind != .VECTOR {
				runtime_error("expected vector as first argument.\nusage: (idx vector index)")
				return Value{}
			}

			index, index_is_int := index_value.(i64)
			if !index_is_int {
				runtime_error("expected int as second argument.\nusage: (idx vector index)")
				return Value{}
			}

			vector := cast(^VectorObject)vector_object
			if index < 0 || index >= i64(len(vector.items)) {
				runtime_error("vector index out of range.")
				return Value{}
			}

			vm.slots[dst] = vector.items[int(index)]

		case .MAP_GET, .MAP_GET_CONST:
			inst := InstABC(word)
			dst := slot_base + int(inst.a)
			map_value := vm.slots[slot_base + int(inst.b)]

			key_value: Value
			if op == .MAP_GET {
				key_value = vm.slots[slot_base + int(inst.c)]
			} else {
				constant_index := int(inst.c)
				assert(constant_index < len(constants), "constant index out of range")
				key_value = constants[constant_index]
			}

			map_object, map_is_object := map_value.(^Object)
			if !map_is_object || map_object.kind != .MAP {
				runtime_error("expected map as first argument.\nusage: (key map key)")
				return Value{}
			}

			result := map_get(cast(^MapObject)map_object, key_value)
			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = result

		case .VECTOR_SET, .VECTOR_SET_CONST:
			// C remains the set-expression result; this opcode only mutates A.
			inst := InstABC(word)
			vector_value := vm.slots[slot_base + int(inst.a)]
			new_value := vm.slots[slot_base + int(inst.c)]

			index_value: Value
			if op == .VECTOR_SET {
				index_value = vm.slots[slot_base + int(inst.b)]
			} else {
				constant_index := int(inst.b)
				assert(constant_index < len(constants), "constant index out of range")
				index_value = constants[constant_index]
			}

			vector_object, vector_is_object := vector_value.(^Object)
			if !vector_is_object || vector_object.kind != .VECTOR {
				runtime_error("expected vector in assignment target.\nusage: (set (idx vector index) value)")
				return Value{}
			}

			index, index_is_int := index_value.(i64)
			if !index_is_int {
				runtime_error("expected int index in assignment target.\nusage: (set (idx vector index) value)")
				return Value{}
			}

			vector := cast(^VectorObject)vector_object
			if index < 0 || index >= i64(len(vector.items)) {
				runtime_error("vector index out of range.")
				return Value{}
			}

			vector.items[int(index)] = new_value

		case .MAP_SET, .MAP_SET_CONST:
			// C remains the set-expression result; this opcode only mutates A.
			inst := InstABC(word)
			map_value := vm.slots[slot_base + int(inst.a)]
			new_value := vm.slots[slot_base + int(inst.c)]

			key_value: Value
			if op == .MAP_SET {
				key_value = vm.slots[slot_base + int(inst.b)]
			} else {
				constant_index := int(inst.b)
				assert(constant_index < len(constants), "constant index out of range")
				key_value = constants[constant_index]
			}

			map_object, map_is_object := map_value.(^Object)
			if !map_is_object || map_object.kind != .MAP {
				runtime_error("expected map in assignment target.\nusage: (set (key map key) value)")
				return Value{}
			}

			map_set(cast(^MapObject)map_object, key_value, new_value)
			if vm.error_string != "" { return Value{} }

		case .EACH_INIT:
			inst := InstABC(word)
			state_base := slot_base + int(inst.a)
			collection_value := vm.slots[slot_base + int(inst.b)]
			map_target_ok := inst.c != 0

			collection_object, collection_is_object := collection_value.(^Object)
			if !collection_is_object {
				runtime_error("`each` expected vector or map.")
				return Value{}
			}

			switch collection_object.kind {
			case .VECTOR:
				vector := cast(^VectorObject)collection_object
				vm.slots[state_base + EACH_KIND_SLOT] = Value(bool(false))
				vm.slots[state_base + EACH_CURSOR_SLOT] = Value(i64(0))
				vm.slots[state_base + EACH_LIMIT_SLOT] = Value(i64(len(vector.items)))

			case .MAP:
				if !map_target_ok {
					runtime_error("map `each` requires [key value] target.")
					return Value{}
				}

				map_object := cast(^MapObject)collection_object
				map_object.active_iteration_count += 1

				vm.slots[state_base + EACH_KIND_SLOT] = Value(bool(true))
				vm.slots[state_base + EACH_CURSOR_SLOT] = Value(i64(0))
				vm.slots[state_base + EACH_LIMIT_SLOT] = Value(i64(len(map_object.entries)))

			case .STRING, .SYMBOL, .LIST, .NATIVE_FUNCTION, .FUNCTION:
				runtime_error("`each` expected vector or map.")
				return Value{}
			}

		case .EACH_NEXT:
			inst := InstABC(word)
			state_base := slot_base + int(inst.a)
			collection_value := vm.slots[slot_base + int(inst.b)]
			is_map := vm.slots[state_base + EACH_KIND_SLOT].(bool)

			if !is_map {
				vector_object := collection_value.(^Object)
				vector := cast(^VectorObject)vector_object

				cursor := vm.slots[state_base + EACH_CURSOR_SLOT].(i64)
				limit := vm.slots[state_base + EACH_LIMIT_SLOT].(i64)

				if cursor >= limit {
					vm.slots[state_base + EACH_PRESENT_SLOT] = Value(bool(false))
					break
				}

				if cursor >= i64(len(vector.items)) {
					runtime_error("vector index out of range.")
					return Value{}
				}

				vm.slots[state_base + EACH_ITEM_SLOT] = vector.items[int(cursor)]
				vm.slots[state_base + EACH_CURSOR_SLOT] = Value(cursor + 1)
				vm.slots[state_base + EACH_PRESENT_SLOT] = Value(bool(true))
				break
			}

			map_object := collection_value.(^Object)
			map_value := cast(^MapObject)map_object

			cursor := vm.slots[state_base + EACH_CURSOR_SLOT].(i64)
			limit := vm.slots[state_base + EACH_LIMIT_SLOT].(i64)

			found_entry := false
			for bucket_index := int(cursor); bucket_index < int(limit); bucket_index += 1 {
				entry := map_value.entries[bucket_index]
				if entry.key == nil {
					continue
				}

				vm.slots[state_base + EACH_KEY_SLOT] = entry.key
				vm.slots[state_base + EACH_VALUE_SLOT] = entry.value
				vm.slots[state_base + EACH_CURSOR_SLOT] = Value(i64(bucket_index + 1))
				vm.slots[state_base + EACH_PRESENT_SLOT] = Value(bool(true))
				found_entry = true
				break
			}

			if !found_entry {
				vm.slots[state_base + EACH_CURSOR_SLOT] = Value(limit)
				vm.slots[state_base + EACH_PRESENT_SLOT] = Value(bool(false))
			}

		case .EACH_END:
			inst := InstABC(word)
			state_base := slot_base + int(inst.a)
			is_map := vm.slots[state_base + EACH_KIND_SLOT].(bool)

			if is_map {
				collection_object := vm.slots[slot_base + int(inst.b)].(^Object)
				map_object := cast(^MapObject)collection_object
				assert(map_object.active_iteration_count > 0, "active map iteration count underflow")
				map_object.active_iteration_count -= 1
			}

		case .UNPACK_VECTOR:
			inst := InstABC(word)
			source_slot := slot_base + int(inst.a)
			first_dst := slot_base + int(inst.b)
			count := int(inst.c)

			source_object, source_is_object := vm.slots[source_slot].(^Object)
			if !source_is_object || source_object.kind != .VECTOR {
				runtime_error("expected vector for vector pattern.")
				return Value{}
			}

			vector := cast(^VectorObject)source_object
			if len(vector.items) < count {
				runtime_error(fmt.tprintf("vector pattern expected at least %d items, got %d.", count, len(vector.items)))
				return Value{}
			}

			for i := 0; i < count; i += 1 {
				vm.slots[first_dst + i] = vector.items[i]
			}

		case .JUMP:
			inst := InstAx(word)
			pc = int(inst.a)
			frame.instruction_index = pc

		case .JUMP_IF_FALSEY:
			inst := InstABx(word)
			cond := vm.slots[slot_base + int(inst.a)]
			if value_is_falsey(cond) {
				pc = int(inst.b)
				frame.instruction_index = pc
			}

		case .JUMP_IF_NIL:
			inst := InstABx(word)
			if vm.slots[slot_base + int(inst.a)] == nil {
				pc = int(inst.b)
				frame.instruction_index = pc
			}

		// Fused compare jumps read their target from the raw word after the instruction.
		case .JUMP_IF_NOT_LESS:
			inst := InstABC(word)
			target := int(bytecode[pc])
			pc += 1
			frame.instruction_index = pc

			lhs := vm.slots[slot_base + int(inst.a)]
			rhs := vm.slots[slot_base + int(inst.b)]

			condition: bool
			lhs_int, lhs_is_int := lhs.(i64)
			rhs_int, rhs_is_int := rhs.(i64)
			if lhs_is_int && rhs_is_int {
				condition = lhs_int < rhs_int
			} else {
				condition = compare_numbers(lhs, rhs, .LESS)
				if vm.error_string != "" { return Value{} }
			}

			if !condition {
				pc = target
				frame.instruction_index = pc
			}

		case .JUMP_IF_NOT_LESS_EQUAL:
			inst := InstABC(word)
			target := int(bytecode[pc])
			pc += 1
			frame.instruction_index = pc

			lhs := vm.slots[slot_base + int(inst.a)]
			rhs := vm.slots[slot_base + int(inst.b)]

			condition: bool
			lhs_int, lhs_is_int := lhs.(i64)
			rhs_int, rhs_is_int := rhs.(i64)
			if lhs_is_int && rhs_is_int {
				condition = lhs_int <= rhs_int
			} else {
				condition = compare_numbers(lhs, rhs, .LESS_EQUAL)
				if vm.error_string != "" { return Value{} }
			}

			if !condition {
				pc = target
				frame.instruction_index = pc
			}

		case .JUMP_IF_NOT_GREATER:
			inst := InstABC(word)
			target := int(bytecode[pc])
			pc += 1
			frame.instruction_index = pc

			lhs := vm.slots[slot_base + int(inst.a)]
			rhs := vm.slots[slot_base + int(inst.b)]

			condition: bool
			lhs_int, lhs_is_int := lhs.(i64)
			rhs_int, rhs_is_int := rhs.(i64)
			if lhs_is_int && rhs_is_int {
				condition = lhs_int > rhs_int
			} else {
				condition = compare_numbers(lhs, rhs, .GREATER)
				if vm.error_string != "" { return Value{} }
			}

			if !condition {
				pc = target
				frame.instruction_index = pc
			}

		case .JUMP_IF_NOT_GREATER_EQUAL:
			inst := InstABC(word)
			target := int(bytecode[pc])
			pc += 1
			frame.instruction_index = pc

			lhs := vm.slots[slot_base + int(inst.a)]
			rhs := vm.slots[slot_base + int(inst.b)]

			condition: bool
			lhs_int, lhs_is_int := lhs.(i64)
			rhs_int, rhs_is_int := rhs.(i64)
			if lhs_is_int && rhs_is_int {
				condition = lhs_int >= rhs_int
			} else {
				condition = compare_numbers(lhs, rhs, .GREATER_EQUAL)
				if vm.error_string != "" { return Value{} }
			}

			if !condition {
				pc = target
				frame.instruction_index = pc
			}

		case .RETURN:
			inst := InstABx(word)
			result := vm.slots[slot_base + int(inst.a)]

			close_upvalues_from(vm, slot_base)

			vm.frame_count -= 1

			if vm.frame_count == stop_frame_count {
				return result
			}

			return_slot := slot_base - 1
			vm.slots[return_slot] = result

			frame = &vm.frames[vm.frame_count - 1]
			active_code = frame.code
			bytecode = active_code.bytecode
			constants = active_code.constants
			child_codes = active_code.child_codes
			slot_base = frame.slot_base
			pc = frame.instruction_index

		case:
			assert(false, "invalid opcode")
		}
	}
}

// Sets up top-level Code execution, then runs the VM loop.
run_code :: proc(code: ^Code) -> Value {
	vm := Active_VM

	clear(&vm.open_upvalues)

	vm.frames[0] = CallFrame{
		code              = code,
		upvalues          = nil,
		instruction_index = 0,
		slot_base         = 0,
	}
	vm.frame_count = 1
	vm.call_slot_top = 0

	return run_vm(vm, 0)
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
