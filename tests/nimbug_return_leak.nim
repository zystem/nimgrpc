## A string made into `result` is lost when the proc then returns a literal: `return ""` after
## `result = newString(n)`. Nim 2.4.0, ORC. Built with AddressSanitizer it reports
## "4900 byte(s) leaked in 100 allocation(s)" for the 100 calls below (docs/nim-compiler-notes.md, 3).
##
##   nim c -d:useMalloc --passC:-fsanitize=address --passL:-fsanitize=address tests/nimbug_return_leak.nim
##   ASAN_OPTIONS=detect_leaks=1 tests/nimbug_return_leak

proc leaks(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    if result[i] == '\0': return ""     # the buffer made above is not freed

proc fine(n: int): string =
  for i in 0 ..< n:                     # check first, make the string only when it is wanted
    if i == 3: return ""
  newString(n)

var total = 0
for i in 0 ..< 100:
  total += leaks(40).len
  total += fine(40).len
echo total
