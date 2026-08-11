#!/usr/bin/env bash
# Lightweight automated checks for Phase 1–2 (no UI).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

pass=0
fail=0
check() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    echo "  PASS  $name"
    pass=$((pass + 1))
  else
    echo "  FAIL  $name"
    fail=$((fail + 1))
  fi
}

echo "==> Phase 1–2 smoke (fixtures + parse helpers)"

TEST_DIR="$ROOT/docs/samples/phase12-test"
check "TEST.md exists" "[[ -f \"$TEST_DIR/TEST.md\" ]]"
check "sample.png exists" "[[ -f \"$TEST_DIR/assets/sample.png\" ]]"
check "dot.png exists" "[[ -f \"$TEST_DIR/assets/dot.png\" ]]"

# Image markdown lines present
check "relative image syntax in TEST.md" "grep -q '!\\[Sample diagram\\](assets/sample.png)' \"$TEST_DIR/TEST.md\""
check "task list syntax in TEST.md" "grep -q '\\- \\[ \\] Unchecked' \"$TEST_DIR/TEST.md\""
check "nested list indent in TEST.md" "grep -qE '^  - Child' \"$TEST_DIR/TEST.md\""
check "swift fence in TEST.md" "grep -q 'swift' \"$TEST_DIR/TEST.md\" && grep -q 'func greet' \"$TEST_DIR/TEST.md\""

# Pure regex checks mirroring MarkdownImage.matchImagePrefix
python3 - <<'PY'
import re, sys
pat = re.compile(r'^!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)')
samples = [
    ('![alt](assets/x.png)', True, 'alt', 'assets/x.png'),
    ('![](data:image/png;base64,aaa)', True, '', 'data:image/png;base64,aaa'),
    ('[not](img.png)', False, None, None),
    ('![a](b.png) tail', True, 'a', 'b.png'),
]
ok = True
for s, expect, alt, src in samples:
    m = pat.match(s)
    got = m is not None
    if got != expect:
        print(f'  FAIL  regex match {s!r}')
        ok = False
        continue
    if expect and m:
        if m.group(1) != alt or m.group(2) != src:
            print(f'  FAIL  groups for {s!r}: {m.groups()}')
            ok = False
if ok:
    print('  PASS  image markdown regex')
sys.exit(0 if ok else 1)
PY

echo ""
echo "Results: $pass checks named above + regex (see FAIL lines if any)"
echo "Build check next via xcodebuild…"
