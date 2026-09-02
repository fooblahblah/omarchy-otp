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
scores cannot separate the top two candidates, the plugin refuses and shows
them rather than guessing.

Signals it uses: proximity to words like *code*, *verification*, *passcode*;
Google's `G-123456` and Apple's `#123456` autofill conventions; a strong
preference for six digits; and penalties for numbers that sit inside a phone
number, a time, a currency amount, or next to words like *account ending in*.
On the OCR path only, digit-shaped tokens are repaired for common confusions
(`O`→`0`, `l`→`1`, `S`→`5`).

Toasts show the code masked. The clipboard is the delivery mechanism, and
printing the digits would write them into notification history.

## Tests

```bash
./test/all.sh
```

`otp-test.sh` runs the shared corpus in `test/corpus.json` under Node.
`qml-engine-test.sh` runs the *same* corpus through Qt's QML JavaScript engine,
which is the stricter target: Qt 6.11 has no lookbehind, no named capture
groups and no `String.matchAll`, and a regex it rejects throws at construction.
Node alone would happily pass syntax the shell cannot load, so both runs must
agree.

## License

MIT
