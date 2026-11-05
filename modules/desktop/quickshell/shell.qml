import Quickshell

ShellRoot {
  id: root

  property T theme: T {}
  property Lib lib: Lib {
    theme: root.theme
  }

  Bar {
    id: bar
    theme: root.theme
    lib: root.lib
    onControlsOpened: menu.close()
  }
  Menu {
    id: menu
    theme: root.theme
    lib: root.lib
    focusedScreen: root.lib.focusedScreen
    onOpened: bar.closeDetails()
  }
  Notification {
    theme: root.theme
    focusedScreen: root.lib.focusedScreen
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
