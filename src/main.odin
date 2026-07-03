package main

import "core:fmt"
import "core:os"
import "core:strings"


main :: proc() {
	vm: VM
	vm.globals = make([dynamic]GlobalBinding)
	vm.symbols = make([dynamic]^SymbolObject)
	install_builtins(&vm)

	if len(os.args) == 2 && os.args[1] != "eval" {
		path_arg := os.args[1]
		source_path := path_arg

		if !os.exists(source_path) && !strings.has_suffix(path_arg, ".wisp") {
			source_path = fmt.tprintf("%s.wisp", path_arg)
		}

		_ = run_file(&vm, source_path)
	} else if len(os.args) == 3 && os.args[1] == "eval" {
		result := run_string(&vm, os.args[2])
		if vm.error_string == "" {
			print_value(result)
			fmt.println()
		}
	} else {
		fmt.eprintln("usage: wisp <file>")
		fmt.eprintln("       wisp eval <string>")
		os.exit(1)
	}

	if vm.error_string != "" {
		fmt.eprintln(vm.error_string)
		os.exit(1)
	}
}
