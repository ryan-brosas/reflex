import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'
import path from 'node:path'

const file = path.join(import.meta.dirname, '..', 'omarchy', 'plugin', 'Terminal.js')
const context = {}
vm.createContext(context)
vm.runInContext(fs.readFileSync(file, 'utf8'), context)

function screenText(screen) {
  const out = []
  for (let y = 0; y < screen.rows; y++) {
    let line = ''
    for (let x = 0; x < screen.cols; x++) {
      const cell = screen.cells[y * screen.cols + x]
      if (cell && !cell.cont) line += cell.ch || ' '
    }
    out.push(line.replace(/\s+$/, ''))
  }
  return out.join('\n')
}

test('alternate screen saves and restores the primary buffer', () => {
  const screen = context.createScreen(20, 4)
  context.feed(screen, 'primary')
  context.feed(screen, '\x1b[?1049h')
  context.feed(screen, 'ALT')
  assert.match(screenText(screen), /ALT/)
  assert.doesNotMatch(screenText(screen), /primary/)
  context.feed(screen, '\x1b[?1049l')
  assert.match(screenText(screen), /primary/)
  assert.doesNotMatch(screenText(screen), /ALT/)
})

test('scroll region leaves rows outside the region alone', () => {
  const screen = context.createScreen(10, 4)
  context.feed(screen, 'A\x1b[2;1HB\x1b[3;1HC\x1b[4;1HD')
  context.feed(screen, '\x1b[2;3r\x1b[3;1H\n')
  assert.equal(screen.cells[0].ch, 'A')
  assert.equal(screen.cells[1 * 10].ch, 'C')
  assert.equal(screen.cells[2 * 10].ch, ' ')
  assert.equal(screen.cells[3 * 10].ch, 'D')
})

test('wide characters reserve two cells and combining marks attach', () => {
  const screen = context.createScreen(10, 2)
  context.feed(screen, '你e\u0301')
  assert.equal(screen.cells[0].ch, '你')
  assert.equal(screen.cells[0].width, 2)
  assert.equal(screen.cells[1].cont, true)
  assert.equal(screen.cells[2].ch, 'e\u0301')
  assert.equal(screen.cx, 3)
})

test('application cursor mode is tracked', () => {
  const screen = context.createScreen(10, 2)
  context.feed(screen, '\x1b[?1h')
  assert.equal(screen.appCursor, true)
  context.feed(screen, '\x1b[?1l')
  assert.equal(screen.appCursor, false)
})

test('scrolled primary rows are retained in history', () => {
  const screen = context.createScreen(8, 3)
  context.feed(screen, 'A\nB\nC\nD\n')
  assert.ok(screen.history.length > 0)
  assert.match(screen.history.map(row => row.map(cell => cell.ch).join('')).join('\n'), /A/)
})

test('base64 UTF-8 decoding handles non-ASCII input', () => {
  const bytes = Buffer.from('你好', 'utf8').toString('base64')
  assert.equal(context.decode(bytes), '你好')
})
