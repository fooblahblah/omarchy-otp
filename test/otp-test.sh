#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const otp = requireFromRoot('OtpLogic.js')
const corpus = JSON.parse(fs.readFileSync(path.join(root, 'test/corpus.json'), 'utf8'))

for (const entry of corpus) {
  const result = otp.extract(entry.text, entry.ocr === true)
  const actual = result.status === 'ok' ? result.code : null
  assertEqual(actual, entry.expect, `otp extracts the code from ${entry.name}`)
}

// Ambiguity is reported rather than guessed at.
const tie = otp.extract('Code 445566 is your login code. Backup code 778899.')
assert(tie.status === 'ok' || tie.status === 'ambiguous', 'otp resolves or refuses two labelled codes')

const bare = otp.extract('483920 903218')
assertEqual(bare.status, 'none', 'otp refuses two adjacent unlabelled numbers')

// The newest notification carrying a code wins.
const picked = otp.extractFromNotifications([
  { app: 'kitty', summary: 'Claude Code', body: 'Claude is waiting for your input' },
  { app: 'Beeper', summary: 'Chase', body: 'Your verification code is 483920.' }
])
assertEqual(picked.code, '483920', 'otp skips notifications without a code')
assertEqual(picked.app, 'Beeper', 'otp reports which app carried the code')

const none = otp.extractFromNotifications([{ app: 'kitty', summary: 'Build', body: 'done' }])
assertEqual(none.status, 'none', 'otp reports nothing when no notification carries a code')

// Nothing past the ceilings is looked at, so a hostile text costs a bounded
// amount of work and cannot push a real code out with decoys.
const padding = 'y'.repeat(otp.MAX_TEXT_LENGTH)
assertEqual(otp.extract(padding + ' code 123456').status, 'none', 'otp ignores text beyond MAX_TEXT_LENGTH')

const flood = Array.from({ length: otp.MAX_CANDIDATES * 2 }, (_, i) => String(100000 + i)).join(' ')
assert(otp.candidates(flood).length <= otp.MAX_CANDIDATES, 'otp considers at most MAX_CANDIDATES matches')

const filler = Array.from({ length: otp.MAX_ENTRIES }, () => ({ app: 'x', summary: 'Build', body: 'done' }))
const late = otp.extractFromNotifications(filler.concat([{ app: 'late', body: 'code 654321' }]))
assertEqual(late.status, 'none', 'otp reads at most MAX_ENTRIES notifications')
assertEqual(otp.extract(null).status, 'none', 'otp treats a missing text as empty')

// The QML engine has no lookbehind; keep it out of the source entirely.
const source = fs.readFileSync(path.join(root, 'OtpLogic.js'), 'utf8')
assert(!source.includes('(?<'), 'OtpLogic.js avoids lookbehind and named groups the QML engine rejects')
assert(!source.includes('.matchAll('), 'OtpLogic.js avoids String.matchAll, which the QML engine lacks')
JS
