package eld

import "core:fmt"
import "core:os"
import filepath "core:path/filepath"
import "core:strings"


// Disassembly ====================================================================================

DISASM_OPCODE_WIDTH :: 17
DISASM_COMMENT_COLUMN :: 48

disasm_value_text :: proc(value: Value) -> string {
	object, is_object := value.(^Object)
	if is_object && object.kind == .STRING {
		string_object := cast(^StringObject)object
		return fmt.tprintf("\"%s\"", string_object.text)
	}

	parts := make([dynamic]string)
	parents := make([dynamic]^Object)
	defer delete(parts)
	defer delete(parents)

	append_value_text(&parts, value, &parents)
	return strings.concatenate(parts[:], context.temp_allocator)
}

disasm_append_line :: proc(parts: ^[dynamic]string, body, comment: string) {
	append(parts, body)

	if comment != "" {
		for i := len(body); i < DISASM_COMMENT_COLUMN; i += 1 {
			append(parts, " ")
		}

		append(parts, "; ")
		append(parts, comment)
	}

	append(parts, "\n")
}

disasm_append_inst :: proc(parts: ^[dynamic]string, ip: int, op_name, operands, comment: string) {
	body := fmt.tprintf("    %04d    %s", ip, op_name)

	for i := len(op_name); i < DISASM_OPCODE_WIDTH; i += 1 {
		body = strings.concatenate({body, " "}, context.temp_allocator)
	}

	if operands != "" {
		body = strings.concatenate({body, operands}, context.temp_allocator)
	}

	disasm_append_line(parts, body, comment)
}

disasm_append_code_sections :: proc(parts: ^[dynamic]string, code: ^Code) {
	if len(code.constants) > 0 {
		append(parts, "\n")
		append(parts, "  constants\n")

		for i := 0; i < len(code.constants); i += 1 {
			append(parts, fmt.tprintf("    C%d = %s\n", i, disasm_value_text(code.constants[i])))
		}
	}

	if len(code.upvalue_descs) > 0 {
		append(parts, "\n")
		append(parts, "  upvalues\n")

		for i := 0; i < len(code.upvalue_descs); i += 1 {
			desc := code.upvalue_descs[i]
			source := "local" if desc.from_parent_local else "upvalue"
			mutability := "var" if desc.mutable else "def"
			append(parts, fmt.tprintf("    U%d = %s %d, %s\n", i, source, desc.index, mutability))
		}
	}

	if len(code.exports) > 0 {
		append(parts, "\n")
		append(parts, "  exports\n")

		for i := 0; i < len(code.exports); i += 1 {
			binding := code.exports[i]
			mutability := "var" if binding.mutable else "def"
			append(parts, fmt.tprintf("    %s = R%d, %s\n", binding.symbol.text, binding.slot, mutability))
		}
	}

	if len(code.child_codes) > 0 {
		append(parts, "\n")
		append(parts, "  children\n")

		for i := 0; i < len(code.child_codes); i += 1 {
			child := code.child_codes[i]
			append(parts, fmt.tprintf("    F%d = params %d, slots %d, ops %d\n", i, child.param_count, child.frame_slot_count, len(child.bytecode)))
		}
	}
}

disasm_append_code :: proc(parts: ^[dynamic]string, code: ^Code) {
	append(parts, "\n")
	append(parts, "  code\n")

	for ip := 0; ip < len(code.bytecode); ip += 1 {
		word := code.bytecode[ip]
		op := InstABC(word).op

		switch op {
		case .LOAD_NIL:
			inst := InstABx(word)
			disasm_append_inst(parts, ip, "LOAD_NIL", fmt.tprintf("R%d", inst.a), "")

		case .LOAD_TRUE:
			inst := InstABx(word)
			disasm_append_inst(parts, ip, "LOAD_TRUE", fmt.tprintf("R%d", inst.a), "")

		case .LOAD_FALSE:
			inst := InstABx(word)
			disasm_append_inst(parts, ip, "LOAD_FALSE", fmt.tprintf("R%d", inst.a), "")

		case .LOAD_CONST:
			inst := InstABx(word)
			comment := disasm_value_text(code.constants[int(inst.b)])
			disasm_append_inst(parts, ip, "LOAD_CONST", fmt.tprintf("R%d, C%d", inst.a, inst.b), comment)

		case .MOVE:
			inst := InstABC(word)
			disasm_append_inst(parts, ip, "MOVE", fmt.tprintf("R%d, R%d", inst.a, inst.b), "")

		case .GET_BUILTIN:
			inst := InstABx(word)
			comment := Active_VM.builtins[int(inst.b)].symbol.text
			disasm_append_inst(parts, ip, "GET_BUILTIN", fmt.tprintf("R%d, B%d", inst.a, inst.b), comment)

		case .LOAD_FUNCTION:
			inst := InstABx(word)
			disasm_append_inst(parts, ip, "LOAD_FUNCTION", fmt.tprintf("R%d, F%d", inst.a, inst.b), "")

		case .GET_UPVALUE:
			inst := InstABx(word)
			disasm_append_inst(parts, ip, "GET_UPVALUE", fmt.tprintf("R%d, U%d", inst.a, inst.b), "")

		case .SET_UPVALUE:
			inst := InstABx(word)
			disasm_append_inst(parts, ip, "SET_UPVALUE", fmt.tprintf("R%d, U%d", inst.a, inst.b), "")

		case .CLOSE_UPVALUES:
			inst := InstABx(word)
			disasm_append_inst(parts, ip, "CLOSE_UPVALUES", fmt.tprintf("R%d", inst.a), "")

		case .ADD, .SUB, .MUL, .DIV:
			inst := InstABC(word)
			op_name := "ADD"
			if op == .SUB {
				op_name = "SUB"
			} else if op == .MUL {
				op_name = "MUL"
			} else if op == .DIV {
				op_name = "DIV"
			}
			disasm_append_inst(parts, ip, op_name, fmt.tprintf("R%d, R%d, %d", inst.a, inst.b, inst.c), "")

		case .ADD_CONST, .SUB_CONST, .MUL_CONST, .DIV_CONST, .MOD_CONST:
			inst := InstABC(word)
			op_name := "ADD_CONST"
			if op == .SUB_CONST {
				op_name = "SUB_CONST"
			} else if op == .MUL_CONST {
				op_name = "MUL_CONST"
			} else if op == .DIV_CONST {
				op_name = "DIV_CONST"
			} else if op == .MOD_CONST {
				op_name = "MOD_CONST"
			}
			comment := disasm_value_text(code.constants[int(inst.c)])
			disasm_append_inst(parts, ip, op_name, fmt.tprintf("R%d, R%d, C%d", inst.a, inst.b, inst.c), comment)

		case .MOD, .EQUAL, .LESS, .LESS_EQUAL, .GREATER, .GREATER_EQUAL:
			inst := InstABC(word)
			op_name := "MOD"
			if op == .EQUAL {
				op_name = "EQUAL"
			} else if op == .LESS {
				op_name = "LESS"
			} else if op == .LESS_EQUAL {
				op_name = "LESS_EQUAL"
			} else if op == .GREATER {
				op_name = "GREATER"
			} else if op == .GREATER_EQUAL {
				op_name = "GREATER_EQUAL"
			}
			disasm_append_inst(parts, ip, op_name, fmt.tprintf("R%d, R%d, R%d", inst.a, inst.b, inst.c), "")

		case .NOT, .LEN:
			inst := InstABC(word)
			op_name := "NOT" if op == .NOT else "LEN"
			disasm_append_inst(parts, ip, op_name, fmt.tprintf("R%d, R%d", inst.a, inst.b), "")

		case .CALL:
			inst := InstABC(word)
			disasm_append_inst(parts, ip, "CALL", fmt.tprintf("R%d, %d", inst.a, inst.b), "")

		case .NEW_VECTOR:
			inst := InstABx(word)
			disasm_append_inst(parts, ip, "NEW_VECTOR", fmt.tprintf("R%d, %d", inst.a, inst.b), "")

		case .NEW_MAP:
			inst := InstABx(word)
			disasm_append_inst(parts, ip, "NEW_MAP", fmt.tprintf("R%d, %d", inst.a, inst.b), "")

		case .VECTOR_PUSH:
			inst := InstABC(word)
			disasm_append_inst(parts, ip, "VECTOR_PUSH", fmt.tprintf("R%d, R%d", inst.a, inst.b), "")

		case .VECTOR_POP:
			inst := InstABC(word)
			disasm_append_inst(parts, ip, "VECTOR_POP", fmt.tprintf("R%d, R%d", inst.a, inst.b), "")

		case .UNPACK_VECTOR:
			inst := InstABC(word)
			disasm_append_inst(parts, ip, "UNPACK_VECTOR", fmt.tprintf("R%d, R%d, %d", inst.a, inst.b, inst.c), "")

		case .VECTOR_GET:
			inst := InstABC(word)
			disasm_append_inst(parts, ip, "VECTOR_GET", fmt.tprintf("R%d, R%d, R%d", inst.a, inst.b, inst.c), "")

		case .VECTOR_GET_CONST:
			inst := InstABC(word)
			comment := disasm_value_text(code.constants[int(inst.c)])
			disasm_append_inst(parts, ip, "VECTOR_GET_CONST", fmt.tprintf("R%d, R%d, C%d", inst.a, inst.b, inst.c), comment)

		case .VECTOR_SET:
			inst := InstABC(word)
			disasm_append_inst(parts, ip, "VECTOR_SET", fmt.tprintf("R%d, R%d, R%d", inst.a, inst.b, inst.c), "")

		case .VECTOR_SET_CONST:
			inst := InstABC(word)
			comment := disasm_value_text(code.constants[int(inst.b)])
			disasm_append_inst(parts, ip, "VECTOR_SET_CONST", fmt.tprintf("R%d, C%d, R%d", inst.a, inst.b, inst.c), comment)

		case .MAP_GET:
			inst := InstABC(word)
			disasm_append_inst(parts, ip, "MAP_GET", fmt.tprintf("R%d, R%d, R%d", inst.a, inst.b, inst.c), "")

		case .MAP_GET_CONST:
			inst := InstABC(word)
			comment := disasm_value_text(code.constants[int(inst.c)])
			disasm_append_inst(parts, ip, "MAP_GET_CONST", fmt.tprintf("R%d, R%d, C%d", inst.a, inst.b, inst.c), comment)

		case .MAP_SET:
			inst := InstABC(word)
			disasm_append_inst(parts, ip, "MAP_SET", fmt.tprintf("R%d, R%d, R%d", inst.a, inst.b, inst.c), "")

		case .MAP_SET_CONST:
			inst := InstABC(word)
			comment := disasm_value_text(code.constants[int(inst.b)])
			disasm_append_inst(parts, ip, "MAP_SET_CONST", fmt.tprintf("R%d, C%d, R%d", inst.a, inst.b, inst.c), comment)

		case .EACH_INIT:
			inst := InstABC(word)
			map_target_ok := "false"
			if inst.c != 0 {
				map_target_ok = "true"
			}
			disasm_append_inst(parts, ip, "EACH_INIT", fmt.tprintf("R%d, R%d, %s", inst.a, inst.b, map_target_ok), "")

		case .EACH_NEXT:
			inst := InstABC(word)
			disasm_append_inst(parts, ip, "EACH_NEXT", fmt.tprintf("R%d, R%d", inst.a, inst.b), "")

		case .EACH_END:
			inst := InstABC(word)
			disasm_append_inst(parts, ip, "EACH_END", fmt.tprintf("R%d, R%d", inst.a, inst.b), "")

		case .RETURN:
			inst := InstABx(word)
			disasm_append_inst(parts, ip, "RETURN", fmt.tprintf("R%d", inst.a), "")

		case .JUMP:
			inst := InstAx(word)
			disasm_append_inst(parts, ip, "JUMP", fmt.tprintf("%d", inst.a), "")

		case .JUMP_IF_FALSEY:
			inst := InstABx(word)
			disasm_append_inst(parts, ip, "JUMP_IF_FALSEY", fmt.tprintf("R%d, %d", inst.a, inst.b), "")

		case .JUMP_IF_NIL:
			inst := InstABx(word)
			disasm_append_inst(parts, ip, "JUMP_IF_NIL", fmt.tprintf("R%d, %d", inst.a, inst.b), "")

		case .JUMP_IF_NOT_LESS, .JUMP_IF_NOT_LESS_EQUAL, .JUMP_IF_NOT_GREATER, .JUMP_IF_NOT_GREATER_EQUAL:
			inst := InstABC(word)
			target := code.bytecode[ip + 1]
			op_name := "JUMP_IF_NOT_LESS"
			if op == .JUMP_IF_NOT_LESS_EQUAL {
				op_name = "JUMP_IF_NOT_LESS_EQUAL"
			} else if op == .JUMP_IF_NOT_GREATER {
				op_name = "JUMP_IF_NOT_GREATER"
			} else if op == .JUMP_IF_NOT_GREATER_EQUAL {
				op_name = "JUMP_IF_NOT_GREATER_EQUAL"
			}
			disasm_append_inst(parts, ip, op_name, fmt.tprintf("R%d, R%d, %d", inst.a, inst.b, target), "")
			// Target is stored as the raw word after the opcode; do not disassemble it separately.
			ip += 1
		}
	}
}

disasm_append_code_tree :: proc(parts: ^[dynamic]string, code: ^Code, label: string) {
	append(parts, "\n")
	append(parts, label)
	append(parts, "\n")
	append(parts, fmt.tprintf("  params %d\n", code.param_count))
	append(parts, fmt.tprintf("  slots  %d\n", code.frame_slot_count))
	append(parts, fmt.tprintf("  ops    %d\n", len(code.bytecode)))

	disasm_append_code_sections(parts, code)
	disasm_append_code(parts, code)

	for i := 0; i < len(code.child_codes); i += 1 {
		disasm_append_code_tree(parts, code.child_codes[i], fmt.tprintf("%s/F%d", label, i))
	}
}

disassemble_file :: proc(vm: ^VM, path: string) -> string {
	Active_VM = vm
	clear_error(vm)

	resolved_path, resolve_error := filepath.abs(path, context.allocator)
	if resolve_error != nil {
		set_error(fmt.tprintf("read error: could not resolve file `%s`", path))
		return ""
	}
	defer delete(resolved_path)

	source_bytes, read_error := os.read_entire_file(resolved_path, context.allocator)
	if read_error != nil {
		set_error(fmt.tprintf("read error: could not read file `%s`", path))
		return ""
	}
	defer delete(source_bytes)

	forms := read_source(string(source_bytes))
	if Reader.failed { return "" }
	defer delete(forms)

	code := compile_forms(forms[:], resolved_path)
	if Compiler.failed { return "" }
	defer delete_code(code)

	parts := make([dynamic]string)
	defer delete(parts)

	append(&parts, resolved_path)
	append(&parts, "\n")
	disasm_append_code_tree(&parts, code, "root")

	return strings.concatenate(parts[:])
}
