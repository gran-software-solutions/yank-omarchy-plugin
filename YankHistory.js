// Yank history helpers: normalize, dedupe, pin, filter, and shape display rows.

function normalizeEntry(value) {
  if (typeof value === "string")
    return value.trim().length > 0 ? { type: "text", text: value } : null

  if (!value || typeof value !== "object") return null

  var type = String(value.type || "")
  var pinned = !!value.pinned
  var createdAt = String(value.createdAt || "")
  if (type === "text") {
    var text = String(value.text || "")
    if (text.trim().length === 0) return null
    var textEntry = { type: "text", text: text }
    if (pinned) textEntry.pinned = true
    if (createdAt) textEntry.createdAt = createdAt
    return textEntry
  }
  if (type === "image") {
    var path = String(value.path || "")
    if (!path) return null
    var imageEntry = { type: "image", path: path, mime: String(value.mime || "image/png") }
    if (pinned) imageEntry.pinned = true
    if (createdAt) imageEntry.createdAt = createdAt
    return imageEntry
  }
  return null
}

function entryKey(entry) {
  if (!entry) return ""
  if (entry.type === "image") return "image:" + String(entry.path || "")
  return "text:" + String(entry.text || "")
}

function parseHistory(raw) {
  try {
    var parsed = JSON.parse(String(raw || "[]"))
    var next = []
    if (!Array.isArray(parsed)) return next
    for (var i = 0; i < parsed.length; i++) {
      var entry = normalizeEntry(parsed[i])
      if (entry) next.push(entry)
    }
    return next
  } catch (e) {
    return []
  }
}

// Enforce limits: maxEntries caps the count (oldest dropped first);
// maxAgeDays drops entries older than that (0 disables the age limit).
// Pinned entries are exempt from the age limit, not the count limit.
// Entries older than "days", ignoring pinned ones. Used both to prune and to
// tell the settings screen how much a retention choice would remove.
function entriesOlderThan(history, days) {
  var values = Array.isArray(history) ? history : []
  var n = Number(days) || 0
  if (n <= 0) return []
  var cutoff = Date.now() - n * 86400000
  var out = []
  for (var i = 0; i < values.length; i++) {
    var entry = normalizeEntry(values[i])
    if (!entry || entry.pinned) continue
    var ts = Date.parse(String(entry.createdAt || ""))
    if (!isNaN(ts) && ts < cutoff) out.push(entry)
  }
  return out
}

function pruneHistory(history, maxEntries, maxAgeDays) {
  var values = Array.isArray(history) ? history : []
  var max = Math.max(1, Number(maxEntries) || 200)
  var days = Number(maxAgeDays) || 0
  var next = []

  var cutoff = days > 0 ? Date.now() - days * 86400000 : 0
  for (var i = 0; i < values.length && next.length < max; i++) {
    var entry = normalizeEntry(values[i])
    if (!entry) continue
    if (cutoff > 0 && !entry.pinned) {
      var ts = Date.parse(String(entry.createdAt || ""))
      if (!isNaN(ts) && ts < cutoff) continue
    }
    next.push(entry)
  }
  return next
}

function addEntry(history, entry, limit) {
  var normalized = normalizeEntry(entry)
  var max = Math.max(0, Number(limit) || 0)
  if (!normalized || max === 0) return []

  var key = entryKey(normalized)
  var wasPinned = false
  var values = Array.isArray(history) ? history : []
  for (var i = 0; i < values.length; i++) {
    var existing = normalizeEntry(values[i])
    if (existing && entryKey(existing) === key) {
      wasPinned = !!existing.pinned
      break
    }
  }
  if (wasPinned) normalized.pinned = true

  // A re-copied pinned entry keeps its hand-placed position; everything else
  // moves to the top (recency).
  if (wasPinned) {
    var kept = values.slice()
    for (var k = 0; k < kept.length; k++) {
      var inPlace = normalizeEntry(kept[k])
      if (inPlace && entryKey(inPlace) === key) {
        kept[k] = normalized
        return kept.slice(0, max)
      }
    }
  }

  var next = [normalized]
  for (var j = 0; j < values.length && next.length < max; j++) {
    var other = normalizeEntry(values[j])
    if (!other || entryKey(other) === key) continue
    next.push(other)
  }
  return next
}

function removeEntryAt(history, index) {
  var values = Array.isArray(history) ? history : []
  var target = Number(index)
  if (isNaN(target) || target < 0 || target >= values.length) return values.slice()
  var next = values.slice()
  next.splice(target, 1)
  return next
}

function togglePinAt(history, index) {
  var values = Array.isArray(history) ? history : []
  var target = Number(index)
  if (isNaN(target) || target < 0 || target >= values.length) return values.slice()
  var next = values.slice()
  var entry = normalizeEntry(next[target])
  if (!entry) return next
  if (entry.pinned) delete entry.pinned
  else entry.pinned = true
  next[target] = entry
  return next
}

// Remove every non-pinned entry; pinned ones survive.
function clearUnpinned(history) {
  var values = Array.isArray(history) ? history : []
  var next = []
  for (var i = 0; i < values.length; i++) {
    var entry = normalizeEntry(values[i])
    if (entry && entry.pinned) next.push(entry)
  }
  return next
}

// Move the entry at stored position `index` up/down in *display* order
// (pinned group first). Only pinned entries can be reordered — unpinned ones
// are always recency-ordered — and moves cannot cross the pin boundary.
function moveEntryAt(history, index, delta) {
  var values = Array.isArray(history) ? history : []
  var target = Number(index)
  var entry = normalizeEntry(values[target])
  if (!entry || !entry.pinned) return values.slice()

  var order = sortedForDisplay(values)
  var pos = -1
  for (var i = 0; i < order.length; i++) {
    if (order[i] === index) { pos = i; break }
  }
  if (pos < 0) return values.slice()

  var target = pos + Number(delta)
  if (isNaN(target)) return values.slice()
  if (target < 0 || target >= order.length) return values.slice()

  var a = normalizeEntry(values[order[pos]])
  var b = normalizeEntry(values[order[target]])
  if (!a || !b || !!a.pinned !== !!b.pinned) return values.slice() // section boundary

  var tmp = order[pos]
  order[pos] = order[target]
  order[target] = tmp

  var next = []
  for (var j = 0; j < order.length; j++) next.push(values[order[j]])
  return next
}

// Display order: pinned first (newest pinned first), then the rest by recency.
// Rows keep their .index pointing back into the stored history array.
function sortedForDisplay(history) {
  var values = Array.isArray(history) ? history : []
  var pinned = []
  var rest = []
  for (var i = 0; i < values.length; i++) {
    var entry = normalizeEntry(values[i])
    if (!entry) continue
    if (entry.pinned) pinned.push(i)
    else rest.push(i)
  }
  return pinned.concat(rest)
}

function isLink(text) {
  return /^https?:\/\/\S+$/i.test(String(text || "").trim()) || /^www\.\S+$/i.test(String(text || "").trim())
}

function isColor(text) {
  var t = String(text || "").trim()
  if (/^#([0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(t)) return true
  return /^(rgba?|hsla?)\(/i.test(t)
}

function isEmail(text) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(text || "").trim())
}

// A single-line filesystem path (/, ./, ~/, file:// URI).
function isPath(text) {
  var t = String(text || "").trim()
  if (/[\r\n\s]/.test(t)) return false
  if (/^file:\/\/\S+/.test(t)) return true
  return /^(~\/|\.{1,2}\/|\/)[^\s]+$/.test(t)
}

// Sniff code/JSON: starts with a structural char or carries code markers.
function isCode(text) {
  var t = String(text || "").trim()
  if (t.length < 8) return false
  if (/^[{\[<]/.test(t) && /[}\]>]/.test(t)) return true
  return /(^|\n)\s*(function |def |class |import |from |#!\/|#! )/.test(t)
}

// Which filter kinds an entry belongs to. "all" and "text"/"images" are the
// base kinds; links/colors are text sub-kinds.
function matchesKind(entry, kind) {
  if (!entry) return false
  switch (String(kind || "all")) {
    case "all": return true
    case "text": return entry.type === "text"
    case "images": return entry.type === "image"
    case "links": return entry.type === "text" && isLink(entry.text)
    case "colors": return entry.type === "text" && isColor(entry.text)
    default: return true
  }
}

function kindLabel(entry) {
  if (!entry) return "Text"
  if (entry.type === "image") return "Image"
  if (isColor(entry.text)) return "Color"
  if (isLink(entry.text)) return "Link"
  if (isEmail(entry.text)) return "Email"
  if (isPath(entry.text)) return "Path"
  if (isCode(entry.text)) return "Code"
  return "Text"
}

// Caption under the row title, e.g. "Text · 4 words · 2 lines".
function metadata(entry) {
  if (!entry) return ""
  if (entry.type === "image") return "Image · " + String(entry.mime || "image/png")

  var text = String(entry.text || "").replace(/\n$/, "")
  var words = text.split(/\s+/).filter(function(w) { return w.length > 0 }).length
  var lines = text.split(/\r?\n/).length
  var label = kindLabel(entry)
  return label + " · " + words + (words === 1 ? " word" : " words") +
         " · " + lines + (lines === 1 ? " line" : " lines")
}

function searchableText(entry) {
  if (!entry) return ""
  if (entry.type === "image") return "image " + String(entry.mime || "") + " " + String(entry.path || "")
  return String(entry.text || "")
}

// How well an entry answers the query. A match is not binary: typing "git"
// should put the short "git status" line above a 40-line paste that merely
// contains those letters. Returns -1 when the entry does not match at all.
function relevanceScore(text, needle) {
  var haystack = String(text || "").toLowerCase()
  var at = haystack.indexOf(needle)
  if (at < 0) return -1
  if (haystack === needle) return 0          // the whole entry is the query
  if (at === 0) return 1                     // starts with the query
  if (!/[a-z0-9]/.test(haystack.charAt(at - 1))) return 2   // matches at a word start
  return 3                                   // matches inside a word
}

function previewText(entry) {
  if (!entry) return ""
  if (entry.type === "image") return "Image (" + String(entry.mime || "image/png") + ")"
  return String(entry.text || "").replace(/\s+/g, " ")
}

// Search and render only a prefix of huge entries — a giant paste must not
// stall the shell on every keystroke. Pasting reads the full entry from
// history by index, so nothing is lost.
var displayTextLimit = 8192

function cappedEntry(entry) {
  if (!entry || entry.type !== "text" || entry.text.length <= displayTextLimit) return entry
  return { type: "text", text: entry.text.slice(0, displayTextLimit) }
}

function displayRows(history, query, kind, limit) {
  var order = sortedForDisplay(history)
  var needle = String(query || "").trim().toLowerCase()
  var max = Math.max(0, Number(limit) || 50)

  var rows = []
  for (var i = 0; i < order.length; i++) {
    var entry = cappedEntry(normalizeEntry(history[order[i]]))
    if (!entry) continue
    if (!matchesKind(entry, kind)) continue
    var haystack = searchableText(entry)
    // Rank by how well the entry matches rather than by recency alone, so the
    // closest answers surface first. A one-character query matches almost
    // everything, so it falls back to plain recency.
    var score = 0
    var at = 0
    if (needle) {
      score = relevanceScore(haystack, needle)
      if (score < 0) continue
      if (needle.length < 2) score = 0
      at = haystack.toLowerCase().indexOf(needle)
    }

    rows.push({
      entryType: entry.type,
      pinned: !!entry.pinned,
      fullText: entry.type === "image" ? "" : String(entry.text || ""),
      previewText: previewText(entry),
      caption: metadata(entry),
      isLink: entry.type === "text" && isLink(entry.text),
      isColor: entry.type === "text" && isColor(entry.text),
      isEmail: entry.type === "text" && isEmail(entry.text),
      isPath: entry.type === "text" && isPath(entry.text),
      isCode: entry.type === "text" && isCode(entry.text),
      previewImage: entry.type === "image" ? String(entry.path || "") : "",
      path: entry.type === "image" ? String(entry.path || "") : "",
      mime: entry.type === "image" ? String(entry.mime || "image/png") : "text/plain",
      index: order[i],
      _score: score,
      _length: haystack.length,
      _at: at
    })
  }

  if (needle) {
    rows.sort(function(a, b) {
      if (a._score !== b._score) return a._score - b._score
      if (a._length !== b._length) return a._length - b._length
      if (a._at !== b._at) return a._at - b._at
      return 0
    })
  }

  rows = rows.slice(0, max)
  for (var r = 0; r < rows.length; r++) {
    delete rows[r]._score
    delete rows[r]._length
    delete rows[r]._at
  }
  return rows
}
