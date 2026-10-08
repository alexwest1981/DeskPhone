import QtQuick
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.alexwest1981.deskphone"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰏲 DeskPhone"
    tooltipText: "DeskPhone – SMS, samtal och notifikationer från telefonen"
    onPressed: function(btn) {
      if (!root.bar) return
      if (btn === Qt.RightButton) {
        root.bar.run("omarchy-shell shell call io.github.alexwest1981.deskphone refresh '{}'")
      } else {
        root.bar.run("omarchy-shell shell toggle io.github.alexwest1981.deskphone '{}'")
      }
    }
  }
}
