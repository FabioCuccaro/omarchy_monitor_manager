#!/usr/bin/env node
'use strict'

// Regression tests for Model.js without a QML host: node test/model.test.js
// Model.js is a QML `.pragma library` module; stripping that line lets node run it as is.
//
// fixtures.json holds golden results produced by the reference implementation
// of the standalone GTK app (gtk-standalone branch), so the plugin keeps the
// exact same layout and monitors.lua behaviour.

const fs = require('fs')
const path = require('path')
const vm = require('vm')

const source = fs.readFileSync(path.join(__dirname, '..', 'Model.js'), 'utf8')
  .replace(/^\.pragma library\s*/, '')
const M = {}
vm.createContext(M)
vm.runInContext(source, M, { filename: 'Model.js' })

const fx = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures.json'), 'utf8'))

let checks = 0
let failures = 0

function check(label, actual, expected) {
  checks++
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) {
    failures++
    console.error(`FAIL ${label}:\n  expected ${e}\n  got      ${a}`)
  }
}

function build() { return M.buildMonitors(fx.hypr, fx.omarchyConfig) }
function states(mons) { return mons.map(M.state) }
function clone(mons) { return JSON.parse(JSON.stringify(mons)) }

// --- parsing hyprctl output
const mons = build()
check('states', states(mons), fx.built.states)
check('modes', mons.map(m => m.modes), fx.built.modes)
check('eval lines', mons.map(m => M.luaInline(m, true)), fx.built.inline)
check('apply order', M.applyOrder(mons).map(m => m.name), fx.built.applyOrder)

// --- monitors.lua rewriting
check('rewrite matches reference (new outputs appended)', M.updateConfigText(fx.omarchyConfig, mons), fx.roundtrip)
check('unchanged monitors leave the file byte for byte identical',
      M.updateConfigText(fx.omarchyConfig, mons.slice(0, 2)), fx.omarchyConfig)
const edge = clone(mons)
edge[1].transform = 1
edge[1].vrr = 2
check('desc:, extra fields, comments, duplicates', M.updateConfigText(fx.edgeConfig, edge), fx.edge)
check('empty file gets header + blocks', M.updateConfigText('', mons.slice(0, 2)), fx.empty)

// --- formatting and scales
for (const key of Object.keys(fx.scales)) {
  const [w, h] = key.split('x').map(Number)
  check(`valid scales ${key}`, M.validScales(w, h), fx.scales[key])
}
for (const [s, scale, label] of fx.labels) {
  check(`fmtScale ${s}`, M.fmtScale(s), scale)
  check(`scaleLabel ${s}`, M.scaleLabel(s), label)
}
for (const [r, label] of fx.refresh) check(`fmtRefresh ${r}`, M.fmtRefresh(r), label)

// --- snapping with hysteresis
{
  const lay = clone(mons.slice(0, 2))
  lay[1].x = 2600
  lay[1].y = 200
  let sticky = [null, null]
  fx.snaps.steps.forEach(([raw, x, y, guides, expSticky]) => {
    const r = M.snapPosition(lay[1], raw, 200, [lay[0]], fx.snaps.threshold, sticky)
    sticky = r.sticky
    check(`snap raw=${raw}`, [r.x, r.y, r.guides, r.sticky], [x, y, guides, expSticky])
  })
}

// --- geometry
{
  const over = clone(mons.slice(0, 2))
  over[1].x = 300
  over[1].y = 700
  check('overlap state', states(over), fx.geometry.overlapState)
  check('overlapping names', M.overlappingNames(over), fx.geometry.overlapping)

  const far = clone(mons.slice(0, 2))
  far[1].x = 5000
  far[1].y = 0
  check('detached', M.detachedMonitors(far).map(m => m.name), fx.geometry.detached)
  check('not detached', M.detachedMonitors(clone(mons.slice(0, 2))).map(m => m.name), fx.geometry.detachedNone)

  const row = clone(over)
  M.autoArrange(row)
  check('auto arrange (row)', states(row), fx.geometry.autoArrangeRow)

  const col = clone(mons.slice(0, 2))
  col[1].x = 2000
  col[1].y = 1350
  M.autoArrange(col)
  check('auto arrange (column)', states(col), fx.geometry.autoArrangeColumn)

  const side = clone(mons.slice(0, 2))
  side[1].x = 2400
  side[1].y = 0
  M.changeGeometry(side, side[0], () => { side[0].transform = 1 })
  check('rotation keeps neighbour attached', states(side), fx.geometry.rotateKeepsNeighbour)
}

// --- undo snapshots
{
  const a = clone(mons)
  const snap = M.snapshot(a)
  a[0].x = 123
  a[1].scale = 2
  check('snapshot detects change', M.sameSnapshot(snap, M.snapshot(a)), false)
  M.restore(a, snap)
  check('restore brings it back', M.sameSnapshot(snap, M.snapshot(a)), true)
}

// --- sidebar order follows the layout
{
  const mk = (name, x, y, w, h) => ({ name, x, y, width: w, height: h, scale: 1, transform: 0, disabled: false, mirror: '' })
  const stacked = [mk('A', 160, 1080, 1920, 1080), mk('B', 0, 0, 3840, 1080)]
  check('stacked: top first', M.displayOrder(stacked), [1, 0])
  const row = [mk('A', 1920, 0, 1920, 1080), mk('B', 0, 0, 1920, 1080)]
  check('row: left first', M.displayOrder(row), [1, 0])
  const off = [mk('A', 0, 0, 1920, 1080), mk('B', 0, 0, 1920, 1080), mk('C', 1920, 0, 1920, 1080)]
  off[0].disabled = true
  check('disabled screens go last', M.displayOrder(off), [1, 2, 0])
}

if (failures) {
  console.error(`\n${failures} of ${checks} checks failed`)
  process.exit(1)
}
console.log(`ok - ${checks} checks passed`)
