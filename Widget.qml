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
    iconComponent: Component {
      // Two screens side by side, drawn so it follows the bar's foreground and
      // can't be mistaken for the stock monitor glyph.
      Item {
        readonly property real stroke: Math.max(1.5, width / 12)
        Rectangle {
          x: 0
          y: parent.height * 0.2
          width: parent.width * 0.46
          height: parent.height * 0.6
          radius: 2
          color: "transparent"
          border.width: parent.stroke
          border.color: button.foreground
        }
        Rectangle {
          x: parent.width * 0.54
          y: parent.height * 0.3
          width: parent.width * 0.46
          height: parent.height * 0.4
          radius: 2
          color: "transparent"
          border.width: parent.stroke
          border.color: button.foreground
        }
      }
    }
    tooltipText: "Monitor Manager"
    onPressed: function(b) {
      if (root.bar) root.bar.run("omarchy-shell shell toggle io.github.fabiocuccaro.monitor-manager")
    }
  }
}
