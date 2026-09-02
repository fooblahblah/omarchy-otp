// One-time passcode service for the Omarchy shell.
//
// The shell already is the notification server, and the notifications plugin
// persists every notification as JSON on disk. So this plugin needs no watcher
// and no daemon: it reads those files when the hotkey fires, finds the newest
// notification carrying a passcode, and puts it on the clipboard. Nothing is
// copied until asked for, which keeps codes out of clipboard history.

import QtQuick
import Quickshell
import Quickshell.Io
import "OtpLogic.js" as OtpLogic

Item {
  id: service

  // Injected by omarchy-shell's service loader.
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  // Live popups sit directly in this directory; anything dismissed, expired or
  // acted upon is moved into history/. Reading both is what makes the hotkey
  // work long after the toast has gone.
  readonly property string notificationDir: home + "/.local/state/omarchy/notifications/"
  // The notifications plugin keeps 10 history entries, so scanning further is
  // wasted work.
  readonly property int scanLimit: 20

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")

  // Toasts never show the code itself. The clipboard is the delivery mechanism;
  // printing the digits would persist them into notification history for the
  // OCR path, which otherwise never touches disk.
  function maskOf(code) {
    var out = ""
    for (var i = 0; i < code.length; i++) out += "•"
    return out
  }

  function notify(headline, description, glyph) {
    notifyProc.command = ["omarchy-notification-send", "--app-name", "otp",
                          "-g", glyph || "󰯄", "-t", "4000", headline, description || ""]
    notifyProc.running = true
  }

  function deliver(code, source) {
    copyProc.command = ["wl-copy", code]
    copyProc.running = true
    notify("Copied 2FA code", maskOf(code) + " · from " + source, "󰅍")
  }

  function report(result, source) {
    if (result.status === "ok") {
      deliver(result.code, result.app ? result.app : source)
      return
    }
    if (result.status === "ambiguous") {
      var codes = []
      for (var i = 0; i < result.candidates.length; i++) codes.push(result.candidates[i].code)
      notify("Ambiguous code", "Candidates: " + codes.join(", ") + " — nothing copied.", "󰀦")
      return
    }
    notify("No code found", source === "OCR"
      ? "Couldn't spot a passcode in that region."
      : "No recent notification carried a passcode.", "󰀦")
  }

  // Newest first, across live popups and history, as a single JSON array.
  Process {
    id: scanProc
    command: ["bash", "-c",
      'd="$1"; limit="$2"; ' +
      'files=$(ls -t "$d"*.json "$d"history/*.json 2>/dev/null | head -"$limit"); ' +
      '[ -z "$files" ] && { echo "[]"; exit 0; }; ' +
      'printf "%s\\n" "$files" | tr "\\n" "\\0" | ' +
      'xargs -0 -r jq -s "[.[] | {app, summary, body, timestamp}]" 2>/dev/null || echo "[]"',
      "bash", service.notificationDir, String(service.scanLimit)]
    stdout: StdioCollector {
      onStreamFinished: {
        var entries = []
        try {
          entries = JSON.parse(String(text || "[]"))
        } catch (e) {
          entries = []
        }
        service.report(OtpLogic.extractFromNotifications(entries, false), "notifications")
      }
    }
  }

  Process {
    id: ocrProc
    command: [service.pluginDir + "otp-capture-text"]
    stdout: StdioCollector {
      onStreamFinished: {
        var captured = String(text || "").trim()
        if (captured === "") {
          service.notify("No text found", "OCR read nothing in that region.", "󰀦")
          return
        }
        service.report(OtpLogic.extract(captured, true), "OCR")
      }
    }
  }

  Process { id: copyProc }
  Process { id: notifyProc }

  IpcHandler {
    target: "otp"

    // Copy the passcode from the most recent notification that carries one.
    function copyLast(): string {
      if (scanProc.running) return "busy"
      scanProc.running = true
      return "ok"
    }

    // Select a region of the screen and copy the passcode OCR finds there.
    function copyRegion(): string {
      if (ocrProc.running) return "busy"
      ocrProc.running = true
      return "ok"
    }
  }
}
