// What protobuf-go's protowire makes of the varints and tags in cases.txt (hex, one per line),
// to compare with tests/interop/gopb/cmp.nim (see the comment there):
//
//	cp go.mod.example go.mod && go run . < cases.txt
package main

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"os"
	"strings"

	"google.golang.org/protobuf/encoding/protowire"
)

func main() {
	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		b, err := hex.DecodeString(strings.ReplaceAll(line, " ", ""))
		if err != nil {
			panic(err)
		}
		v, n := protowire.ConsumeVarint(b)
		var out string
		if n < 0 {
			out = "err"
		} else {
			out = fmt.Sprintf("ok %d", v)
		}
		num, typ, tn := protowire.ConsumeTag(b)
		var tout string
		if tn < 0 {
			tout = "err"
		} else {
			tout = fmt.Sprintf("ok field=%d wt=%d", num, typ)
		}
		fmt.Printf("%-44s varint: %-22s tag: %s\n", line, out, tout)
	}
}
