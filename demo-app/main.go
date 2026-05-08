package main

import (
	"fmt"
	"os"
	"strings"
)

func main() {
	args := os.Args[1:]

	// Minimal help.
	if len(args) == 0 || args[0] == "--help" || args[0] == "help" {
		fmt.Println("demo-app")
		fmt.Println("usage:")
		fmt.Println("  demo-app [--goshbuild-test <sentinel>] [exit42] [args...]")
		return
	}

	// Used by goshbuild acceptance tests to confirm arg forwarding.
	if args[0] == "--goshbuild-test" {
		if len(args) >= 2 {
			fmt.Println(args[1])
			return
		}
		fmt.Println("missing sentinel")
		os.Exit(2)
	}

	// Used to confirm exit-code forwarding.
	if args[0] == "exit42" {
		fmt.Println("exit42")
		os.Exit(42)
	}

	// Default: echo args so callers can observe forwarding.
	fmt.Println(strings.Join(args, " "))
}
