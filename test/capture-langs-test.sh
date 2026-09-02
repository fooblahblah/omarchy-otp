#!/bin/bash

# OMARCHY_OCR_LANGS is user-controlled text that ends up in tesseract's argv.
# Only a plain tesseract language list gets through; everything else falls
# back to English.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

CAPTURE="$ROOT/otp-capture-text"

check() {
  local input="$1" expected="$2" description="$3"
  local actual
  if [[ $input == "<unset>" ]]; then
    actual=$(env -u OMARCHY_OCR_LANGS "$CAPTURE" --print-langs)
  else
    actual=$(OMARCHY_OCR_LANGS="$input" "$CAPTURE" --print-langs)
  fi
  [[ $actual == "$expected" ]] || fail "$description" "input:    $input
expected: $expected
actual:   $actual"
  pass "$description"
}

check "<unset>" "eng" "capture defaults to English"
check "eng" "eng" "capture accepts a single language"
check "deu+eng" "deu+eng" "capture accepts a language list"
check "chi_sim+eng" "chi_sim+eng" "capture accepts a script suffix"
check "" "eng" "capture treats an empty value as unset"
check "--list-langs" "eng" "capture refuses a value shaped like an option"
check "eng --user-words /etc/passwd" "eng" "capture refuses embedded arguments"
check "eng;id" "eng" "capture refuses shell metacharacters"
check "../../tmp/x" "eng" "capture refuses path traversal"
check "eng+deu+fra+spa+ita" "eng" "capture refuses more than four languages"
check "$(head -c 200 /dev/zero | tr '\0' 'e')" "eng" "capture refuses an over-long value"
