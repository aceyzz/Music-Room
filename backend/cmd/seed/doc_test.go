package main

import (
	"os"
	"testing"
)

// The committed doc must be what the seeder would write. When this fails,
// run `make seed-doc` and commit the result.
func TestDocIsUpToDate(t *testing.T) {
	committed, err := os.ReadFile("../../../docs/annex/init_script_doc.md")
	if err != nil {
		t.Fatalf("read the doc: %v (run `make seed-doc`)", err)
	}
	if string(committed) != renderDoc(Build(docNow)) {
		t.Fatal("docs/annex/init_script_doc.md is stale: run `make seed-doc`")
	}
}
