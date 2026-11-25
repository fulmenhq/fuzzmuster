// Command gatecheck backs scripts/deps-check.sh. It is a repository tool,
// not part of the shipped binary.
//
//	gatecheck cgo FILE...   refuse any file that imports "C", in any import
//	                        form and under any build constraint
//	gatecheck replace       read `go mod edit -json` on stdin; refuse any
//	                        replace directive
package main

import (
	"encoding/json"
	"fmt"
	"go/parser"
	"go/token"
	"io"
	"os"
	"strconv"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "cgo":
		err = checkCgo(os.Args[2:])
	case "replace":
		err = checkReplace(os.Stdin)
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: gatecheck cgo FILE... | gatecheck replace < go-mod-edit.json")
	os.Exit(2)
}

// checkCgo parses only the import declarations, so build constraints, import
// names (blank, dot, alias), comments and grouping cannot hide an import of
// "C". A file that does not parse is refused: it cannot be verified.
func checkCgo(files []string) error {
	fset := token.NewFileSet()
	var bad []string
	for _, f := range files {
		ast, err := parser.ParseFile(fset, f, nil, parser.ImportsOnly)
		if err != nil {
			return fmt.Errorf("cannot parse %s: %v", f, err)
		}
		for _, imp := range ast.Imports {
			path, err := strconv.Unquote(imp.Path.Value)
			if err != nil {
				return fmt.Errorf("%s: bad import path %s", f, imp.Path.Value)
			}
			if path == "C" {
				bad = append(bad, fmt.Sprintf("%s imports \"C\"; cgo is not allowed", fset.Position(imp.Pos())))
			}
		}
	}
	for _, b := range bad {
		fmt.Fprintln(os.Stderr, "error:", b)
	}
	if len(bad) > 0 {
		return fmt.Errorf("%d cgo import(s)", len(bad))
	}
	return nil
}

type goMod struct {
	Replace []struct {
		Old struct{ Path, Version string }
		New struct{ Path, Version string }
	}
}

// checkReplace refuses every replace directive: a replace builds other code
// under a listed module path, which the module listing cannot see.
func checkReplace(r io.Reader) error {
	var m goMod
	if err := json.NewDecoder(r).Decode(&m); err != nil {
		return fmt.Errorf("cannot read go mod edit -json: %v", err)
	}
	for _, rep := range m.Replace {
		fmt.Fprintf(os.Stderr, "error: go.mod replaces %s with %s %s\n", rep.Old.Path, rep.New.Path, rep.New.Version)
	}
	if len(m.Replace) > 0 {
		return fmt.Errorf("replace directives are not allowed")
	}
	return nil
}
