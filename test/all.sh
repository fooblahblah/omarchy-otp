#!/bin/bash

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

for test_file in \
  otp-test.sh \
  qml-engine-test.sh \
  watch-test.sh \
  capture-langs-test.sh; do
  "$root/test/$test_file"
done
