package rite

import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem"
import "core:os"
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

	// Lists are immutable Rite values. This storage is built once and is not mutated by language operations.
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

	GET_GLOBAL, // ABx: A=dst, Bx=global index

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
	SET_INDEX,   // ABC: A=receiver, B=index/key, C=value -> expression result remains in C

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

new_map_object :: proc() -> ^MapObject {
	object := new(MapObject)
	object.header.kind = .MAP
	return object
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

		case .LIST, .VECTOR, .MAP, .NATIVE_FUNCTION:
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

		case .NATIVE_FUNCTION:
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

emit_mod :: proc(dst, lhs, rhs: int) {
	record_slots(dst, lhs, rhs)
	emit_ABC(.MOD, dst, lhs, rhs)
}

emit_equal :: proc(dst, lhs, rhs: int) {
	record_slots(dst, lhs, rhs)
	emit_ABC(.EQUAL, dst, lhs, rhs)
}

emit_less :: proc(dst, lhs, rhs: int) {
	record_slots(dst, lhs, rhs)
	emit_ABC(.LESS, dst, lhs, rhs)
}

emit_less_equal :: proc(dst, lhs, rhs: int) {
	record_slots(dst, lhs, rhs)
	emit_ABC(.LESS_EQUAL, dst, lhs, rhs)
}

emit_greater :: proc(dst, lhs, rhs: int) {
	record_slots(dst, lhs, rhs)
	emit_ABC(.GREATER, dst, lhs, rhs)
}

emit_greater_equal :: proc(dst, lhs, rhs: int) {
	record_slots(dst, lhs, rhs)
	emit_ABC(.GREATER_EQUAL, dst, lhs, rhs)
}

emit_not :: proc(dst, src: int) {
	record_slots(dst, src)
	emit_ABC(.NOT, dst, src, 0)
}

emit_len :: proc(dst, src: int) {
	record_slots(dst, src)
	emit_ABC(.LEN, dst, src, 0)
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

emit_new_map :: proc(dst, capacity: int) {
	assert(capacity >= 0 && capacity <= int(max(u16)), "map capacity does not fit u16")
	record_slots(dst)
	emit_ABx(.NEW_MAP, dst, capacity)
}

emit_vector_push :: proc(vector_slot, value_slot: int) {
	record_slots(vector_slot, value_slot)
	emit_ABC(.VECTOR_PUSH, vector_slot, value_slot, 0)
}

emit_vector_pop :: proc(dst, vector_slot: int) {
	record_slots(dst, vector_slot)
	emit_ABC(.VECTOR_POP, dst, vector_slot, 0)
}

emit_set_index :: proc(receiver_slot, index_slot, value_slot: int) {
	record_slots(receiver_slot, index_slot, value_slot)
	emit_ABC(.SET_INDEX, receiver_slot, index_slot, value_slot)
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

compile_map_expr :: proc(map_object: ^MapObject, dst: int) {
	// Source entries are linear pairs; runtime table capacity is only a hint.
	capacity_hint := len(map_object.entries)
	if capacity_hint > int(max(u16)) {
		capacity_hint = int(max(u16))
	}

	emit_new_map(dst, capacity_hint)

	if len(map_object.entries) == 0 {
		return
	}

	key_slot := claim_slot()
	value_slot := claim_slot()
	if Compiler.failed { return }

	for entry in map_object.entries {
		compile_expr(entry.key, key_slot)
		if Compiler.failed { return }

		compile_expr(entry.value, value_slot)
		if Compiler.failed { return }

		emit_set_index(dst, key_slot, value_slot)
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

		emit_set_index(receiver_slot, index_slot, dst)
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

	if symbol.text == "%" ||
	   symbol.text == "=" ||
	   symbol.text == "!=" ||
	   symbol.text == "<" ||
	   symbol.text == "<=" ||
	   symbol.text == ">" ||
	   symbol.text == ">=" {
		assert(len(args) == 2, "binary builtin opcode requires two arguments")

		operand_base := Compiler.next_slot
		reserve_slots_until(operand_base + 2)
		if Compiler.failed { return }

		compile_expr(args[0], operand_base)
		if Compiler.failed { return }

		compile_expr(args[1], operand_base + 1)
		if Compiler.failed { return }

		if symbol.text == "%" {
			emit_mod(dst, operand_base, operand_base + 1)
		} else if symbol.text == "=" {
			emit_equal(dst, operand_base, operand_base + 1)
		} else if symbol.text == "!=" {
			emit_equal(dst, operand_base, operand_base + 1)
			emit_not(dst, dst)
		} else if symbol.text == "<" {
			emit_less(dst, operand_base, operand_base + 1)
		} else if symbol.text == "<=" {
			emit_less_equal(dst, operand_base, operand_base + 1)
		} else if symbol.text == ">" {
			emit_greater(dst, operand_base, operand_base + 1)
		} else {
			emit_greater_equal(dst, operand_base, operand_base + 1)
		}
		return
	}

	if symbol.text == "not" ||
	   symbol.text == "len" {
		assert(len(args) == 1, "unary builtin opcode requires one argument")

		compile_expr(args[0], dst)
		if Compiler.failed { return }

		if symbol.text == "not" {
			emit_not(dst, dst)
		} else {
			emit_len(dst, dst)
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

		if (head.text == "%" ||
		    head.text == "=" ||
		    head.text == "!=" ||
		    head.text == "<" ||
		    head.text == "<=" ||
		    head.text == ">" ||
		    head.text == ">=") &&
		   argument_count == 2 {
			compile_builtin_opcode(head, list.items[1:], dst)
			return
		}

		if (head.text == "not" ||
		    head.text == "len") &&
		   argument_count == 1 {
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

		case .MAP:
			compile_map_expr(cast(^MapObject)v, dst)

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

// Numeric +, -, and * stay int while all operands are ints.
// + concatenates display text when any operand is a string; / always returns float.

core_add :: proc(args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("+ expects two or more arguments")
		return Value{}
	}

	saw_string := false
	for arg in args {
		object, is_object := arg.(^Object)
		if is_object && object.kind == .STRING {
			saw_string = true
			break
		}
	}

	if saw_string {
		parts := make([dynamic]string)
		parents := make([dynamic]^Object)

		for arg in args {
			append_value_text(&parts, arg, &parents)
		}

		text := strings.concatenate(parts[:])
		result := Value(cast(^Object)new_string_object(text))

		delete(text)
		delete(parts)
		delete(parents)
		return result
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

core_mod :: proc(lhs, rhs: Value) -> Value {
	left_int, left_is_int := lhs.(i64)
	right_int, right_is_int := rhs.(i64)

	if left_is_int && right_is_int {
		if right_int == 0 {
			runtime_error("% divisor cannot be zero")
			return Value{}
		}
		// The mathematical result is zero; direct signed division cannot represent the quotient.
		if left_int == min(i64) && right_int == -1 {
			return Value(i64(0))
		}
		return Value(left_int %% right_int)
	}

	left_float, left_is_float := lhs.(f64)
	if left_is_int {
		left_float = f64(left_int)
	} else if !left_is_float {
		runtime_error("% expects numbers")
		return Value{}
	}

	right_float, right_is_float := rhs.(f64)
	if right_is_int {
		right_float = f64(right_int)
	} else if !right_is_float {
		runtime_error("% expects numbers")
		return Value{}
	}

	if right_float == 0 {
		runtime_error("% divisor cannot be zero")
		return Value{}
	}

	return Value(left_float - right_float * math.floor(left_float / right_float))
}

values_equal :: proc(lhs, rhs: Value) -> bool {
	if lhs == nil || rhs == nil {
		return lhs == nil && rhs == nil
	}

	left_int, left_is_int := lhs.(i64)
	right_int, right_is_int := rhs.(i64)
	if left_is_int && right_is_int {
		return left_int == right_int
	}

	left_float, left_is_float := lhs.(f64)
	right_float, right_is_float := rhs.(f64)

	// TODO: Mixed numeric equality loses precision for huge i64 map keys.
	if left_is_int && right_is_float {
		return f64(left_int) == right_float
	}
	if left_is_float && right_is_int {
		return left_float == f64(right_int)
	}
	if left_is_float && right_is_float {
		return left_float == right_float
	}

	left_bool, left_is_bool := lhs.(bool)
	if left_is_bool {
		right_bool, right_is_bool := rhs.(bool)
		return right_is_bool && left_bool == right_bool
	}

	left_object, left_is_object := lhs.(^Object)
	right_object, right_is_object := rhs.(^Object)
	if !left_is_object || !right_is_object || left_object.kind != right_object.kind {
		return false
	}

	if left_object.kind == .STRING {
		left_string := cast(^StringObject)left_object
		right_string := cast(^StringObject)right_object
		return left_string.text == right_string.text
	}

	return left_object == right_object
}

core_equal :: proc(lhs, rhs: Value) -> Value {
	return Value(bool(values_equal(lhs, rhs)))
}

core_less :: proc(lhs, rhs: Value) -> Value {
	left_int, left_is_int := lhs.(i64)
	right_int, right_is_int := rhs.(i64)
	if left_is_int && right_is_int {
		return Value(bool(left_int < right_int))
	}

	left_float, left_is_float := lhs.(f64)
	if left_is_int {
		left_float = f64(left_int)
	} else if !left_is_float {
		runtime_error("< expects numbers")
		return Value{}
	}

	right_float, right_is_float := rhs.(f64)
	if right_is_int {
		right_float = f64(right_int)
	} else if !right_is_float {
		runtime_error("< expects numbers")
		return Value{}
	}

	return Value(bool(left_float < right_float))
}

core_less_equal :: proc(lhs, rhs: Value) -> Value {
	left_int, left_is_int := lhs.(i64)
	right_int, right_is_int := rhs.(i64)
	if left_is_int && right_is_int {
		return Value(bool(left_int <= right_int))
	}

	left_float, left_is_float := lhs.(f64)
	if left_is_int {
		left_float = f64(left_int)
	} else if !left_is_float {
		runtime_error("<= expects numbers")
		return Value{}
	}

	right_float, right_is_float := rhs.(f64)
	if right_is_int {
		right_float = f64(right_int)
	} else if !right_is_float {
		runtime_error("<= expects numbers")
		return Value{}
	}

	return Value(bool(left_float <= right_float))
}

core_greater :: proc(lhs, rhs: Value) -> Value {
	left_int, left_is_int := lhs.(i64)
	right_int, right_is_int := rhs.(i64)
	if left_is_int && right_is_int {
		return Value(bool(left_int > right_int))
	}

	left_float, left_is_float := lhs.(f64)
	if left_is_int {
		left_float = f64(left_int)
	} else if !left_is_float {
		runtime_error("> expects numbers")
		return Value{}
	}

	right_float, right_is_float := rhs.(f64)
	if right_is_int {
		right_float = f64(right_int)
	} else if !right_is_float {
		runtime_error("> expects numbers")
		return Value{}
	}

	return Value(bool(left_float > right_float))
}

core_greater_equal :: proc(lhs, rhs: Value) -> Value {
	left_int, left_is_int := lhs.(i64)
	right_int, right_is_int := rhs.(i64)
	if left_is_int && right_is_int {
		return Value(bool(left_int >= right_int))
	}

	left_float, left_is_float := lhs.(f64)
	if left_is_int {
		left_float = f64(left_int)
	} else if !left_is_float {
		runtime_error(">= expects numbers")
		return Value{}
	}

	right_float, right_is_float := rhs.(f64)
	if right_is_int {
		right_float = f64(right_int)
	} else if !right_is_float {
		runtime_error(">= expects numbers")
		return Value{}
	}

	return Value(bool(left_float >= right_float))
}

value_is_falsey :: proc(value: Value) -> bool {
	if value == nil { return true }

	boolean, is_bool := value.(bool)
	return is_bool && !boolean
}

core_not :: proc(value: Value) -> Value {
	return Value(bool(value_is_falsey(value)))
}

core_len :: proc(value: Value) -> Value {
	object, is_object := value.(^Object)
	if !is_object {
		runtime_error("len expects a vector, map, or string")
		return Value{}
	}

	switch object.kind {
	case .STRING:
		return Value(i64(len((cast(^StringObject)object).text)))
	case .VECTOR:
		return Value(i64(len((cast(^VectorObject)object).items)))
	case .MAP:
		return Value(i64((cast(^MapObject)object).count))
	case .SYMBOL, .LIST, .NATIVE_FUNCTION:
		runtime_error("len expects a vector, map, or string")
		return Value{}
	}

	return Value{}
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

native_mod :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("% expects two arguments")
		return Value{}
	}
	return core_mod(args[0], args[1])
}

native_equal :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("= expects two arguments")
		return Value{}
	}
	return core_equal(args[0], args[1])
}

native_not_equal :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("!= expects two arguments")
		return Value{}
	}
	return Value(bool(!values_equal(args[0], args[1])))
}

native_less :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("< expects two arguments")
		return Value{}
	}
	return core_less(args[0], args[1])
}

native_less_equal :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("<= expects two arguments")
		return Value{}
	}
	return core_less_equal(args[0], args[1])
}

native_greater :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("> expects two arguments")
		return Value{}
	}
	return core_greater(args[0], args[1])
}

native_greater_equal :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error(">= expects two arguments")
		return Value{}
	}
	return core_greater_equal(args[0], args[1])
}

native_not :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("not expects one argument")
		return Value{}
	}
	return core_not(args[0])
}

native_nil_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("nil? expects one argument")
		return Value{}
	}
	return Value(bool(args[0] == nil))
}

native_bool_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("bool? expects one argument")
		return Value{}
	}
	_, is_bool := args[0].(bool)
	return Value(bool(is_bool))
}

native_number_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("num? expects one argument")
		return Value{}
	}
	_, is_int := args[0].(i64)
	_, is_float := args[0].(f64)
	return Value(bool(is_int || is_float))
}

native_int_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("int? expects one argument")
		return Value{}
	}
	_, is_int := args[0].(i64)
	return Value(bool(is_int))
}

native_float_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("float? expects one argument")
		return Value{}
	}
	_, is_float := args[0].(f64)
	return Value(bool(is_float))
}

native_string_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("str? expects one argument")
		return Value{}
	}
	object, is_object := args[0].(^Object)
	return Value(bool(is_object && object.kind == .STRING))
}

native_vector_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("vec? expects one argument")
		return Value{}
	}
	object, is_object := args[0].(^Object)
	return Value(bool(is_object && object.kind == .VECTOR))
}

native_map_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("map? expects one argument")
		return Value{}
	}
	object, is_object := args[0].(^Object)
	return Value(bool(is_object && object.kind == .MAP))
}

native_function_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("fn? expects one argument")
		return Value{}
	}
	object, is_object := args[0].(^Object)
	return Value(bool(is_object && object.kind == .NATIVE_FUNCTION))
}

native_len :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("len expects one argument")
		return Value{}
	}
	return core_len(args[0])
}

native_copy :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("copy expects one argument")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object {
		runtime_error("copy expects a vector or map")
		return Value{}
	}

	switch object.kind {
	case .VECTOR:
		source := cast(^VectorObject)object
		items := make([dynamic]Value)
		reserve(&items, len(source.items))
		for item in source.items {
			append(&items, item)
		}
		return Value(cast(^Object)new_vector_object(items))

	case .MAP:
		source := cast(^MapObject)object
		result := new_map_object()
		map_init(result, source.count)

		for entry in source.entries {
			if entry.key != nil {
				map_set(result, entry.key, entry.value)
			}
		}

		return Value(cast(^Object)result)

	case .STRING, .SYMBOL, .LIST, .NATIVE_FUNCTION:
		runtime_error("copy expects a vector or map")
		return Value{}
	}

	return Value{}
}

native_clear :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("clear expects one argument")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object {
		runtime_error("clear expects a vector or map")
		return Value{}
	}

	switch object.kind {
	case .VECTOR:
		vector := cast(^VectorObject)object
		clear(&vector.items)
		return args[0]

	case .MAP:
		map_object := cast(^MapObject)object
		for i := 0; i < len(map_object.entries); i += 1 {
			map_object.entries[i] = MapEntry{}
		}
		map_object.count = 0
		map_object.tombstone_count = 0
		return args[0]

	case .STRING, .SYMBOL, .LIST, .NATIVE_FUNCTION:
		runtime_error("clear expects a vector or map")
		return Value{}
	}

	return Value{}
}

native_type :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("type expects one argument")
		return Value{}
	}

	value := args[0]
	type_name: string

	if value == nil {
		type_name = "nil"
	} else {
		switch v in value {
		case bool:
			type_name = "bool"
		case i64:
			type_name = "int"
		case f64:
			type_name = "float"
		case ^Object:
			switch v.kind {
			case .STRING:
				type_name = "string"
			case .LIST:
				type_name = "list"
			case .VECTOR:
				type_name = "vector"
			case .MAP:
				type_name = "map"
			case .NATIVE_FUNCTION:
				type_name = "function"
			case .SYMBOL:
				assert(false, "symbol is not a Rite runtime value")
				return Value{}
			}
		}
	}

	return Value(cast(^Object)new_string_object(type_name))
}

native_assert :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) < 1 || len(args) > 2 {
		runtime_error("assert expects a condition and optional message")
		return Value{}
	}

	if !value_is_falsey(args[0]) { return Value{} }

	if len(args) == 1 {
		runtime_error("assertion failed")
		return Value{}
	}

	message := value_display_text(args[1])
	runtime_error(fmt.tprintf("assertion failed: %s", message))
	delete(message)
	return Value{}
}

native_error :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("error expects one argument")
		return Value{}
	}

	message := value_display_text(args[0])
	runtime_error(message)
	delete(message)
	return Value{}
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

native_insert :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 3 {
		runtime_error("insert expects a vector, index, and value")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object || object.kind != .VECTOR {
		runtime_error("insert expects a vector as its first argument")
		return Value{}
	}

	index, is_int := args[1].(i64)
	if !is_int {
		runtime_error("insert index must be int")
		return Value{}
	}

	vector := cast(^VectorObject)object
	if index < 0 || index > i64(len(vector.items)) {
		runtime_error("insert index out of range")
		return Value{}
	}

	inject_at(&vector.items, int(index), args[2])
	return args[0]
}

native_remove :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("remove expects a vector and index")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object || object.kind != .VECTOR {
		runtime_error("remove expects a vector as its first argument")
		return Value{}
	}

	index, is_int := args[1].(i64)
	if !is_int {
		runtime_error("remove index must be int")
		return Value{}
	}

	vector := cast(^VectorObject)object
	if index < 0 || index >= i64(len(vector.items)) {
		runtime_error("remove index out of range")
		return Value{}
	}

	result := vector.items[int(index)]
	ordered_remove(&vector.items, int(index))
	return result
}

native_slice :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 3 {
		runtime_error("slice expects a vector, start, and count")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object || object.kind != .VECTOR {
		runtime_error("slice expects a vector as its first argument")
		return Value{}
	}

	start, start_is_int := args[1].(i64)
	count, count_is_int := args[2].(i64)
	if !start_is_int || !count_is_int {
		runtime_error("slice start and count must be ints")
		return Value{}
	}

	vector := cast(^VectorObject)object
	length := i64(len(vector.items))
	if start < 0 || count < 0 || start > length || count > length - start {
		runtime_error("slice range out of bounds")
		return Value{}
	}

	items := make([dynamic]Value)
	reserve(&items, int(count))
	for item in vector.items[int(start):int(start + count)] {
		append(&items, item)
	}

	return Value(cast(^Object)new_vector_object(items))
}

native_keys :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("keys expects one argument")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object || object.kind != .MAP {
		runtime_error("keys expects a map")
		return Value{}
	}

	map_object := cast(^MapObject)object
	items := make([dynamic]Value)
	reserve(&items, map_object.count)

	for entry in map_object.entries {
		if entry.key != nil {
			append(&items, entry.key)
		}
	}

	return Value(cast(^Object)new_vector_object(items))
}

native_vals :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("vals expects one argument")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object || object.kind != .MAP {
		runtime_error("vals expects a map")
		return Value{}
	}

	map_object := cast(^MapObject)object
	items := make([dynamic]Value)
	reserve(&items, map_object.count)

	for entry in map_object.entries {
		if entry.key != nil {
			append(&items, entry.value)
		}
	}

	return Value(cast(^Object)new_vector_object(items))
}

native_pairs :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("pairs expects one argument")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object || object.kind != .MAP {
		runtime_error("pairs expects a map")
		return Value{}
	}

	map_object := cast(^MapObject)object
	items := make([dynamic]Value)
	reserve(&items, map_object.count)

	for entry in map_object.entries {
		if entry.key == nil {
			continue
		}

		pair := make([dynamic]Value)
		reserve(&pair, 2)
		append(&pair, entry.key, entry.value)
		append(&items, Value(cast(^Object)new_vector_object(pair)))
	}

	return Value(cast(^Object)new_vector_object(items))
}

native_merge :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("merge expects two or more maps")
		return Value{}
	}

	entry_capacity := 0
	for arg in args {
		object, is_object := arg.(^Object)
		if !is_object || object.kind != .MAP {
			runtime_error("merge expects maps")
			return Value{}
		}

		map_object := cast(^MapObject)object
		entry_capacity += map_object.count
	}

	result := new_map_object()
	map_init(result, entry_capacity)

	for arg in args {
		object := arg.(^Object)
		map_object := cast(^MapObject)object

		for entry in map_object.entries {
			if entry.key != nil {
				map_set(result, entry.key, entry.value)
			}
		}
	}

	return Value(cast(^Object)result)
}

native_print :: proc(vm: ^VM, args: []Value) -> Value {
	for i := 0; i < len(args); i += 1 {
		if i > 0 {
			fmt.print(" ")
		}
		print_value(args[i])
	}
	fmt.println()
	return Value{}
}

native_write :: proc(vm: ^VM, args: []Value) -> Value {
	for value in args {
		print_value(value)
	}
	return Value{}
}

make_vm :: proc() -> VM {
	vm := VM{
		globals = make([dynamic]GlobalBinding),
		symbols = make([dynamic]^SymbolObject),
	}

	install_builtins(&vm)
	return vm
}

@(private)
install_builtins :: proc(vm: ^VM) {
	// Supplied globals are immutable; install them exactly once per VM.
	bind_native_global(vm, "+", native_add)
	bind_native_global(vm, "-", native_sub)
	bind_native_global(vm, "*", native_mul)
	bind_native_global(vm, "/", native_div)
	bind_native_global(vm, "%", native_mod)
	bind_native_global(vm, "=", native_equal)
	bind_native_global(vm, "!=", native_not_equal)
	bind_native_global(vm, "<", native_less)
	bind_native_global(vm, "<=", native_less_equal)
	bind_native_global(vm, ">", native_greater)
	bind_native_global(vm, ">=", native_greater_equal)
	bind_native_global(vm, "not", native_not)
	bind_native_global(vm, "nil?", native_nil_predicate)
	bind_native_global(vm, "bool?", native_bool_predicate)
	bind_native_global(vm, "num?", native_number_predicate)
	bind_native_global(vm, "int?", native_int_predicate)
	bind_native_global(vm, "float?", native_float_predicate)
	bind_native_global(vm, "str?", native_string_predicate)
	bind_native_global(vm, "vec?", native_vector_predicate)
	bind_native_global(vm, "map?", native_map_predicate)
	bind_native_global(vm, "fn?", native_function_predicate)
	bind_native_global(vm, "len", native_len)
	bind_native_global(vm, "copy", native_copy)
	bind_native_global(vm, "clear", native_clear)
	bind_native_global(vm, "type", native_type)
	bind_native_global(vm, "assert", native_assert)
	bind_native_global(vm, "error", native_error)
	bind_native_global(vm, "push", native_push)
	bind_native_global(vm, "pop", native_pop)
	bind_native_global(vm, "insert", native_insert)
	bind_native_global(vm, "remove", native_remove)
	bind_native_global(vm, "slice", native_slice)
	bind_native_global(vm, "keys", native_keys)
	bind_native_global(vm, "vals", native_vals)
	bind_native_global(vm, "pairs", native_pairs)
	bind_native_global(vm, "merge", native_merge)
	bind_native_global(vm, "print", native_print)
	bind_native_global(vm, "write", native_write)
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

		// Both instruction layouts store the opcode in the same field.
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
			// B and C describe one contiguous variadic operand window.
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

			// Error returns are disposable and must not be stored in dst.
			if vm.error_string != "" {
				return Value{}
			}
			vm.slots[dst] = result

		case .MOD, .EQUAL, .LESS, .LESS_EQUAL, .GREATER, .GREATER_EQUAL:
			// These binary operations share A=dst, B=lhs, C=rhs.
			inst := InstABC(word)
			dst := int(inst.a)
			lhs := vm.slots[int(inst.b)]
			rhs := vm.slots[int(inst.c)]

			result: Value
			#partial switch op {
			case .MOD:
				result = core_mod(lhs, rhs)
			case .EQUAL:
				result = core_equal(lhs, rhs)
			case .LESS:
				result = core_less(lhs, rhs)
			case .LESS_EQUAL:
				result = core_less_equal(lhs, rhs)
			case .GREATER:
				result = core_greater(lhs, rhs)
			case .GREATER_EQUAL:
				result = core_greater_equal(lhs, rhs)
			}

			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = result

		case .NOT, .LEN:
			// These unary operations share A=dst, B=src; LEN may fail.
			inst := InstABC(word)
			dst := int(inst.a)
			src := vm.slots[int(inst.b)]

			result: Value
			#partial switch op {
			case .NOT:
				result = core_not(src)
			case .LEN:
				result = core_len(src)
			}

			if vm.error_string != "" { return Value{} }
			vm.slots[dst] = result

		case .CALL:
			// A holds the callee before the call and its result afterward.
			inst := InstABC(word)
			base := int(inst.a)
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
			dst := int(inst.a)
			capacity := int(inst.b)

			items := make([dynamic]Value)
			if capacity > 0 {
				reserve(&items, capacity)
			}

			vm.slots[dst] = Value(cast(^Object)new_vector_object(items))

		case .NEW_MAP:
			// Capacity is a pair-count hint; map_init chooses the bucket count.
			inst := InstABx(word)
			dst := int(inst.a)

			object := new_map_object()
			map_init(object, int(inst.b))
			vm.slots[dst] = Value(cast(^Object)object)

		case .VECTOR_PUSH:
			// A already holds the vector and remains the result after mutation.
			inst := InstABC(word)
			core_push(vm.slots[int(inst.a)], vm.slots[int(inst.b)])
			if vm.error_string != "" { return Value{} }

		case .VECTOR_POP:
			// Validate the pop before replacing A with the removed value.
			inst := InstABC(word)
			result := core_pop(vm.slots[int(inst.b)])
			if vm.error_string != "" { return Value{} }
			vm.slots[int(inst.a)] = result

		case .SET_INDEX:
			// C remains the set-expression result; this opcode only mutates A.
			inst := InstABC(word)
			receiver_value := vm.slots[int(inst.a)]
			index_value := vm.slots[int(inst.b)]
			new_value := vm.slots[int(inst.c)]

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

			case .STRING, .SYMBOL, .LIST, .NATIVE_FUNCTION:
				runtime_error("indexed set receiver must be vector or map")
				return Value{}
			}

		case .RETURN:
			inst := InstABx(word)
			return vm.slots[int(inst.a)]

		case:
			assert(false, "invalid opcode")
		}
	}
}


// Host operations ===============================================================================

run_source :: proc(source: string) -> Value {
	forms := read_source(source)
	if Reader.failed { return Value{} }
	defer delete(forms)

	code := compile_forms(forms[:])
	if Compiler.failed { return Value{} }
	defer delete(code.bytecode)
	defer delete(code.constants)

	return run_code(&code)
}

// Owns one read, compile, and execute operation and its diagnostic lifetime.
run_string :: proc(vm: ^VM, source: string) -> Value {
	Active_VM = vm
	clear_error(vm)
	return run_source(source)
}

// Reads an exact path, then runs the shared source pipeline.
run_file :: proc(vm: ^VM, path: string) -> Value {
	Active_VM = vm
	clear_error(vm)

	source_bytes, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		set_error(fmt.tprintf("read error: could not read file `%s`", path))
		return Value{}
	}
	defer delete(source_bytes)

	return run_source(string(source_bytes))
}
