// One-time passcode extraction for the Omarchy OTP plugin.
//
// Deliberately heuristic rather than a model: a transposed digit is a silent
// failure that only surfaces when a login is rejected, so these rules prefer
// refusing over guessing. Anything the scores cannot separate is reported as
// ambiguous for a human to settle.
//
// This file runs in two engines: Qt's QML JavaScript engine (the shell) and
// Node (the tests). Qt 6.11 has no lookbehind, no named capture groups and no
// String.matchAll, so none are used here -- a leading capture group stands in
// for lookbehind, and matches are walked with an exec loop. test/qml-engine-test.sh
// guards that, since Node alone would happily accept syntax the shell rejects.

var KEYWORD_SOURCE =
  "(one[- ]?time|verification|verify|security|access|login|log[- ]?in|" +
  "auth(?:entication)?|confirm(?:ation)?|passcode|pass ?code|otp|pin|" +
  "code|token|2fa|mfa)"

// Words that mark a nearby number as something other than a passcode.
var DECOY_SOURCE =
  "(ending in|account|acct|order|invoice|ref(?:erence)?|tracking|amount|" +
  "balance|total|zip|postal|expires?|valid for|minutes?|mins?|hours?|" +
  "seconds?|call|dial|phone|ext(?:ension)?|street|suite|apt)"

// Length preferences: six digits is overwhelmingly the common shape.
var LENGTH_BONUS = { 4: 1.5, 5: 0.5, 6: 3, 7: 0.5, 8: 1 }

// Conservative OCR confusions, applied only to otherwise-numeric tokens and
// only when the caller says the text came from OCR.
var OCR_CONFUSIONS = { "O": "0", "o": "0", "I": "1", "l": "1", "|": "1", "S": "5", "B": "8", "Z": "2" }

function keywordRe(flags) {
  return new RegExp(KEYWORD_SOURCE, flags)
}

function decoyRe() {
  return new RegExp(DECOY_SOURCE, "i")
}

function isDigits(value) {
  return /^[0-9]+$/.test(value)
}

function repairOcr(token) {
  var out = ""
  for (var i = 0; i < token.length; i++) {
    var ch = token.charAt(i)
    out += OCR_CONFUSIONS[ch] === undefined ? ch : OCR_CONFUSIONS[ch]
  }
  return out
}

// Spans that look like a phone number, so digits inside one can be discounted.
function phoneSpans(text) {
  var re = /\+?[0-9][0-9\-().\s]{8,}[0-9]/g
  var spans = []
  var match
  while ((match = re.exec(text)) !== null) {
    var digits = match[0].replace(/[^0-9]/g, "").length
    spans.push({ start: match.index, end: match.index + match[0].length, digits: digits })
    if (re.lastIndex === match.index) re.lastIndex++
  }
  return spans
}

function timeSpans(text) {
  var re = /[0-9]{1,2}:[0-9]{2}/g
  var spans = []
  var match
  while ((match = re.exec(text)) !== null) {
    spans.push({ start: match.index, end: match.index + match[0].length })
    if (re.lastIndex === match.index) re.lastIndex++
  }
  return spans
}

function lastKeywordGap(before) {
  var re = keywordRe("gi")
  var match
  var end = -1
  while ((match = re.exec(before)) !== null) {
    end = match.index + match[0].length
    if (re.lastIndex === match.index) re.lastIndex++
  }
  return end === -1 ? -1 : before.length - end
}

function scoreCandidate(text, code, start, end, context, repaired) {
  var before = text.slice(Math.max(0, start - 45), start)
  var after = text.slice(end, end + 30)
  var score = 0
  var reasons = []

  var gap = lastKeywordGap(before)
  var keywordAfter = keywordRe("i").test(after)
  if (gap >= 0) {
    // A closer keyword wins: "code is 123456" beats one 40 characters back.
    score += 6 - Math.min(gap, 40) / 10
    reasons.push("keyword " + gap + "c before")
  }
  if (keywordAfter) {
    score += 4
    reasons.push("keyword after")
  }
  if (gap < 0 && !keywordAfter) {
    score -= 1
    reasons.push("no keyword")
  }

  var bonus = LENGTH_BONUS[code.length]
  if (bonus !== undefined) score += bonus
  if (isDigits(code)) score += 1
  if (repaired) {
    score -= 0.5
    reasons.push("ocr-repaired")
  }

  var decoy = decoyRe()
  if (decoy.test(before.slice(-25)) || decoy.test(after.slice(0, 20))) {
    score -= 5
    reasons.push("decoy context")
  }
  if (code.length === 4 && isDigits(code)) {
    var year = parseInt(code, 10)
    if (year >= 1900 && year <= 2099) {
      score -= 3
      reasons.push("looks like a year")
    }
  }
  if (/\$\s*$/.test(before) || /^\s*%/.test(after)) {
    score -= 6
    reasons.push("currency/percent")
  }
  for (var t = 0; t < context.times.length; t++) {
    if (context.times[t].start <= start && start < context.times[t].end) {
      score -= 8
      reasons.push("inside a time")
    }
  }
  for (var p = 0; p < context.phones.length; p++) {
    var span = context.phones[p]
    if (span.start <= start && end <= span.end && (span.end - span.start) > code.length + 1 && span.digits >= 10) {
      score -= 7
      reasons.push("inside a phone number")
    }
  }

  return { score: Math.round(score * 100) / 100, reasons: reasons }
}

// Walk one pattern, where group 1 absorbs the character before the candidate
// (standing in for a lookbehind) and `group` names the candidate itself.
function eachMatch(text, pattern, group, handler) {
  var re = new RegExp(pattern, "g")
  var match
  while ((match = re.exec(text)) !== null) {
    var value = match[group]
    var start = match.index + match[1].length
    handler(value, start, start + value.length)
    if (re.lastIndex === match.index) re.lastIndex++
  }
}

function candidates(text, ocr) {
  var normalized = String(text === undefined || text === null ? "" : text).replace(/[ \t]+/g, " ")
  var context = { phones: phoneSpans(normalized), times: timeSpans(normalized) }
  var found = {}

  function add(code, start, end, bonus, repaired) {
    var scored = scoreCandidate(normalized, code, start, end, context, repaired)
    var total = Math.round((scored.score + (bonus || 0)) * 100) / 100
    var existing = found[code]
    if (existing === undefined || total > existing.score) {
      found[code] = { code: code, score: total, reasons: scored.reasons }
    }
  }

  // Google's "G-123456" and Apple's "#123456" are explicit autofill
  // conventions -- about as unambiguous as a passcode gets.
  eachMatch(normalized, "(^|[^0-9A-Za-z])(?:G-|#)([0-9]{4,8})(?![0-9A-Za-z])", 2,
    function (code, start, end) { add(code, start, end, 6, false) })

  eachMatch(normalized, "(^|[^0-9A-Za-z])([0-9]{4,8})(?![0-9A-Za-z])", 2,
    function (code, start, end) { add(code, start, end, 0, false) })

  eachMatch(normalized, "(^|[^0-9A-Za-z])([A-Z0-9]{6,8})(?![0-9A-Za-z])", 2,
    function (token, start, end) {
      var digitCount = token.replace(/[^0-9]/g, "").length
      if (digitCount < 2 || isDigits(token)) return
      var repaired = ocr ? repairOcr(token) : token
      if (ocr && isDigits(repaired) && repaired !== token) {
        // Under OCR an all-digit reading of a digit-shaped token beats the
        // letter reading, so only the repair is offered and the two cannot tie.
        add(repaired, start, end, 0, true)
      } else {
        add(token, start, end, 0, false)
      }
    })

  var ranked = []
  for (var key in found) {
    if (found.hasOwnProperty(key)) ranked.push(found[key])
  }
  ranked.sort(function (a, b) { return b.score - a.score })
  return ranked
}

// Returns { status: "ok"|"ambiguous"|"none", code, candidates }.
// "ambiguous" means the top two scores are within a point of each other; the
// caller should ask rather than copy.
function extract(text, ocr) {
  var ranked = candidates(text, ocr).filter(function (entry) { return entry.score > 0 })
  if (ranked.length === 0) return { status: "none", code: "", candidates: [] }
  if (ranked.length > 1 && ranked[0].score - ranked[1].score < 2) {
    return { status: "ambiguous", code: "", candidates: ranked.slice(0, 3) }
  }
  return { status: "ok", code: ranked[0].code, candidates: ranked }
}

// Pick the newest notification that carries a code. `entries` are the shell's
// persisted notification records, newest first.
function extractFromNotifications(entries, ocr) {
  if (!entries || !entries.length) return { status: "none", code: "", candidates: [] }
  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i] || {}
    var text = String(entry.summary || "") + "\n" + String(entry.body || "")
    var result = extract(text, ocr)
    if (result.status === "ok") {
      result.app = String(entry.app || "")
      result.timestamp = entry.timestamp || 0
      return result
    }
    if (result.status === "ambiguous") {
      result.app = String(entry.app || "")
      result.timestamp = entry.timestamp || 0
      return result
    }
  }
  return { status: "none", code: "", candidates: [] }
}

if (typeof module !== "undefined") {
  module.exports = {
    candidates: candidates,
    extract: extract,
    extractFromNotifications: extractFromNotifications,
    repairOcr: repairOcr,
    phoneSpans: phoneSpans
  }
}
