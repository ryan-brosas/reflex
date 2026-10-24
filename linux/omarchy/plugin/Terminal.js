// Terminal.js - the small ANSI/VT screen used by Terminal.qml.
//
// Herdr's "terminal session observe" sends full-screen frames as JSON with a
// base64 ANSI payload. This module turns those bytes into a cell grid; QML
// paints the grid and sends input back through herdr's pane commands.

var DEFAULT_FG = "#d8dee9"
var DEFAULT_BG = "#111318"
var PALETTE = [
  "#1b1d23", "#e06c75", "#98c379", "#e5c07b",
  "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
  "#5c6370", "#e06c75", "#98c379", "#e5c07b",
  "#61afef", "#c678dd", "#56b6c2", "#ffffff"
]

function blankCell() {
  return { ch: " ", fg: DEFAULT_FG, bg: DEFAULT_BG, bold: false, underline: false, reverse: false, width: 1, cont: false }
}

function resetCell(cell) {
  cell.ch = " "
  cell.fg = DEFAULT_FG
  cell.bg = DEFAULT_BG
  cell.bold = false
  cell.underline = false
  cell.reverse = false
  cell.width = 1
  cell.cont = false
}

function createScreen(cols, rows) {
  var screen = {
    cols: Math.max(1, Number(cols) || 80),
    rows: Math.max(1, Number(rows) || 24),
    cells: [],
    cx: 0, cy: 0,
    fg: DEFAULT_FG, bg: DEFAULT_BG,
    bold: false, underline: false, reverse: false,
    cursor: true,
    savedX: 0, savedY: 0,
    scrollTop: 0, scrollBottom: Math.max(0, (Number(rows) || 24) - 1),
    history: [], historyLimit: 2000,
    isAlt: false, primary: null,
    appCursor: false, autoWrap: true, bracketedPaste: false
  }
  var total = screen.cols * screen.rows
  for (var i = 0; i < total; i++) screen.cells.push(blankCell())
  return screen
}

function clear(screen) {
  for (var i = 0; i < screen.cells.length; i++) resetCell(screen.cells[i])
  screen.cx = 0
  screen.cy = 0
  screen.fg = DEFAULT_FG
  screen.bg = DEFAULT_BG
  screen.bold = false
  screen.underline = false
  screen.reverse = false
  screen.cursor = true
  screen.scrollTop = 0
  screen.scrollBottom = screen.rows - 1
  screen.history = []
  screen.isAlt = false
  screen.primary = null
  screen.appCursor = false
  screen.autoWrap = true
  screen.bracketedPaste = false
}

function cellAt(screen, x, y) {
  if (y < 0 || y >= screen.rows || x < 0 || x >= screen.cols) return null
  return screen.cells[y * screen.cols + x]
}

function setCell(screen, x, y) {
  var cell = cellAt(screen, x, y)
  if (!cell) return null
  cell.fg = screen.fg
  cell.bg = screen.bg
  cell.bold = screen.bold
  cell.underline = screen.underline
  cell.reverse = screen.reverse
  cell.width = 1
  cell.cont = false
  return cell
}

function copyCell(cell) {
  return { ch: cell.ch, fg: cell.fg, bg: cell.bg, bold: cell.bold,
    underline: cell.underline, reverse: cell.reverse, width: cell.width, cont: cell.cont }
}

function pushHistory(screen, row) {
  if (screen.isAlt || !row || screen.scrollTop !== 0) return
  var copy = []
  for (var i = 0; i < row.length; i++) copy.push(copyCell(row[i]))
  screen.history.push(copy)
  if (screen.history.length > screen.historyLimit) screen.history.shift()
}

function scrollUp(screen, count) {
  var n = Math.max(1, Math.min(Number(count) || 1, screen.scrollBottom - screen.scrollTop + 1))
  for (var i = 0; i < n; i++) {
    var top = screen.scrollTop * screen.cols
    if (!screen.isAlt && screen.scrollTop === 0)
      pushHistory(screen, screen.cells.slice(top, top + screen.cols))
    screen.cells.splice(top, screen.cols)
    var insertAt = screen.scrollBottom * screen.cols
    if (insertAt > screen.cells.length) insertAt = screen.cells.length
    for (var c = 0; c < screen.cols; c++) screen.cells.splice(insertAt, 0, blankCell())
  }
  screen.cy = screen.scrollBottom
}

function scrollDown(screen, count) {
  var n = Math.max(1, Math.min(Number(count) || 1, screen.scrollBottom - screen.scrollTop + 1))
  for (var i = 0; i < n; i++) {
    var bottom = screen.scrollBottom * screen.cols
    screen.cells.splice(bottom, screen.cols)
    var insertAt = screen.scrollTop * screen.cols
    for (var c = 0; c < screen.cols; c++) screen.cells.splice(insertAt, 0, blankCell())
  }
  screen.cy = screen.scrollTop
}

function lineFeed(screen) {
  if (screen.cy >= screen.scrollBottom) scrollUp(screen, 1)
  else screen.cy++
}

function isCombining(ch) {
  var cp = ch.codePointAt(0)
  return (cp >= 0x0300 && cp <= 0x036f) || (cp >= 0x1ab0 && cp <= 0x1aff) ||
    (cp >= 0x1dc0 && cp <= 0x1dff) || (cp >= 0x20d0 && cp <= 0x20ff) ||
    (cp >= 0xfe00 && cp <= 0xfe0f) || (cp >= 0xfe20 && cp <= 0xfe2f) || cp === 0x200d
}

function charWidth(ch) {
  if (isCombining(ch)) return 0
  var cp = ch.codePointAt(0)
  if ((cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x2e80 && cp <= 0xa4cf) ||
      (cp >= 0xac00 && cp <= 0xd7a3) || (cp >= 0xf900 && cp <= 0xfaff) ||
      (cp >= 0xfe10 && cp <= 0xfe19) || (cp >= 0xfe30 && cp <= 0xfe6f) ||
      (cp >= 0xff00 && cp <= 0xff60) || (cp >= 0xffe0 && cp <= 0xffe6) ||
      (cp >= 0x1f300 && cp <= 0x1f64f) || (cp >= 0x1f900 && cp <= 0x1f9ff) ||
      (cp >= 0x20000 && cp <= 0x3fffd)) return 2
  return 1
}

function put(screen, ch) {
  if (ch === "\r" || ch === "\n" || ch === "\b" || ch === "\t" || ch === "\u0007") return
  var width = charWidth(ch)
  if (width === 0) {
    var prev = cellAt(screen, screen.cx - 1, screen.cy)
    if (!prev && screen.cx === 0) prev = cellAt(screen, screen.cols - 1, Math.max(0, screen.cy - 1))
    if (prev) prev.ch += ch
    return
  }
  if (screen.autoWrap && screen.cx + width > screen.cols) {
    screen.cx = 0
    lineFeed(screen)
  }
  if (screen.cx >= screen.cols) {
    screen.cx = 0
    lineFeed(screen)
  }
  var cell = setCell(screen, screen.cx, screen.cy)
  if (cell) {
    cell.ch = ch
    cell.width = width
    cell.cont = false
    if (width === 2) {
      var next = cellAt(screen, screen.cx + 1, screen.cy)
      if (next) {
        resetCell(next)
        next.ch = ""
        next.width = 0
        next.cont = true
      }
    }
  }
  screen.cx += width
}

function paletteColor(index) {
  var n = Number(index) || 0
  if (n < 0) n = 0
  if (n < 16) return PALETTE[n]
  if (n >= 16 && n <= 231) {
    var r = Math.floor((n - 16) / 36)
    var g = Math.floor(((n - 16) % 36) / 6)
    var b = (n - 16) % 6
    var values = [0, 95, 135, 175, 215, 255]
    return "rgb(" + values[r] + "," + values[g] + "," + values[b] + ")"
  }
  if (n >= 232 && n <= 255) {
    var v = 8 + (n - 232) * 10
    return "rgb(" + v + "," + v + "," + v + ")"
  }
  return DEFAULT_FG
}

function sgr(screen, params) {
  if (!params.length) params = [0]
  for (var i = 0; i < params.length; i++) {
    var n = Number(params[i]) || 0
    if (n === 0) {
      screen.fg = DEFAULT_FG
      screen.bg = DEFAULT_BG
      screen.bold = false
      screen.underline = false
      screen.reverse = false
    } else if (n === 1) screen.bold = true
    else if (n === 2) screen.bold = false
    else if (n === 4) screen.underline = true
    else if (n === 7) screen.reverse = true
    else if (n === 22) screen.bold = false
    else if (n === 24) screen.underline = false
    else if (n === 27) screen.reverse = false
    else if (n >= 30 && n <= 37) screen.fg = PALETTE[n - 30]
    else if (n >= 90 && n <= 97) screen.fg = PALETTE[n - 90 + 8]
    else if (n >= 40 && n <= 47) screen.bg = PALETTE[n - 40]
    else if (n >= 100 && n <= 107) screen.bg = PALETTE[n - 100 + 8]
    else if (n === 39) screen.fg = DEFAULT_FG
    else if (n === 49) screen.bg = DEFAULT_BG
    else if (n === 38 || n === 48) {
      var target = n === 38 ? "fg" : "bg"
      if (Number(params[i + 1]) === 5) {
        screen[target] = paletteColor(params[i + 2])
        i += 2
      } else if (Number(params[i + 1]) === 2) {
        var r = Number(params[i + 2]) || 0
        var g = Number(params[i + 3]) || 0
        var b = Number(params[i + 4]) || 0
        screen[target] = "rgb(" + r + "," + g + "," + b + ")"
        i += 4
      }
    }
  }
}

function eraseLine(screen, mode) {
  var from = 0
  var to = screen.cols - 1
  if (mode === 0) from = screen.cx
  else if (mode === 1) to = screen.cx
  for (var x = from; x <= to; x++) {
    var cell = cellAt(screen, x, screen.cy)
    if (cell) resetCell(cell)
  }
}

function eraseDisplay(screen, mode) {
  if (mode === 0) {
    eraseLine(screen, 0)
    for (var y = screen.cy + 1; y < screen.rows; y++)
      for (var x = 0; x < screen.cols; x++) {
        var c = cellAt(screen, x, y)
        if (c) resetCell(c)
      }
  } else if (mode === 1) {
    eraseLine(screen, 1)
    for (var y2 = 0; y2 < screen.cy; y2++)
      for (var x2 = 0; x2 < screen.cols; x2++) {
        var c2 = cellAt(screen, x2, y2)
        if (c2) resetCell(c2)
      }
  } else {
    for (var i = 0; i < screen.cells.length; i++) resetCell(screen.cells[i])
  }
}

function enterAlt(screen, saveCursor) {
  if (screen.isAlt) return
  screen.primary = {
    cells: screen.cells, cx: screen.cx, cy: screen.cy,
    scrollTop: screen.scrollTop, scrollBottom: screen.scrollBottom,
    fg: screen.fg, bg: screen.bg, bold: screen.bold,
    underline: screen.underline, reverse: screen.reverse
  }
  screen.isAlt = true
  if (saveCursor) { screen.savedX = screen.cx; screen.savedY = screen.cy }
  screen.cells = []
  var total = screen.cols * screen.rows
  for (var i = 0; i < total; i++) screen.cells.push(blankCell())
  screen.cx = 0
  screen.cy = 0
  screen.scrollTop = 0
  screen.scrollBottom = screen.rows - 1
  screen.fg = DEFAULT_FG
  screen.bg = DEFAULT_BG
  screen.bold = false
  screen.underline = false
  screen.reverse = false
}

function leaveAlt(screen) {
  if (!screen.isAlt || !screen.primary) return
  var p = screen.primary
  screen.cells = p.cells
  screen.cx = p.cx
  screen.cy = p.cy
  screen.scrollTop = p.scrollTop
  screen.scrollBottom = p.scrollBottom
  screen.fg = p.fg
  screen.bg = p.bg
  screen.bold = p.bold
  screen.underline = p.underline
  screen.reverse = p.reverse
  screen.isAlt = false
  screen.primary = null
}

function csi(screen, text) {
  var prefix = ""
  var i = 0
  if (text.charAt(0) === "?") { prefix = "?"; i = 1 }
  var raw = text.substring(i)
  var final = raw.charAt(raw.length - 1)
  var body = raw.substring(0, raw.length - 1)
  var parts = body === "" ? [] : body.split(";")
  var p0 = Number(parts[0]) || 0
  var p1 = Number(parts[1]) || 0

  if (final === "m") { sgr(screen, parts); return }
  if (final === "A") { screen.cy = Math.max(0, screen.cy - Math.max(1, p0)); return }
  if (final === "B") { screen.cy = Math.min(screen.rows - 1, screen.cy + Math.max(1, p0)); return }
  if (final === "C") { screen.cx = Math.min(screen.cols - 1, screen.cx + Math.max(1, p0)); return }
  if (final === "D") { screen.cx = Math.max(0, screen.cx - Math.max(1, p0)); return }
  if (final === "E") { screen.cy = Math.min(screen.rows - 1, screen.cy + Math.max(1, p0)); screen.cx = 0; return }
  if (final === "F") { screen.cy = Math.max(0, screen.cy - Math.max(1, p0)); screen.cx = 0; return }
  if (final === "G" || final === "\u0060") { screen.cx = Math.max(0, Math.min(screen.cols - 1, Math.max(1, p0) - 1)); return }
  if (final === "H" || final === "f") {
    screen.cy = Math.max(0, Math.min(screen.rows - 1, Math.max(1, p0) - 1))
    screen.cx = Math.max(0, Math.min(screen.cols - 1, Math.max(1, p1) - 1))
    return
  }
  if (final === "d") { screen.cy = Math.max(0, Math.min(screen.rows - 1, Math.max(1, p0) - 1)); return }
  if (final === "e") { screen.cy = Math.min(screen.rows - 1, screen.cy + Math.max(1, p0)); return }
  if (final === "a") { screen.cx = Math.min(screen.cols - 1, screen.cx + Math.max(1, p0)); return }
  if (final === "s") { screen.savedX = screen.cx; screen.savedY = screen.cy; return }
  if (final === "u") { screen.cx = screen.savedX; screen.cy = screen.savedY; return }
  if (final === "J") { eraseDisplay(screen, p0); return }
  if (final === "K") { eraseLine(screen, p0); return }
  if (final === "X") {
    var n = Math.max(1, p0)
    for (var x = screen.cx; x < Math.min(screen.cols, screen.cx + n); x++) {
      var c = cellAt(screen, x, screen.cy)
      if (c) resetCell(c)
    }
    return
  }
  if (final === "@") {
    var count = Math.max(1, p0)
    var row = []
    for (var x2 = 0; x2 < screen.cols; x2++) row.push(screen.cells[screen.cy * screen.cols + x2])
    for (var k = 0; k < count; k++) row.splice(screen.cx, 0, blankCell())
    row.length = screen.cols
    for (var x3 = 0; x3 < screen.cols; x3++) screen.cells[screen.cy * screen.cols + x3] = row[x3]
    return
  }
  if (final === "P") {
    var count2 = Math.max(1, p0)
    var row2 = []
    for (var x4 = 0; x4 < screen.cols; x4++) row2.push(screen.cells[screen.cy * screen.cols + x4])
    row2.splice(screen.cx, count2)
    while (row2.length < screen.cols) row2.push(blankCell())
    for (var x5 = 0; x5 < screen.cols; x5++) screen.cells[screen.cy * screen.cols + x5] = row2[x5]
    return
  }
  if (final === "L" || final === "M") {
    var count3 = Math.max(1, p0)
    var at = screen.cy * screen.cols
    for (var i3 = 0; i3 < count3; i3++) {
      if (final === "L") {
        screen.cells.splice(at, 0)
        for (var c3 = 0; c3 < screen.cols; c3++) screen.cells.splice(at, 0, blankCell())
        screen.cells.length = screen.rows * screen.cols
      } else {
        screen.cells.splice(at, screen.cols)
        for (var c4 = 0; c4 < screen.cols; c4++) screen.cells.push(blankCell())
      }
    }
    return
  }
  if (final === "S" || final === "T") {
    if (final === "S") scrollUp(screen, Math.max(1, p0))
    else scrollDown(screen, Math.max(1, p0))
    return
  }
  if (final === "r") {
    screen.scrollTop = Math.max(0, Math.min(screen.rows - 1, Math.max(1, p0) - 1))
    screen.scrollBottom = Math.max(screen.scrollTop, Math.min(screen.rows - 1, (p1 || screen.rows) - 1))
    screen.cx = 0
    screen.cy = 0
    return
  }
  if (final === "h" || final === "l") {
    if (prefix === "?") {
      if (body === "25") { screen.cursor = final === "h"; return }
      if (body === "1049") { if (final === "h") enterAlt(screen, true); else leaveAlt(screen); return }
      if (body === "47" || body === "1047") { if (final === "h") enterAlt(screen, false); else leaveAlt(screen); return }
      if (body === "1048") {
        if (final === "h") { screen.savedX = screen.cx; screen.savedY = screen.cy }
        else { screen.cx = screen.savedX; screen.cy = screen.savedY }
        return
      }
      if (body === "1") { screen.appCursor = final === "h"; return }
      if (body === "7") { screen.autoWrap = final === "h"; return }
      if (body === "2004") { screen.bracketedPaste = final === "h"; return }
    }
    return
  }
}

function feed(screen, text) {
  if (!screen || !text) return screen
  var i = 0
  while (i < text.length) {
    var cp = text.codePointAt(i)
    var ch = String.fromCodePoint(cp)
    var step = ch.length
    if (ch === "\u001b") {
      var next = text.charAt(i + 1)
      if (next === "[") {
        var j = i + 2
        while (j < text.length) {
          var code = text.charCodeAt(j)
          if (code >= 0x40 && code <= 0x7e) break
          j++
        }
        if (j < text.length) {
          csi(screen, text.substring(i + 2, j + 1))
          i = j + 1
          continue
        }
        i = text.length
        continue
      }
      if (next === "]") {
        var k = i + 2
        while (k < text.length) {
          if (text.charAt(k) === "\u0007") { k++; break }
          if (text.charAt(k) === "\u001b" && text.charAt(k + 1) === "\\") { k += 2; break }
          k++
        }
        i = k
        continue
      }
      if (next === "(" || next === ")" || next === "*" || next === "+") { i += 3; continue }
      if (next === "P" || next === "X" || next === "^" || next === "_") {
        var m = i + 2
        while (m < text.length) {
          if (text.charAt(m) === "\u001b" && text.charAt(m + 1) === "\\") { m += 2; break }
          m++
        }
        i = m
        continue
      }
      if (next === "7") { screen.savedX = screen.cx; screen.savedY = screen.cy; i += 2; continue }
      if (next === "8") { screen.cx = screen.savedX; screen.cy = screen.savedY; i += 2; continue }
      if (next === "D") { lineFeed(screen); i += 2; continue }
      if (next === "M") {
        if (screen.cy <= screen.scrollTop) scrollDown(screen, 1)
        else screen.cy--
        i += 2
        continue
      }
      if (next === "E") { lineFeed(screen); screen.cx = 0; i += 2; continue }
      if (next === "c") { clear(screen); i += 2; continue }
      i += 2
      continue
    }
    if (ch === "\n") { lineFeed(screen); i += step; continue }
    if (ch === "\r") { screen.cx = 0; i += step; continue }
    if (ch === "\b") { screen.cx = Math.max(0, screen.cx - 1); i += step; continue }
    if (ch === "\t") { screen.cx = Math.min(screen.cols - 1, (Math.floor(screen.cx / 8) + 1) * 8); i += step; continue }
    if (ch === "\u0007") { i += step; continue }
    put(screen, ch)
    i += step
  }
  return screen
}

function base64Bytes(text) {
  var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  var clean = String(text || "").replace(/[^A-Za-z0-9+/=]/g, "")
  var out = []
  var buffer = 0
  var bits = 0
  for (var i = 0; i < clean.length; i++) {
    var c = clean.charAt(i)
    if (c === "=") break
    var v = chars.indexOf(c)
    if (v < 0) continue
    buffer = (buffer << 6) | v
    bits += 6
    if (bits >= 8) {
      bits -= 8
      out.push((buffer >> bits) & 0xff)
    }
  }
  return out
}

function utf8(bytes) {
  var out = ""
  var i = 0
  while (i < bytes.length) {
    var b = bytes[i++] & 0xff
    if (b < 0x80) out += String.fromCharCode(b)
    else if (b >= 0xc0 && b < 0xe0 && i < bytes.length) {
      out += String.fromCharCode(((b & 0x1f) << 6) | (bytes[i++] & 0x3f))
    } else if (b >= 0xe0 && b < 0xf0 && i + 1 < bytes.length) {
      out += String.fromCharCode(((b & 0x0f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f))
    } else if (b >= 0xf0 && i + 2 < bytes.length) {
      var cp = ((b & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f)
      cp -= 0x10000
      out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff))
    } else {
      out += "\ufffd"
    }
  }
  return out
}

function decode(text) {
  return utf8(base64Bytes(text))
}
