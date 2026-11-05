import Quickshell
import Quickshell.Hyprland

ShellRoot {
  id: root

  property T theme: T {}
  readonly property var focusedScreen: {
    const monitor = Hyprland.focusedMonitor;
    return Quickshell.screens.find(screen => Hyprland.monitorFor(screen) === monitor)
        ?? Quickshell.screens[0] ?? null;
  }

  Bar {
    id: bar
    theme: root.theme
    onControlsOpened: menu.close()
  }
  Menu {
    id: menu
    theme: root.theme
    focusedScreen: root.focusedScreen
    onOpened: bar.closeDetails()
  }
  Notification {
    theme: root.theme
    focusedScreen: root.focusedScreen
  }
  Polkit {
    theme: root.theme
  }
  Lock {
    theme: root.theme
  }
  Wallpaper {
    theme: root.theme
  }
}
