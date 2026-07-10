package main

import "core:fmt"
import "core:os"
import "core:strings"
import "obel"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: obel <file> [arg...]")
		fmt.eprintln("         obel eval <string>")
		fmt.eprintln("         obel dis <file>")
		os.exit(1)
	}

	if os.args[1] == "eval" {
		if len(os.args) != 3 {
			fmt.eprintln("usage: obel eval <string>")
			os.exit(1)
		}

		vm := obel.make_vm()
		obel.set_argv(&vm, os.args, 3)
		result := obel.run_string(&vm, os.args[2])

		if vm.error_string != "" {
			fmt.eprintln(vm.error_string)
			os.exit(1)
		}

		obel.print_value(result)
		fmt.println()
		return
	}

	if os.args[1] == "dis" {
		if len(os.args) != 3 {
			fmt.eprintln("usage: obel dis <file>")
			os.exit(1)
		}

		path_arg := os.args[2]
		source_path := path_arg

		if !os.exists(source_path) && !strings.has_suffix(path_arg, ".obel") {
			source_path = fmt.tprintf("%s.obel", path_arg)
		}

		vm := obel.make_vm()
		obel.set_argv(&vm, os.args, 3)

		disassembly := obel.disassemble_file(&vm, source_path)
		if vm.error_string != "" {
			fmt.eprintln(vm.error_string)
			os.exit(1)
		}
		defer delete(disassembly)

		fmt.print(disassembly)
		return
	}

	path_arg := os.args[1]
	source_path := path_arg

	if !os.exists(source_path) && !strings.has_suffix(path_arg, ".obel") {
		source_path = fmt.tprintf("%s.obel", path_arg)
	}

	vm := obel.make_vm()
	obel.set_argv(&vm, os.args, 2)
	_ = obel.run_file(&vm, source_path)

	if vm.error_string != "" {
		fmt.eprintln(vm.error_string)
		os.exit(1)
	}
}
