import QtQuick
import Quickshell
import Quickshell.Wayland

Scope {
  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData
      screen: modelData

      WlrLayershell.namespace: "wallpaper"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.exclusiveZone: -1
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      anchors {
        top: true
        bottom: true
        left: true
        right: true
      }

      color: T.colB

      Image {
        anchors.fill: parent
        fillMode: Image.PreserveAspectFit
        source: Qt.resolvedUrl(T.wallpaper)
      }
    }
  }
}
