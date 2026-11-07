// One-time passcode service for the Omarchy shell.
//
// Every notification is a Notify call on the session bus. A small helper
// watches those calls and hands this service each one's app, title and body;
// the service runs the heuristic on arrival and keeps the newest passcode in
// memory for ten minutes. The hotkey copies that. Nothing is copied until
// asked for, which keeps codes out of clipboard history, and nothing is ever
// written to disk -- the shell itself redacts passcodes from what it persists,
// so there is nothing to read back afterwards anyway.
//
// Every helper runs under timeout(1): when the shell stops a Process (or a
// deadline passes) it signals the helper's whole process group, so busctl,
// hyprpicker, slurp, grim, tesseract and jq never outlive this service or the
// hotkey that started them. A Timer per short-lived helper backs that up.

import QtQuick
import Quickshell
import Quickshell.Io
import "OtpLogic.js" as OtpLogic

Item {
  id: service

  // Injected by omarchy-shell's service loader.
  property var shell: null
  property var manifest: null

  // How long a passcode stays copyable after its notification arrived. Codes
  // themselves rarely live longer, and anything older is more likely to be the
  // wrong number than the one you are waiting for.
  readonly property int codeLifetime: 10 * 60 * 1000

  // The newest notification that carried a passcode (or two numbers too close
  // to call), as OtpLogic reports it, stamped with when it arrived. Memory only.
  property var held: null

  // Deadlines, in seconds. OCR includes the user drawing a selection, so it
  // gets long enough to not feel rushed.
  readonly property int ocrDeadline: 90
  readonly property int helperDeadline: 5
  // Anything a helper prints beyond this is treated as no output at all; the
  // scripts cap themselves well below it.
  readonly property int maxOutputChars: 262144
  // The watcher prints one short line per notification (its fields are capped
  // at 64 + 512 + 4096 characters), so anything much longer is not from it.
  readonly property int maxLineChars: 16384

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")

  // timeout(1) sends SIGTERM to the helper's process group at the deadline or
  // when it is itself told to stop, then SIGKILL two seconds later for anything
  // that ignored it. A deadline of 0 means none: the watcher runs until stopped,
  // and timeout(1) is there only for its process-group teardown.
  function withDeadline(seconds, argv) {
    return ["timeout", "-k", "2", String(seconds)].concat(argv)
  }

  // Toasts never show the code itself, nor any candidate for it. The clipboard
  // is the delivery mechanism; printing digits would put them on screen and in
  // the notification list, which otherwise never hold them.
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
      : "No notification in the last 10 minutes carried a passcode.", "󰀦")
  }

  // stdout and the exit code arrive as separate signals in no guaranteed
  // order, so each helper records both and acts once it has the pair.
  function bounded(text) {
    var out = String(text || "")
    return out.length > maxOutputChars ? "" : out
  }

  // One notification from the watcher: run the heuristic now, while the text
  // exists, and remember the result if it found anything. The plugin's own
  // toasts are skipped; they carry only a masked code, but they are not news.
  function observe(line) {
    var text = String(line || "")
    if (!text || text.length > maxLineChars) return
    var entry = null
    try {
      entry = JSON.parse(text)
    } catch (e) {
      return
    }
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) return
    if (String(entry.app || "") === "otp") return
    var result = OtpLogic.extractFromNotifications([entry], false)
    if (result.status === "none") return
    result.timestamp = Date.now()
    held = result
    forget.restart()
  }

  function copyHeld() {
    var current = held
    // Checked against the clock as well as by the timer, since a timer does
    // not count time spent suspended.
    if (current && Date.now() - current.timestamp <= codeLifetime) {
      report(current, "notifications")
      return
    }
    held = null
    if (!watchProc.running) {
      notify("Not watching notifications", "The notification watcher isn't running, so no code was seen.", "󰀦")
      return
    }
    report({ status: "none" }, "notifications")
  }

  // Drop a passcode from memory once it is too old to copy.
  Timer {
    id: forget
    interval: service.codeLifetime
    onTriggered: service.held = null
  }

  // The watcher runs for as long as this service is loaded. If it exits, it
  // is restarted after a pause that doubles each time it dies young, so a
  // missing busctl costs a retry a minute rather than a busy loop.
  Process {
    id: watchProc
    property real startedAt: 0
    property int retryDelay: 1000

    // setpriv ties timeout(1) to the shell: if the shell dies without stopping
    // it, timeout gets SIGTERM and takes the watcher's group down with it.
    command: ["setpriv", "--pdeathsig", "TERM", "--"]
      .concat(service.withDeadline(0, [service.pluginDir + "otp-watch-notifications"]))
    running: true
    stdout: SplitParser {
      onRead: data => service.observe(data)
    }
    onStarted: startedAt = Date.now()
    onExited: (code, status) => {
      if (Date.now() - startedAt > 60000) retryDelay = 1000
      console.warn("otp: notification watcher exited (" + code + "), restarting in " + retryDelay + " ms")
      watchRestart.interval = retryDelay
      watchRestart.start()
      retryDelay = Math.min(retryDelay * 2, 60000)
    }
  }

  Timer {
    id: watchRestart
    onTriggered: watchProc.running = true
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

  // Backstop for the deadline timeout(1) already enforces: stopping the
  // Process sends SIGTERM to timeout, which forwards it to the whole group.
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

    // Copy the passcode from the newest notification that carried one, if it
    // arrived in the last ten minutes.
    function copyLast(): string {
      service.copyHeld()
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
