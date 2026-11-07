#!/bin/bash

# The watcher turns busctl's monitor stream into one short line per
# notification. It has to survive whatever else is on that stream, drop the
# hints (image data included) before they reach the shell, and cap each field.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

WATCH="$ROOT/otp-watch-notifications"

# A Notify call as busctl --user monitor --json=short prints it, with the
# arguments as given and an optional extra hint.
notify_line() {
  local app="$1" summary="$2" body="$3" hints="${4:-{\}}"
  jq -cn --arg app "$app" --arg summary "$summary" --arg body "$body" --argjson hints "$hints" '{
    type: "method_call", sender: ":1.1", destination: ":1.2",
    path: "/org/freedesktop/Notifications", interface: "org.freedesktop.Notifications",
    member: "Notify",
    payload: {type: "susssasa{sv}i", data: [$app, 0, "", $summary, $body, [], $hints, -1]}
  }'
}

image='{"image-data":{"type":"(iiibiiay)","data":[64,64,256,true,8,4,[]]}}'
image=$(jq -c '.["image-data"].data[6] = [range(0; 16384) | . % 256]' <<<"$image")
long=$(head -c 6000 /dev/zero | tr '\0' 'y')

out=$(
  {
    echo "Monitoring bus message stream."
    notify_line "notify-send" "Chase" "Your verification code is 483920."
    echo '{"member": "Notify", "payload": {"data": ["broken"'
    echo '{"type":"method_call","member":"CloseNotification","payload":{"type":"u","data":[7]}}'
    echo '{"type":"method_call","member":"Notify","payload":{"type":"s","data":"not an array"}}'
    notify_line "Chromium" "Bank" "code 112233" "$image"
    notify_line "long" "s" "$long code 999999"
    echo '{"member":"Notify","payload":{"data":[5,0,"",{"a":1},null,[],{},-1]}}'
  } | "$WATCH" --filter
)

count=$(printf '%s\n' "$out" | grep -c .)
[[ $count == 4 ]] || fail "watch emits one line per Notify call and skips everything else" "$out"
pass "watch emits one line per Notify call and skips everything else"

first=$(printf '%s\n' "$out" | sed -n 1p)
[[ $first == '{"app":"notify-send","summary":"Chase","body":"Your verification code is 483920."}' ]] \
  || fail "watch keeps app, summary and body" "$first"
pass "watch keeps app, summary and body"

printf '%s\n' "$out" | jq -e -s 'all(.[]; keys == ["app", "body", "summary"] and all(.[]; type == "string"))' >/dev/null \
  || fail "watch emits only three string fields" "$out"
pass "watch emits only three string fields"

imaged=$(printf '%s\n' "$out" | sed -n 2p)
[[ $imaged == '{"app":"Chromium","summary":"Bank","body":"code 112233"}' ]] \
  || fail "watch reads a notification carrying image data and drops the image" "$imaged"
pass "watch reads a notification carrying image data and drops the image"

bodylen=$(printf '%s\n' "$out" | sed -n 3p | jq '.body | length')
[[ $bodylen == 4096 ]] || fail "watch truncates bodies to 4096 characters" "got $bodylen"
pass "watch truncates bodies to 4096 characters"

odd=$(printf '%s\n' "$out" | sed -n 4p)
[[ $odd == '{"app":"5","summary":"{\"a\":1}","body":""}' ]] \
  || fail "watch coerces wrongly typed arguments to strings" "$odd"
pass "watch coerces wrongly typed arguments to strings"

# Lines arrive as they are sent, not when the stream ends: the plugin acts on
# each one while the stream stays open.
fifo_dir=$(mktemp -d)
trap 'rm -rf "$fifo_dir"' EXIT
mkfifo "$fifo_dir/in"
"$WATCH" --filter < "$fifo_dir/in" > "$fifo_dir/out" &
watcher=$!
exec 3> "$fifo_dir/in"
notify_line "app" "s" "code 123456" >&3
for _ in $(seq 1 50); do
  [[ -s $fifo_dir/out ]] && break
  sleep 0.1
done
exec 3>&-
wait "$watcher" || true
[[ -s $fifo_dir/out ]] || fail "watch flushes each line while the stream is still open"
pass "watch flushes each line while the stream is still open"
