#!/bin/bash

# The scan script reads whatever the notifications plugin left on disk. It has
# to cope with any filename, refuse to buffer more than it promised, and still
# hand the heuristic the newest entries first.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

SCAN="$ROOT/otp-scan-notifications"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

state="$WORK/notifications/"
mkdir -p "$state/history"

# One notification file with a chosen mtime; the app name doubles as a label so
# ordering can be checked from the output alone.
write_note() {
  local path="$1" app="$2" body="$3" when="$4"
  jq -cn --arg app "$app" --arg body "$body" '{app: $app, summary: "s", body: $body, timestamp: 1}' > "$path"
  touch -d "$when" -- "$path"
}

write_note "$state/plain.json"        "plain"   "code 111111" "2026-01-01 00:00:01"
write_note "$state/with space.json"   "space"   "code 222222" "2026-01-01 00:00:02"
write_note "$state/"$'tab\there.json' "tab"     "code 333333" "2026-01-01 00:00:03"
write_note "$state/"$'new\nline.json' "newline" "code 444444" "2026-01-01 00:00:04"
write_note "$state/history/old.json"  "old"     "code 555555" "2025-12-31 00:00:00"
write_note "$state/history/-dash.json" "dash"   "code 666666" "2026-01-01 00:00:05"

# Things that must be skipped, not crash the scan or poison the array.
printf '{"app": "broken", "body": "code 777777"' > "$state/broken.json"
printf '[1, 2, 3]' > "$state/array.json"
printf '"just a string"' > "$state/string.json"
head -c 100000 /dev/zero | tr '\0' 'x' | jq -Rc '{app: "huge", body: ("code 888888 " + .)}' > "$state/huge.json"
touch -d "2025-12-30 00:00:00" -- "$state/broken.json" "$state/array.json" "$state/string.json" "$state/huge.json"

# A body far longer than the ceiling, with the code at the end.
long=$(head -c 6000 /dev/zero | tr '\0' 'y')
jq -cn --arg body "$long code 999999" '{app: "long", summary: "s", body: $body, timestamp: 2}' > "$state/history/long.json"
touch -d "2026-01-01 00:00:00" -- "$state/history/long.json"

out=$("$SCAN" "$state" 20)
printf '%s' "$out" | jq -e 'type == "array"' >/dev/null || fail "scan prints a JSON array" "$out"
pass "scan prints a JSON array"

apps=$(printf '%s' "$out" | jq -r '[.[].app] | join(",")')
assert_apps() {
  [[ $apps == "$1" ]] || fail "$2" "expected: $1
actual:   $apps"
  pass "$2"
}
assert_apps "dash,newline,tab,space,plain,long,old" \
  "scan orders entries newest first across live and history, whatever the filename"

bodylen=$(printf '%s' "$out" | jq '.[] | select(.app == "long") | .body | length')
[[ $bodylen == 4096 ]] || fail "scan truncates bodies to 4096 characters" "got $bodylen"
pass "scan truncates bodies to 4096 characters"

printf '%s' "$out" | jq -e 'all(.[]; (.app|type) == "string" and (.summary|type) == "string" and (.body|type) == "string" and (.timestamp|type) == "number")' >/dev/null \
  || fail "scan emits only the four fields, each with a fixed type" "$out"
pass "scan emits only the four fields, each with a fixed type"

count=$(printf '%s' "$out" | jq 'length')
[[ $count == 7 ]] || fail "scan drops malformed, non-object and oversized files" "got $count entries"
pass "scan drops malformed, non-object and oversized files"

limited=$("$SCAN" "$state" 2 | jq -r '[.[].app] | join(",")')
[[ $limited == "dash,newline" ]] || fail "scan honours the entry limit" "got $limited"
pass "scan honours the entry limit"

capped=$("$SCAN" "$state" 999 | jq 'length')
[[ $capped == 7 ]] || fail "scan ignores an out-of-range limit instead of failing" "got $capped"
pass "scan ignores an out-of-range limit instead of failing"

bogus=$("$SCAN" "$state" "20; rm -rf /" | jq 'length')
[[ $bogus == 7 ]] || fail "scan treats a non-numeric limit as the default" "got $bogus"
pass "scan treats a non-numeric limit as the default"

empty=$("$SCAN" "$WORK/missing/" 20)
[[ $empty == "[]" ]] || fail "scan prints [] for a missing directory" "$empty"
pass "scan prints [] for a missing directory"

# Enumeration is capped per directory before anything is stat'ed or sorted.
flood="$WORK/flood/"
mkdir -p "$flood/history"
for i in $(seq 1 300); do printf '{"app":"n%d","body":"b"}' "$i" > "$flood/$i.json"; done
flooded=$("$SCAN" "$flood" 64 | jq 'length')
[[ $flooded == 64 ]] || fail "scan caps entries at 64 even with hundreds of files" "got $flooded"
pass "scan caps entries at 64 even with hundreds of files"
