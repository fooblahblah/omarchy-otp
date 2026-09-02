// One-time passcode service for the Omarchy shell.
//
// The shell already is the notification server, and the notifications plugin
// persists every notification as JSON on disk. So this plugin needs no watcher
// and no daemon: it reads those files when the hotkey fires, finds the newest
// notification carrying a passcode, and puts it on the clipboard. Nothing is
// copied until asked for, which keeps codes out of clipboard history.
//
// Every helper runs under timeout(1): it owns the deadline, and when the shell
// stops a Process (or the deadline passes) it signals the helper's whole
// process group, so hyprpicker, slurp, grim, tesseract and jq never outlive
// the hotkey that started them. A Timer per helper backs that up from this side.

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
  // wasted work. The scan script enforces its own ceilings on top of this.
  readonly property int scanLimit: 20

  // Deadlines, in seconds. The scan is disk and jq only. OCR includes the user
  // drawing a selection, so it gets long enough to not feel rushed.
  readonly property int scanDeadline: 10
  readonly property int ocrDeadline: 90
  readonly property int helperDeadline: 5
  // Anything a helper prints beyond this is treated as no output at all; the
  // scripts cap themselves well below it.
  readonly property int maxOutputChars: 262144

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")

  // timeout(1) sends SIGTERM to the helper's process group at the deadline or
  // when it is itself told to stop, then SIGKILL two seconds later for anything
  // that ignored it.
  function withDeadline(seconds, argv) {
    return ["timeout", "-k", "2", String(seconds)].concat(argv)
  }

  // Toasts never show the code itself, nor any candidate for it. The clipboard
  // is the delivery mechanism; printing digits would persist them into
  // notification history, which for the OCR path otherwise never touches disk.
  function maskOf(code) {
    var out = ""
    for (var i = 0; i < code.length; i++) out += "•"
    return out
  }

  function notify(headline, description, glyph) {
    notifyProc.command = withDeadline(helperDeadline,
      ["omarchy-notification-send", "--app-name", "otp",
       "-g", glyph || "󰯄", "-t", "4000", headline, description || ""])
    notifyProc.running = true
  }

  // The code goes to wl-copy over stdin, never argv, so it is not visible in
  // the process table for the moment wl-copy runs.
  function deliver(code, source) {
    copyProc.pending = code
    copyProc.stdinEnabled = true
    copyProc.running = true
    notify("Copied 2FA code", maskOf(code) + " · from " + source, "󰅍")
  }

  function report(result, source) {
    if (result.status === "ok") {
      deliver(result.code, result.app ? result.app : source)
      return
    }
    if (result.status === "ambiguous") {
      notify("Ambiguous code", result.candidates.length + " numbers scored alike in "
        + (result.app ? result.app : source) + " — nothing copied.", "󰀦")
      return
    }
    notify("No code found", source === "OCR"
      ? "Couldn't spot a passcode in that region."
      : "No recent notification carried a passcode.", "󰀦")
  }

  // stdout and the exit code arrive as separate signals in no guaranteed
  // order, so each helper records both and acts once it has the pair.
  function bounded(text) {
    var out = String(text || "")
    return out.length > maxOutputChars ? "" : out
  }

  // Newest first, across live popups and history, as a single JSON array.
  Process {
    id: scanProc
    property int exitCode: -1
    property var output: null

    command: service.withDeadline(service.scanDeadline,
      [service.pluginDir + "otp-scan-notifications", service.notificationDir, String(service.scanLimit)])
    stdout: StdioCollector {
      onStreamFinished: {
        scanProc.output = service.bounded(text)
        scanProc.settle()
      }
    }
    onStarted: {
      exitCode = -1
      output = null
      scanWatchdog.restart()
    }
    onExited: (code, status) => {
      scanWatchdog.stop()
      exitCode = status === 0 ? code : 255
      settle()
    }

    function settle() {
      if (exitCode < 0 || output === null) return
      if (exitCode === 124) {
        service.notify("Timed out", "Reading notifications took too long.", "󰀦")
        return
      }
      var entries = []
      try {
        entries = JSON.parse(exitCode === 0 ? output : "[]")
      } catch (e) {
        entries = []
      }
      if (!Array.isArray(entries)) entries = []
      service.report(OtpLogic.extractFromNotifications(entries, false), "notifications")
    }
  }

  Process {
    id: ocrProc
    property int exitCode: -1
    property var output: null

    command: service.withDeadline(service.ocrDeadline, [service.pluginDir + "otp-capture-text"])
    stdout: StdioCollector {
      onStreamFinished: {
        ocrProc.output = service.bounded(text)
        ocrProc.settle()
      }
    }
    onStarted: {
      exitCode = -1
      output = null
      ocrWatchdog.restart()
    }
    onExited: (code, status) => {
      ocrWatchdog.stop()
      exitCode = status === 0 ? code : 255
      settle()
    }

    function settle() {
      if (exitCode < 0 || output === null) return
      // 1 is slurp cancelled: the user changed their mind, so say nothing.
      if (exitCode === 1) return
      if (exitCode === 124) {
        service.notify("Timed out", "The selection was not finished in time.", "󰀦")
        return
      }
      if (exitCode !== 0) {
        service.notify("OCR failed", "Couldn't capture or read that region.", "󰀦")
        return
      }
      var captured = output.trim()
      if (captured === "") {
        service.notify("No text found", "OCR read nothing in that region.", "󰀦")
        return
      }
      service.report(OtpLogic.extract(captured, true), "OCR")
    }
  }

  // Backstops for the deadlines timeout(1) already enforces: stopping the
  // Process sends SIGTERM to timeout, which forwards it to the whole group.
  Timer {
    id: scanWatchdog
    interval: (service.scanDeadline + 5) * 1000
    onTriggered: scanProc.running = false
  }
  Timer {
    id: ocrWatchdog
    interval: (service.ocrDeadline + 5) * 1000
    onTriggered: ocrProc.running = false
  }

  Process {
    id: copyProc
    property string pending: ""
    command: service.withDeadline(service.helperDeadline, ["wl-copy", "--sensitive"])
    onStarted: {
      write(pending)
      pending = ""
      // Closing stdin is what tells wl-copy the content is complete.
      stdinEnabled = false
    }
  }

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
