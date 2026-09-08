import QtQuick
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "alex.phone"

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
        root.bar.run("omarchy-shell shell call alex.phone refresh '{}'")
      } else {
        root.bar.run("omarchy-shell shell toggle alex.phone '{}'")
      }
    }
  }
}
