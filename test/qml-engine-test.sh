#!/bin/bash

# Runs the shared corpus through Qt's QML JavaScript engine, which is a
# stricter target than Node: Qt 6.11 has no lookbehind, no named capture
# groups and no String.matchAll, and a regex it rejects throws at construction.
# The Node suite would happily pass on syntax the shell cannot load, so this
# check is what makes the port trustworthy.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command qml6
require_command node

WORK=$(mktemp -d)
export WORK
trap 'rm -rf "$WORK"' EXIT

node -e '
const fs = require("fs")
const root = process.env.ROOT
const corpus = fs.readFileSync(root + "/test/corpus.json", "utf8")
const qml = `import QtQml
import "file://${root}/OtpLogic.js" as Otp

QtObject {
  Component.onCompleted: {
    var corpus = ${corpus};
    for (var i = 0; i < corpus.length; i++) {
      var entry = corpus[i];
      var result = Otp.extract(entry.text, entry.ocr === true);
      var actual = result.status === "ok" ? result.code : null;
      var expected = entry.expect === undefined ? null : entry.expect;
      if (actual !== expected) { Qt.exit(10 + i); return; }
    }
    Qt.exit(0);
  }
}
`
fs.writeFileSync(process.env.WORK + "/EngineCheck.qml", qml)
'

set +e
QT_QPA_PLATFORM=offscreen qml6 "$WORK/EngineCheck.qml" >/dev/null 2>&1
STATUS=$?
set -e

if (( STATUS == 0 )); then
  pass "the QML engine loads OtpLogic.js and matches the corpus"
elif (( STATUS >= 10 )); then
  INDEX=$(( STATUS - 10 ))
  NAME=$(node -e 'const c=require(process.env.ROOT+"/test/corpus.json"); console.log(c[process.argv[1]].name)' "$INDEX")
  fail "the QML engine matches the corpus" "QML disagreed with Node on case $INDEX: $NAME"
else
  fail "the QML engine loads OtpLogic.js" "qml6 exited $STATUS -- the engine rejected the file (run without redirects to see why)"
fi
