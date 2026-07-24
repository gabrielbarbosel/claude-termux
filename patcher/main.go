// patch copies the Claude Code binary from src to dst, rewriting its OAuth
// callback URLs from http://localhost: to http://127.0.0.1:. On Android the
// "localhost" name does not resolve through glibc the way the loopback literal
// does, so the login callback server is unreachable until this is rewritten. The
// replacement is the same length, so every other byte offset is preserved.
//
// Usage: patch <src> <dst>
package main

import (
	"bytes"
	"fmt"
	"os"
)

var (
	oldURL = []byte("http://localhost:${")
	newURL = []byte("http://127.0.0.1:${")
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: patch <src> <dst>")
		os.Exit(2)
	}
	if err := patch(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "patch:", err)
		os.Exit(1)
	}
}

// patch reads src, rewrites the callback URLs in place, and writes dst.
func patch(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	n := bytes.Count(data, oldURL)
	data = bytes.ReplaceAll(data, oldURL, newURL)
	if err := os.WriteFile(dst, data, 0o755); err != nil {
		return err
	}
	fmt.Printf("callback urls rewritten: %d\n", n)
	return nil
}
