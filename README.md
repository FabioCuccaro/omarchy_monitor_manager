# Omarchy Monitor Manager

An [Omarchy](https://omarchy.org) shell plugin to arrange your displays
visually: drag monitors into place with snapping, pick resolution, scale,
rotation, VRR and mirroring, try the layout live with an automatic rollback,
then save it to `~/.config/hypr/monitors.lua`.


### Demo
*Drag the monitors, try the layout live, save.*

https://github.com/user-attachments/assets/0b1ef378-7105-4c5d-b816-a2d7b57fb3cd


> **Status: early development (0.1.0).** This plugin grew out of the
> standalone GTK app
> [omarchy_monitor_arranger](https://github.com/FabioCuccaro/omarchy_monitor_arranger),
> which is feature complete and remains available.

## Features

- Drag & drop layout with magnetic snapping to edges, adjacency and centres
  (hold <kbd>Shift</kbd> to disable), guide lines and hysteresis so it doesn't
  jitter at the snap boundary.
- Per monitor: on/off, resolution & refresh rate, scale (only values with an
  integer logical size), rotation/flip, mirroring, VRR.
- Neighbours stay attached when a monitor's size changes.
- Warnings for overlapping or unreachable monitors, with a one-click **Fix**.
- **Try** applies the layout via `hyprctl eval` and rolls back after 15 s
  unless you keep it.
- **Save** rewrites only your outputs' `hl.monitor({...})` blocks (comments,
  variables, the catch-all rule and unmanaged fields such as `bitdepth` are
  kept), backs the file up (last 10 kept), reloads Hyprland and reports
  `hyprctl configerrors`.
- Native look: Omarchy shell fonts, controls and theme colours.

## Requirements

- Omarchy with the Quickshell-based shell and Hyprland ≥ 0.55 (Lua config).
- `python3`, only for the optional menu entry script (it validates the menu
  file before saving it).

## Install

```bash
omarchy plugin add https://github.com/FabioCuccaro/omarchy_monitor_manager.git --enable
```

The plugin is cloned into
`~/.config/omarchy/plugins/io.github.fabiocuccaro.monitor-manager/`.
To update or uninstall it:

```bash
omarchy plugin update io.github.fabiocuccaro.monitor-manager
omarchy plugin remove io.github.fabiocuccaro.monitor-manager
```

If the panel still shows the old version after an update, run
`omarchy restart shell` (the shell caches the plugin's QML).

## Usage

```bash
omarchy-shell shell toggle io.github.fabiocuccaro.monitor-manager
```

<kbd>Esc</kbd> closes the panel.

### Omarchy menu entry

`omarchy plugin add` never runs plugin code, so adding the menu entry is a
separate, opt-in step. This adds **Monitor Manager** at the end of the
*Setup* menu:

```bash
~/.config/omarchy/plugins/io.github.fabiocuccaro.monitor-manager/menu-entry.sh install
```

It edits `~/.config/omarchy/extensions/omarchy-menu.jsonc` (with a backup and
a parse check, so a mistake can't break your menu). The entry hides itself if
the plugin is removed; `menu-entry.sh remove` takes it out for good.

You can also bind the command above to a key in `~/.config/hypr/bindings.lua`.

## Development

```
manifest.json        plugin manifest (kind: panel)
Panel.qml            UI: window, canvas, sidebar, try/save flow
Model.js             pure layout + monitors.lua logic, no QML types
menu-entry.sh        opt-in Omarchy menu entry (install/remove)
test/model.test.js   node tests for Model.js
test/fixtures.json   golden results from the reference GTK implementation
```

```bash
node test/model.test.js                                   # logic tests
omarchy plugin validate "$PWD"                            # manifest
qmllint -I "$OMARCHY_PATH/shell" Panel.qml                # QML
```

To try local changes, copy the plugin files into the installed plugin folder
and restart the shell — saving files there triggers a reload, but changed QML
is only picked up reliably after a restart:

```bash
cp manifest.json Model.js Panel.qml \
  ~/.config/omarchy/plugins/io.github.fabiocuccaro.monitor-manager/
omarchy restart shell
```

## Roadmap

- [ ] Identify: show each output's name on its screen
- [ ] Undo and keyboard navigation (arrows to nudge, Tab to cycle)
- [ ] Precise X/Y position fields
- [ ] A shortcut from the built-in Display panel (needs a change in Omarchy itself)
- [ ] Publish on [plugins.omarchy.org](https://plugins.omarchy.org)

## License

[MIT](LICENSE) © 2026 Fabio Cuccaro
