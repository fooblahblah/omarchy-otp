# One-Time Codes

An Omarchy shell plugin that copies the 2FA code out of your most recent
notification with a hotkey — or, when the code never arrives as a notification,
out of any region of the screen via OCR.

Nothing is copied until you ask for it, so codes stay out of your clipboard
history until the moment you need one.

## Why there is no daemon

The Omarchy shell *is* the notification server, and its notifications plugin
already persists every notification as JSON under
`~/.local/state/omarchy/notifications/` — live popups in that directory, and
everything dismissed or expired in `history/`.

So this plugin reads those files when the hotkey fires instead of watching a
bus. That means no background process, no systemd unit, no state file of its
own, and no expiry bookkeeping. It also means the hotkey still works long after
the toast has disappeared: dismissing a notification moves it into history
rather than deleting it.

The notifications plugin keeps 10 history entries, which bounds how far back a
code can be recovered.

## What it will not do

The code is the only secret here, and it stays on one path: file → heuristic →
clipboard.

- It reaches `wl-copy` over stdin, never as an argument, so it is not visible
  in the process table, and it is copied with the `--sensitive` hint so
  clipboard managers that honour it keep it out of their history.
- Toasts show the code masked. When two numbers score alike the toast says so
  and copies nothing; the candidates themselves are never printed, since
  notification text is persisted to disk.
- Every helper runs under `timeout(1)`, which signals the helper's whole
  process group at the deadline (10 s for the notification scan, 90 s for the
  OCR path including the time you take to draw the selection) or when the
  shell stops it, and escalates to `SIGKILL` two seconds later. So
  `hyprpicker`, `slurp`, `grim`, `tesseract` and `jq` never outlive the hotkey
  that started them.
- Everything read is bounded before it is buffered: at most 20 notification
  files (hard ceiling 64), 64 KiB read from each, 4096 characters of body kept,
  64 candidate numbers considered per text, 64 KiB of OCR output. Filenames are
  handled as opaque bytes end to end.
- `OMARCHY_OCR_LANGS` is validated as a plain tesseract language list
  (`eng`, `deu+eng`, `chi_sim+eng`, at most four entries) before it goes near
  `tesseract`'s argv; anything else falls back to `eng`.

## Install

```bash
omarchy plugin add https://github.com/fooblahblah/omarchy-otp --enable --yes
```

Then bind the hotkeys in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + O", "Copy 2FA code", "omarchy-shell otp copyLast")
o.bind("SUPER + SHIFT + ALT + O", "Copy 2FA code (OCR)", "omarchy-shell otp copyRegion")
```

`SUPER+ALT+O` sits next to Omarchy's own `SUPER+ALT+COMMA` ("invoke last
notification") on purpose — both act on the notification you just received.

## Requirements

Everything this plugin shells out to already ships with Omarchy — there is
nothing extra to install. Omarchy's own `omarchy capture text` uses the same
OCR chain.

| Command | Package | Used for |
|---|---|---|
| `jq` | `jq` | Reading the notification JSON the shell persists |
| `wl-copy` | `wl-clipboard` | Putting the code on the clipboard |
| `timeout`, `stat`, `sort`, `head` | `coreutils` | Deadlines and bounded reads |
| `pkill` | `procps-ng` | Tearing down the OCR helpers |
| `hyprpicker`, `slurp`, `grim`, `tesseract` | same names, `tesseract` | The OCR path only (`copyRegion`) |

Set `OMARCHY_OCR_LANGS` (for example `deu+eng`) to OCR in a language other than
English. It is the same variable Omarchy's own `omarchy capture text` reads.

## Removing

```bash
omarchy plugin remove fooblahblah.otp --yes
```

Then delete the two `o.bind` lines for `SUPER + ALT + O` and
`SUPER + SHIFT + ALT + O` from `~/.config/hypr/bindings.lua`, and reload with
`hyprctl reload`.

The plugin writes no state of its own — no config file, no cache, no daemon —
so removing it leaves nothing behind.

## IPC

| Call | Effect |
|---|---|
| `omarchy shell otp copyLast` | Copy the code from the newest notification that carries one |
| `omarchy shell otp copyRegion` | Select a screen region, OCR it, copy the code found there |

## How a code is chosen

Extraction is a scored heuristic, not a model. The hard part is not reading the
message but telling the code apart from the phone number, the dollar amount and
the "expires in 10 minutes" in the same text, which is what regex with
keyword-proximity scoring is good at.

A model was considered and rejected: it would add seconds of latency to a
hotkey that must feel instant, and — the deciding factor — a transposed digit
is a silent failure you discover only when the login is rejected. When the
scores cannot separate the top two candidates, the plugin refuses and says so
rather than guessing.

Signals it uses: proximity to words like *code*, *verification*, *passcode*;
Google's `G-123456` and Apple's `#123456` autofill conventions; a strong
preference for six digits; and penalties for numbers that sit inside a phone
number, a time, a currency amount, or next to words like *account ending in*.
On the OCR path only, digit-shaped tokens are repaired for common confusions
(`O`→`0`, `l`→`1`, `S`→`5`).

Toasts show the code masked. The clipboard is the delivery mechanism, and
printing the digits would write them into notification history.

The heuristic only ever looks at the first 4096 characters of a text and the
first 64 number-shaped tokens in it; a passcode lives near the top of a
message, and a text with hundreds of candidates is not carrying one.

## Tests

```bash
./test/all.sh
```

`otp-test.sh` runs the shared corpus in `test/corpus.json` under Node, plus
the ceilings on text length, candidates and entries.
`qml-engine-test.sh` runs the *same* corpus through Qt's QML JavaScript engine,
which is the stricter target: Qt 6.11 has no lookbehind, no named capture
groups and no `String.matchAll`, and a regex it rejects throws at construction.
Node alone would happily pass syntax the shell cannot load, so both runs must
agree.
`scan-test.sh` points `otp-scan-notifications` at a directory of awkward
files — spaces, tabs and newlines in names, malformed JSON, a 100 KiB body —
and checks the ordering, the truncation and the ceilings.
`capture-langs-test.sh` feeds `otp-capture-text` hostile `OMARCHY_OCR_LANGS`
values and checks each falls back to `eng`.

## License

MIT
