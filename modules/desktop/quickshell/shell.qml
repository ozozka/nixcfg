import Quickshell
import Quickshell.Hyprland

ShellRoot {
  id: root

  readonly property var focusedScreen: {
    const monitor = Hyprland.focusedMonitor;
    return Quickshell.screens.find(screen => Hyprland.monitorFor(screen) === monitor)
        ?? Quickshell.screens[0] ?? null;
  }

  Bar {
    id: bar
    onControlsOpened: menu.close()
  }
  Menu {
    id: menu
    focusedScreen: root.focusedScreen
    onOpened: bar.closeDetails()
  }
  Notification {
    focusedScreen: root.focusedScreen
  }
  Polkit {}
  Lock {}
  Wallpaper {}
}
