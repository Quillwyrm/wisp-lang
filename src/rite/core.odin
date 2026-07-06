package rite

import "core:fmt"
import "core:math"
import "core:strings"


// Native function binding =========================================================================

new_native_function_object :: proc(native: NativeProc) -> ^NativeFunctionObject {
	function := new(NativeFunctionObject)
	function.header.kind = .NATIVE_FUNCTION
	function.native = native
	return function
}

bind_native_function :: proc(vm: ^VM, bindings: ^[dynamic]Binding, name: string, native: NativeProc) {
	symbol := intern_symbol(vm, name)
	function := new_native_function_object(native)

	append(bindings, Binding{
		symbol  = symbol,
		value   = Value(cast(^Object)function),
		mutable = false,
	})
}


// Builtin install =================================================================================

// Supplied native builtins are immutable but may be shadowed by user bindings.
bind_native_builtin :: proc(vm: ^VM, name: string, native: NativeProc) -> int {
	symbol := intern_symbol(vm, name)
	_, found := find_builtin(vm, symbol)
	assert(!found, "duplicate supplied builtin binding")

	function := new_native_function_object(native)

	append(&vm.builtins, Binding{
		symbol  = symbol,
		value   = Value(cast(^Object)function),
		mutable = false,
	})

	return len(vm.builtins) - 1
}


// Operation semantics =============================================================================

// Numeric +, -, and * stay int while all operands are ints.
// + concatenates display text when any operand is a string; / always returns float.

op_add :: proc(args: []Value) -> Value {
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

op_sub :: proc(args: []Value) -> Value {
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

op_mul :: proc(args: []Value) -> Value {
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

op_div :: proc(args: []Value) -> Value {
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

op_mod :: proc(lhs, rhs: Value) -> Value {
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

op_equal :: proc(lhs, rhs: Value) -> Value {
	return Value(bool(values_equal(lhs, rhs)))
}

op_less :: proc(lhs, rhs: Value) -> Value {
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

op_less_equal :: proc(lhs, rhs: Value) -> Value {
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

op_greater :: proc(lhs, rhs: Value) -> Value {
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

op_greater_equal :: proc(lhs, rhs: Value) -> Value {
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

op_not :: proc(value: Value) -> Value {
	return Value(bool(value_is_falsey(value)))
}

op_len :: proc(value: Value) -> Value {
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
	case .SYMBOL, .LIST, .NATIVE_FUNCTION, .FUNCTION:
		runtime_error("len expects a vector, map, or string")
		return Value{}
	}

	return Value{}
}

op_push :: proc(vector_value, item: Value) -> Value {
	vector_object, vector_is_object := vector_value.(^Object)
	if !vector_is_object || vector_object.kind != .VECTOR {
		runtime_error("push expects a vector as its first argument")
		return Value{}
	}

	vector := cast(^VectorObject)vector_object
	append(&vector.items, item)
	return vector_value
}

op_pop :: proc(vector_value: Value) -> Value {
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

// (+ value value...) number|string; Numeric sum, or display-text concatenation if any argument is a string.
native_add :: proc(vm: ^VM, args: []Value) -> Value {
	return op_add(args)
}

// (- number number...) number; Numeric subtraction.
native_sub :: proc(vm: ^VM, args: []Value) -> Value {
	return op_sub(args)
}

// (* number number...) number; Numeric multiplication.
native_mul :: proc(vm: ^VM, args: []Value) -> Value {
	return op_mul(args)
}

// (/ number number...) float; Numeric division.
native_div :: proc(vm: ^VM, args: []Value) -> Value {
	return op_div(args)
}

// (% number number) number; Remainder.
native_mod :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("% expects two arguments")
		return Value{}
	}
	return op_mod(args[0], args[1])
}

// (= left right) bool; true if values are equal by Rite equality.
native_equal :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("= expects two arguments")
		return Value{}
	}
	return op_equal(args[0], args[1])
}

// (!= left right) bool; true if values are not equal by Rite equality.
native_not_equal :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("!= expects two arguments")
		return Value{}
	}
	return Value(bool(!values_equal(args[0], args[1])))
}

// (< left right) bool; Numeric less-than.
native_less :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("< expects two arguments")
		return Value{}
	}
	return op_less(args[0], args[1])
}

// (<= left right) bool; Numeric less-than-or-equal.
native_less_equal :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("<= expects two arguments")
		return Value{}
	}
	return op_less_equal(args[0], args[1])
}

// (> left right) bool; Numeric greater-than.
native_greater :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("> expects two arguments")
		return Value{}
	}
	return op_greater(args[0], args[1])
}

// (>= left right) bool; Numeric greater-than-or-equal.
native_greater_equal :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error(">= expects two arguments")
		return Value{}
	}
	return op_greater_equal(args[0], args[1])
}

// (not value) bool; true if value is falsey.
native_not :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("not expects one argument")
		return Value{}
	}
	return op_not(args[0])
}

// (nil? value) bool; true if value is nil.
native_nil_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("nil? expects one argument")
		return Value{}
	}
	return Value(bool(args[0] == nil))
}

// (bool? value) bool; true if value is bool.
native_bool_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("bool? expects one argument")
		return Value{}
	}
	_, is_bool := args[0].(bool)
	return Value(bool(is_bool))
}

// (num? value) bool; true if value is int or float.
native_number_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("num? expects one argument")
		return Value{}
	}
	_, is_int := args[0].(i64)
	_, is_float := args[0].(f64)
	return Value(bool(is_int || is_float))
}

// (int? value) bool; true if value is int.
native_int_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("int? expects one argument")
		return Value{}
	}
	_, is_int := args[0].(i64)
	return Value(bool(is_int))
}

// (float? value) bool; true if value is float.
native_float_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("float? expects one argument")
		return Value{}
	}
	_, is_float := args[0].(f64)
	return Value(bool(is_float))
}

// (str? value) bool; true if value is string.
native_string_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("str? expects one argument")
		return Value{}
	}
	object, is_object := args[0].(^Object)
	return Value(bool(is_object && object.kind == .STRING))
}

// (vec? value) bool; true if value is vector.
native_vector_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("vec? expects one argument")
		return Value{}
	}
	object, is_object := args[0].(^Object)
	return Value(bool(is_object && object.kind == .VECTOR))
}

// (map? value) bool; true if value is map.
native_map_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("map? expects one argument")
		return Value{}
	}
	object, is_object := args[0].(^Object)
	return Value(bool(is_object && object.kind == .MAP))
}

// (fn? value) bool; true if value is a native or Rite function.
native_function_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("fn? expects one argument")
		return Value{}
	}
	object, is_object := args[0].(^Object)
	return Value(bool(is_object && (object.kind == .NATIVE_FUNCTION || object.kind == .FUNCTION)))
}

// (len value) int; Length of a string, vector, or map.
native_len :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("len expects one argument")
		return Value{}
	}
	return op_len(args[0])
}

// (copy value) value; Shallow copy of a vector or map.
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

	case .STRING, .SYMBOL, .LIST, .NATIVE_FUNCTION, .FUNCTION:
		runtime_error("copy expects a vector or map")
		return Value{}
	}

	return Value{}
}

// (clear value) value; Empty a vector or map in place and return it.
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

	case .STRING, .SYMBOL, .LIST, .NATIVE_FUNCTION, .FUNCTION:
		runtime_error("clear expects a vector or map")
		return Value{}
	}

	return Value{}
}

// (type value) string; Runtime type name.
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
			case .NATIVE_FUNCTION, .FUNCTION:
				type_name = "function"
			case .SYMBOL:
				assert(false, "symbol is not a Rite runtime value")
				return Value{}
			}
		}
	}

	return Value(cast(^Object)new_string_object(type_name))
}

// (assert condition message?) nil; Runtime error if condition is falsey.
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

// (error message) never; Raise a runtime error using the display text of message.
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

// (push vector value...) vector; Append values to vector in place.
native_push :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("push expects a vector and one or more values")
		return Value{}
	}

	vector_value := args[0]
	for i := 1; i < len(args); i += 1 {
		op_push(vector_value, args[i])
		if vm.error_string != "" { return Value{} }
	}

	return vector_value
}

// (pop vector) value; Remove and return the last vector item.
native_pop :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("pop expects one argument")
		return Value{}
	}

	return op_pop(args[0])
}

// (insert vector index value) vector; Insert value into vector at index.
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

// (remove vector index) value; Remove and return vector item at index.
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

// (slice vector start count) vector; Copy a vector range.
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

// (keys map) vector; Map keys in unspecified order.
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

// (vals map) vector; Map values in unspecified order.
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

// (pairs map) vector; Map key/value pairs as two-item vectors, in unspecified order.
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

// (merge map map...) map; Fresh map with later maps overriding earlier maps.
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

// (print value...) nil; Display values separated by spaces, followed by newline.
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

// (write value...) nil; Display values without separators or trailing newline.
native_write :: proc(vm: ^VM, args: []Value) -> Value {
	for value in args {
		print_value(value)
	}
	return Value{}
}


// Host module install ============================================================================

install_host_module :: proc(vm: ^VM, id: string, exports: []Binding) {
	_, found := find_module(vm, id)
	assert(!found, "duplicate host module")

	final_exports := make([]Binding, len(exports))
	copy(final_exports, exports)

	append(&vm.modules, Module{
		id      = strings.clone(id),
		loading = false,
		code    = nil,
		exports = final_exports,
	})
}

require_string_arg :: proc(args: []Value, index: int, proc_name, arg_name: string) -> (string, bool) {
	object, is_object := args[index].(^Object)
	if !is_object || object.kind != .STRING {
		runtime_error(fmt.tprintf("%s expects %s argument to be string", proc_name, arg_name))
		return "", false
	}

	return (cast(^StringObject)object).text, true
}

require_int_arg :: proc(args: []Value, index: int, proc_name, arg_name: string) -> (i64, bool) {
	value, is_int := args[index].(i64)
	if !is_int {
		runtime_error(fmt.tprintf("%s expects %s argument to be int", proc_name, arg_name))
		return 0, false
	}

	return value, true
}


// String module ==================================================================================

// (has? text part) bool; true if text contains part.
native_str_has :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("str/has? expects two arguments")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/has?", "first")
	if !text_ok { return Value{} }
	part, part_ok := require_string_arg(args, 1, "str/has?", "second")
	if !part_ok { return Value{} }

	return Value(bool(strings.contains(text, part)))
}

// (prefix? text prefix) bool; true if text starts with prefix.
native_str_prefix :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("str/prefix? expects two arguments")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/prefix?", "first")
	if !text_ok { return Value{} }
	prefix, prefix_ok := require_string_arg(args, 1, "str/prefix?", "second")
	if !prefix_ok { return Value{} }

	return Value(bool(strings.has_prefix(text, prefix)))
}

// (suffix? text suffix) bool; true if text ends with suffix.
native_str_suffix :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("str/suffix? expects two arguments")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/suffix?", "first")
	if !text_ok { return Value{} }
	suffix, suffix_ok := require_string_arg(args, 1, "str/suffix?", "second")
	if !suffix_ok { return Value{} }

	return Value(bool(strings.has_suffix(text, suffix)))
}

// (split text separator) vector; Split text by separator into strings.
native_str_split :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("str/split expects two arguments")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/split", "first")
	if !text_ok { return Value{} }
	separator, separator_ok := require_string_arg(args, 1, "str/split", "second")
	if !separator_ok { return Value{} }

	parts, err := strings.split(text, separator)
	if err != nil {
		runtime_error("str/split failed to allocate result vector")
		return Value{}
	}
	defer delete(parts)

	items := make([dynamic]Value)
	reserve(&items, len(parts))
	for part in parts {
		append(&items, Value(cast(^Object)new_string_object(part)))
	}

	return Value(cast(^Object)new_vector_object(items))
}

// (slice text start count) string; Copy a byte range from text.
native_str_slice :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 3 {
		runtime_error("str/slice expects a string, start, and count")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/slice", "first")
	if !text_ok { return Value{} }
	start, start_ok := require_int_arg(args, 1, "str/slice", "second")
	if !start_ok { return Value{} }
	count, count_ok := require_int_arg(args, 2, "str/slice", "third")
	if !count_ok { return Value{} }

	length := i64(len(text))
	if start < 0 || count < 0 || start > length || count > length - start {
		runtime_error("str/slice range out of bounds")
		return Value{}
	}

	return Value(cast(^Object)new_string_object(text[int(start):int(start + count)]))
}

// (replace text old new) string; Replace all old text with new text.
native_str_replace :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 3 {
		runtime_error("str/replace expects a string, old text, and new text")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/replace", "first")
	if !text_ok { return Value{} }
	old, old_ok := require_string_arg(args, 1, "str/replace", "second")
	if !old_ok { return Value{} }
	new, new_ok := require_string_arg(args, 2, "str/replace", "third")
	if !new_ok { return Value{} }

	result, result_was_allocation := strings.replace_all(text, old, new)
	if result_was_allocation {
		object := new_string_object(result)
		delete(result)
		return Value(cast(^Object)object)
	}

	return Value(cast(^Object)new_string_object(result))
}

// (trim text) string; Trim surrounding whitespace.
native_str_trim :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("str/trim expects one argument")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/trim", "first")
	if !text_ok { return Value{} }

	return Value(cast(^Object)new_string_object(strings.trim_space(text)))
}

// (lower text) string; Lowercase text.
native_str_lower :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("str/lower expects one argument")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/lower", "first")
	if !text_ok { return Value{} }

	lower, err := strings.to_lower(text)
	if err != nil {
		runtime_error("str/lower failed to allocate result string")
		return Value{}
	}
	defer delete(lower)

	return Value(cast(^Object)new_string_object(lower))
}

// (upper text) string; Uppercase text.
native_str_upper :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("str/upper expects one argument")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/upper", "first")
	if !text_ok { return Value{} }

	upper, err := strings.to_upper(text)
	if err != nil {
		runtime_error("str/upper failed to allocate result string")
		return Value{}
	}
	defer delete(upper)

	return Value(cast(^Object)new_string_object(upper))
}

// (byte text index) int; Byte value at index.
native_str_byte :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("str/byte expects a string and index")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/byte", "first")
	if !text_ok { return Value{} }
	index, index_ok := require_int_arg(args, 1, "str/byte", "second")
	if !index_ok { return Value{} }

	if index < 0 || index >= i64(len(text)) {
		runtime_error("str/byte index out of bounds")
		return Value{}
	}

	return Value(i64(text[int(index)]))
}

// (bytes text) vector; Byte values of text.
native_str_bytes :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("str/bytes expects one argument")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/bytes", "first")
	if !text_ok { return Value{} }

	items := make([dynamic]Value)
	reserve(&items, len(text))
	for byte_value in text {
		append(&items, Value(i64(byte_value)))
	}

	return Value(cast(^Object)new_vector_object(items))
}


// Registration ==================================================================================

install_core_modules :: proc(vm: ^VM) {
	str_exports := make([dynamic]Binding)

	bind_native_function(vm, &str_exports, "has?", native_str_has)
	bind_native_function(vm, &str_exports, "prefix?", native_str_prefix)
	bind_native_function(vm, &str_exports, "suffix?", native_str_suffix)
	bind_native_function(vm, &str_exports, "split", native_str_split)
	bind_native_function(vm, &str_exports, "slice", native_str_slice)
	bind_native_function(vm, &str_exports, "replace", native_str_replace)
	bind_native_function(vm, &str_exports, "trim", native_str_trim)
	bind_native_function(vm, &str_exports, "lower", native_str_lower)
	bind_native_function(vm, &str_exports, "upper", native_str_upper)
	bind_native_function(vm, &str_exports, "byte", native_str_byte)
	bind_native_function(vm, &str_exports, "bytes", native_str_bytes)

	install_host_module(vm, "str", str_exports[:])
	delete(str_exports)
}


install_builtins :: proc(vm: ^VM) {
	// Supplied builtins are immutable; install them exactly once per VM.
	bind_native_builtin(vm, "+", native_add)
	bind_native_builtin(vm, "-", native_sub)
	bind_native_builtin(vm, "*", native_mul)
	bind_native_builtin(vm, "/", native_div)
	bind_native_builtin(vm, "%", native_mod)
	bind_native_builtin(vm, "=", native_equal)
	bind_native_builtin(vm, "!=", native_not_equal)
	bind_native_builtin(vm, "<", native_less)
	bind_native_builtin(vm, "<=", native_less_equal)
	bind_native_builtin(vm, ">", native_greater)
	bind_native_builtin(vm, ">=", native_greater_equal)
	bind_native_builtin(vm, "not", native_not)
	bind_native_builtin(vm, "nil?", native_nil_predicate)
	bind_native_builtin(vm, "bool?", native_bool_predicate)
	bind_native_builtin(vm, "num?", native_number_predicate)
	bind_native_builtin(vm, "int?", native_int_predicate)
	bind_native_builtin(vm, "float?", native_float_predicate)
	bind_native_builtin(vm, "str?", native_string_predicate)
	bind_native_builtin(vm, "vec?", native_vector_predicate)
	bind_native_builtin(vm, "map?", native_map_predicate)
	bind_native_builtin(vm, "fn?", native_function_predicate)
	bind_native_builtin(vm, "len", native_len)
	bind_native_builtin(vm, "copy", native_copy)
	bind_native_builtin(vm, "clear", native_clear)
	bind_native_builtin(vm, "type", native_type)
	bind_native_builtin(vm, "assert", native_assert)
	bind_native_builtin(vm, "error", native_error)
	bind_native_builtin(vm, "push", native_push)
	bind_native_builtin(vm, "pop", native_pop)
	bind_native_builtin(vm, "insert", native_insert)
	bind_native_builtin(vm, "remove", native_remove)
	bind_native_builtin(vm, "slice", native_slice)
	bind_native_builtin(vm, "keys", native_keys)
	bind_native_builtin(vm, "vals", native_vals)
	bind_native_builtin(vm, "pairs", native_pairs)
	bind_native_builtin(vm, "merge", native_merge)
	bind_native_builtin(vm, "print", native_print)
	bind_native_builtin(vm, "write", native_write)
}
