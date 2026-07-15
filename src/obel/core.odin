package obel

import "base:intrinsics"
import "core:fmt"
import "core:io"
import "core:math"
import rand "core:math/rand"
import "core:os"
import filepath "core:path/filepath"
import "core:strings"
import "core:time"

// Native module binding ==========================================================================

new_native_function_object :: proc(native: NativeProc) -> ^NativeFunctionObject {
	function := new(NativeFunctionObject)
	function.header.kind = .NATIVE_FUNCTION
	function.native = native
	return function
}

bind_module_value :: proc(vm: ^VM, bindings: ^[dynamic]Binding, name: string, value: Value) {
	symbol := intern_symbol(vm, name)

	append(bindings, Binding{
		symbol  = symbol,
		value   = value,
		mutable = false,
	})
}

bind_module_native_function :: proc(vm: ^VM, bindings: ^[dynamic]Binding, name: string, native: NativeProc) {
	function := new_native_function_object(native)
	bind_module_value(vm, bindings, name, Value(cast(^Object)function))
}

install_native_module :: proc(vm: ^VM, id: string, exports: []Binding) {
	_, found := find_module(vm, id)
	assert(!found, "duplicate native module")

	final_exports := make([]Binding, len(exports))
	copy(final_exports, exports)

	append(&vm.modules, Module{
		id      = strings.clone(id),
		loading = false,
		code    = nil,
		exports = final_exports,
	})
}


// Builtin binding ================================================================================

// Supplied native builtins are immutable but may be shadowed by user bindings.
bind_builtin :: proc(vm: ^VM, name: string, native: NativeProc) -> int {
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

op_abs :: proc(value: Value) -> Value {
	int_value, is_int := value.(i64)
	if is_int {
		if int_value == min(i64) {
			runtime_error("`abs` cannot represent absolute value of minimum int.")
			return Value{}
		}

		if int_value < 0 { return Value(-int_value) }
		return Value(int_value)
	}

	float_value, is_float := value.(f64)
	if is_float {
		return Value(math.abs(float_value))
	}

	runtime_error("`abs` expected int or float as argument.")
	return Value{}
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

value_is_number :: proc(value: Value) -> bool {
	_, is_int := value.(i64)
	_, is_float := value.(f64)
	return is_int || is_float
}

op_min_binary :: proc(lhs, rhs: Value) -> Value {
	if !value_is_number(lhs) {
		runtime_error("`min` expected int or float arguments.")
		return Value{}
	}

	if !value_is_number(rhs) {
		runtime_error("`min` expected int or float arguments.")
		return Value{}
	}

	_, lhs_is_float := lhs.(f64)
	_, rhs_is_float := rhs.(f64)
	has_float := lhs_is_float || rhs_is_float
	result := lhs

	if compare_numbers(rhs, lhs, .LESS) {
		result = rhs
	}

	if has_float {
		#partial switch value in result {
		case i64:
			return Value(f64(value))
		case f64:
			return result
		}
	}

	return result
}

op_max_binary :: proc(lhs, rhs: Value) -> Value {
	if !value_is_number(lhs) {
		runtime_error("`max` expected int or float arguments.")
		return Value{}
	}

	if !value_is_number(rhs) {
		runtime_error("`max` expected int or float arguments.")
		return Value{}
	}

	_, lhs_is_float := lhs.(f64)
	_, rhs_is_float := rhs.(f64)
	has_float := lhs_is_float || rhs_is_float
	result := lhs

	if compare_numbers(rhs, lhs, .GREATER) {
		result = rhs
	}

	if has_float {
		#partial switch value in result {
		case i64:
			return Value(f64(value))
		case f64:
			return result
		}
	}

	return result
}

op_min :: proc(args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("`min` expects two or more arguments.\nusage: (min number number...)")
		return Value{}
	}

	if len(args) == 2 {
		return op_min_binary(args[0], args[1])
	}

	if !value_is_number(args[0]) {
		runtime_error("`min` expected int or float arguments.")
		return Value{}
	}

	_, first_is_float := args[0].(f64)
	has_float := first_is_float
	result := args[0]

	for i := 1; i < len(args); i += 1 {
		if !value_is_number(args[i]) {
			runtime_error("`min` expected int or float arguments.")
			return Value{}
		}

		_, is_float := args[i].(f64)
		if is_float { has_float = true }
		if compare_numbers(args[i], result, .LESS) {
			result = args[i]
		}
	}

	if has_float {
		#partial switch value in result {
		case i64:
			return Value(f64(value))
		case f64:
			return result
		}
	}

	return result
}

op_max :: proc(args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("`max` expects two or more arguments.\nusage: (max number number...)")
		return Value{}
	}

	if len(args) == 2 {
		return op_max_binary(args[0], args[1])
	}

	if !value_is_number(args[0]) {
		runtime_error("`max` expected int or float arguments.")
		return Value{}
	}

	_, first_is_float := args[0].(f64)
	has_float := first_is_float
	result := args[0]

	for i := 1; i < len(args); i += 1 {
		if !value_is_number(args[i]) {
			runtime_error("`max` expected int or float arguments.")
			return Value{}
		}

		_, is_float := args[i].(f64)
		if is_float { has_float = true }
		if compare_numbers(args[i], result, .GREATER) {
			result = args[i]
		}
	}

	if has_float {
		#partial switch value in result {
		case i64:
			return Value(f64(value))
		case f64:
			return result
		}
	}

	return result
}

op_clamp :: proc(x, lo, hi: Value) -> Value {
	if !value_is_number(x) {
		runtime_error("`clamp` expected int or float arguments.")
		return Value{}
	}

	if !value_is_number(lo) {
		runtime_error("`clamp` expected int or float arguments.")
		return Value{}
	}

	if !value_is_number(hi) {
		runtime_error("`clamp` expected int or float arguments.")
		return Value{}
	}

	if !compare_numbers(lo, hi, .LESS_EQUAL) {
		runtime_error("`clamp` lower bound cannot be greater than upper bound.")
		return Value{}
	}

	_, x_is_float := x.(f64)
	_, lo_is_float := lo.(f64)
	_, hi_is_float := hi.(f64)
	has_float := x_is_float || lo_is_float || hi_is_float
	result := x

	if compare_numbers(x, lo, .LESS) {
		result = lo
	} else if compare_numbers(x, hi, .GREATER) {
		result = hi
	}

	if has_float {
		#partial switch value in result {
		case i64:
			return Value(f64(value))
		case f64:
			return result
		}
	}

	return result
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

check_arg_count :: proc(args: []Value, expected: int, message: string) -> bool {
	if len(args) != expected {
		runtime_error(message)
		return false
	}

	return true
}

check_min_arg_count :: proc(args: []Value, minimum: int, message: string) -> bool {
	if len(args) < minimum {
		runtime_error(message)
		return false
	}

	return true
}

check_arg_count_range :: proc(args: []Value, minimum, maximum: int, message: string) -> bool {
	if len(args) < minimum || len(args) > maximum {
		runtime_error(message)
		return false
	}

	return true
}

check_string_arg :: proc(args: []Value, index: int, proc_name, arg_name: string) -> (string, bool) {
	object, is_object := args[index].(^Object)
	if !is_object || object.kind != .STRING {
		runtime_error(fmt.tprintf("`%s` expected string as %s argument.", proc_name, arg_name))
		return "", false
	}

	return (cast(^StringObject)object).text, true
}

check_int_arg :: proc(args: []Value, index: int, proc_name, arg_name: string) -> (i64, bool) {
	value, is_int := args[index].(i64)
	if !is_int {
		runtime_error(fmt.tprintf("`%s` expected int as %s argument.", proc_name, arg_name))
		return 0, false
	}

	return value, true
}

check_number_arg :: proc(args: []Value, index: int, proc_name, arg_name: string) -> (f64, bool) {
	int_value, is_int := args[index].(i64)
	if is_int {
		return f64(int_value), true
	}

	float_value, is_float := args[index].(f64)
	if is_float {
		return float_value, true
	}

	runtime_error(fmt.tprintf("`%s` expected number as %s argument.", proc_name, arg_name))
	return 0, false
}

check_vector_arg :: proc(args: []Value, index: int, proc_name, arg_name: string) -> (^VectorObject, bool) {
	object, is_object := args[index].(^Object)
	if !is_object || object.kind != .VECTOR {
		runtime_error(fmt.tprintf("`%s` expected vector as %s argument.", proc_name, arg_name))
		return nil, false
	}

	return cast(^VectorObject)object, true
}

check_map_arg :: proc(args: []Value, index: int, proc_name, arg_name: string) -> (^MapObject, bool) {
	object, is_object := args[index].(^Object)
	if !is_object || object.kind != .MAP {
		runtime_error(fmt.tprintf("`%s` expected map as %s argument.", proc_name, arg_name))
		return nil, false
	}

	return cast(^MapObject)object, true
}

check_function_arg :: proc(args: []Value, index: int, proc_name, arg_name: string) -> (Value, bool) {
	if !value_is_function(args[index]) {
		runtime_error(fmt.tprintf("`%s` expected function as %s argument.", proc_name, arg_name))
		return Value{}, false
	}

	return args[index], true
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
	if !check_arg_count(args, 2, "`%` expects two arguments.\nusage: (% number number)") { return Value{} }
	return op_mod(args[0], args[1])
}

// (abs number) number; Absolute value.
native_abs :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`abs` expects one argument.\nusage: (abs number)") { return Value{} }
	return op_abs(args[0])
}

// (min number number...) number; Smallest numeric argument.
native_min :: proc(vm: ^VM, args: []Value) -> Value {
	return op_min(args)
}

// (max number number...) number; Largest numeric argument.
native_max :: proc(vm: ^VM, args: []Value) -> Value {
	return op_max(args)
}

// (clamp number number number) number; Constrain a number between inclusive bounds.
native_clamp :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 3, "`clamp` expects three arguments.\nusage: (clamp number number number)") { return Value{} }
	return op_clamp(args[0], args[1], args[2])
}

// (= left right) bool; true if values are equal by Obel equality.
native_equal :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`=` expects two arguments.\nusage: (= value value)") { return Value{} }
	return op_equal(args[0], args[1])
}

// (!= left right) bool; true if values are not equal by Obel equality.
native_not_equal :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`!=` expects two arguments.\nusage: (!= value value)") { return Value{} }
	return Value(bool(!values_equal(args[0], args[1])))
}

// (< left right) bool; Numeric less-than.
native_less :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`<` expects two arguments.\nusage: (< number number)") { return Value{} }
	return Value(bool(compare_numbers(args[0], args[1], .LESS)))
}

// (<= left right) bool; Numeric less-than-or-equal.
native_less_equal :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`<=` expects two arguments.\nusage: (<= number number)") { return Value{} }
	return Value(bool(compare_numbers(args[0], args[1], .LESS_EQUAL)))
}

// (> left right) bool; Numeric greater-than.
native_greater :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`>` expects two arguments.\nusage: (> number number)") { return Value{} }
	return Value(bool(compare_numbers(args[0], args[1], .GREATER)))
}

// (>= left right) bool; Numeric greater-than-or-equal.
native_greater_equal :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`>=` expects two arguments.\nusage: (>= number number)") { return Value{} }
	return Value(bool(compare_numbers(args[0], args[1], .GREATER_EQUAL)))
}

// (not value) bool; true if value is falsey.
native_not :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`not` expects one argument.\nusage: (not value)") { return Value{} }
	return op_not(args[0])
}

// (nil? value) bool; true if value is nil.
native_nil_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`nil?` expects one argument.\nusage: (nil? value)") { return Value{} }
	return Value(bool(args[0] == nil))
}

// (bool? value) bool; true if value is bool.
native_bool_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`bool?` expects one argument.\nusage: (bool? value)") { return Value{} }
	_, is_bool := args[0].(bool)
	return Value(bool(is_bool))
}

// (number? value) bool; true if value is int or float.
native_number_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`number?` expects one argument.\nusage: (number? value)") { return Value{} }
	return Value(bool(value_is_number(args[0])))
}

// (number value) number|nil; Parse or pass through an Obel number.
native_number :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`number` expects one argument.\nusage: (number value)") { return Value{} }

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
			number, parse_error := parse_number_text(text)
			if parse_error == "" { return number }
		}
	}

	return Value{}
}

// (int? value) bool; true if value is int.
native_int_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`int?` expects one argument.\nusage: (int? value)") { return Value{} }
	_, is_int := args[0].(i64)
	return Value(bool(is_int))
}

// (float? value) bool; true if value is float.
native_float_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`float?` expects one argument.\nusage: (float? value)") { return Value{} }
	_, is_float := args[0].(f64)
	return Value(bool(is_float))
}

// (str? value) bool; true if value is string.
native_string_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`str?` expects one argument.\nusage: (str? value)") { return Value{} }
	object, is_object := args[0].(^Object)
	return Value(bool(is_object && object.kind == .STRING))
}

// (vec? value) bool; true if value is vector.
native_vector_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`vec?` expects one argument.\nusage: (vec? value)") { return Value{} }
	object, is_object := args[0].(^Object)
	return Value(bool(is_object && object.kind == .VECTOR))
}

// (map? value) bool; true if value is map.
native_map_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`map?` expects one argument.\nusage: (map? value)") { return Value{} }
	object, is_object := args[0].(^Object)
	return Value(bool(is_object && object.kind == .MAP))
}

// (fn? value) bool; true if value is a native or Obel function.
native_function_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`fn?` expects one argument.\nusage: (fn? value)") { return Value{} }
	return Value(bool(value_is_function(args[0])))
}

// (empty? value) bool; true if a string, vector, or map has no contents.
native_empty_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`empty?` expects one argument.\nusage: (empty? value)") { return Value{} }

	object, is_object := args[0].(^Object)
	if !is_object {
		runtime_error("`empty?` expected string, vector, or map as argument.")
		return Value{}
	}

	switch object.kind {
	case .STRING:
		return Value(bool(len((cast(^StringObject)object).text) == 0))
	case .VECTOR:
		return Value(bool(len((cast(^VectorObject)object).items) == 0))
	case .MAP:
		return Value(bool((cast(^MapObject)object).count == 0))
	case .SYMBOL, .LIST, .NATIVE_FUNCTION, .FUNCTION:
		runtime_error("`empty?` expected string, vector, or map as argument.")
		return Value{}
	}

	return Value{}
}

// (len value) int; Length of a string, vector, or map.
native_len :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`len` expects one argument.\nusage: (len value)") { return Value{} }
	return op_len(args[0])
}

// (copy value) value; Shallow copy of a vector or map.
native_copy :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`copy` expects one argument.\nusage: (copy value)") { return Value{} }

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
	if !check_arg_count(args, 1, "`clear` expects one argument.\nusage: (clear value)") { return Value{} }

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
	if !check_arg_count(args, 1, "`type` expects one argument.\nusage: (type value)") { return Value{} }

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
	if !check_arg_count_range(args, 1, 2, "`assert` expects condition and optional message.\nusage: (assert condition message?)") { return Value{} }

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
	if !check_arg_count(args, 1, "`error` expects one argument.\nusage: (error message)") { return Value{} }

	message := value_display_text(args[0])
	runtime_error(message)
	delete(message)
	return Value{}
}

// (push vector value...) vector; Append values to vector in place.
native_push :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_min_arg_count(args, 2, "`push` expects vector and one or more values.\nusage: (push vector value value...)") { return Value{} }

	vector_value := args[0]
	for i := 1; i < len(args); i += 1 {
		op_push(vector_value, args[i])
		if vm.error_string != "" { return Value{} }
	}

	return vector_value
}

// (pop vector) value; Remove and return the last vector item.
native_pop :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`pop` expects one argument.\nusage: (pop vector)") { return Value{} }

	return op_pop(args[0])
}

// (insert vector index value) vector; Insert value into vector at index.
native_insert :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 3, "`insert` expects vector, index, and value.\nusage: (insert vector index value)") { return Value{} }

	vector, vector_ok := check_vector_arg(args, 0, "insert", "first")
	if !vector_ok { return Value{} }
	index, index_ok := check_int_arg(args, 1, "insert", "second")
	if !index_ok { return Value{} }

	if index < 0 || index > i64(len(vector.items)) {
		runtime_error("`insert` index out of range.")
		return Value{}
	}

	inject_at(&vector.items, int(index), args[2])
	return args[0]
}

// (remove vector index) value; Remove and return vector item at index.
native_remove :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`remove` expects vector and index.\nusage: (remove vector index)") { return Value{} }

	vector, vector_ok := check_vector_arg(args, 0, "remove", "first")
	if !vector_ok { return Value{} }
	index, index_ok := check_int_arg(args, 1, "remove", "second")
	if !index_ok { return Value{} }

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
	if !check_arg_count(args, 3, "`slice` expects vector, start, and count.\nusage: (slice vector start count)") { return Value{} }

	vector, vector_ok := check_vector_arg(args, 0, "slice", "first")
	if !vector_ok { return Value{} }
	start, start_ok := check_int_arg(args, 1, "slice", "second")
	if !start_ok { return Value{} }
	count, count_ok := check_int_arg(args, 2, "slice", "third")
	if !count_ok { return Value{} }

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
	if !check_arg_count(args, 1, "`keys` expects one argument.\nusage: (keys map)") { return Value{} }

	map_object, map_ok := check_map_arg(args, 0, "keys", "first")
	if !map_ok { return Value{} }
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
	if !check_arg_count(args, 1, "`vals` expects one argument.\nusage: (vals map)") { return Value{} }

	map_object, map_ok := check_map_arg(args, 0, "vals", "first")
	if !map_ok { return Value{} }
	items := make([dynamic]Value)
	reserve(&items, map_object.count)

	for entry in map_object.entries {
		if entry.key != nil {
			append(&items, entry.value)
		}
	}

	return Value(cast(^Object)new_vector_object(items))
}

map_pairs_snapshot :: proc(map_object: ^MapObject) -> ^VectorObject {
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

	return new_vector_object(items)
}

// (pairs map) vector; Map key/value pairs as two-item vectors, in unspecified order.
native_pairs :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`pairs` expects one argument.\nusage: (pairs map)") { return Value{} }

	map_object, map_ok := check_map_arg(args, 0, "pairs", "first")
	if !map_ok { return Value{} }
	return Value(cast(^Object)map_pairs_snapshot(map_object))
}

// (merge map map...) map; Fresh map with later maps overriding earlier maps.
native_merge :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_min_arg_count(args, 2, "`merge` expects two or more maps.\nusage: (merge map map...)") { return Value{} }

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

// Higher-order collection builtins ---------------------------------------------------------------

// Vector input returns the original vector; map input returns a fresh pairs snapshot.
collection_callback_items :: proc(collection: Value, proc_name: string) -> ^VectorObject {
	object, is_object := collection.(^Object)
	if !is_object {
		runtime_error(fmt.tprintf("`%s` expected vector or map as collection.", proc_name))
		return nil
	}

	switch object.kind {
	case .VECTOR:
		return cast(^VectorObject)object

	case .MAP:
		return map_pairs_snapshot(cast(^MapObject)object)

	case .STRING, .SYMBOL, .LIST, .NATIVE_FUNCTION, .FUNCTION:
		runtime_error(fmt.tprintf("`%s` expected vector or map as collection.", proc_name))
		return nil
	}

	assert(false, "invalid collection object kind")
	return nil
}

// (map f coll) vector; Transform each collection item.
native_map :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`map` expects two arguments.\nusage: (map f coll)") { return Value{} }
	function, function_ok := check_function_arg(args, 0, "map", "first")
	if !function_ok { return Value{} }

	item_vector := collection_callback_items(args[1], "map")
	if item_vector == nil { return Value{} }
	initial_length := len(item_vector.items)

	results := make([dynamic]Value)
	reserve(&results, initial_length)

	call_args: [1]Value
	for i := 0; i < initial_length; i += 1 {
		if i >= len(item_vector.items) {
			runtime_error("vector index out of range.")
			return Value{}
		}

		call_args[0] = item_vector.items[i]
		result := call_function_from_native(vm, function, call_args[:])
		if vm.error_string != "" { return Value{} }

		append(&results, result)
	}

	return Value(cast(^Object)new_vector_object(results))
}

// (filter pred coll) vector; Keep original items where pred returns truthy.
native_filter :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`filter` expects two arguments.\nusage: (filter pred coll)") { return Value{} }
	predicate, predicate_ok := check_function_arg(args, 0, "filter", "first")
	if !predicate_ok { return Value{} }

	item_vector := collection_callback_items(args[1], "filter")
	if item_vector == nil { return Value{} }
	initial_length := len(item_vector.items)

	results := make([dynamic]Value)

	call_args: [1]Value
	for i := 0; i < initial_length; i += 1 {
		if i >= len(item_vector.items) {
			runtime_error("vector index out of range.")
			return Value{}
		}

		item := item_vector.items[i]
		call_args[0] = item
		keep := call_function_from_native(vm, predicate, call_args[:])
		if vm.error_string != "" { return Value{} }

		if !value_is_falsey(keep) {
			append(&results, item)
		}
	}

	return Value(cast(^Object)new_vector_object(results))
}

// (reduce f start coll) value; Fold collection items through f.
native_reduce :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 3, "`reduce` expects three arguments.\nusage: (reduce f start coll)") { return Value{} }
	function, function_ok := check_function_arg(args, 0, "reduce", "first")
	if !function_ok { return Value{} }

	item_vector := collection_callback_items(args[2], "reduce")
	if item_vector == nil { return Value{} }
	initial_length := len(item_vector.items)

	result := args[1]

	call_args: [2]Value
	for i := 0; i < initial_length; i += 1 {
		if i >= len(item_vector.items) {
			runtime_error("vector index out of range.")
			return Value{}
		}

		call_args[0] = result
		call_args[1] = item_vector.items[i]
		result = call_function_from_native(vm, function, call_args[:])
		if vm.error_string != "" { return Value{} }
	}

	return result
}

// (find pred coll) value|nil; First original item where pred returns truthy.
native_find :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`find` expects two arguments.\nusage: (find pred coll)") { return Value{} }
	predicate, predicate_ok := check_function_arg(args, 0, "find", "first")
	if !predicate_ok { return Value{} }

	item_vector := collection_callback_items(args[1], "find")
	if item_vector == nil { return Value{} }
	initial_length := len(item_vector.items)

	call_args: [1]Value
	for i := 0; i < initial_length; i += 1 {
		if i >= len(item_vector.items) {
			runtime_error("vector index out of range.")
			return Value{}
		}

		item := item_vector.items[i]
		call_args[0] = item
		found := call_function_from_native(vm, predicate, call_args[:])
		if vm.error_string != "" { return Value{} }

		if !value_is_falsey(found) {
			return item
		}
	}

	return Value{}
}

// (pick f coll) value|nil; First truthy value produced by f.
native_pick :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`pick` expects two arguments.\nusage: (pick f coll)") { return Value{} }
	function, function_ok := check_function_arg(args, 0, "pick", "first")
	if !function_ok { return Value{} }

	item_vector := collection_callback_items(args[1], "pick")
	if item_vector == nil { return Value{} }
	initial_length := len(item_vector.items)

	call_args: [1]Value
	for i := 0; i < initial_length; i += 1 {
		if i >= len(item_vector.items) {
			runtime_error("vector index out of range.")
			return Value{}
		}

		call_args[0] = item_vector.items[i]
		result := call_function_from_native(vm, function, call_args[:])
		if vm.error_string != "" { return Value{} }

		if !value_is_falsey(result) {
			return result
		}
	}

	return Value{}
}

// Sorting builtins -------------------------------------------------------------------------------

stable_sort_order :: proc(vm: ^VM, values: []Value, comparator: Value) -> [dynamic]int {
	count := len(values)

	// order holds indexes into values; merge passes move indexes, not values.
	order := make([dynamic]int, count)
	for i := 0; i < count; i += 1 {
		order[i] = i
	}

	if count < 2 {
		return order
	}

	default_values_are_numbers := comparator == nil && value_is_number(values[0])

	scratch := make([dynamic]int, count)
	defer delete(scratch)

	source := order[:]
	destination := scratch[:]
	source_is_order := true

	for width := 1; width < count; width *= 2 {
		for left := 0; left < count; left += width * 2 {
			mid := left + width
			if mid > count { mid = count }

			right_end := left + width * 2
			if right_end > count { right_end = count }

			i := left
			j := mid

			for out := left; out < right_end; out += 1 {
				if i >= mid {
					destination[out] = source[j]
					j += 1
					continue
				}

				if j >= right_end {
					destination[out] = source[i]
					i += 1
					continue
				}

				left_index := source[i]
				right_index := source[j]
				right_before_left := false

				if comparator != nil {
					call_args: [2]Value
					call_args[0] = values[right_index]
					call_args[1] = values[left_index]

					result := call_function_from_native(vm, comparator, call_args[:])
					if vm.error_string != "" { return order }

					right_before_left = !value_is_falsey(result)
				} else if default_values_are_numbers {
					right_before_left = compare_numbers(values[right_index], values[left_index], .LESS)
				} else {
					right_object := values[right_index].(^Object)
					left_object := values[left_index].(^Object)
					right_string := cast(^StringObject)right_object
					left_string := cast(^StringObject)left_object

					right_before_left = strings.compare(right_string.text, left_string.text) < 0
				}

				if right_before_left {
					destination[out] = right_index
					j += 1
				} else {
					destination[out] = left_index
					i += 1
				}
			}
		}

		temp := source
		source = destination
		destination = temp
		source_is_order = !source_is_order
	}

	if !source_is_order {
		copy(order[:], source)
	}

	return order
}

// (sort vector) vector; Stable sort with default number/string ordering.
// (sort comp-fn vector) vector; Stable sort with a comparator.
native_sort :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count_range(args, 1, 2, "`sort` expects one or two arguments.\nusage: (sort vector)\n       (sort comp-fn vector)") { return Value{} }

	comparator := Value{}
	vector_value := args[0]

	if len(args) == 2 {
		parsed_comparator, comparator_ok := check_function_arg(args, 0, "sort", "first")
		if !comparator_ok { return Value{} }
		comparator = parsed_comparator
		vector_value = args[1]
	}

	object, is_object := vector_value.(^Object)
	if !is_object || object.kind != .VECTOR {
		runtime_error("`sort` expected vector as final argument.")
		return Value{}
	}

	vector := cast(^VectorObject)object
	items := make([dynamic]Value, len(vector.items))
	copy(items[:], vector.items[:])
	defer delete(items)

	if comparator == nil && len(items) > 0 {
		first_is_number := value_is_number(items[0])
		first_object, first_is_object := items[0].(^Object)
		first_is_string := first_is_object && first_object.kind == .STRING

		if !first_is_number && !first_is_string {
			runtime_error("`sort` default ordering expected numbers or strings.")
			return Value{}
		}

		for i := 1; i < len(items); i += 1 {
			if first_is_number {
				if !value_is_number(items[i]) {
					runtime_error("`sort` default ordering expected all numbers or all strings.")
					return Value{}
				}
			} else {
				item_object, item_is_object := items[i].(^Object)
				if !item_is_object || item_object.kind != .STRING {
					runtime_error("`sort` default ordering expected all numbers or all strings.")
					return Value{}
				}
			}
		}
	}

	order := stable_sort_order(vm, items[:], comparator)
	defer delete(order)
	if vm.error_string != "" { return Value{} }

	results := make([dynamic]Value, len(items))
	for i := 0; i < len(order); i += 1 {
		results[i] = items[order[i]]
	}

	return Value(cast(^Object)new_vector_object(results))
}

// (sort-by key-fn vector) vector; Stable sort by generated keys.
// (sort-by key-fn comp-fn vector) vector; Stable sort by generated keys with a comparator.
native_sort_by :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count_range(args, 2, 3, "`sort-by` expects two or three arguments.\nusage: (sort-by key-fn vector)\n       (sort-by key-fn comp-fn vector)") { return Value{} }
	key_function, key_function_ok := check_function_arg(args, 0, "sort-by", "first")
	if !key_function_ok { return Value{} }

	comparator := Value{}
	vector_value := args[1]

	if len(args) == 3 {
		parsed_comparator, comparator_ok := check_function_arg(args, 1, "sort-by", "second")
		if !comparator_ok { return Value{} }
		comparator = parsed_comparator
		vector_value = args[2]
	}

	object, is_object := vector_value.(^Object)
	if !is_object || object.kind != .VECTOR {
		runtime_error("`sort-by` expected vector as final argument.")
		return Value{}
	}

	vector := cast(^VectorObject)object
	items := make([dynamic]Value, len(vector.items))
	copy(items[:], vector.items[:])
	defer delete(items)

	keys := make([dynamic]Value, len(items))
	defer delete(keys)

	call_args: [1]Value
	for i := 0; i < len(items); i += 1 {
		call_args[0] = items[i]
		keys[i] = call_function_from_native(vm, key_function, call_args[:])
		if vm.error_string != "" { return Value{} }
	}

	if comparator == nil && len(keys) > 0 {
		first_is_number := value_is_number(keys[0])
		first_object, first_is_object := keys[0].(^Object)
		first_is_string := first_is_object && first_object.kind == .STRING

		if !first_is_number && !first_is_string {
			runtime_error("`sort-by` default ordering expected number or string keys.")
			return Value{}
		}

		for i := 1; i < len(keys); i += 1 {
			if first_is_number {
				if !value_is_number(keys[i]) {
					runtime_error("`sort-by` default ordering expected all number keys or all string keys.")
					return Value{}
				}
			} else {
				key_object, key_is_object := keys[i].(^Object)
				if !key_is_object || key_object.kind != .STRING {
					runtime_error("`sort-by` default ordering expected all number keys or all string keys.")
					return Value{}
				}
			}
		}
	}

	order := stable_sort_order(vm, keys[:], comparator)
	defer delete(order)
	if vm.error_string != "" { return Value{} }

	results := make([dynamic]Value, len(items))
	for i := 0; i < len(order); i += 1 {
		results[i] = items[order[i]]
	}

	return Value(cast(^Object)new_vector_object(results))
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


// Math module ====================================================================================

value_from_integral_float :: proc(value: f64) -> Value {
	// The valid i64 conversion range is [-2^63, 2^63).
	// f64(max(i64)) rounds up to 2^63, so the upper bound is exclusive.
	if value >= -9223372036854775808.0 && value < 9223372036854775808.0 {
		return Value(i64(value))
	}

	return Value(value)
}

// (floor number) number; Round down, returning int when the result fits.
native_math_floor :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/floor` expects one argument.\nusage: (math/floor number)") { return Value{} }

	int_value, is_int := args[0].(i64)
	if is_int { return Value(int_value) }

	value, value_ok := check_number_arg(args, 0, "math/floor", "first")
	if !value_ok { return Value{} }

	return value_from_integral_float(math.floor(value))
}

// (ceil number) number; Round up, returning int when the result fits.
native_math_ceil :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/ceil` expects one argument.\nusage: (math/ceil number)") { return Value{} }

	int_value, is_int := args[0].(i64)
	if is_int { return Value(int_value) }

	value, value_ok := check_number_arg(args, 0, "math/ceil", "first")
	if !value_ok { return Value{} }

	return value_from_integral_float(math.ceil(value))
}

// (round number) number; Round to nearest, halves away from zero.
native_math_round :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/round` expects one argument.\nusage: (math/round number)") { return Value{} }

	int_value, is_int := args[0].(i64)
	if is_int { return Value(int_value) }

	value, value_ok := check_number_arg(args, 0, "math/round", "first")
	if !value_ok { return Value{} }

	return value_from_integral_float(math.round(value))
}

// (trunc number) number; Round toward zero, returning int when the result fits.
native_math_trunc :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/trunc` expects one argument.\nusage: (math/trunc number)") { return Value{} }

	int_value, is_int := args[0].(i64)
	if is_int { return Value(int_value) }

	value, value_ok := check_number_arg(args, 0, "math/trunc", "first")
	if !value_ok { return Value{} }

	return value_from_integral_float(math.trunc(value))
}

// (sqrt number) float; Square root.
native_math_sqrt :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/sqrt` expects one argument.\nusage: (math/sqrt number)") { return Value{} }

	value, value_ok := check_number_arg(args, 0, "math/sqrt", "first")
	if !value_ok { return Value{} }

	return Value(math.sqrt(value))
}

// (pow number number) float; Raise base to exponent.
native_math_pow :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`math/pow` expects two arguments.\nusage: (math/pow base exponent)") { return Value{} }

	base, base_ok := check_number_arg(args, 0, "math/pow", "first")
	if !base_ok { return Value{} }
	exponent, exponent_ok := check_number_arg(args, 1, "math/pow", "second")
	if !exponent_ok { return Value{} }

	return Value(math.pow(base, exponent))
}

// (exp number) float; e raised to x.
native_math_exp :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/exp` expects one argument.\nusage: (math/exp number)") { return Value{} }

	value, value_ok := check_number_arg(args, 0, "math/exp", "first")
	if !value_ok { return Value{} }

	return Value(math.exp(value))
}

// (log number) float; Natural logarithm.
native_math_log :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/log` expects one argument.\nusage: (math/log number)") { return Value{} }

	value, value_ok := check_number_arg(args, 0, "math/log", "first")
	if !value_ok { return Value{} }

	return Value(math.ln(value))
}

// (sin radians) float; Sine.
native_math_sin :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/sin` expects one argument.\nusage: (math/sin radians)") { return Value{} }

	value, value_ok := check_number_arg(args, 0, "math/sin", "first")
	if !value_ok { return Value{} }

	return Value(math.sin(value))
}

// (cos radians) float; Cosine.
native_math_cos :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/cos` expects one argument.\nusage: (math/cos radians)") { return Value{} }

	value, value_ok := check_number_arg(args, 0, "math/cos", "first")
	if !value_ok { return Value{} }

	return Value(math.cos(value))
}

// (tan radians) float; Tangent.
native_math_tan :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/tan` expects one argument.\nusage: (math/tan radians)") { return Value{} }

	value, value_ok := check_number_arg(args, 0, "math/tan", "first")
	if !value_ok { return Value{} }

	return Value(math.tan(value))
}

// (asin number) float; Arc sine.
native_math_asin :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/asin` expects one argument.\nusage: (math/asin number)") { return Value{} }

	value, value_ok := check_number_arg(args, 0, "math/asin", "first")
	if !value_ok { return Value{} }

	return Value(math.asin(value))
}

// (acos number) float; Arc cosine.
native_math_acos :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/acos` expects one argument.\nusage: (math/acos number)") { return Value{} }

	value, value_ok := check_number_arg(args, 0, "math/acos", "first")
	if !value_ok { return Value{} }

	return Value(math.acos(value))
}

// (atan number) float; Arc tangent.
native_math_atan :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/atan` expects one argument.\nusage: (math/atan number)") { return Value{} }

	value, value_ok := check_number_arg(args, 0, "math/atan", "first")
	if !value_ok { return Value{} }

	return Value(math.atan(value))
}

// (atan2 y x) float; Angle of a direction.
native_math_atan2 :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`math/atan2` expects two arguments.\nusage: (math/atan2 y x)") { return Value{} }

	y, y_ok := check_number_arg(args, 0, "math/atan2", "first")
	if !y_ok { return Value{} }
	x, x_ok := check_number_arg(args, 1, "math/atan2", "second")
	if !x_ok { return Value{} }

	return Value(math.atan2(y, x))
}

// (radians degrees) float; Convert degrees to radians.
native_math_radians :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/radians` expects one argument.\nusage: (math/radians degrees)") { return Value{} }

	value, value_ok := check_number_arg(args, 0, "math/radians", "first")
	if !value_ok { return Value{} }

	return Value(math.to_radians(value))
}

// (degrees radians) float; Convert radians to degrees.
native_math_degrees :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/degrees` expects one argument.\nusage: (math/degrees radians)") { return Value{} }

	value, value_ok := check_number_arg(args, 0, "math/degrees", "first")
	if !value_ok { return Value{} }

	return Value(math.to_degrees(value))
}

// (finite? number) bool; True for ints and finite floats.
native_math_finite_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/finite?` expects one argument.\nusage: (math/finite? number)") { return Value{} }

	value, value_ok := check_number_arg(args, 0, "math/finite?", "first")
	if !value_ok { return Value{} }

	return Value(bool(!math.is_nan(value) && !math.is_inf(value)))
}

// (nan? number) bool; True only for NaN floats.
native_math_nan_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/nan?` expects one argument.\nusage: (math/nan? number)") { return Value{} }

	value, value_ok := check_number_arg(args, 0, "math/nan?", "first")
	if !value_ok { return Value{} }

	return Value(bool(math.is_nan(value)))
}

// (inf? number) bool; True only for positive or negative infinity.
native_math_inf_predicate :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/inf?` expects one argument.\nusage: (math/inf? number)") { return Value{} }

	value, value_ok := check_number_arg(args, 0, "math/inf?", "first")
	if !value_ok { return Value{} }

	return Value(bool(math.is_inf(value)))
}

// (sign number) int; -1, 0, or 1 by numeric sign.
native_math_sign :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/sign` expects one argument.\nusage: (math/sign number)") { return Value{} }

	value, value_ok := check_number_arg(args, 0, "math/sign", "first")
	if !value_ok { return Value{} }
	if math.is_nan(value) {
		runtime_error("`math/sign` cannot classify NaN.")
		return Value{}
	}
	if value < 0 { return Value(i64(-1)) }
	if value > 0 { return Value(i64(1)) }
	return Value(i64(0))
}

// (fract number) float; Fractional part as x - floor(x).
native_math_fract :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`math/fract` expects one argument.\nusage: (math/fract number)") { return Value{} }

	_, is_int := args[0].(i64)
	if is_int { return Value(f64(0)) }

	value, value_ok := check_number_arg(args, 0, "math/fract", "first")
	if !value_ok { return Value{} }

	return Value(value - math.floor(value))
}

// (hypot x y) float; Length of the x/y vector.
native_math_hypot :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`math/hypot` expects two arguments.\nusage: (math/hypot x y)") { return Value{} }

	x, x_ok := check_number_arg(args, 0, "math/hypot", "first")
	if !x_ok { return Value{} }
	y, y_ok := check_number_arg(args, 1, "math/hypot", "second")
	if !y_ok { return Value{} }

	return Value(math.hypot(x, y))
}

// (lerp a b t) float; Linear interpolation.
native_math_lerp :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 3, "`math/lerp` expects three arguments.\nusage: (math/lerp a b t)") { return Value{} }

	a, a_ok := check_number_arg(args, 0, "math/lerp", "first")
	if !a_ok { return Value{} }
	b, b_ok := check_number_arg(args, 1, "math/lerp", "second")
	if !b_ok { return Value{} }
	t, t_ok := check_number_arg(args, 2, "math/lerp", "third")
	if !t_ok { return Value{} }

	return Value(math.lerp(a, b, t))
}

// (inverse-lerp a b x) float; Position of x between a and b.
native_math_inverse_lerp :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 3, "`math/inverse-lerp` expects three arguments.\nusage: (math/inverse-lerp a b x)") { return Value{} }

	a, a_ok := check_number_arg(args, 0, "math/inverse-lerp", "first")
	if !a_ok { return Value{} }
	b, b_ok := check_number_arg(args, 1, "math/inverse-lerp", "second")
	if !b_ok { return Value{} }
	x, x_ok := check_number_arg(args, 2, "math/inverse-lerp", "third")
	if !x_ok { return Value{} }

	if a == b {
		runtime_error("`math/inverse-lerp` range cannot be zero.")
		return Value{}
	}

	return Value(math.unlerp(a, b, x))
}

// (remap x in-min in-max out-min out-max) float; Map x from one range to another.
native_math_remap :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 5, "`math/remap` expects five arguments.\nusage: (math/remap x in-min in-max out-min out-max)") { return Value{} }

	x, x_ok := check_number_arg(args, 0, "math/remap", "first")
	if !x_ok { return Value{} }
	in_min, in_min_ok := check_number_arg(args, 1, "math/remap", "second")
	if !in_min_ok { return Value{} }
	in_max, in_max_ok := check_number_arg(args, 2, "math/remap", "third")
	if !in_max_ok { return Value{} }
	out_min, out_min_ok := check_number_arg(args, 3, "math/remap", "fourth")
	if !out_min_ok { return Value{} }
	out_max, out_max_ok := check_number_arg(args, 4, "math/remap", "fifth")
	if !out_max_ok { return Value{} }

	if in_min == in_max {
		runtime_error("`math/remap` input range cannot be zero.")
		return Value{}
	}

	return Value(math.remap(x, in_min, in_max, out_min, out_max))
}

// (wrap x min max) number; Wrap x into the half-open range [min, max).
native_math_wrap :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 3, "`math/wrap` expects three arguments.\nusage: (math/wrap x min max)") { return Value{} }

	x_int, x_is_int := args[0].(i64)
	min_int, min_is_int := args[1].(i64)
	max_int, max_is_int := args[2].(i64)
	if x_is_int && min_is_int && max_is_int {
		if min_int >= max_int {
			runtime_error("`math/wrap` min must be less than max.")
			return Value{}
		}

		width := i128(max_int) - i128(min_int)
		offset := i128(x_int) - i128(min_int)
		wrapped := offset % width
		if wrapped < 0 {
			wrapped += width
		}

		return Value(i64(i128(min_int) + wrapped))
	}

	x, x_ok := check_number_arg(args, 0, "math/wrap", "first")
	if !x_ok { return Value{} }
	min_value, min_ok := check_number_arg(args, 1, "math/wrap", "second")
	if !min_ok { return Value{} }
	max_value, max_ok := check_number_arg(args, 2, "math/wrap", "third")
	if !max_ok { return Value{} }

	if min_value >= max_value {
		runtime_error("`math/wrap` min must be less than max.")
		return Value{}
	}

	width := max_value - min_value
	return Value(min_value + math.wrap(x - min_value, width))
}

// (smoothstep edge-a edge-b x) float; Clamped smooth transition from 0.0 to 1.0.
native_math_smoothstep :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 3, "`math/smoothstep` expects three arguments.\nusage: (math/smoothstep edge-a edge-b x)") { return Value{} }

	edge_a, edge_a_ok := check_number_arg(args, 0, "math/smoothstep", "first")
	if !edge_a_ok { return Value{} }
	edge_b, edge_b_ok := check_number_arg(args, 1, "math/smoothstep", "second")
	if !edge_b_ok { return Value{} }
	x, x_ok := check_number_arg(args, 2, "math/smoothstep", "third")
	if !x_ok { return Value{} }

	if edge_a >= edge_b {
		runtime_error("`math/smoothstep` first edge must be less than second edge.")
		return Value{}
	}

	return Value(math.smoothstep(edge_a, edge_b, x))
}


// Rand module ====================================================================================

// (seed seed) nil; Reset the VM's default random generator.
native_rand_seed :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`rand/seed` expects one argument.\nusage: (rand/seed seed)") { return Value{} }

	seed, seed_ok := check_int_arg(args, 0, "rand/seed", "first")
	if !seed_ok { return Value{} }

	rand.reset_u64(transmute(u64)seed, rand.xoshiro256_random_generator(&vm.rng_state))
	return Value{}
}

// (float) float; Random float in [0.0, 1.0).
native_rand_float :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 0, "`rand/float` expects no arguments.\nusage: (rand/float)") { return Value{} }

	return Value(rand.float64(rand.xoshiro256_random_generator(&vm.rng_state)))
}

// (int min max) int; Random int in the inclusive range [min, max].
native_rand_int :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`rand/int` expects two arguments.\nusage: (rand/int min max)") { return Value{} }

	min_value, min_ok := check_int_arg(args, 0, "rand/int", "first")
	if !min_ok { return Value{} }
	max_value, max_ok := check_int_arg(args, 1, "rand/int", "second")
	if !max_ok { return Value{} }

	if min_value > max_value {
		runtime_error("`rand/int` min must be <= max.")
		return Value{}
	}

	width := u128(i128(max_value) - i128(min_value) + 1)
	offset := rand.uint128_max(width, rand.xoshiro256_random_generator(&vm.rng_state))
	return Value(i64(i128(min_value) + i128(offset)))
}

// (bool) bool; 50/50 random bool.
// (bool chance) bool; true with finite chance in [0, 1].
native_rand_bool :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count_range(args, 0, 1, "`rand/bool` expects zero or one argument.\nusage: (rand/bool)\n       (rand/bool chance)") { return Value{} }

	if len(args) == 0 {
		return Value(bool(rand.uint64_max(2, rand.xoshiro256_random_generator(&vm.rng_state)) == 1))
	}

	chance, chance_ok := check_number_arg(args, 0, "rand/bool", "first")
	if !chance_ok { return Value{} }

	if math.is_nan(chance) || math.is_inf(chance) || chance < 0 || chance > 1 {
		runtime_error("`rand/bool` chance must be a finite number in [0, 1].")
		return Value{}
	}

	if chance == 0 { return Value(bool(false)) }
	if chance == 1 { return Value(bool(true)) }

	return Value(bool(rand.float64(rand.xoshiro256_random_generator(&vm.rng_state)) < chance))
}

// (pick items) value; Uniformly pick one item from a non-empty vector.
// (pick items weights) value; Weighted pick using positional non-negative finite weights.
native_rand_pick :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count_range(args, 1, 2, "`rand/pick` expects one or two arguments.\nusage: (rand/pick vector)\n       (rand/pick vector weights)") { return Value{} }

	items, items_ok := check_vector_arg(args, 0, "rand/pick", "first")
	if !items_ok { return Value{} }

	item_count := len(items.items)
	if item_count == 0 {
		runtime_error("`rand/pick` item vector must not be empty.")
		return Value{}
	}

	if len(args) == 1 {
		rng := rand.xoshiro256_random_generator(&vm.rng_state)
		index := rand.int_range(0, item_count, rng)
		return items.items[index]
	}

	weights, weights_ok := check_vector_arg(args, 1, "rand/pick", "second")
	if !weights_ok { return Value{} }

	if len(weights.items) != item_count {
		runtime_error("`rand/pick` weights length must match item vector length.")
		return Value{}
	}

	total_weight: f64
	last_positive_index := -1

	for i := 0; i < item_count; i += 1 {
		weight_value := weights.items[i]

		weight_int, weight_is_int := weight_value.(i64)
		weight: f64
		if weight_is_int {
			weight = f64(weight_int)
		} else {
			weight_float, weight_is_float := weight_value.(f64)
			if !weight_is_float {
				runtime_error("`rand/pick` expected number items in weights vector.")
				return Value{}
			}

			weight = weight_float
		}

		if math.is_nan(weight) || math.is_inf(weight) || weight < 0 {
			runtime_error("`rand/pick` weights must be finite non-negative numbers.")
			return Value{}
		}

		if weight > 0 {
			last_positive_index = i
		}

		total_weight += weight
	}

	if total_weight <= 0 {
		runtime_error("`rand/pick` weight total must be greater than zero.")
		return Value{}
	}
	if math.is_inf(total_weight) {
		runtime_error("`rand/pick` weight total must be finite.")
		return Value{}
	}

	rng := rand.xoshiro256_random_generator(&vm.rng_state)
	roll := rand.float64(rng) * total_weight
	for i := 0; i < item_count; i += 1 {
		weight_value := weights.items[i]

		weight_int, weight_is_int := weight_value.(i64)
		weight: f64
		if weight_is_int {
			weight = f64(weight_int)
		} else {
			weight = weight_value.(f64)
		}

		if roll < weight {
			return items.items[i]
		}

		roll -= weight
	}

	return items.items[last_positive_index]
}

// (shuffle vector) vector; In-place Fisher-Yates shuffle, returning the same vector.
native_rand_shuffle :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`rand/shuffle` expects one argument.\nusage: (rand/shuffle vector)") { return Value{} }

	vector, vector_ok := check_vector_arg(args, 0, "rand/shuffle", "first")
	if !vector_ok { return Value{} }

	rng := rand.xoshiro256_random_generator(&vm.rng_state)

	for i := len(vector.items) - 1; i >= 1; i -= 1 {
		j := rand.int_range(0, i + 1, rng)
		vector.items[i], vector.items[j] = vector.items[j], vector.items[i]
	}

	return args[0]
}


// String module ==================================================================================

// (has? text part) bool; true if text contains part.
native_str_has :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`str/has?` expects two arguments.\nusage: (str/has? text part)") { return Value{} }

	text, text_ok := check_string_arg(args, 0, "str/has?", "first")
	if !text_ok { return Value{} }
	part, part_ok := check_string_arg(args, 1, "str/has?", "second")
	if !part_ok { return Value{} }

	return Value(bool(strings.contains(text, part)))
}

// (prefix? text prefix) bool; true if text starts with prefix.
native_str_prefix :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`str/prefix?` expects two arguments.\nusage: (str/prefix? text prefix)") { return Value{} }

	text, text_ok := check_string_arg(args, 0, "str/prefix?", "first")
	if !text_ok { return Value{} }
	prefix, prefix_ok := check_string_arg(args, 1, "str/prefix?", "second")
	if !prefix_ok { return Value{} }

	return Value(bool(strings.has_prefix(text, prefix)))
}

// (suffix? text suffix) bool; true if text ends with suffix.
native_str_suffix :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`str/suffix?` expects two arguments.\nusage: (str/suffix? text suffix)") { return Value{} }

	text, text_ok := check_string_arg(args, 0, "str/suffix?", "first")
	if !text_ok { return Value{} }
	suffix, suffix_ok := check_string_arg(args, 1, "str/suffix?", "second")
	if !suffix_ok { return Value{} }

	return Value(bool(strings.has_suffix(text, suffix)))
}

// (split text separator) vector; Split text by separator into strings.
native_str_split :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`str/split` expects two arguments.\nusage: (str/split text separator)") { return Value{} }

	text, text_ok := check_string_arg(args, 0, "str/split", "first")
	if !text_ok { return Value{} }
	separator, separator_ok := check_string_arg(args, 1, "str/split", "second")
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
	if !check_arg_count(args, 2, "`str/join` expects vector and separator.\nusage: (str/join vector separator)") { return Value{} }

	vector, vector_ok := check_vector_arg(args, 0, "str/join", "first")
	if !vector_ok { return Value{} }
	separator, separator_ok := check_string_arg(args, 1, "str/join", "second")
	if !separator_ok { return Value{} }

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
	if !check_arg_count(args, 2, "`str/find` expects two arguments.\nusage: (str/find text part)") { return Value{} }

	text, text_ok := check_string_arg(args, 0, "str/find", "first")
	if !text_ok { return Value{} }
	part, part_ok := check_string_arg(args, 1, "str/find", "second")
	if !part_ok { return Value{} }

	index := strings.index(text, part)
	if index < 0 {
		return Value{}
	}

	return Value(i64(index))
}

// (slice text start count) string; Copy a byte range from text.
native_str_slice :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 3, "`str/slice` expects string, start, and count.\nusage: (str/slice text start count)") { return Value{} }

	text, text_ok := check_string_arg(args, 0, "str/slice", "first")
	if !text_ok { return Value{} }
	start, start_ok := check_int_arg(args, 1, "str/slice", "second")
	if !start_ok { return Value{} }
	count, count_ok := check_int_arg(args, 2, "str/slice", "third")
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
	if !check_arg_count(args, 3, "`str/replace` expects string, old text, and new text.\nusage: (str/replace text old new)") { return Value{} }

	text, text_ok := check_string_arg(args, 0, "str/replace", "first")
	if !text_ok { return Value{} }
	old, old_ok := check_string_arg(args, 1, "str/replace", "second")
	if !old_ok { return Value{} }
	new, new_ok := check_string_arg(args, 2, "str/replace", "third")
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
	if !check_arg_count(args, 1, "`str/trim` expects one argument.\nusage: (str/trim text)") { return Value{} }

	text, text_ok := check_string_arg(args, 0, "str/trim", "first")
	if !text_ok { return Value{} }

	return Value(cast(^Object)new_string_object(strings.trim_space(text)))
}

// (lower text) string; Lowercase text.
native_str_lower :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`str/lower` expects one argument.\nusage: (str/lower text)") { return Value{} }

	text, text_ok := check_string_arg(args, 0, "str/lower", "first")
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
	if !check_arg_count(args, 1, "`str/upper` expects one argument.\nusage: (str/upper text)") { return Value{} }

	text, text_ok := check_string_arg(args, 0, "str/upper", "first")
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
	if !check_arg_count(args, 2, "`str/byte` expects string and index.\nusage: (str/byte text index)") { return Value{} }

	text, text_ok := check_string_arg(args, 0, "str/byte", "first")
	if !text_ok { return Value{} }
	index, index_ok := check_int_arg(args, 1, "str/byte", "second")
	if !index_ok { return Value{} }

	if index < 0 || index >= i64(len(text)) {
		runtime_error("`str/byte` index out of bounds.")
		return Value{}
	}

	return Value(i64(text[int(index)]))
}

// (bytes text) vector; Byte values of text.
native_str_bytes :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`str/bytes` expects one argument.\nusage: (str/bytes text)") { return Value{} }

	text, text_ok := check_string_arg(args, 0, "str/bytes", "first")
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

// (join part...) string; Join path parts using platform path rules.
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
	if !check_arg_count(args, 1, "`path/base` expects one argument.\nusage: (path/base path)") { return Value{} }

	path, path_ok := check_string_arg(args, 0, "path/base", "first")
	if !path_ok { return Value{} }

	return Value(cast(^Object)new_string_object(os.base(path)))
}

// (dir path) string; Parent path portion.
native_path_dir :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`path/dir` expects one argument.\nusage: (path/dir path)") { return Value{} }

	path, path_ok := check_string_arg(args, 0, "path/dir", "first")
	if !path_ok { return Value{} }

	dir, _ := os.split_path(path)
	return Value(cast(^Object)new_string_object(dir))
}

// (ext path) string; File extension, including the dot.
native_path_ext :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`path/ext` expects one argument.\nusage: (path/ext path)") { return Value{} }

	path, path_ok := check_string_arg(args, 0, "path/ext", "first")
	if !path_ok { return Value{} }

	return Value(cast(^Object)new_string_object(os.ext(path)))
}

// (stem path) string; Final path component without extension.
native_path_stem :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`path/stem` expects one argument.\nusage: (path/stem path)") { return Value{} }

	path, path_ok := check_string_arg(args, 0, "path/stem", "first")
	if !path_ok { return Value{} }

	if path == "" {
		return Value(cast(^Object)new_string_object(""))
	}

	return Value(cast(^Object)new_string_object(os.stem(path)))
}

// (clean path) string; Lexically clean redundant path components.
native_path_clean :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`path/clean` expects one argument.\nusage: (path/clean path)") { return Value{} }

	path, path_ok := check_string_arg(args, 0, "path/clean", "first")
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
	if !check_arg_count(args, 1, "`path/abs` expects one argument.\nusage: (path/abs path)") { return Value{} }

	path, path_ok := check_string_arg(args, 0, "path/abs", "first")
	if !path_ok { return Value{} }

	absolute_path, abs_error := filepath.abs(path, context.allocator)
	if abs_error != nil {
		runtime_error(fmt.tprintf("`path/abs` failed for `%s`: %v", path, abs_error))
		return Value{}
	}
	defer delete(absolute_path)

	return Value(cast(^Object)new_string_object(absolute_path))
}


// Builds the core-module [value err] result vector.
value_err_vector :: proc(value, err: Value) -> Value {
	items := make([dynamic]Value, 2)
	items[0] = value
	items[1] = err

	return Value(cast(^Object)new_vector_object(items))
}


// OS module ======================================================================================

// (argv) vector; Raw process arguments.
native_os_argv :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 0, "`os/argv` expects no arguments.\nusage: (os/argv)") { return Value{} }

	items := make([dynamic]Value)
	reserve(&items, len(vm.argv))
	for arg in vm.argv {
		append(&items, Value(cast(^Object)new_string_object(arg)))
	}

	return Value(cast(^Object)new_vector_object(items))
}

// (args) vector; Script arguments.
native_os_args :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 0, "`os/args` expects no arguments.\nusage: (os/args)") { return Value{} }

	items := make([dynamic]Value)
	reserve(&items, len(vm.argv[vm.args_start:]))
	for arg in vm.argv[vm.args_start:] {
		append(&items, Value(cast(^Object)new_string_object(arg)))
	}

	return Value(cast(^Object)new_vector_object(items))
}

// (time) float; Unix time in seconds.
native_os_time :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 0, "`os/time` expects no arguments.\nusage: (os/time)") { return Value{} }

	nanoseconds := time.time_to_unix_nano(time.now())
	return Value(f64(nanoseconds) / 1e9)
}

// (tick) float; Monotonic clock reading in seconds.
native_os_tick :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 0, "`os/tick` expects no arguments.\nusage: (os/tick)") { return Value{} }

	tick := time.tick_now()
	return Value(f64(tick._nsec) / 1e9)
}

// (sleep seconds) nil; Block for approximately seconds.
native_os_sleep :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`os/sleep` expects one argument.\nusage: (os/sleep seconds)") { return Value{} }

	seconds, seconds_ok := check_number_arg(args, 0, "os/sleep", "first")
	if !seconds_ok { return Value{} }

	if math.is_nan(seconds) || math.is_inf(seconds) || seconds < 0 {
		runtime_error("`os/sleep` expected finite non-negative seconds.")
		return Value{}
	}

	nanoseconds := seconds * 1e9
	// time.Duration is i64 nanoseconds; 2^63 is the first invalid positive value.
	if nanoseconds >= 9223372036854775808.0 {
		runtime_error("`os/sleep` duration is too large.")
		return Value{}
	}

	time.sleep(time.Duration(i64(nanoseconds)))
	return Value{}
}

// (run args) [exit-code nil]|[nil err]; Run a process and inherit standard streams.
native_os_run :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`os/run` expects one argument.\nusage: (os/run args)") { return Value{} }

	command_vector, command_ok := check_vector_arg(args, 0, "os/run", "first")
	if !command_ok { return Value{} }
	if len(command_vector.items) == 0 {
		runtime_error("`os/run` args vector must not be empty.")
		return Value{}
	}

	command := make([]string, len(command_vector.items))
	defer delete(command)

	for item, index in command_vector.items {
		item_object, item_is_object := item.(^Object)
		if !item_is_object || item_object.kind != .STRING {
			runtime_error(fmt.tprintf("`os/run` expected string item at args index %d.", index))
			return Value{}
		}

		command[index] = (cast(^StringObject)item_object).text
	}

	process, start_error := os.process_start(os.Process_Desc{
		command = command,
		stdin   = os.stdin,
		stdout  = os.stdout,
		stderr  = os.stderr,
	})
	if start_error != nil {
		return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`os/run` failed to start `%s`: %v", command[0], start_error))))
	}

	state, wait_error := os.process_wait(process)
	if wait_error != nil {
		return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`os/run` failed while waiting for `%s`: %v", command[0], wait_error))))
	}

	return value_err_vector(Value(i64(state.exit_code)), Value{})
}

// (env name) string|nil; Environment variable value, or nil if unset.
native_os_env :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`os/env` expects one argument.\nusage: (os/env name)") { return Value{} }

	name, name_ok := check_string_arg(args, 0, "os/env", "first")
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
	if !check_arg_count(args, 2, "`os/set-env` expects environment variable name and value.\nusage: (os/set-env name value)") { return Value{} }

	name, name_ok := check_string_arg(args, 0, "os/set-env", "first")
	if !name_ok { return Value{} }
	value, value_ok := check_string_arg(args, 1, "os/set-env", "second")
	if !value_ok { return Value{} }

	set_error := os.set_env(name, value)
	if set_error != nil {
		return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`os/set-env` failed for `%s`: %v", name, set_error))))
	}

	return value_err_vector(Value(bool(true)), Value{})
}

// (exit code) never; Exit the process.
native_os_exit :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`os/exit` expects one argument.\nusage: (os/exit code)") { return Value{} }

	code, code_ok := check_int_arg(args, 0, "os/exit", "first")
	if !code_ok { return Value{} }

	os.exit(int(code))
}

// (name) string; Operating system name.
native_os_name :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 0, "`os/name` expects no arguments.\nusage: (os/name)") { return Value{} }

	return Value(cast(^Object)new_string_object(ODIN_OS_STRING))
}

// (arch) string; CPU architecture name.
native_os_arch :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 0, "`os/arch` expects no arguments.\nusage: (os/arch)") { return Value{} }

	return Value(cast(^Object)new_string_object(ODIN_ARCH_STRING))
}


// FS module ======================================================================================

// (read-file path) [string nil]|[nil err]; Read a text file.
native_fs_read_file :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`fs/read-file` expects one argument.\nusage: (fs/read-file path)") { return Value{} }

	path, path_ok := check_string_arg(args, 0, "fs/read-file", "first")
	if !path_ok { return Value{} }

	bytes, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/read-file` failed for `%s`: %v", path, read_error))))
	}
	defer delete(bytes)

	return value_err_vector(Value(cast(^Object)new_string_object(string(bytes))), Value{})
}

// (write-file path text) [true nil]|[nil err]; Write text to a file.
native_fs_write_file :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 2, "`fs/write-file` expects path and text.\nusage: (fs/write-file path text)") { return Value{} }

	path, path_ok := check_string_arg(args, 0, "fs/write-file", "first")
	if !path_ok { return Value{} }
	text, text_ok := check_string_arg(args, 1, "fs/write-file", "second")
	if !text_ok { return Value{} }

	write_error := os.write_entire_file(path, text)
	if write_error != nil {
		return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/write-file` failed for `%s`: %v", path, write_error))))
	}

	return value_err_vector(Value(bool(true)), Value{})
}

// (cwd) [string nil]|[nil err]; Current working directory.
native_fs_cwd :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 0, "`fs/cwd` expects no arguments.\nusage: (fs/cwd)") { return Value{} }

	cwd, cwd_error := os.get_working_directory(context.allocator)
	if cwd_error != nil {
		return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/cwd` failed: %v", cwd_error))))
	}
	defer delete(cwd)

	return value_err_vector(Value(cast(^Object)new_string_object(cwd)), Value{})
}

// (set-cwd path) [true nil]|[nil err]; Change current working directory.
native_fs_set_cwd :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`fs/set-cwd` expects one argument.\nusage: (fs/set-cwd path)") { return Value{} }

	path, path_ok := check_string_arg(args, 0, "fs/set-cwd", "first")
	if !path_ok { return Value{} }

	cwd_error := os.set_working_directory(path)
	if cwd_error != nil {
		return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/set-cwd` failed for `%s`: %v", path, cwd_error))))
	}

	return value_err_vector(Value(bool(true)), Value{})
}

// (exists? path) bool; true if path exists.
native_fs_exists :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`fs/exists?` expects one argument.\nusage: (fs/exists? path)") { return Value{} }

	path, path_ok := check_string_arg(args, 0, "fs/exists?", "first")
	if !path_ok { return Value{} }

	return Value(bool(os.exists(path)))
}

// (file? path) bool; true if path exists and is a file.
native_fs_file :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`fs/file?` expects one argument.\nusage: (fs/file? path)") { return Value{} }

	path, path_ok := check_string_arg(args, 0, "fs/file?", "first")
	if !path_ok { return Value{} }

	return Value(bool(os.is_file(path)))
}

// (dir? path) bool; true if path exists and is a directory.
native_fs_dir :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`fs/dir?` expects one argument.\nusage: (fs/dir? path)") { return Value{} }

	path, path_ok := check_string_arg(args, 0, "fs/dir?", "first")
	if !path_ok { return Value{} }

	return Value(bool(os.is_dir(path)))
}

// (list-dir path) [vector nil]|[nil err]; Direct directory entry names.
native_fs_list_dir :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`fs/list-dir` expects one argument.\nusage: (fs/list-dir path)") { return Value{} }

	path, path_ok := check_string_arg(args, 0, "fs/list-dir", "first")
	if !path_ok { return Value{} }

	entries, list_error := os.read_all_directory_by_path(path, context.allocator)
	if list_error != nil {
		return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/list-dir` failed for `%s`: %v", path, list_error))))
	}
	defer os.file_info_slice_delete(entries, context.allocator)

	entry_items := make([dynamic]Value)
	reserve(&entry_items, len(entries))
	for entry in entries {
		append(&entry_items, Value(cast(^Object)new_string_object(entry.name)))
	}

	return value_err_vector(Value(cast(^Object)new_vector_object(entry_items)), Value{})
}

// (make-dir path) [true nil]|[nil err]; Create one directory level.
native_fs_make_dir :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`fs/make-dir` expects one argument.\nusage: (fs/make-dir path)") { return Value{} }

	path, path_ok := check_string_arg(args, 0, "fs/make-dir", "first")
	if !path_ok { return Value{} }

	make_error := os.make_directory(path)
	if make_error != nil {
		return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/make-dir` failed for `%s`: %v", path, make_error))))
	}

	return value_err_vector(Value(bool(true)), Value{})
}

// (remove-file path) [true nil]|[nil err]; Remove a file.
native_fs_remove_file :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`fs/remove-file` expects one argument.\nusage: (fs/remove-file path)") { return Value{} }

	path, path_ok := check_string_arg(args, 0, "fs/remove-file", "first")
	if !path_ok { return Value{} }

	if !os.is_file(path) {
		return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/remove-file` failed for `%s`: not a file", path))))
	}

	remove_error := os.remove(path)
	if remove_error != nil {
		return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/remove-file` failed for `%s`: %v", path, remove_error))))
	}

	return value_err_vector(Value(bool(true)), Value{})
}

// (remove-dir path) [true nil]|[nil err]; Remove an empty directory.
native_fs_remove_dir :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`fs/remove-dir` expects one argument.\nusage: (fs/remove-dir path)") { return Value{} }

	path, path_ok := check_string_arg(args, 0, "fs/remove-dir", "first")
	if !path_ok { return Value{} }

	if !os.is_dir(path) {
		return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/remove-dir` failed for `%s`: not a directory", path))))
	}

	remove_error := os.remove(path)
	if remove_error != nil {
		return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`fs/remove-dir` failed for `%s`: %v", path, remove_error))))
	}

	return value_err_vector(Value(bool(true)), Value{})
}


// IO module ======================================================================================

// (read-all) [string nil]|[nil err]; Read all remaining stdin.
native_io_read_all :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 0, "`io/read-all` expects no arguments.\nusage: (io/read-all)") { return Value{} }

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
				return value_err_vector(Value(cast(^Object)new_string_object(string(data[:]))), Value{})
			}

			return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`io/read-all` failed: %v", read_error))))
		}
	}
}

// (read-line) [string nil]|[nil nil]|[nil err]; Read one stdin line.
native_io_read_line :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 0, "`io/read-line` expects no arguments.\nusage: (io/read-line)") { return Value{} }

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

				return value_err_vector(Value(cast(^Object)new_string_object(string(line[:]))), Value{})
			}

			append(&line, buffer[0])
		}

		if read_error != nil {
			read_io_error, read_is_io_error := read_error.(io.Error)
			read_general_error, read_is_general_error := read_error.(os.General_Error)
			if (read_is_io_error && read_io_error == .EOF) || (read_is_general_error && read_general_error == .Broken_Pipe) {
				if len(line) == 0 {
					return value_err_vector(Value{}, Value{})
				}

				if line[len(line) - 1] == '\r' {
					pop(&line)
				}

				return value_err_vector(Value(cast(^Object)new_string_object(string(line[:]))), Value{})
			}

			return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`io/read-line` failed: %v", read_error))))
		}
	}
}

// (write-err text) [true nil]|[nil err]; Write exact text to stderr.
native_io_write_err :: proc(vm: ^VM, args: []Value) -> Value {
	if !check_arg_count(args, 1, "`io/write-err` expects one argument.\nusage: (io/write-err text)") { return Value{} }

	text, text_ok := check_string_arg(args, 0, "io/write-err", "first")
	if !text_ok { return Value{} }

	_, write_error := os.write_string(os.stderr, text)
	if write_error != nil {
		return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`io/write-err` failed: %v", write_error))))
	}

	return value_err_vector(Value(bool(true)), Value{})
}

// (print-err value...) [true nil]|[nil err]; Print display text to stderr with newline.
native_io_print_err :: proc(vm: ^VM, args: []Value) -> Value {
	for i := 0; i < len(args); i += 1 {
		if i > 0 {
			_, space_error := os.write_string(os.stderr, " ")
			if space_error != nil {
				return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`io/print-err` failed: %v", space_error))))
			}
		}

		text := value_display_text(args[i])
		_, write_error := os.write_string(os.stderr, text)
		delete(text)
		if write_error != nil {
			return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`io/print-err` failed: %v", write_error))))
		}
	}

	_, newline_error := os.write_string(os.stderr, "\n")
	if newline_error != nil {
		return value_err_vector(Value{}, Value(cast(^Object)new_string_object(fmt.tprintf("`io/print-err` failed: %v", newline_error))))
	}

	return value_err_vector(Value(bool(true)), Value{})
}


// Registration ==================================================================================

install_builtins :: proc(vm: ^VM) {

	// Supplied builtins are immutable; install them exactly once per VM.
	bind_builtin(vm, "+", native_add)
	bind_builtin(vm, "-", native_sub)
	bind_builtin(vm, "*", native_mul)
	bind_builtin(vm, "/", native_div)
	bind_builtin(vm, "%", native_mod)
	bind_builtin(vm, "abs", native_abs)
	bind_builtin(vm, "min", native_min)
	bind_builtin(vm, "max", native_max)
	bind_builtin(vm, "clamp", native_clamp)
	bind_builtin(vm, "=", native_equal)
	bind_builtin(vm, "!=", native_not_equal)
	bind_builtin(vm, "<", native_less)
	bind_builtin(vm, "<=", native_less_equal)
	bind_builtin(vm, ">", native_greater)
	bind_builtin(vm, ">=", native_greater_equal)
	bind_builtin(vm, "not", native_not)
	bind_builtin(vm, "nil?", native_nil_predicate)
	bind_builtin(vm, "bool?", native_bool_predicate)
	bind_builtin(vm, "number?", native_number_predicate)
	bind_builtin(vm, "number", native_number)
	bind_builtin(vm, "int?", native_int_predicate)
	bind_builtin(vm, "float?", native_float_predicate)
	bind_builtin(vm, "str?", native_string_predicate)
	bind_builtin(vm, "vec?", native_vector_predicate)
	bind_builtin(vm, "map?", native_map_predicate)
	bind_builtin(vm, "fn?", native_function_predicate)
	bind_builtin(vm, "empty?", native_empty_predicate)
	bind_builtin(vm, "len", native_len)
	bind_builtin(vm, "copy", native_copy)
	bind_builtin(vm, "clear", native_clear)
	bind_builtin(vm, "type", native_type)
	bind_builtin(vm, "str", native_str)
	bind_builtin(vm, "assert", native_assert)
	bind_builtin(vm, "error", native_error)
	bind_builtin(vm, "push", native_push)
	bind_builtin(vm, "pop", native_pop)
	bind_builtin(vm, "insert", native_insert)
	bind_builtin(vm, "remove", native_remove)
	bind_builtin(vm, "slice", native_slice)
	bind_builtin(vm, "keys", native_keys)
	bind_builtin(vm, "vals", native_vals)
	bind_builtin(vm, "pairs", native_pairs)
	bind_builtin(vm, "map", native_map)
	bind_builtin(vm, "filter", native_filter)
	bind_builtin(vm, "reduce", native_reduce)
	bind_builtin(vm, "find", native_find)
	bind_builtin(vm, "pick", native_pick)
	bind_builtin(vm, "sort", native_sort)
	bind_builtin(vm, "sort-by", native_sort_by)
	bind_builtin(vm, "merge", native_merge)
	bind_builtin(vm, "print", native_print)
	bind_builtin(vm, "write", native_write)
}


install_core_modules :: proc(vm: ^VM) {
	// str
	str_exports := make([dynamic]Binding)
	defer delete(str_exports)

	bind_module_native_function(vm, &str_exports, "has?", native_str_has)
	bind_module_native_function(vm, &str_exports, "prefix?", native_str_prefix)
	bind_module_native_function(vm, &str_exports, "suffix?", native_str_suffix)
	bind_module_native_function(vm, &str_exports, "split", native_str_split)
	bind_module_native_function(vm, &str_exports, "join", native_str_join)
	bind_module_native_function(vm, &str_exports, "find", native_str_find)
	bind_module_native_function(vm, &str_exports, "slice", native_str_slice)
	bind_module_native_function(vm, &str_exports, "replace", native_str_replace)
	bind_module_native_function(vm, &str_exports, "trim", native_str_trim)
	bind_module_native_function(vm, &str_exports, "lower", native_str_lower)
	bind_module_native_function(vm, &str_exports, "upper", native_str_upper)
	bind_module_native_function(vm, &str_exports, "byte", native_str_byte)
	bind_module_native_function(vm, &str_exports, "bytes", native_str_bytes)
	install_native_module(vm, "str", str_exports[:])

	// path
	path_exports := make([dynamic]Binding)
	defer delete(path_exports)

	bind_module_native_function(vm, &path_exports, "join", native_path_join)
	bind_module_native_function(vm, &path_exports, "base", native_path_base)
	bind_module_native_function(vm, &path_exports, "dir", native_path_dir)
	bind_module_native_function(vm, &path_exports, "ext", native_path_ext)
	bind_module_native_function(vm, &path_exports, "stem", native_path_stem)
	bind_module_native_function(vm, &path_exports, "clean", native_path_clean)
	bind_module_native_function(vm, &path_exports, "abs", native_path_abs)
	install_native_module(vm, "path", path_exports[:])

	// math
	math_exports := make([dynamic]Binding)
	defer delete(math_exports)

	bind_module_value(vm, &math_exports, "pi", Value(f64(math.PI)))
	bind_module_value(vm, &math_exports, "tau", Value(f64(math.TAU)))
	bind_module_value(vm, &math_exports, "e", Value(f64(math.E)))
	bind_module_value(vm, &math_exports, "inf", Value(math.inf_f64(1)))
	bind_module_value(vm, &math_exports, "-inf", Value(math.inf_f64(-1)))
	bind_module_value(vm, &math_exports, "nan", Value(math.nan_f64()))
	bind_module_native_function(vm, &math_exports, "floor", native_math_floor)
	bind_module_native_function(vm, &math_exports, "ceil", native_math_ceil)
	bind_module_native_function(vm, &math_exports, "round", native_math_round)
	bind_module_native_function(vm, &math_exports, "trunc", native_math_trunc)
	bind_module_native_function(vm, &math_exports, "sqrt", native_math_sqrt)
	bind_module_native_function(vm, &math_exports, "pow", native_math_pow)
	bind_module_native_function(vm, &math_exports, "exp", native_math_exp)
	bind_module_native_function(vm, &math_exports, "log", native_math_log)
	bind_module_native_function(vm, &math_exports, "sin", native_math_sin)
	bind_module_native_function(vm, &math_exports, "cos", native_math_cos)
	bind_module_native_function(vm, &math_exports, "tan", native_math_tan)
	bind_module_native_function(vm, &math_exports, "asin", native_math_asin)
	bind_module_native_function(vm, &math_exports, "acos", native_math_acos)
	bind_module_native_function(vm, &math_exports, "atan", native_math_atan)
	bind_module_native_function(vm, &math_exports, "atan2", native_math_atan2)
	bind_module_native_function(vm, &math_exports, "radians", native_math_radians)
	bind_module_native_function(vm, &math_exports, "degrees", native_math_degrees)
	bind_module_native_function(vm, &math_exports, "finite?", native_math_finite_predicate)
	bind_module_native_function(vm, &math_exports, "nan?", native_math_nan_predicate)
	bind_module_native_function(vm, &math_exports, "inf?", native_math_inf_predicate)
	bind_module_native_function(vm, &math_exports, "sign", native_math_sign)
	bind_module_native_function(vm, &math_exports, "fract", native_math_fract)
	bind_module_native_function(vm, &math_exports, "hypot", native_math_hypot)
	bind_module_native_function(vm, &math_exports, "lerp", native_math_lerp)
	bind_module_native_function(vm, &math_exports, "inverse-lerp", native_math_inverse_lerp)
	bind_module_native_function(vm, &math_exports, "remap", native_math_remap)
	bind_module_native_function(vm, &math_exports, "wrap", native_math_wrap)
	bind_module_native_function(vm, &math_exports, "smoothstep", native_math_smoothstep)
	install_native_module(vm, "math", math_exports[:])

	// rand
	rand_exports := make([dynamic]Binding)
	defer delete(rand_exports)

	bind_module_native_function(vm, &rand_exports, "seed", native_rand_seed)
	bind_module_native_function(vm, &rand_exports, "float", native_rand_float)
	bind_module_native_function(vm, &rand_exports, "int", native_rand_int)
	bind_module_native_function(vm, &rand_exports, "bool", native_rand_bool)
	bind_module_native_function(vm, &rand_exports, "pick", native_rand_pick)
	bind_module_native_function(vm, &rand_exports, "shuffle", native_rand_shuffle)
	install_native_module(vm, "rand", rand_exports[:])

	// os
	os_exports := make([dynamic]Binding)
	defer delete(os_exports)

	bind_module_native_function(vm, &os_exports, "argv", native_os_argv)
	bind_module_native_function(vm, &os_exports, "args", native_os_args)
	bind_module_native_function(vm, &os_exports, "time", native_os_time)
	bind_module_native_function(vm, &os_exports, "tick", native_os_tick)
	bind_module_native_function(vm, &os_exports, "sleep", native_os_sleep)
	bind_module_native_function(vm, &os_exports, "run", native_os_run)
	bind_module_native_function(vm, &os_exports, "env", native_os_env)
	bind_module_native_function(vm, &os_exports, "set-env", native_os_set_env)
	bind_module_native_function(vm, &os_exports, "exit", native_os_exit)
	bind_module_native_function(vm, &os_exports, "name", native_os_name)
	bind_module_native_function(vm, &os_exports, "arch", native_os_arch)
	install_native_module(vm, "os", os_exports[:])

	// fs
	fs_exports := make([dynamic]Binding)
	defer delete(fs_exports)

	bind_module_native_function(vm, &fs_exports, "read-file", native_fs_read_file)
	bind_module_native_function(vm, &fs_exports, "write-file", native_fs_write_file)
	bind_module_native_function(vm, &fs_exports, "cwd", native_fs_cwd)
	bind_module_native_function(vm, &fs_exports, "set-cwd", native_fs_set_cwd)
	bind_module_native_function(vm, &fs_exports, "exists?", native_fs_exists)
	bind_module_native_function(vm, &fs_exports, "file?", native_fs_file)
	bind_module_native_function(vm, &fs_exports, "dir?", native_fs_dir)
	bind_module_native_function(vm, &fs_exports, "list-dir", native_fs_list_dir)
	bind_module_native_function(vm, &fs_exports, "make-dir", native_fs_make_dir)
	bind_module_native_function(vm, &fs_exports, "remove-file", native_fs_remove_file)
	bind_module_native_function(vm, &fs_exports, "remove-dir", native_fs_remove_dir)
	install_native_module(vm, "fs", fs_exports[:])

	// io
	io_exports := make([dynamic]Binding)
	defer delete(io_exports)

	bind_module_native_function(vm, &io_exports, "read-all", native_io_read_all)
	bind_module_native_function(vm, &io_exports, "read-line", native_io_read_line)
	bind_module_native_function(vm, &io_exports, "write-err", native_io_write_err)
	bind_module_native_function(vm, &io_exports, "print-err", native_io_print_err)
	install_native_module(vm, "io", io_exports[:])
}
