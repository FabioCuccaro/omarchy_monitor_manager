import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Monitor Arranger for omarchy-shell. Summoned/toggled through the shell host:
//   omarchy-shell shell toggle io.github.fabiocuccaro.monitor-arranger
// The host calls open(payloadJson) / close() and reads `opened`; it also
// injects `shell` right after the Loader resolves.
//
// All layout and monitors.lua logic lives in Model.js (tested under node).
// Monitors are plain JS objects mutated in place, so every change bumps
// `revision`, which the bindings below depend on to re-evaluate.
//
// TODO: identify overlay on each screen, undo, keyboard navigation.
Item {
  id: root

  property bool opened: false
  readonly property string selfId: "io.github.fabiocuccaro.monitor-arranger"
  property var shell: null
  onShellChanged: {
    if (!root.opened && root.shell && root.shell.openPanelIds
        && root.shell.openPanelIds[root.selfId] === true)
      root.open("{}")
  }

  readonly property string configPath: Quickshell.env("HOME") + "/.config/hypr/monitors.lua"
  readonly property int revertSeconds: 15
  readonly property int snapPx: 14

  // ------------------------------------------------------------------ state

  property var monitors: []
  property int revision: 0
  property int selectedIndex: 0
  property var liveSnapshot: ({})
  property string configText: ""
  property string statusText: ""
  property bool snapEnabled: true

  readonly property var selected: {
    root.revision
    return root.monitors.length ? root.monitors[Math.min(root.selectedIndex, root.monitors.length - 1)] : null
  }
  readonly property bool dirty: {
    root.revision
    return !Model.sameSnapshot(Model.snapshot(root.monitors), root.liveSnapshot)
  }
  readonly property var warnings: {
    root.revision
    var out = []
    var bad = Model.overlappingNames(root.monitors)
    if (bad.length) out.push(bad.join(" and ") + " overlap")
    var far = Model.detachedMonitors(Model.layoutMonitors(root.monitors))
    if (far.length) out.push(far.map(function(m) { return m.name }).join(", ")
                             + (far.length === 1 ? " does" : " do") + " not touch the others")
    return out
  }

  function changed() { root.revision++ }

  // ------------------------------------------------------------------ theme

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color accent: Color.accent
  property color urgent: Color.urgent
  property color muted: Color.muted
  property string fontFamily: Style.font.family

  function mix(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
  }
  // One hue per monitor, rotated from the theme accent so they stay on palette.
  function monitorColor(name) {
    var names = root.monitors.map(function(m) { return m.name }).sort()
    var i = Math.max(0, names.indexOf(name))
    var a = root.accent
    var hue = a.hslHue < 0 ? 0.6 : a.hslHue
    return Qt.hsla((hue + i * 0.13) % 1, Math.max(a.hslSaturation, 0.35), Math.min(Math.max(a.hslLightness, 0.45), 0.65), 1)
  }

  // ------------------------------------------------------------- open/close

  function open(payloadJson) {
    root.opened = true
    root.reload()
  }

  function close() {
    if (!root.opened) return
    if (revertTimer.running) root.finishTry(false)
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.selfId)
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // --------------------------------------------------------------- loading

  function reload() {
    configFile.reload()
    readMonitors.running = true
  }

  FileView {
    id: configFile
    path: root.configPath
    printErrors: false
    atomicWrites: false   // write in place: Hyprland watches the file for auto-reload
    onLoaded: root.configText = text()
    onLoadFailed: function(err) { root.configText = "" }
  }

  Process {
    id: readMonitors
    command: ["hyprctl", "monitors", "all", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          var keep = root.selected ? root.selected.name : ""
          root.monitors = Model.buildMonitors(data, root.configText)
          root.liveSnapshot = Model.snapshot(root.monitors)
          var idx = root.monitors.findIndex(function(m) { return m.name === keep })
          if (idx < 0) idx = Math.max(0, root.monitors.findIndex(function(m) { return m.focused }))
          root.selectedIndex = idx
          root.changed()
        } catch (e) {
          root.statusText = "Couldn't read the monitors: " + e
        }
      }
    }
  }

  // -------------------------------------------------------------- applying

  // Runs `hyprctl eval` once per Lua line and stops at the first answer that
  // isn't "ok" (with the Lua config, `hyprctl keyword` no longer works).
  Process {
    id: evalProc
    property var onDone: null
    stdout: StdioCollector { id: evalOut; waitForEnd: true }
    onExited: function(code) {
      var cb = evalProc.onDone
      evalProc.onDone = null
      if (cb) cb(code === 0, evalOut.text.trim())
    }
  }

  function evalLines(monitors, done) {
    var lines = Model.applyOrder(monitors).map(function(m) { return Model.luaInline(m, true) })
    evalProc.onDone = done
    evalProc.command = ["sh", "-c",
      'for l in "$@"; do out=$(hyprctl eval "$l" 2>&1); [ "$out" = ok ] || { echo "$out"; exit 1; }; done',
      "sh"].concat(lines)
    evalProc.running = true
  }

  property var previousMonitors: []
  property int countdown: 0

  // Read the live state right before applying, so a rollback restores what
  // Hyprland really had (not what was loaded when the panel opened).
  Process {
    id: liveProc
    command: ["hyprctl", "monitors", "all", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.previousMonitors = Model.buildMonitors(JSON.parse(text), root.configText)
        } catch (e) {
          root.statusText = "Couldn't read the monitors: " + e
          return
        }
        root.evalLines(root.monitors, function(ok, out) {
          if (!ok) {
            root.statusText = "Not applied: " + out
            root.evalLines(root.previousMonitors, null)
            return
          }
          root.countdown = root.revertSeconds
          revertTimer.start()
        })
      }
    }
  }

  function tryLayout() {
    if (evalProc.running || liveProc.running || revertTimer.running) return
    Model.normalize(root.monitors)
    root.changed()
    liveProc.running = true
  }

  function finishTry(keep) {
    revertTimer.stop()
    root.countdown = 0
    if (keep) {
      root.liveSnapshot = Model.snapshot(root.monitors)
      root.statusText = "Applied. Save it to keep it after a restart."
      root.changed()
    } else {
      root.evalLines(root.previousMonitors, null)
      root.statusText = "Previous configuration restored."
    }
  }

  Timer {
    id: revertTimer
    interval: 1000
    repeat: true
    onTriggered: {
      root.countdown--
      if (root.countdown <= 0) root.finishTry(false)
    }
  }

  // ---------------------------------------------------------------- saving

  Process {
    id: backupProc
    property string newText: ""
    command: ["sh", "-c", 'f="$1"; [ -f "$f" ] || exit 0; cp -p "$f" "$f.bak.$(date +%Y%m%d%H%M%S)"; '
              + 'ls -1t "$f".bak.* 2>/dev/null | tail -n +11 | xargs -r rm -f', "sh", root.configPath]
    onExited: function(code) {
      if (code !== 0) { root.statusText = "Backup failed, nothing saved."; return }
      configFile.setText(backupProc.newText)
      reloadProc.running = true
    }
  }

  Process {
    id: reloadProc
    command: ["sh", "-c", "hyprctl reload >/dev/null && hyprctl -j configerrors"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var errors = []
        try { errors = JSON.parse(text).filter(function(e) { return e && e.trim() }) } catch (e) {}
        if (errors.length) {
          root.statusText = "Saved, but Hyprland reports errors: " + errors.join(" · ")
        } else {
          root.liveSnapshot = Model.snapshot(root.monitors)
          root.statusText = "Saved to ~/.config/hypr/monitors.lua"
          root.changed()
        }
      }
    }
  }

  function save() {
    if (backupProc.running || reloadProc.running) return
    Model.normalize(root.monitors)
    root.changed()
    backupProc.newText = Model.updateConfigText(root.configText, root.monitors)
    backupProc.running = true
  }

  // ---------------------------------------------------------------- editing

  function select(i) { root.selectedIndex = i; root.changed() }

  function setMode(value) {
    var m = root.selected
    var md = m.modes[parseInt(value, 10)]
    Model.changeGeometry(root.monitors, m, function() {
      m.width = md[0]; m.height = md[1]; m.refresh = md[2]
      m.scale = Model.nearest(Model.validScales(md[0], md[1]), m.scale)
    })
    root.changed()
  }

  function setScale(value) {
    var m = root.selected
    Model.changeGeometry(root.monitors, m, function() { m.scale = parseFloat(value) })
    root.changed()
  }

  function setTransform(value) {
    var m = root.selected
    Model.changeGeometry(root.monitors, m, function() { m.transform = parseInt(value, 10) })
    root.changed()
  }

  function setEnabled(on) {
    var m = root.selected
    if (!on && Model.layoutMonitors(root.monitors).filter(function(o) { return o !== m }).length === 0) {
      root.statusText = "At least one screen must stay on."
      return
    }
    m.disabled = !on
    if (m.disabled) root.monitors.forEach(function(o) { if (o.mirror === m.name) o.mirror = "" })
    Model.normalize(root.monitors)
    root.changed()
  }

  function setMirror(value) {
    var m = root.selected
    m.mirror = value === "-" ? "" : value
    if (m.mirror) root.monitors.forEach(function(o) { if (o.mirror === m.name) o.mirror = "" })
    Model.normalize(root.monitors)
    root.changed()
  }

  function setVrr(value) { root.selected.vrr = parseInt(value, 10); root.changed() }

  function fix() { if (Model.autoArrange(root.monitors)) root.changed() }

  // ------------------------------------------------------------------ window

  FloatingWindow {
    id: win
    visible: root.opened
    title: "Monitor Arranger"
    color: root.background
    implicitWidth: Style.space(1100)
    implicitHeight: Style.space(680)
    minimumSize: Qt.size(Style.space(760), Style.space(480))
    onClosed: root.close()

    Item {
      anchors.fill: parent
      anchors.margins: Style.spacing.panelPadding
      focus: true
      Keys.onEscapePressed: root.close()

      // ---- header
      Row {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.spacing.md
        height: Math.max(titleCol.implicitHeight, saveBtn.implicitHeight)

        Column {
          id: titleCol
          width: parent.width - actions.width - parent.spacing
          anchors.verticalCenter: parent.verticalCenter
          Text {
            text: "Monitor Arranger"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          Text {
            text: {
              root.revision
              var n = Model.layoutMonitors(root.monitors).length
              return n + " active " + (n === 1 ? "screen" : "screens")
                     + (root.dirty ? " · unapplied changes" : " · current")
            }
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          id: actions
          spacing: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          Button { text: "Reload"; bordered: true; onClicked: root.reload() }
          Button {
            text: root.snapEnabled ? "Snap: on" : "Snap: off"
            bordered: true
            selected: root.snapEnabled
            onClicked: root.snapEnabled = !root.snapEnabled
          }
          Button { text: "Try"; bordered: true; onClicked: root.tryLayout() }
          Button { id: saveBtn; text: "Save"; bordered: true; active: true; onClicked: root.save() }
        }
      }

      // ---- canvas
      Rectangle {
        id: canvas
        anchors.top: header.bottom
        anchors.topMargin: Style.spacing.lg
        anchors.left: parent.left
        anchors.bottom: statusLine.top
        anchors.bottomMargin: Style.spacing.md
        width: parent.width - sidebar.width - Style.spacing.xl
        radius: Style.cornerRadius
        color: root.mix(root.background, root.foreground, 0.03)
        border.color: root.mix(root.background, root.foreground, 0.12)
        clip: true

        // view transform, frozen while dragging so the layout doesn't rescale under the cursor
        property bool frozen: false
        property real zoom: 0.1
        property real ox: 0
        property real oy: 0
        property real px: 0
        property real py: 0
        property var guides: []

        function fit() {
          if (canvas.frozen) return
          var lay = Model.layoutMonitors(root.monitors)
          if (!lay.length || canvas.width <= 0) return
          var minX = Math.min.apply(null, lay.map(function(m) { return m.x }))
          var minY = Math.min.apply(null, lay.map(function(m) { return m.y }))
          var bw = Math.max(Math.max.apply(null, lay.map(function(m) { return m.x + Model.logicalW(m) })) - minX, 1)
          var bh = Math.max(Math.max.apply(null, lay.map(function(m) { return m.y + Model.logicalH(m) })) - minY, 1)
          var pad = Style.space(48)
          canvas.zoom = Math.max(0.01, Math.min(0.5, Math.min((canvas.width - 2 * pad) / bw, (canvas.height - 2 * pad) / bh)))
          canvas.ox = minX
          canvas.oy = minY
          canvas.px = (canvas.width - bw * canvas.zoom) / 2
          canvas.py = (canvas.height - bh * canvas.zoom) / 2
        }
        onWidthChanged: fit()
        onHeightChanged: fit()
        Connections {
          target: root
          function onRevisionChanged() { canvas.fit() }
        }

        Repeater {
          model: {
            root.revision
            return root.monitors.map(function(m, i) { return i })
          }

          delegate: Rectangle {
            id: tile
            required property int modelData
            readonly property var mon: { root.revision; return root.monitors[modelData] }
            readonly property bool isSelected: modelData === root.selectedIndex
            readonly property color tint: root.monitorColor(mon ? mon.name : "")
            readonly property bool overlapping: { root.revision; return Model.overlappingNames(root.monitors).indexOf(mon.name) >= 0 }

            visible: !!mon && Model.inLayout(mon)
            x: { root.revision; canvas.zoom; return mon ? (mon.x - canvas.ox) * canvas.zoom + canvas.px : 0 }
            y: { root.revision; canvas.zoom; return mon ? (mon.y - canvas.oy) * canvas.zoom + canvas.py : 0 }
            width: { root.revision; return mon ? Model.logicalW(mon) * canvas.zoom : 0 }
            height: { root.revision; return mon ? Model.logicalH(mon) * canvas.zoom : 0 }
            z: isSelected ? 2 : 1
            radius: Math.min(Style.cornerRadius + Style.space(6), width / 8, height / 8)
            color: root.mix(root.background, tint, isSelected ? 0.34 : (dragArea.containsMouse ? 0.24 : 0.16))
            border.width: isSelected ? Style.space(3) : Style.space(1)
            border.color: overlapping ? root.urgent : tint

            Column {
              anchors.centerIn: parent
              width: parent.width - Style.space(16)
              spacing: Style.space(2)
              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: tile.mon ? tile.mon.name : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Math.max(Style.font.caption, Math.min(Style.font.display, tile.height * 0.12))
                font.bold: true
              }
              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                visible: tile.height > Style.space(70)
                text: tile.mon ? tile.mon.width + "×" + tile.mon.height + " · " + Model.fmtRefresh(tile.mon.refresh)
                                 + " Hz\nscale " + Model.scaleLabel(tile.mon.scale) + " · "
                                 + Math.round(Model.logicalW(tile.mon)) + "×" + Math.round(Model.logicalH(tile.mon)) : ""
                color: root.mix(root.background, root.foreground, 0.75)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              id: dragArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
              property real startX: 0
              property real startY: 0
              property real pressX: 0
              property real pressY: 0
              property var sticky: [null, null]

              onPressed: function(mouse) {
                root.select(tile.modelData)
                var p = mapToItem(canvas, mouse.x, mouse.y)
                pressX = p.x; pressY = p.y
                startX = tile.mon.x; startY = tile.mon.y
                sticky = [null, null]
                canvas.frozen = true
              }
              onPositionChanged: function(mouse) {
                if (!pressed) return
                var p = mapToItem(canvas, mouse.x, mouse.y)
                var nx = startX + (p.x - pressX) / canvas.zoom
                var ny = startY + (p.y - pressY) / canvas.zoom
                if (root.snapEnabled && !(mouse.modifiers & Qt.ShiftModifier)) {
                  var others = Model.layoutMonitors(root.monitors).filter(function(o) { return o !== tile.mon })
                  var r = Model.snapPosition(tile.mon, nx, ny, others, root.snapPx / canvas.zoom, sticky)
                  nx = r.x; ny = r.y; sticky = r.sticky
                  canvas.guides = r.guides
                } else {
                  canvas.guides = []
                }
                nx = Math.round(nx); ny = Math.round(ny)
                if (nx === tile.mon.x && ny === tile.mon.y) return
                tile.mon.x = nx; tile.mon.y = ny
                root.changed()
              }
              onReleased: {
                canvas.frozen = false
                canvas.guides = []
                Model.normalize(root.monitors)
                root.changed()
              }
            }
          }
        }

        // snap guides
        Repeater {
          model: canvas.guides
          delegate: Rectangle {
            required property var modelData
            readonly property bool vertical: modelData[0] === "v"
            z: 3
            color: root.accent
            opacity: 0.8
            x: vertical ? (modelData[1] - canvas.ox) * canvas.zoom + canvas.px : 0
            y: vertical ? 0 : (modelData[1] - canvas.oy) * canvas.zoom + canvas.py
            width: vertical ? Style.space(1) : canvas.width
            height: vertical ? canvas.height : Style.space(1)
          }
        }

        // warnings float over the canvas so they never shift the layout
        Rectangle {
          z: 4
          visible: root.warnings.length > 0 && !canvas.frozen
          anchors.top: parent.top
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.topMargin: Style.spacing.lg
          width: warnRow.implicitWidth + Style.spacing.xl * 2
          height: warnRow.implicitHeight + Style.spacing.md * 2
          radius: Style.cornerRadius
          color: root.background
          border.color: root.urgent
          Row {
            id: warnRow
            anchors.centerIn: parent
            spacing: Style.spacing.lg
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "⚠  " + root.warnings.join(" · ")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Button { text: "Fix"; bordered: true; onClicked: root.fix() }
          }
        }

        // confirm a tried layout; without an answer it rolls back on its own
        Rectangle {
          z: 5
          visible: revertTimer.running
          anchors.centerIn: parent
          width: confirmCol.implicitWidth + Style.spacing.xxl * 2
          height: confirmCol.implicitHeight + Style.spacing.xxl * 2
          radius: Style.cornerRadius
          color: root.background
          border.color: root.accent
          Column {
            id: confirmCol
            anchors.centerIn: parent
            spacing: Style.spacing.lg
            Text {
              text: "Keep this configuration?"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }
            Text {
              text: "Reverting in " + root.countdown + " s unless you confirm."
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Row {
              spacing: Style.spacing.md
              Button { text: "Revert"; bordered: true; onClicked: root.finishTry(false) }
              Button { text: "Keep"; bordered: true; active: true; onClicked: root.finishTry(true) }
            }
          }
        }
      }

      // ---- sidebar
      Column {
        id: sidebar
        anchors.top: canvas.top
        anchors.right: parent.right
        width: Style.space(320)
        spacing: Style.spacing.md

        Text {
          text: "Screens"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Repeater {
          model: { root.revision; return root.monitors.map(function(m, i) { return i }) }
          delegate: Rectangle {
            id: row
            required property int modelData
            readonly property var mon: { root.revision; return root.monitors[modelData] }
            width: sidebar.width
            height: rowCol.implicitHeight + Style.spacing.md * 2
            radius: Style.cornerRadius
            color: modelData === root.selectedIndex ? Style.selectedFill
                   : (rowArea.containsMouse ? Style.hoverFill : "transparent")
            Rectangle {
              id: dot
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(10); height: width; radius: width / 2
              color: root.monitorColor(row.mon ? row.mon.name : "")
            }
            Column {
              id: rowCol
              anchors.left: dot.right
              anchors.leftMargin: Style.spacing.md
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              Text {
                width: parent.width
                elide: Text.ElideRight
                text: row.mon ? row.mon.name + "   " + (row.mon.disabled ? "off" : row.mon.mirror ? "mirrors " + row.mon.mirror
                                : row.mon.width + "×" + row.mon.height + " · " + Model.scaleLabel(row.mon.scale) + "×") : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                text: row.mon ? Model.subtitle(row.mon) : ""
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
            MouseArea { id: rowArea; anchors.fill: parent; hoverEnabled: true; onClicked: root.select(row.modelData) }
          }
        }

        Item { width: 1; height: Style.spacing.md }

        Text {
          visible: !!root.selected
          text: root.selected ? root.selected.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Row {
          visible: !!root.selected
          spacing: Style.spacing.md
          ToggleSwitch {
            checked: { root.revision; return root.selected ? !root.selected.disabled : false }
            onToggled: root.setEnabled(!checked)
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Enabled"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        Dropdown {
          width: sidebar.width
          visible: !!root.selected
          enabled: !!root.selected && Model.inLayout(root.selected)
          label: "Resolution"
          value: { root.revision; return root.selected ? String(Model.modeIndex(root.selected)) : "" }
          options: {
            root.revision
            if (!root.selected) return []
            return root.selected.modes.map(function(md, i) {
              return { label: md[0] + "×" + md[1] + " @ " + Model.fmtRefresh(md[2]) + " Hz", value: String(i) }
            })
          }
          onChanged: function(v) { root.setMode(v) }
        }

        Dropdown {
          width: sidebar.width
          visible: !!root.selected
          enabled: !!root.selected && Model.inLayout(root.selected)
          label: "Scale"
          value: { root.revision; return root.selected ? String(Model.nearest(Model.scalesFor(root.selected), root.selected.scale)) : "" }
          options: {
            root.revision
            var m = root.selected
            if (!m) return []
            var lw = Model.isRotated(m) ? m.height : m.width
            var lh = Model.isRotated(m) ? m.width : m.height
            return Model.scalesFor(m).map(function(s) {
              return { label: Model.scaleLabel(s) + "× · " + Math.round(lw / s) + "×" + Math.round(lh / s), value: String(s) }
            })
          }
          onChanged: function(v) { root.setScale(v) }
        }

        Dropdown {
          width: sidebar.width
          visible: !!root.selected
          enabled: !!root.selected && Model.inLayout(root.selected)
          label: "Rotation"
          value: { root.revision; return root.selected ? String(root.selected.transform) : "" }
          options: Model.TRANSFORMS.map(function(t, i) { return { label: t, value: String(i) } })
          onChanged: function(v) { root.setTransform(v) }
        }

        Dropdown {
          width: sidebar.width
          visible: !!root.selected
          enabled: !!root.selected && !root.selected.disabled
          label: "Mirror"
          value: { root.revision; return root.selected && root.selected.mirror ? root.selected.mirror : "-" }
          options: {
            root.revision
            var m = root.selected
            if (!m) return []
            return [{ label: "No", value: "-" }].concat(root.monitors.filter(function(o) {
              return o !== m && !o.disabled && !o.mirror
            }).map(function(o) { return { label: o.name, value: o.name } }))
          }
          onChanged: function(v) { root.setMirror(v) }
        }

        Dropdown {
          width: sidebar.width
          visible: !!root.selected
          enabled: !!root.selected && !root.selected.disabled
          label: "VRR"
          value: { root.revision; return root.selected ? String(root.selected.vrr) : "" }
          options: Model.VRR_MODES.map(function(t, i) { return { label: t, value: String(i) } })
          onChanged: function(v) { root.setVrr(v) }
        }

        Text {
          visible: !!root.selected
          text: { root.revision; return root.selected ? "Position " + root.selected.x + ", " + root.selected.y : "" }
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ---- status line
      Text {
        id: statusLine
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        elide: Text.ElideRight
        text: root.statusText || "Drag to move · Shift: no snapping · Esc: close"
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
