import QtQuick
import qs.Ui

// Bar icon that toggles the Monitor Manager panel (Panel.qml).
BarWidget {
  id: root
  moduleName: "io.github.fabiocuccaro.monitor-manager"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍹"
    tooltipText: "Monitor Manager"
    onPressed: function(b) {
      if (root.bar) root.bar.run("omarchy-shell shell toggle io.github.fabiocuccaro.monitor-manager")
    }
  }
}
