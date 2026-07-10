package obel

import "base:intrinsics"
import "core:fmt"
import "core:io"
import "core:math"
import "core:os"
import filepath "core:path/filepath"
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


// Builtin binding ================================================================================

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
// Int +, -, and * wrap in i64 range.
// / always returns float.

op_add_binary :: proc(lhs, rhs: Value) -> Value {
	lhs_int, lhs_is_int := lhs.(i64)
	rhs_int, rhs_is_int := rhs.(i64)
	if lhs_is_int && rhs_is_int {
		result, _ := intrinsics.overflow_add(lhs_int, rhs_int)
		return Value(result)
	}

	lhs_float, lhs_is_float := lhs.(f64)
	if lhs_is_int {
		lhs_float = f64(lhs_int)
	} else if !lhs_is_float {
		runtime_error("`+` expected number arguments.")
		return Value{}
	}

	rhs_float, rhs_is_float := rhs.(f64)
	if rhs_is_int {
		rhs_float = f64(rhs_int)
	} else if !rhs_is_float {
		runtime_error("`+` expected number arguments.")
		return Value{}
	}

	return Value(lhs_float + rhs_float)
}

op_sub_binary :: proc(lhs, rhs: Value) -> Value {
	lhs_int, lhs_is_int := lhs.(i64)
	rhs_int, rhs_is_int := rhs.(i64)
	if lhs_is_int && rhs_is_int {
		result, _ := intrinsics.overflow_sub(lhs_int, rhs_int)
		return Value(result)
	}

	lhs_float, lhs_is_float := lhs.(f64)
	if lhs_is_int {
		lhs_float = f64(lhs_int)
	} else if !lhs_is_float {
		runtime_error("`-` expected number arguments.")
		return Value{}
	}

	rhs_float, rhs_is_float := rhs.(f64)
	if rhs_is_int {
		rhs_float = f64(rhs_int)
	} else if !rhs_is_float {
		runtime_error("`-` expected number arguments.")
		return Value{}
	}

	return Value(lhs_float - rhs_float)
}

op_mul_binary :: proc(lhs, rhs: Value) -> Value {
	lhs_int, lhs_is_int := lhs.(i64)
	rhs_int, rhs_is_int := rhs.(i64)
	if lhs_is_int && rhs_is_int {
		result, _ := intrinsics.overflow_mul(lhs_int, rhs_int)
		return Value(result)
	}

	lhs_float, lhs_is_float := lhs.(f64)
	if lhs_is_int {
		lhs_float = f64(lhs_int)
	} else if !lhs_is_float {
		runtime_error("`*` expected number arguments.")
		return Value{}
	}

	rhs_float, rhs_is_float := rhs.(f64)
	if rhs_is_int {
		rhs_float = f64(rhs_int)
	} else if !rhs_is_float {
		runtime_error("`*` expected number arguments.")
		return Value{}
	}

	return Value(lhs_float * rhs_float)
}

op_div_binary :: proc(lhs, rhs: Value) -> Value {
	lhs_int, lhs_is_int := lhs.(i64)
	lhs_float, lhs_is_float := lhs.(f64)
	if lhs_is_int {
		lhs_float = f64(lhs_int)
	} else if !lhs_is_float {
		runtime_error("`/` expected number arguments.")
		return Value{}
	}

	rhs_int, rhs_is_int := rhs.(i64)
	rhs_float, rhs_is_float := rhs.(f64)
	if rhs_is_int {
		if rhs_int == 0 {
			runtime_error("`/` divisor cannot be zero.")
			return Value{}
		}

		rhs_float = f64(rhs_int)
	} else if rhs_is_float {
		if rhs_float == 0 {
			runtime_error("`/` divisor cannot be zero.")
			return Value{}
		}
	} else {
		runtime_error("`/` expected number arguments.")
		return Value{}
	}

	return Value(lhs_float / rhs_float)
}

op_add :: proc(args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("`+` expects two or more arguments.\nusage: (+ number number...)")
		return Value{}
	}

	all_int := true
	int_result: i64
	float_result: f64

	for arg in args {
		int_value, is_int := arg.(i64)
		if is_int {
			if all_int {
				int_result, _ = intrinsics.overflow_add(int_result, int_value)
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

		runtime_error("`+` expected number arguments.")
		return Value{}
	}

	if all_int {
		return Value(int_result)
	}
	return Value(float_result)
}

op_sub :: proc(args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("`-` expects two or more arguments.\nusage: (- number number...)")
		return Value{}
	}

	int_result, first_is_int := args[0].(i64)
	float_result, first_is_float := args[0].(f64)
	if !first_is_int && !first_is_float {
		runtime_error("`-` expected number arguments.")
		return Value{}
	}

	all_int := first_is_int

	for i := 1; i < len(args); i += 1 {
		int_value, is_int := args[i].(i64)
		if is_int {
			if all_int {
				int_result, _ = intrinsics.overflow_sub(int_result, int_value)
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

		runtime_error("`-` expected number arguments.")
		return Value{}
	}

	if all_int {
		return Value(int_result)
	}
	return Value(float_result)
}

op_mul :: proc(args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("`*` expects two or more arguments.\nusage: (* number number...)")
		return Value{}
	}

	all_int := true
	int_result: i64 = 1
	float_result: f64 = 1

	for arg in args {
		int_value, is_int := arg.(i64)
		if is_int {
			if all_int {
				int_result, _ = intrinsics.overflow_mul(int_result, int_value)
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

		runtime_error("`*` expected number arguments.")
		return Value{}
	}

	if all_int {
		return Value(int_result)
	}
	return Value(float_result)
}

op_div :: proc(args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("`/` expects two or more arguments.\nusage: (/ number number...)")
		return Value{}
	}

	int_value, first_is_int := args[0].(i64)
	float_result, first_is_float := args[0].(f64)
	if first_is_int {
		float_result = f64(int_value)
	} else if !first_is_float {
		runtime_error("`/` expected number arguments.")
		return Value{}
	}

	for i := 1; i < len(args); i += 1 {
		int_divisor, is_int := args[i].(i64)
		if is_int {
			if int_divisor == 0 {
				runtime_error("`/` divisor cannot be zero.")
				return Value{}
			}

			float_result /= f64(int_divisor)
			continue
		}

		float_divisor, is_float := args[i].(f64)
		if is_float {
			if float_divisor == 0 {
				runtime_error("`/` divisor cannot be zero.")
				return Value{}
			}

			float_result /= float_divisor
			continue
		}

		runtime_error("`/` expected number arguments.")
		return Value{}
	}

	return Value(float_result)
}

op_mod :: proc(lhs, rhs: Value) -> Value {
	left_int, left_is_int := lhs.(i64)
	right_int, right_is_int := rhs.(i64)

	if left_is_int && right_is_int {
		if right_int == 0 {
			runtime_error("`%` divisor cannot be zero.")
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
		runtime_error("`%` expected number arguments.")
		return Value{}
	}

	right_float, right_is_float := rhs.(f64)
	if right_is_int {
		right_float = f64(right_int)
	} else if !right_is_float {
		runtime_error("`%` expected number arguments.")
		return Value{}
	}

	if right_float == 0 {
		runtime_error("`%` divisor cannot be zero.")
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

	if left_object == right_object {
		return true
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

NumericCompare :: enum u8 {
	LESS,
	LESS_EQUAL,
	GREATER,
	GREATER_EQUAL,
}

compare_numbers :: proc(lhs, rhs: Value, compare: NumericCompare) -> bool {
	left_int, left_is_int := lhs.(i64)
	right_int, right_is_int := rhs.(i64)
	if left_is_int && right_is_int {
		#partial switch compare {
		case .LESS:
			return left_int < right_int
		case .LESS_EQUAL:
			return left_int <= right_int
		case .GREATER:
			return left_int > right_int
		case .GREATER_EQUAL:
			return left_int >= right_int
		}
	}

	left_float, left_is_float := lhs.(f64)
	if left_is_int {
		left_float = f64(left_int)
	} else if !left_is_float {
		#partial switch compare {
		case .LESS:
			runtime_error("`<` expected number arguments.")
		case .LESS_EQUAL:
			runtime_error("`<=` expected number arguments.")
		case .GREATER:
			runtime_error("`>` expected number arguments.")
		case .GREATER_EQUAL:
			runtime_error("`>=` expected number arguments.")
		}
		return false
	}

	right_float, right_is_float := rhs.(f64)
	if right_is_int {
		right_float = f64(right_int)
	} else if !right_is_float {
		#partial switch compare {
		case .LESS:
			runtime_error("`<` expected number arguments.")
		case .LESS_EQUAL:
			runtime_error("`<=` expected number arguments.")
		case .GREATER:
			runtime_error("`>` expected number arguments.")
		case .GREATER_EQUAL:
			runtime_error("`>=` expected number arguments.")
		}
		return false
	}

	#partial switch compare {
	case .LESS:
		return left_float < right_float
	case .LESS_EQUAL:
		return left_float <= right_float
	case .GREATER:
		return left_float > right_float
	case .GREATER_EQUAL:
		return left_float >= right_float
	}

	assert(false, "invalid numeric comparison")
	return false
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
		runtime_error("`len` expected string, vector, or map as argument.")
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
		runtime_error("`len` expected string, vector, or map as argument.")
		return Value{}
	}

	return Value{}
}

op_push :: proc(vector_value, item: Value) -> Value {
	vector_object, vector_is_object := vector_value.(^Object)
	if !vector_is_object || vector_object.kind != .VECTOR {
		runtime_error("`push` expected vector as first argument.")
		return Value{}
	}

	vector := cast(^VectorObject)vector_object
	append(&vector.items, item)
	return vector_value
}

op_pop :: proc(vector_value: Value) -> Value {
	vector_object, vector_is_object := vector_value.(^Object)
	if !vector_is_object || vector_object.kind != .VECTOR {
		runtime_error("`pop` expected vector as argument.")
		return Value{}
	}

	vector := cast(^VectorObject)vector_object
	if len(vector.items) == 0 {
		runtime_error("cannot pop empty vector.")
		return Value{}
	}

	return pop(&vector.items)
}


// Native argument helpers ========================================================================

require_string_arg :: proc(args: []Value, index: int, proc_name, arg_name: string) -> (string, bool) {
	object, is_object := args[index].(^Object)
	if !is_object || object.kind != .STRING {
		runtime_error(fmt.tprintf("`%s` expected string as %s argument.", proc_name, arg_name))
		return "", false
	}

	return (cast(^StringObject)object).text, true
}

require_int_arg :: proc(args: []Value, index: int, proc_name, arg_name: string) -> (i64, bool) {
	value, is_int := args[index].(i64)
	if !is_int {
		runtime_error(fmt.tprintf("`%s` expected int as %s argument.", proc_name, arg_name))
		return 0, false
	}

	return value, true
}


// Native builtins ================================================================================

// (+ number number...) number; Numeric sum.
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
		runtime_error("`%` expects two arguments.\nusage: (% number number)")
		return Value{}
	}
	return op_mod(args[0], args[1])
}

// (= left right) bool; true if values are equal by Obel equality.
native_equal :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("`=` expects two arguments.\nusage: (= value value)")
		return Value{}
	}
	return op_equal(args[0], args[1])
}

// (!= left right) bool; true if values are not equal by Obel equality.
native_not_equal :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("`!=` expects two arguments.\nusage: (!= value value)")
		return Value{}
	}
	return Value(bool(!values_equal(args[0], args[1])))
}

// (< left right) bool; Numeric less-than.
native_less :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("`<` expects two arguments.\nusage: (< number number)")
		return Value{}
	}
	return Value(bool(compare_numbers(args[0], args[1], .LESS)))
}

// (<= left right) bool; Numeric less-than-or-equal.
native_less_equal :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("`<=` expects two arguments.\nusage: (<= number number)")
		return Value{}
	}
	return Value(bool(compare_numbers(args[0], args[1], .LESS_EQUAL)))
}

// (> left right) bool; Numeric greater-than.
native_greater :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("`>` expects two arguments.\nusage: (> number number)")
		return Value{}
	}
	return Value(bool(compare_numbers(args[0], args[1], .GREATER)))
}

// (>= left right) bool; Numeric greater-than-or-equal.
native_greater_equal :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("`>=` expects two arguments.\nusage: (>= number number)")
		return Value{}
	}
	return Value(bool(compare_numbers(args[0], args[1], .GREATER_EQUAL)))
}

// (not value) bool; true if value is falsey.
native_not :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`not` expects one argument.\nusage: (not value)")
		return Value{}
	}
	return op_not(args[0])
}

// (nil? value) bool; true if value is nil.
native_nil_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`nil?` expects one argument.\nusage: (nil? value)")
		return Value{}
	}
	return Value(bool(args[0] == nil))
}

// (bool? value) bool; true if value is bool.
native_bool_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`bool?` expects one argument.\nusage: (bool? value)")
		return Value{}
	}
	_, is_bool := args[0].(bool)
	return Value(bool(is_bool))
}

// (number? value) bool; true if value is int or float.
native_number_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`number?` expects one argument.\nusage: (number? value)")
		return Value{}
	}
	_, is_int := args[0].(i64)
	_, is_float := args[0].(f64)
	return Value(bool(is_int || is_float))
}

// (number value) number|nil; Parse or pass through an Obel number.
native_number :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`number` expects one argument.\nusage: (number value)")
		return Value{}
	}

	value := args[0]
	if value == nil { return Value{} }

	switch v in value {
	case i64, f64:
		return value

	case bool:
		return Value{}

	case ^Object:
		if v.kind == .STRING {
			text := strings.trim_space((cast(^StringObject)v).text)
			number, ok := number_from_text(text, false)
			if ok { return number }
		}
	}

	return Value{}
}

// (int? value) bool; true if value is int.
native_int_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`int?` expects one argument.\nusage: (int? value)")
		return Value{}
	}
	_, is_int := args[0].(i64)
	return Value(bool(is_int))
}

// (float? value) bool; true if value is float.
native_float_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`float?` expects one argument.\nusage: (float? value)")
		return Value{}
	}
	_, is_float := args[0].(f64)
	return Value(bool(is_float))
}

// (str? value) bool; true if value is string.
native_string_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`str?` expects one argument.\nusage: (str? value)")
		return Value{}
	}
	object, is_object := args[0].(^Object)
	return Value(bool(is_object && object.kind == .STRING))
}

// (vec? value) bool; true if value is vector.
native_vector_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`vec?` expects one argument.\nusage: (vec? value)")
		return Value{}
	}
	object, is_object := args[0].(^Object)
	return Value(bool(is_object && object.kind == .VECTOR))
}

// (map? value) bool; true if value is map.
native_map_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`map?` expects one argument.\nusage: (map? value)")
		return Value{}
	}
	object, is_object := args[0].(^Object)
	return Value(bool(is_object && object.kind == .MAP))
}

// (fn? value) bool; true if value is a native or Obel function.
native_function_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`fn?` expects one argument.\nusage: (fn? value)")
		return Value{}
	}
	object, is_object := args[0].(^Object)
	return Value(bool(is_object && (object.kind == .NATIVE_FUNCTION || object.kind == .FUNCTION)))
}

// (len value) int; Length of a string, vector, or map.
native_len :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`len` expects one argument.\nusage: (len value)")
		return Value{}
	}
	return op_len(args[0])
}

// (copy value) value; Shallow copy of a vector or map.
native_copy :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`copy` expects one argument.\nusage: (copy value)")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object {
		runtime_error("`copy` expected vector or map as argument.")
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
		runtime_error("`copy` expected vector or map as argument.")
		return Value{}
	}

	return Value{}
}

// (clear value) value; Empty a vector or map in place and return it.
native_clear :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`clear` expects one argument.\nusage: (clear value)")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object {
		runtime_error("`clear` expected vector or map as argument.")
		return Value{}
	}

	switch object.kind {
	case .VECTOR:
		vector := cast(^VectorObject)object
		clear(&vector.items)
		return args[0]

	case .MAP:
		map_object := cast(^MapObject)object

		// Direct map each scans the existing bucket array, so clear maps in place.
		for i := 0; i < len(map_object.entries); i += 1 {
			map_object.entries[i] = MapEntry{}
		}
		map_object.count = 0
		map_object.tombstone_count = 0
		return args[0]

	case .STRING, .SYMBOL, .LIST, .NATIVE_FUNCTION, .FUNCTION:
		runtime_error("`clear` expected vector or map as argument.")
		return Value{}
	}

	return Value{}
}

// (type value) string; Runtime type name.
native_type :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`type` expects one argument.\nusage: (type value)")
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
				assert(false, "symbol is not an Obel runtime value")
				return Value{}
			}
		}
	}

	return Value(cast(^Object)new_string_object(type_name))
}

// (str value...) string; Concatenate display text for each value.
native_str :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) == 0 {
		return Value(cast(^Object)new_string_object(""))
	}

	parts := make([dynamic]string)
	parents := make([dynamic]^Object)

	for arg in args {
		append_value_text(&parts, arg, &parents)
	}

	text := strings.concatenate(parts[:])

	delete(parts)
	delete(parents)
	defer delete(text)

	return Value(cast(^Object)new_string_object(text))
}

// (assert condition message?) nil; Runtime error if condition is falsey.
native_assert :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) < 1 || len(args) > 2 {
		runtime_error("`assert` expects condition and optional message.\nusage: (assert condition message?)")
		return Value{}
	}

	if !value_is_falsey(args[0]) { return Value{} }

	if len(args) == 1 {
		runtime_error("assertion failed.")
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
		runtime_error("`error` expects one argument.\nusage: (error message)")
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
		runtime_error("`push` expects vector and one or more values.\nusage: (push vector value value...)")
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
		runtime_error("`pop` expects one argument.\nusage: (pop vector)")
		return Value{}
	}

	return op_pop(args[0])
}

// (insert vector index value) vector; Insert value into vector at index.
native_insert :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 3 {
		runtime_error("`insert` expects vector, index, and value.\nusage: (insert vector index value)")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object || object.kind != .VECTOR {
		runtime_error("`insert` expected vector as first argument.")
		return Value{}
	}

	index, is_int := args[1].(i64)
	if !is_int {
		runtime_error("`insert` expected int as index.")
		return Value{}
	}

	vector := cast(^VectorObject)object
	if index < 0 || index > i64(len(vector.items)) {
		runtime_error("`insert` index out of range.")
		return Value{}
	}

	inject_at(&vector.items, int(index), args[2])
	return args[0]
}

// (remove vector index) value; Remove and return vector item at index.
native_remove :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("`remove` expects vector and index.\nusage: (remove vector index)")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object || object.kind != .VECTOR {
		runtime_error("`remove` expected vector as first argument.")
		return Value{}
	}

	index, is_int := args[1].(i64)
	if !is_int {
		runtime_error("`remove` expected int as index.")
		return Value{}
	}

	vector := cast(^VectorObject)object
	if index < 0 || index >= i64(len(vector.items)) {
		runtime_error("`remove` index out of range.")
		return Value{}
	}

	result := vector.items[int(index)]
	ordered_remove(&vector.items, int(index))
	return result
}

// (slice vector start count) vector; Copy a vector range.
native_slice :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 3 {
		runtime_error("`slice` expects vector, start, and count.\nusage: (slice vector start count)")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object || object.kind != .VECTOR {
		runtime_error("`slice` expected vector as first argument.")
		return Value{}
	}

	start, start_is_int := args[1].(i64)
	count, count_is_int := args[2].(i64)
	if !start_is_int || !count_is_int {
		runtime_error("`slice` expected int start and count.")
		return Value{}
	}

	vector := cast(^VectorObject)object
	length := i64(len(vector.items))
	if start < 0 || count < 0 || start > length || count > length - start {
		runtime_error("`slice` range out of bounds.")
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
		runtime_error("`keys` expects one argument.\nusage: (keys map)")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object || object.kind != .MAP {
		runtime_error("`keys` expected map as argument.")
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
		runtime_error("`vals` expects one argument.\nusage: (vals map)")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object || object.kind != .MAP {
		runtime_error("`vals` expected map as argument.")
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
		runtime_error("`pairs` expects one argument.\nusage: (pairs map)")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object || object.kind != .MAP {
		runtime_error("`pairs` expected map as argument.")
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
		runtime_error("`merge` expects two or more maps.\nusage: (merge map map...)")
		return Value{}
	}

	entry_capacity := 0
	for arg in args {
		object, is_object := arg.(^Object)
		if !is_object || object.kind != .MAP {
			runtime_error("`merge` expected map arguments.")
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


// String module ==================================================================================

// (has? text part) bool; true if text contains part.
native_str_has :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("`str/has?` expects two arguments.\nusage: (str/has? text part)")
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
		runtime_error("`str/prefix?` expects two arguments.\nusage: (str/prefix? text prefix)")
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
		runtime_error("`str/suffix?` expects two arguments.\nusage: (str/suffix? text suffix)")
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
		runtime_error("`str/split` expects two arguments.\nusage: (str/split text separator)")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/split", "first")
	if !text_ok { return Value{} }
	separator, separator_ok := require_string_arg(args, 1, "str/split", "second")
	if !separator_ok { return Value{} }

	parts, err := strings.split(text, separator)
	if err != nil {
		runtime_error("`str/split` failed to allocate result vector.")
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

// (join parts separator) string; Join a vector of strings with separator.
native_str_join :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("`str/join` expects vector and separator.\nusage: (str/join vector separator)")
		return Value{}
	}

	object, is_object := args[0].(^Object)
	if !is_object || object.kind != .VECTOR {
		runtime_error("`str/join` expected vector as first argument.")
		return Value{}
	}

	separator, separator_ok := require_string_arg(args, 1, "str/join", "second")
	if !separator_ok { return Value{} }

	vector := cast(^VectorObject)object
	parts := make([dynamic]string)
	defer delete(parts)

	reserve(&parts, len(vector.items))
	for i := 0; i < len(vector.items); i += 1 {
		part_object, part_is_object := vector.items[i].(^Object)
		if !part_is_object || part_object.kind != .STRING {
			runtime_error(fmt.tprintf("`str/join` expected vector item %d to be string.", i))
			return Value{}
		}

		append(&parts, (cast(^StringObject)part_object).text)
	}

	text := strings.join(parts[:], separator)
	defer delete(text)

	return Value(cast(^Object)new_string_object(text))
}

// (find text part) int|nil; First byte index of part in text.
native_str_find :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("`str/find` expects two arguments.\nusage: (str/find text part)")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/find", "first")
	if !text_ok { return Value{} }
	part, part_ok := require_string_arg(args, 1, "str/find", "second")
	if !part_ok { return Value{} }

	index := strings.index(text, part)
	if index < 0 {
		return Value{}
	}

	return Value(i64(index))
}

// (slice text start count) string; Copy a byte range from text.
native_str_slice :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 3 {
		runtime_error("`str/slice` expects string, start, and count.\nusage: (str/slice text start count)")
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
		runtime_error("`str/slice` range out of bounds.")
		return Value{}
	}

	return Value(cast(^Object)new_string_object(text[int(start):int(start + count)]))
}

// (replace text old new) string; Replace all old text with new text.
native_str_replace :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 3 {
		runtime_error("`str/replace` expects string, old text, and new text.\nusage: (str/replace text old new)")
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
		runtime_error("`str/trim` expects one argument.\nusage: (str/trim text)")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/trim", "first")
	if !text_ok { return Value{} }

	return Value(cast(^Object)new_string_object(strings.trim_space(text)))
}

// (lower text) string; Lowercase text.
native_str_lower :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`str/lower` expects one argument.\nusage: (str/lower text)")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/lower", "first")
	if !text_ok { return Value{} }

	lower, err := strings.to_lower(text)
	if err != nil {
		runtime_error("`str/lower` failed to allocate result string.")
		return Value{}
	}
	defer delete(lower)

	return Value(cast(^Object)new_string_object(lower))
}

// (upper text) string; Uppercase text.
native_str_upper :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`str/upper` expects one argument.\nusage: (str/upper text)")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/upper", "first")
	if !text_ok { return Value{} }

	upper, err := strings.to_upper(text)
	if err != nil {
		runtime_error("`str/upper` failed to allocate result string.")
		return Value{}
	}
	defer delete(upper)

	return Value(cast(^Object)new_string_object(upper))
}

// (byte text index) int; Byte value at index.
native_str_byte :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("`str/byte` expects string and index.\nusage: (str/byte text index)")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "str/byte", "first")
	if !text_ok { return Value{} }
	index, index_ok := require_int_arg(args, 1, "str/byte", "second")
	if !index_ok { return Value{} }

	if index < 0 || index >= i64(len(text)) {
		runtime_error("`str/byte` index out of bounds.")
		return Value{}
	}

	return Value(i64(text[int(index)]))
}

// (bytes text) vector; Byte values of text.
native_str_bytes :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`str/bytes` expects one argument.\nusage: (str/bytes text)")
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


// Path module ====================================================================================
// Pure path-string transforms. These do not touch the filesystem.

// (join part...) string; Join path parts using host path rules.
native_path_join :: proc(vm: ^VM, args: []Value) -> Value {
	parts := make([dynamic]string)
	defer delete(parts)

	for i := 0; i < len(args); i += 1 {
		object, is_object := args[i].(^Object)
		if !is_object || object.kind != .STRING {
			runtime_error(fmt.tprintf("`path/join` expected string as argument %d.", i + 1))
			return Value{}
		}

		append(&parts, (cast(^StringObject)object).text)
	}

	joined, join_error := os.join_path(parts[:], context.allocator)
	if join_error != nil {
		runtime_error(fmt.tprintf("`path/join` failed to allocate result string: %v", join_error))
		return Value{}
	}
	defer delete(joined)

	return Value(cast(^Object)new_string_object(joined))
}

// (base path) string; Final path component.
native_path_base :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`path/base` expects one argument.\nusage: (path/base path)")
		return Value{}
	}

	path, path_ok := require_string_arg(args, 0, "path/base", "first")
	if !path_ok { return Value{} }

	return Value(cast(^Object)new_string_object(os.base(path)))
}

// (dir path) string; Parent path portion.
native_path_dir :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`path/dir` expects one argument.\nusage: (path/dir path)")
		return Value{}
	}

	path, path_ok := require_string_arg(args, 0, "path/dir", "first")
	if !path_ok { return Value{} }

	dir, _ := os.split_path(path)
	return Value(cast(^Object)new_string_object(dir))
}

// (ext path) string; File extension, including the dot.
native_path_ext :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`path/ext` expects one argument.\nusage: (path/ext path)")
		return Value{}
	}

	path, path_ok := require_string_arg(args, 0, "path/ext", "first")
	if !path_ok { return Value{} }

	return Value(cast(^Object)new_string_object(os.ext(path)))
}

// (stem path) string; Final path component without extension.
native_path_stem :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`path/stem` expects one argument.\nusage: (path/stem path)")
		return Value{}
	}

	path, path_ok := require_string_arg(args, 0, "path/stem", "first")
	if !path_ok { return Value{} }

	if path == "" {
		return Value(cast(^Object)new_string_object(""))
	}

	return Value(cast(^Object)new_string_object(os.stem(path)))
}

// (clean path) string; Lexically clean redundant path components.
native_path_clean :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`path/clean` expects one argument.\nusage: (path/clean path)")
		return Value{}
	}

	path, path_ok := require_string_arg(args, 0, "path/clean", "first")
	if !path_ok { return Value{} }

	cleaned, clean_error := os.clean_path(path, context.allocator)
	if clean_error != nil {
		runtime_error(fmt.tprintf("`path/clean` failed to allocate result string: %v", clean_error))
		return Value{}
	}
	defer delete(cleaned)

	return Value(cast(^Object)new_string_object(cleaned))
}

// (abs path) string; Absolute path against the current working directory.
native_path_abs :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`path/abs` expects one argument.\nusage: (path/abs path)")
		return Value{}
	}

	path, path_ok := require_string_arg(args, 0, "path/abs", "first")
	if !path_ok { return Value{} }

	absolute_path, abs_error := filepath.abs(path, context.allocator)
	if abs_error != nil {
		runtime_error(fmt.tprintf("`path/abs` failed for `%s`: %v", path, abs_error))
		return Value{}
	}
	defer delete(absolute_path)

	return Value(cast(^Object)new_string_object(absolute_path))
}


// OS module ======================================================================================

// (argv) vector; Raw process arguments.
native_os_argv :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 0 {
		runtime_error("`os/argv` expects no arguments.\nusage: (os/argv)")
		return Value{}
	}

	items := make([dynamic]Value)
	reserve(&items, len(vm.argv))
	for arg in vm.argv {
		append(&items, Value(cast(^Object)new_string_object(arg)))
	}

	return Value(cast(^Object)new_vector_object(items))
}

// (args) vector; Script arguments.
native_os_args :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 0 {
		runtime_error("`os/args` expects no arguments.\nusage: (os/args)")
		return Value{}
	}

	items := make([dynamic]Value)
	reserve(&items, len(vm.argv[vm.args_start:]))
	for arg in vm.argv[vm.args_start:] {
		append(&items, Value(cast(^Object)new_string_object(arg)))
	}

	return Value(cast(^Object)new_vector_object(items))
}

// (env name) string|nil; Environment variable value, or nil if unset.
native_os_env :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`os/env` expects one argument.\nusage: (os/env name)")
		return Value{}
	}

	name, name_ok := require_string_arg(args, 0, "os/env", "first")
	if !name_ok { return Value{} }

	value, found := os.lookup_env(name, context.allocator)
	if !found {
		return Value{}
	}
	defer delete(value)

	return Value(cast(^Object)new_string_object(value))
}

// (set-env name value) [true nil]|[nil err]; Set an environment variable.
native_os_set_env :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("`os/set-env` expects environment variable name and value.\nusage: (os/set-env name value)")
		return Value{}
	}

	name, name_ok := require_string_arg(args, 0, "os/set-env", "first")
	if !name_ok { return Value{} }
	value, value_ok := require_string_arg(args, 1, "os/set-env", "second")
	if !value_ok { return Value{} }

	set_error := os.set_env(name, value)
	if set_error != nil {
		items := make([dynamic]Value)
		reserve(&items, 2)
		append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`os/set-env` failed for `%s`: %v", name, set_error))))
		return Value(cast(^Object)new_vector_object(items))
	}

	items := make([dynamic]Value)
	reserve(&items, 2)
	append(&items, Value(bool(true)), Value{})
	return Value(cast(^Object)new_vector_object(items))
}

// (exit code) never; Exit the process.
native_os_exit :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`os/exit` expects one argument.\nusage: (os/exit code)")
		return Value{}
	}

	code, code_ok := require_int_arg(args, 0, "os/exit", "first")
	if !code_ok { return Value{} }

	os.exit(int(code))
}

// (name) string; Operating system name.
native_os_name :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 0 {
		runtime_error("`os/name` expects no arguments.\nusage: (os/name)")
		return Value{}
	}

	return Value(cast(^Object)new_string_object(ODIN_OS_STRING))
}

// (arch) string; CPU architecture name.
native_os_arch :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 0 {
		runtime_error("`os/arch` expects no arguments.\nusage: (os/arch)")
		return Value{}
	}

	return Value(cast(^Object)new_string_object(ODIN_ARCH_STRING))
}


// FS module ======================================================================================

// (read-file path) [string nil]|[nil err]; Read a text file.
native_fs_read_file :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`fs/read-file` expects one argument.\nusage: (fs/read-file path)")
		return Value{}
	}

	path, path_ok := require_string_arg(args, 0, "fs/read-file", "first")
	if !path_ok { return Value{} }

	bytes, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		items := make([dynamic]Value)
		reserve(&items, 2)
		append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/read-file` failed for `%s`: %v", path, read_error))))
		return Value(cast(^Object)new_vector_object(items))
	}
	defer delete(bytes)

	items := make([dynamic]Value)
	reserve(&items, 2)
	append(&items, Value(cast(^Object)new_string_object(string(bytes))), Value{})
	return Value(cast(^Object)new_vector_object(items))
}

// (write-file path text) [true nil]|[nil err]; Write text to a file.
native_fs_write_file :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 2 {
		runtime_error("`fs/write-file` expects path and text.\nusage: (fs/write-file path text)")
		return Value{}
	}

	path, path_ok := require_string_arg(args, 0, "fs/write-file", "first")
	if !path_ok { return Value{} }
	text, text_ok := require_string_arg(args, 1, "fs/write-file", "second")
	if !text_ok { return Value{} }

	write_error := os.write_entire_file(path, text)
	if write_error != nil {
		items := make([dynamic]Value)
		reserve(&items, 2)
		append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/write-file` failed for `%s`: %v", path, write_error))))
		return Value(cast(^Object)new_vector_object(items))
	}

	items := make([dynamic]Value)
	reserve(&items, 2)
	append(&items, Value(bool(true)), Value{})
	return Value(cast(^Object)new_vector_object(items))
}

// (cwd) [string nil]|[nil err]; Current working directory.
native_fs_cwd :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 0 {
		runtime_error("`fs/cwd` expects no arguments.\nusage: (fs/cwd)")
		return Value{}
	}

	cwd, cwd_error := os.get_working_directory(context.allocator)
	if cwd_error != nil {
		items := make([dynamic]Value)
		reserve(&items, 2)
		append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/cwd` failed: %v", cwd_error))))
		return Value(cast(^Object)new_vector_object(items))
	}
	defer delete(cwd)

	items := make([dynamic]Value)
	reserve(&items, 2)
	append(&items, Value(cast(^Object)new_string_object(cwd)), Value{})
	return Value(cast(^Object)new_vector_object(items))
}

// (set-cwd path) [true nil]|[nil err]; Change current working directory.
native_fs_set_cwd :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`fs/set-cwd` expects one argument.\nusage: (fs/set-cwd path)")
		return Value{}
	}

	path, path_ok := require_string_arg(args, 0, "fs/set-cwd", "first")
	if !path_ok { return Value{} }

	cwd_error := os.set_working_directory(path)
	if cwd_error != nil {
		items := make([dynamic]Value)
		reserve(&items, 2)
		append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/set-cwd` failed for `%s`: %v", path, cwd_error))))
		return Value(cast(^Object)new_vector_object(items))
	}

	items := make([dynamic]Value)
	reserve(&items, 2)
	append(&items, Value(bool(true)), Value{})
	return Value(cast(^Object)new_vector_object(items))
}

// (exists? path) bool; true if path exists.
native_fs_exists :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`fs/exists?` expects one argument.\nusage: (fs/exists? path)")
		return Value{}
	}

	path, path_ok := require_string_arg(args, 0, "fs/exists?", "first")
	if !path_ok { return Value{} }

	return Value(bool(os.exists(path)))
}

// (file? path) bool; true if path exists and is a file.
native_fs_file :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`fs/file?` expects one argument.\nusage: (fs/file? path)")
		return Value{}
	}

	path, path_ok := require_string_arg(args, 0, "fs/file?", "first")
	if !path_ok { return Value{} }

	return Value(bool(os.is_file(path)))
}

// (dir? path) bool; true if path exists and is a directory.
native_fs_dir :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`fs/dir?` expects one argument.\nusage: (fs/dir? path)")
		return Value{}
	}

	path, path_ok := require_string_arg(args, 0, "fs/dir?", "first")
	if !path_ok { return Value{} }

	return Value(bool(os.is_dir(path)))
}

// (list-dir path) [vector nil]|[nil err]; Direct directory entry names.
native_fs_list_dir :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`fs/list-dir` expects one argument.\nusage: (fs/list-dir path)")
		return Value{}
	}

	path, path_ok := require_string_arg(args, 0, "fs/list-dir", "first")
	if !path_ok { return Value{} }

	entries, list_error := os.read_all_directory_by_path(path, context.allocator)
	if list_error != nil {
		items := make([dynamic]Value)
		reserve(&items, 2)
		append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/list-dir` failed for `%s`: %v", path, list_error))))
		return Value(cast(^Object)new_vector_object(items))
	}
	defer os.file_info_slice_delete(entries, context.allocator)

	entry_items := make([dynamic]Value)
	reserve(&entry_items, len(entries))
	for entry in entries {
		append(&entry_items, Value(cast(^Object)new_string_object(entry.name)))
	}

	items := make([dynamic]Value)
	reserve(&items, 2)
	append(&items, Value(cast(^Object)new_vector_object(entry_items)), Value{})
	return Value(cast(^Object)new_vector_object(items))
}

// (make-dir path) [true nil]|[nil err]; Create one directory level.
native_fs_make_dir :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`fs/make-dir` expects one argument.\nusage: (fs/make-dir path)")
		return Value{}
	}

	path, path_ok := require_string_arg(args, 0, "fs/make-dir", "first")
	if !path_ok { return Value{} }

	make_error := os.make_directory(path)
	if make_error != nil {
		items := make([dynamic]Value)
		reserve(&items, 2)
		append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/make-dir` failed for `%s`: %v", path, make_error))))
		return Value(cast(^Object)new_vector_object(items))
	}

	items := make([dynamic]Value)
	reserve(&items, 2)
	append(&items, Value(bool(true)), Value{})
	return Value(cast(^Object)new_vector_object(items))
}

// (remove-file path) [true nil]|[nil err]; Remove a file.
native_fs_remove_file :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`fs/remove-file` expects one argument.\nusage: (fs/remove-file path)")
		return Value{}
	}

	path, path_ok := require_string_arg(args, 0, "fs/remove-file", "first")
	if !path_ok { return Value{} }

	if !os.is_file(path) {
		items := make([dynamic]Value)
		reserve(&items, 2)
		append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/remove-file` failed for `%s`: not a file", path))))
		return Value(cast(^Object)new_vector_object(items))
	}

	remove_error := os.remove(path)
	if remove_error != nil {
		items := make([dynamic]Value)
		reserve(&items, 2)
		append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/remove-file` failed for `%s`: %v", path, remove_error))))
		return Value(cast(^Object)new_vector_object(items))
	}

	items := make([dynamic]Value)
	reserve(&items, 2)
	append(&items, Value(bool(true)), Value{})
	return Value(cast(^Object)new_vector_object(items))
}

// (remove-dir path) [true nil]|[nil err]; Remove an empty directory.
native_fs_remove_dir :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`fs/remove-dir` expects one argument.\nusage: (fs/remove-dir path)")
		return Value{}
	}

	path, path_ok := require_string_arg(args, 0, "fs/remove-dir", "first")
	if !path_ok { return Value{} }

	if !os.is_dir(path) {
		items := make([dynamic]Value)
		reserve(&items, 2)
		append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/remove-dir` failed for `%s`: not a directory", path))))
		return Value(cast(^Object)new_vector_object(items))
	}

	remove_error := os.remove(path)
	if remove_error != nil {
		items := make([dynamic]Value)
		reserve(&items, 2)
		append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/remove-dir` failed for `%s`: %v", path, remove_error))))
		return Value(cast(^Object)new_vector_object(items))
	}

	items := make([dynamic]Value)
	reserve(&items, 2)
	append(&items, Value(bool(true)), Value{})
	return Value(cast(^Object)new_vector_object(items))
}


// IO module ======================================================================================

// (read-all) [string nil]|[nil err]; Read all remaining stdin.
native_io_read_all :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 0 {
		runtime_error("`io/read-all` expects no arguments.\nusage: (io/read-all)")
		return Value{}
	}

	data := make([dynamic]byte)
	defer delete(data)

	buffer: [4096]byte
	for {
		read_count, read_error := os.read(os.stdin, buffer[:])
		if read_count > 0 {
			append(&data, ..buffer[:read_count])
		}

		if read_error != nil {
			read_io_error, read_is_io_error := read_error.(io.Error)
			read_general_error, read_is_general_error := read_error.(os.General_Error)
			if (read_is_io_error && read_io_error == .EOF) || (read_is_general_error && read_general_error == .Broken_Pipe) {
				items := make([dynamic]Value)
				reserve(&items, 2)
				append(&items, Value(cast(^Object)new_string_object(string(data[:]))), Value{})
				return Value(cast(^Object)new_vector_object(items))
			}

			items := make([dynamic]Value)
			reserve(&items, 2)
			append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`io/read-all` failed: %v", read_error))))
			return Value(cast(^Object)new_vector_object(items))
		}
	}
}

// (read-line) [string nil]|[nil nil]|[nil err]; Read one stdin line.
native_io_read_line :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 0 {
		runtime_error("`io/read-line` expects no arguments.\nusage: (io/read-line)")
		return Value{}
	}

	line := make([dynamic]byte)
	defer delete(line)

	buffer: [1]byte
	for {
		read_count, read_error := os.read(os.stdin, buffer[:])
		if read_count > 0 {
			if buffer[0] == '\n' {
				if len(line) > 0 && line[len(line) - 1] == '\r' {
					pop(&line)
				}

				items := make([dynamic]Value)
				reserve(&items, 2)
				append(&items, Value(cast(^Object)new_string_object(string(line[:]))), Value{})
				return Value(cast(^Object)new_vector_object(items))
			}

			append(&line, buffer[0])
		}

		if read_error != nil {
			read_io_error, read_is_io_error := read_error.(io.Error)
			read_general_error, read_is_general_error := read_error.(os.General_Error)
			if (read_is_io_error && read_io_error == .EOF) || (read_is_general_error && read_general_error == .Broken_Pipe) {
				items := make([dynamic]Value)
				reserve(&items, 2)

				if len(line) == 0 {
					append(&items, Value{}, Value{})
					return Value(cast(^Object)new_vector_object(items))
				}

				if line[len(line) - 1] == '\r' {
					pop(&line)
				}

				append(&items, Value(cast(^Object)new_string_object(string(line[:]))), Value{})
				return Value(cast(^Object)new_vector_object(items))
			}

			items := make([dynamic]Value)
			reserve(&items, 2)
			append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`io/read-line` failed: %v", read_error))))
			return Value(cast(^Object)new_vector_object(items))
		}
	}
}

// (write-err text) [true nil]|[nil err]; Write exact text to stderr.
native_io_write_err :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("`io/write-err` expects one argument.\nusage: (io/write-err text)")
		return Value{}
	}

	text, text_ok := require_string_arg(args, 0, "io/write-err", "first")
	if !text_ok { return Value{} }

	_, write_error := os.write_string(os.stderr, text)
	if write_error != nil {
		items := make([dynamic]Value)
		reserve(&items, 2)
		append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`io/write-err` failed: %v", write_error))))
		return Value(cast(^Object)new_vector_object(items))
	}

	items := make([dynamic]Value)
	reserve(&items, 2)
	append(&items, Value(bool(true)), Value{})
	return Value(cast(^Object)new_vector_object(items))
}

// (print-err value...) [true nil]|[nil err]; Print display text to stderr with newline.
native_io_print_err :: proc(vm: ^VM, args: []Value) -> Value {
	for i := 0; i < len(args); i += 1 {
		if i > 0 {
			_, space_error := os.write_string(os.stderr, " ")
			if space_error != nil {
				items := make([dynamic]Value)
				reserve(&items, 2)
				append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`io/print-err` failed: %v", space_error))))
				return Value(cast(^Object)new_vector_object(items))
			}
		}

		text := value_display_text(args[i])
		_, write_error := os.write_string(os.stderr, text)
		delete(text)
		if write_error != nil {
			items := make([dynamic]Value)
			reserve(&items, 2)
			append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`io/print-err` failed: %v", write_error))))
			return Value(cast(^Object)new_vector_object(items))
		}
	}

	_, newline_error := os.write_string(os.stderr, "\n")
	if newline_error != nil {
		items := make([dynamic]Value)
		reserve(&items, 2)
		append(&items, Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`io/print-err` failed: %v", newline_error))))
		return Value(cast(^Object)new_vector_object(items))
	}

	items := make([dynamic]Value)
	reserve(&items, 2)
	append(&items, Value(bool(true)), Value{})
	return Value(cast(^Object)new_vector_object(items))
}


// Registration ==================================================================================

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
	bind_native_builtin(vm, "number?", native_number_predicate)
	bind_native_builtin(vm, "number", native_number)
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
	bind_native_builtin(vm, "str", native_str)
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


install_core_modules :: proc(vm: ^VM) {
	// str
	str_exports := make([dynamic]Binding)
	defer delete(str_exports)

	bind_native_function(vm, &str_exports, "has?", native_str_has)
	bind_native_function(vm, &str_exports, "prefix?", native_str_prefix)
	bind_native_function(vm, &str_exports, "suffix?", native_str_suffix)
	bind_native_function(vm, &str_exports, "split", native_str_split)
	bind_native_function(vm, &str_exports, "join", native_str_join)
	bind_native_function(vm, &str_exports, "find", native_str_find)
	bind_native_function(vm, &str_exports, "slice", native_str_slice)
	bind_native_function(vm, &str_exports, "replace", native_str_replace)
	bind_native_function(vm, &str_exports, "trim", native_str_trim)
	bind_native_function(vm, &str_exports, "lower", native_str_lower)
	bind_native_function(vm, &str_exports, "upper", native_str_upper)
	bind_native_function(vm, &str_exports, "byte", native_str_byte)
	bind_native_function(vm, &str_exports, "bytes", native_str_bytes)
	install_host_module(vm, "str", str_exports[:])

	// path
	path_exports := make([dynamic]Binding)
	defer delete(path_exports)

	bind_native_function(vm, &path_exports, "join", native_path_join)
	bind_native_function(vm, &path_exports, "base", native_path_base)
	bind_native_function(vm, &path_exports, "dir", native_path_dir)
	bind_native_function(vm, &path_exports, "ext", native_path_ext)
	bind_native_function(vm, &path_exports, "stem", native_path_stem)
	bind_native_function(vm, &path_exports, "clean", native_path_clean)
	bind_native_function(vm, &path_exports, "abs", native_path_abs)
	install_host_module(vm, "path", path_exports[:])

	// os
	os_exports := make([dynamic]Binding)
	defer delete(os_exports)

	bind_native_function(vm, &os_exports, "argv", native_os_argv)
	bind_native_function(vm, &os_exports, "args", native_os_args)
	bind_native_function(vm, &os_exports, "env", native_os_env)
	bind_native_function(vm, &os_exports, "set-env", native_os_set_env)
	bind_native_function(vm, &os_exports, "exit", native_os_exit)
	bind_native_function(vm, &os_exports, "name", native_os_name)
	bind_native_function(vm, &os_exports, "arch", native_os_arch)
	install_host_module(vm, "os", os_exports[:])

	// fs
	fs_exports := make([dynamic]Binding)
	defer delete(fs_exports)

	bind_native_function(vm, &fs_exports, "read-file", native_fs_read_file)
	bind_native_function(vm, &fs_exports, "write-file", native_fs_write_file)
	bind_native_function(vm, &fs_exports, "cwd", native_fs_cwd)
	bind_native_function(vm, &fs_exports, "set-cwd", native_fs_set_cwd)
	bind_native_function(vm, &fs_exports, "exists?", native_fs_exists)
	bind_native_function(vm, &fs_exports, "file?", native_fs_file)
	bind_native_function(vm, &fs_exports, "dir?", native_fs_dir)
	bind_native_function(vm, &fs_exports, "list-dir", native_fs_list_dir)
	bind_native_function(vm, &fs_exports, "make-dir", native_fs_make_dir)
	bind_native_function(vm, &fs_exports, "remove-file", native_fs_remove_file)
	bind_native_function(vm, &fs_exports, "remove-dir", native_fs_remove_dir)
	install_host_module(vm, "fs", fs_exports[:])

	// io
	io_exports := make([dynamic]Binding)
	defer delete(io_exports)

	bind_native_function(vm, &io_exports, "read-all", native_io_read_all)
	bind_native_function(vm, &io_exports, "read-line", native_io_read_line)
	bind_native_function(vm, &io_exports, "write-err", native_io_write_err)
	bind_native_function(vm, &io_exports, "print-err", native_io_print_err)
	install_host_module(vm, "io", io_exports[:])
}
