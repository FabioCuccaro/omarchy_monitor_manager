.pragma library

// Pure layout and monitors.lua logic for the Monitor Manager panel.
// No QML types in here, so test/model.test.js can run it under plain node.
//
// A monitor is a plain object:
//   { name, description, make, model, modes: [[w, h, rr], ...],
//     width, height, refresh, x, y, scale, transform, vrr, disabled, mirror, focused }
// width/height/refresh are the physical mode; x/y the position in Hyprland's
// logical layout, which is already scaled and rotated.

var MANAGED_KEYS = ["output", "mode", "position", "scale", "transform", "vrr", "mirror", "disabled"]

var TRANSFORMS = [
  "Normal", "Rotated 90°", "Rotated 180°", "Rotated 270°",
  "Flipped", "Flipped + 90°", "Flipped + 180°", "Flipped + 270°"
]

var VRR_MODES = ["Off", "Always on", "Fullscreen only"]

var CONFIG_HEADER =
  "-- See https://wiki.hypr.land/Configuring/Basics/Monitors/\n" +
  "-- List current monitors and supported resolutions with: hyprctl monitors all\n"

var STATE_KEYS = ["width", "height", "refresh", "x", "y", "scale", "transform", "vrr", "disabled", "mirror"]

// ---------------------------------------------------------------- formatting

function fmtNum(v, digits) {
  var s = Number(v).toFixed(digits)
  if (s.indexOf(".") >= 0) s = s.replace(/0+$/, "").replace(/\.$/, "")
  return (s === "" || s === "-0") ? "0" : s
}

function fmtScale(scale) { return fmtNum(scale, 6) }
function scaleLabel(scale) { return fmtNum(scale, 3) }

function fmtRefresh(rr) {
  if (Math.abs(rr - Math.round(rr)) < 0.01) return String(Math.round(rr))
  return Number(rr).toFixed(2)
}

function luaStr(s) {
  return '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
}

function round2(v) { return Math.round(v * 100) / 100 }

// --------------------------------------------------------------------- modes

function parseModes(raw) {
  var seen = {}
  var modes = []
  for (var i = 0; i < (raw || []).length; i++) {
    var m = /^(\d+)x(\d+)@([\d.]+)/.exec(raw[i])
    if (!m) continue
    var mode = [parseInt(m[1], 10), parseInt(m[2], 10), round2(parseFloat(m[3]))]
    var key = mode.join("x")
    if (seen[key]) continue
    seen[key] = true
    modes.push(mode)
  }
  return modes
}

// Scales that keep the logical resolution integral: Hyprland works in 1/120
// steps and rejects (or adjusts) scales that give fractional pixels.
function validScales(w, h) {
  var out = []
  for (var n = 60; n <= 360; n++)
    if ((w * 120) % n === 0 && (h * 120) % n === 0) out.push(n / 120)
  return out
}

function nearest(values, target) {
  if (!values.length) return target
  var best = values[0]
  for (var i = 1; i < values.length; i++)
    if (Math.abs(values[i] - target) < Math.abs(best - target)) best = values[i]
  return best
}

// ------------------------------------------------------------------- monitor

function monitorFromHypr(d) {
  var modes = parseModes(d.availableModes)
  var w = parseInt(d.width || 0, 10)
  var h = parseInt(d.height || 0, 10)
  var rr = round2(parseFloat(d.refreshRate || 60))
  if (!w || !h) {
    var first = modes.length ? modes[0] : [1920, 1080, 60]
    w = first[0]; h = first[1]; rr = first[2]
  }
  var known = modes.some(function(m) { return m[0] === w && m[1] === h && Math.abs(m[2] - rr) < 0.05 })
  if (!known) modes.unshift([w, h, rr])
  var mirror = String(d.mirrorOf || "none")
  return {
    name: d.name,
    description: d.description || "",
    make: d.make || "",
    model: d.model || "",
    modes: modes,
    width: w, height: h, refresh: rr,
    x: parseInt(d.x || 0, 10), y: parseInt(d.y || 0, 10),
    scale: parseFloat(d.scale || 1) || 1,
    transform: parseInt(d.transform || 0, 10),
    vrr: d.vrr ? 1 : 0,
    disabled: !!d.disabled,
    mirror: mirror === "none" ? "" : mirror,
    focused: !!d.focused
  }
}

// hyprctl reports the mirrored output by id and VRR only as on/off: resolve
// the id to a name and read the VRR mode back from monitors.lua.
function buildMonitors(data, configText) {
  var byId = {}
  data.forEach(function(d) { byId[String(d.id)] = d.name })
  var monitors = data.map(monitorFromHypr)
  var blocks = configText ? findMonitorBlocks(configText) : []
  monitors.forEach(function(m) {
    if (byId[m.mirror] !== undefined) m.mirror = byId[m.mirror]
    blocks.forEach(function(b) {
      var out = blockOutput(b)
      if (out && outputMatches(out, m)) {
        var vrr = fieldValue(b, "vrr")
        if (vrr && /^\d+$/.test(vrr)) m.vrr = parseInt(vrr, 10)
      }
    })
  })
  return monitors
}

function subtitle(m) {
  var s = (m.make + " " + m.model).trim()
  return s || m.description
}

function isRotated(m) { return m.transform % 2 === 1 }
function logicalW(m) { return (isRotated(m) ? m.height : m.width) / m.scale }
function logicalH(m) { return (isRotated(m) ? m.width : m.height) / m.scale }
function inLayout(m) { return !m.disabled && !m.mirror }
function modeSpec(m) { return m.width + "x" + m.height + "@" + fmtRefresh(m.refresh) }

function modeIndex(m) {
  var best = 0, bestKey = null
  for (var i = 0; i < m.modes.length; i++) {
    var md = m.modes[i]
    var key = [(md[0] === m.width && md[1] === m.height) ? 0 : 1, Math.abs(md[2] - m.refresh)]
    if (bestKey === null || key[0] < bestKey[0] || (key[0] === bestKey[0] && key[1] < bestKey[1])) {
      best = i; bestKey = key
    }
  }
  return best
}

function scalesFor(m) {
  var scales = validScales(m.width, m.height)
  if (!scales.some(function(s) { return Math.abs(s - m.scale) < 1e-4 })) {
    scales.push(m.scale)
    scales.sort(function(a, b) { return a - b })
  }
  return scales
}

// Comparable / restorable state (undo, "unapplied changes").
function state(m) {
  return [m.width, m.height, round2(m.refresh), Math.round(m.x), Math.round(m.y),
          Math.round(m.scale * 10000) / 10000, m.transform, m.vrr, m.disabled, m.mirror]
}

function snapshot(monitors) {
  var snap = {}
  monitors.forEach(function(m) { snap[m.name] = state(m) })
  return snap
}

function restore(monitors, snap) {
  monitors.forEach(function(m) {
    var st = snap[m.name]
    if (!st) return
    for (var i = 0; i < STATE_KEYS.length; i++) m[STATE_KEYS[i]] = st[i]
  })
}

function sameSnapshot(a, b) { return JSON.stringify(a) === JSON.stringify(b) }

// explicit=true also writes default values: needed with eval to reset
// rotation/VRR left over from a previous rule.
function luaFields(m, explicit) {
  if (m.disabled) return [["output", luaStr(m.name)], ["disabled", "true"]]
  var fields = [
    ["output", luaStr(m.name)],
    ["mode", luaStr(modeSpec(m))],
    ["position", luaStr(Math.round(m.x) + "x" + Math.round(m.y))],
    ["scale", fmtScale(m.scale)]
  ]
  if (m.transform || explicit) fields.push(["transform", String(m.transform)])
  if (m.vrr || explicit) fields.push(["vrr", String(m.vrr)])
  if (m.mirror) fields.push(["mirror", luaStr(m.mirror)])
  if (explicit) fields.push(["disabled", "false"])
  return fields
}

function luaInline(m, explicit) {
  return "hl.monitor({ " + luaFields(m, explicit).map(function(f) { return f[0] + " = " + f[1] }).join(", ") + " })"
}

// Enabled screens first, then mirrors, disabled ones last: this way we never
// end up halfway through with no output turned on.
function applyOrder(monitors) {
  function rank(m) { return (m.disabled ? 2 : 0) + (m.mirror ? 1 : 0) }
  return monitors.slice().sort(function(a, b) { return rank(a) - rank(b) })
}

// ------------------------------------------------------------------ geometry

function overlaps(a, b) {
  return a.x < b.x + logicalW(b) - 0.5 && b.x < a.x + logicalW(a) - 0.5 &&
         a.y < b.y + logicalH(b) - 0.5 && b.y < a.y + logicalH(a) - 0.5
}

function touches(a, b) {
  var vOverlap = Math.min(a.y + logicalH(a), b.y + logicalH(b)) - Math.max(a.y, b.y)
  var hOverlap = Math.min(a.x + logicalW(a), b.x + logicalW(b)) - Math.max(a.x, b.x)
  var side = (Math.abs(a.x + logicalW(a) - b.x) < 1 || Math.abs(b.x + logicalW(b) - a.x) < 1) && vOverlap > 0
  var stacked = (Math.abs(a.y + logicalH(a) - b.y) < 1 || Math.abs(b.y + logicalH(b) - a.y) < 1) && hOverlap > 0
  return side || stacked || overlaps(a, b)
}

function layoutMonitors(monitors) { return monitors.filter(inLayout) }

function overlappingNames(monitors) {
  var lay = layoutMonitors(monitors)
  var names = {}
  for (var i = 0; i < lay.length; i++)
    for (var j = i + 1; j < lay.length; j++)
      if (overlaps(lay[i], lay[j])) { names[lay[i].name] = true; names[lay[j].name] = true }
  return Object.keys(names).sort()
}

// Screens the cursor cannot reach from the main group.
function detachedMonitors(layout) {
  if (layout.length < 2) return []
  var left = layout.slice()
  var groups = []
  while (left.length) {
    var group = [], queue = [left.shift()]
    while (queue.length) {
      var cur = queue.pop()
      group.push(cur)
      for (var i = left.length - 1; i >= 0; i--) {
        if (touches(cur, left[i])) queue.push(left.splice(i, 1)[0])
      }
    }
    groups.push(group)
  }
  function area(g) { return g.reduce(function(s, m) { return s + logicalW(m) * logicalH(m) }, 0) }
  var main = groups.reduce(function(a, b) { return area(b) > area(a) ? b : a })
  var out = []
  groups.forEach(function(g) { if (g !== main) out = out.concat(g) })
  return out
}

// Snap (x, y) to the edges, adjacencies and centres of the other screens.
// sticky holds the previous step's snaps: they stay active until you move 1.6
// times the threshold away (hysteresis), so it doesn't jump back and forth
// near the limit. Returns { x, y, guides: [["v"|"h", coord]], sticky: [sx, sy] }.
function snapPosition(mon, x, y, others, threshold, sticky) {
  sticky = sticky || [null, null]
  var w = logicalW(mon), h = logicalH(mon)
  var cx = [], cy = []
  others.forEach(function(o) {
    var ox = o.x, oy = o.y, ow = logicalW(o), oh = logicalH(o)
    cx.push([ox + ow, ox + ow], [ox - w, ox], [ox, ox], [ox + ow - w, ox + ow], [ox + (ow - w) / 2, ox + ow / 2])
    cy.push([oy + oh, oy + oh], [oy - h, oy], [oy, oy], [oy + oh - h, oy + oh], [oy + (oh - h) / 2, oy + oh / 2])
  })

  function pick(raw, cands, prev) {
    var i
    if (prev !== null && prev !== undefined) {
      for (i = 0; i < cands.length; i++)
        if (Math.abs(cands[i][0] - prev) < 0.5 && Math.abs(cands[i][0] - raw) < threshold * 1.6) return cands[i]
    }
    var best = null
    for (i = 0; i < cands.length; i++)
      if (best === null || Math.abs(cands[i][0] - raw) < Math.abs(best[0] - raw)) best = cands[i]
    return (best && Math.abs(best[0] - raw) < threshold) ? best : null
  }

  var px = pick(x, cx, sticky[0])
  var py = pick(y, cy, sticky[1])
  var guides = []
  if (px) { x = px[0]; guides.push(["v", px[1]]) }
  if (py) { y = py[0]; guides.push(["h", py[1]]) }
  return { x: x, y: y, guides: guides, sticky: [px ? px[0] : null, py ? py[0] : null] }
}

function normalize(monitors) {
  var lay = layoutMonitors(monitors)
  if (!lay.length) return
  var mx = Math.min.apply(null, lay.map(function(m) { return m.x }))
  var my = Math.min.apply(null, lay.map(function(m) { return m.y }))
  lay.forEach(function(m) { m.x = Math.round(m.x - mx); m.y = Math.round(m.y - my) })
}

// Apply a size change (mode, scale, rotation) keeping the screens that
// touched it on the right and below attached.
function changeGeometry(monitors, mon, mutate) {
  var lay = layoutMonitors(monitors).filter(function(o) { return o !== mon })
  var oldR = mon.x + logicalW(mon), oldB = mon.y + logicalH(mon)
  var right = lay.filter(function(o) {
    return Math.abs(o.x - oldR) < 1 && Math.min(o.y + logicalH(o), oldB) - Math.max(o.y, mon.y) > 0
  })
  var below = lay.filter(function(o) {
    return Math.abs(o.y - oldB) < 1 && Math.min(o.x + logicalW(o), oldR) - Math.max(o.x, mon.x) > 0
  })
  mutate()
  var dr = mon.x + logicalW(mon) - oldR, db = mon.y + logicalH(mon) - oldB
  right.forEach(function(o) { o.x = Math.round(o.x + dr) })
  below.forEach(function(o) { o.y = Math.round(o.y + db) })
  normalize(monitors)
}

// Stacked layouts become a centred column, everything else a bottom-aligned row.
function autoArrange(monitors) {
  var lay = layoutMonitors(monitors)
  if (lay.length < 2) return false
  var minX = Math.min.apply(null, lay.map(function(m) { return m.x }))
  var minY = Math.min.apply(null, lay.map(function(m) { return m.y }))
  var spanW = Math.max.apply(null, lay.map(function(m) { return m.x + logicalW(m) })) - minX
  var spanH = Math.max.apply(null, lay.map(function(m) { return m.y + logicalH(m) })) - minY
  if (spanH > spanW) {
    lay.sort(function(a, b) { return (a.y + logicalH(a) / 2) - (b.y + logicalH(b) / 2) })
    var widest = Math.max.apply(null, lay.map(logicalW))
    var y = 0
    lay.forEach(function(m) { m.x = Math.round((widest - logicalW(m)) / 2); m.y = Math.round(y); y += logicalH(m) })
  } else {
    lay.sort(function(a, b) { return (a.x + logicalW(a) / 2) - (b.x + logicalW(b) / 2) })
    var tallest = Math.max.apply(null, lay.map(logicalH))
    var x = 0
    lay.forEach(function(m) { m.x = Math.round(x); m.y = Math.round(tallest - logicalH(m)); x += logicalW(m) })
  }
  return true
}

// -------------------------------------------------------------- monitors.lua

// Split the body of a Lua table into [key, raw value] pairs.
function splitTopLevel(body) {
  var parts = [], cur = "", depth = 0, inStr = null, i = 0
  while (i < body.length) {
    var c = body[i]
    if (inStr) {
      cur += c
      if (c === "\\" && i + 1 < body.length) { cur += body[i + 1]; i++ }
      else if (c === inStr) inStr = null
    } else if (c === '"' || c === "'") {
      inStr = c; cur += c
    } else if (body.substr(i, 2) === "--") {
      var nl = body.indexOf("\n", i)
      i = nl < 0 ? body.length : nl
      continue
    } else if (c === "{" || c === "(") {
      depth++; cur += c
    } else if (c === "}" || c === ")") {
      depth--; cur += c
    } else if (c === "," && depth === 0) {
      parts.push(cur); cur = ""
    } else {
      cur += c
    }
    i++
  }
  parts.push(cur)
  var fields = []
  parts.forEach(function(p) {
    var m = /^\s*([A-Za-z_]\w*)\s*=\s*([\s\S]+?)\s*$/.exec(p)
    if (m) fields.push([m[1], m[2]])
  })
  return fields
}

// Find the hl.monitor({...}) calls that are not commented out.
function findMonitorBlocks(text) {
  var blocks = []
  var re = /^[ \t]*hl\.monitor\s*\(\s*\{/mg
  var m
  while ((m = re.exec(text)) !== null) {
    var start = m.index + (m[0].length - m[0].replace(/^[ \t]+/, "").length)
    var i = re.lastIndex, depth = 1, inStr = null
    while (i < text.length && depth) {
      var c = text[i]
      if (inStr) {
        if (c === "\\") i++
        else if (c === inStr) inStr = null
      } else if (c === '"' || c === "'") {
        inStr = c
      } else if (text.substr(i, 2) === "--") {
        var nl = text.indexOf("\n", i)
        i = nl < 0 ? text.length : nl
        continue
      } else if (c === "{") {
        depth++
      } else if (c === "}") {
        depth--
      }
      i++
    }
    if (depth) continue
    var j = i
    while (j < text.length && " \t\r\n".indexOf(text[j]) >= 0) j++
    if (j >= text.length || text[j] !== ")") continue
    blocks.push({ start: start, end: j + 1, fields: splitTopLevel(text.slice(re.lastIndex, i - 1)) })
  }
  return blocks
}

function luaUnquote(raw) {
  raw = raw.trim()
  if (raw.length >= 2 && raw[0] === raw[raw.length - 1] && (raw[0] === '"' || raw[0] === "'"))
    return raw.slice(1, -1)
  return null
}

function fieldValue(block, key) {
  for (var i = 0; i < block.fields.length; i++)
    if (block.fields[i][0] === key) return block.fields[i][1]
  return null
}

function blockOutput(block) {
  var raw = fieldValue(block, "output")
  return raw === null ? null : luaUnquote(raw)
}

function outputMatches(out, mon) {
  if (out === mon.name) return true
  var desc = out.indexOf("desc:") === 0 ? out.slice(5).trim() : ""
  return !!desc && mon.description.indexOf(desc) === 0
}

function renderBlock(mon, oldFields, outputRaw) {
  var fields = luaFields(mon, false)
  if (outputRaw) fields[0] = ["output", outputRaw]
  var extra = (oldFields || []).filter(function(f) { return MANAGED_KEYS.indexOf(f[0]) < 0 })
  var lines = ["hl.monitor({"]
  fields.concat(extra).forEach(function(f) { lines.push("  " + f[0] + " = " + f[1] + ",") })
  lines.push("})")
  return lines.join("\n")
}

// Rewrite the blocks of the given monitors leaving everything else untouched
// (comments, variables, the catch-all output = "" rule, extra fields).
function updateConfigText(text, monitors) {
  var blocks = findMonitorBlocks(text)
  var edits = [], appended = [], used = []
  monitors.forEach(function(mon) {
    var mine = blocks.filter(function(b) {
      var o = blockOutput(b)
      return used.indexOf(b) < 0 && o !== null && o !== "" && outputMatches(o, mon)
    })
    if (!mine.length) { appended.push(renderBlock(mon)); return }
    used = used.concat(mine)
    var first = mine[0]
    edits.push([first.start, first.end, renderBlock(mon, first.fields, fieldValue(first, "output"))])
    mine.slice(1).forEach(function(dup) {
      // a duplicate rule would override ours: comment it out
      var old = text.slice(dup.start, dup.end)
      edits.push([dup.start, dup.end, "-- duplicate disabled by monitor-arranger:\n" +
                  old.split("\n").map(function(l) { return "-- " + l }).join("\n")])
    })
  })
  edits.sort(function(a, b) { return b[0] - a[0] })
  edits.forEach(function(e) { text = text.slice(0, e[0]) + e[2] + text.slice(e[1]) })
  if (appended.length) {
    text = text.replace(/\n+$/, "")
    text = (text ? text + "\n\n" : CONFIG_HEADER + "\n") + appended.join("\n\n") + "\n"
  }
  return text
}
