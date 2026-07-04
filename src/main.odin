package main

import "core:fmt"
import "core:os"
import "core:strings"
import "rite"

main :: proc() {
	if len(os.args) == 3 && os.args[1] == "eval" {
		vm := rite.make_vm()
		result := rite.run_string(&vm, os.args[2])

		if vm.error_string != "" {
			fmt.eprintln(vm.error_string)
			os.exit(1)
		}

		rite.print_value(result)
		fmt.println()
		return
	}

	if len(os.args) != 2 {
		fmt.eprintln("usage: rite <file>")
		fmt.eprintln("         rite eval <string>")
		os.exit(1)
	}

	path_arg := os.args[1]
	source_path := path_arg

	if !os.exists(source_path) && !strings.has_suffix(path_arg, ".rite") {
		source_path = fmt.tprintf("%s.rite", path_arg)
	}

	vm := rite.make_vm()
	_ = rite.run_file(&vm, source_path)

	if vm.error_string != "" {
		fmt.eprintln(vm.error_string)
		os.exit(1)
	}
}
