import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets

Scope {
  id: menuModule
  required property T theme
  required property var focusedScreen
  property string pendingAction: ""
  property bool powerExpanded: false
  signal opened
  readonly property var powerEntries: [
    {
      key: "lock",
      symbol: "⎋",
      name: "Lock",
      command: ["qs", "ipc", "call", "lock", "lock"],
      destructive: false
    },
    {
      key: "monitors",
      symbol: "🆥",
      name: "Monitors off",
      command: ["hyprctl", "dispatch", "dpms", "off"],
      destructive: false
    },
    {
      key: "suspend",
      symbol: "⏾",
      name: "Suspend",
      command: ["qs", "ipc", "call", "lock", "suspend"],
      destructive: false
    },
    {
      key: "logout",
      symbol: "⏎",
      name: "Logout",
      command: ["hyprctl", "dispatch", "exit"],
      destructive: true
    },
    {
      key: "reboot",
      symbol: "⏼",
      name: "Reboot",
      command: ["systemctl", "reboot"],
      destructive: true
    },
    {
      key: "shutdown",
      symbol: "⏻",
      name: "Shutdown",
      command: ["systemctl", "poweroff"],
      destructive: true
    }
  ]

  function dismissSelection() {
    pendingAction = "";
    powerExpanded = false;
    applications.focusSearch();
  }

  function togglePower() {
    pendingAction = "";
    powerExpanded = !powerExpanded;
    if (powerExpanded)
      Qt.callLater(() => selection.forceActiveFocus());
    else
      applications.focusSearch();
  }

  function open() {
    pendingAction = "";
    powerExpanded = false;
    if (focusedScreen)
      panel.screen = focusedScreen;
    panel.visible = true;
    opened();
    Qt.callLater(() => {
      applications.resetAndFocus();
      scroll.contentY = Math.max(0, scroll.contentHeight - scroll.height);
    });
  }

  function close() {
    panel.visible = false;
    pendingAction = "";
    applications.query = "";
    powerExpanded = false;
  }

  function activatePower(entry) {
    if (entry.destructive && pendingAction !== entry.key) {
      pendingAction = entry.key;
      return;
    }
    Quickshell.execDetached(entry.command);
    close();
  }

  Component {
    id: powerDetails
    ColumnLayout {
      spacing: menuModule.theme.dimS
      Repeater {
        model: menuModule.powerEntries
        Lib.MenuButton {
          theme: menuModule.theme
          required property var modelData
          Layout.fillWidth: true
          symbol: modelData.symbol
          text: menuModule.pendingAction === modelData.key ? `Confirm ${modelData.name}` :
                                                             modelData.name
          selected: menuModule.pendingAction === modelData.key
          onClicked: menuModule.activatePower(modelData)
        }
      }
    }
  }

  IpcHandler {
    target: "menu"
    function open(): void {
      menuModule.open();
    }
    function hide(): void {
      menuModule.close();
    }
    function toggle(): void {
      if (panel.visible)
        menuModule.close();
      else
        menuModule.open();
    }
  }

  Lib.MenuWindow {
    id: panel

    theme: menuModule.theme
    menuWidth: Math.min(480, width - menuModule.theme.dimS * 2)
    menuHeight: Math.min(applications.height + menuModule.theme.dimS * 2, Math.max(0, height
                                                                                   - menuModule.theme.dimM
                                                                                   - menuModule.theme.dimS
                                                                                   * 2))
    onDismissRequested: menuModule.close()
    widgetContent: SelectionWidget {
      id: selection
      theme: menuModule.theme
      menuWindow: panel
      visible: panel.visible && menuModule.powerExpanded
      title: "Power actions"
      content: powerDetails
    }
    onKeyPressed: event => {
      if (event.key === Qt.Key_Escape) {
        if (selection.visible) {
          menuModule.dismissSelection();
        } else {
          menuModule.close();
        }
        event.accepted = true;
      }
    }

    Flickable {
      id: scroll
      anchors {
        fill: parent
        margins: menuModule.theme.dimS
      }
      contentHeight: applications.height
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      ApplicationSearch {
        id: applications
        theme: menuModule.theme
        width: scroll.width
        height: implicitHeight
        powerSelected: menuModule.powerExpanded
        onPowerClicked: menuModule.togglePower()
        onLaunched: menuModule.close()
        onQueryChanged: menuModule.pendingAction = ""
      }
    }
  }

  component SelectionWidget: Rectangle {
    id: widget
    required property T theme
    color: widget.theme.colB
    required property var menuWindow
    property string title: ""
    property Component content: null
    readonly property real inset: widget.theme.dimS

    width: Math.min(380, menuWindow.width - inset * 2)
    height: Math.min(body.implicitHeight, menuWindow.height - widget.theme.dimM - inset * 2)
    x: {
      const beside = menuWindow.menuX + menuWindow.menuWidth + widget.theme.dimS;
      return beside + width + inset <= menuWindow.width ? beside : Math.max(inset,
                                                                            menuWindow.width
                                                                            - width - inset);
    }
    y: Math.max(inset, Math.min(menuWindow.menuY + menuWindow.menuHeight - height,
                                menuWindow.height - widget.theme.dimM - inset - height))

    // Consume blank-area clicks, but leave child controls interactive.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
    }

    Lib.ScrollColumn {
      id: body
      theme: widget.theme
      anchors.fill: parent
      Lib.Heading {
        theme: widget.theme
        Layout.fillWidth: true
        text: widget.title
      }
      Loader {
        Layout.fillWidth: true
        sourceComponent: widget.visible ? widget.content : null
      }
    }
  }

  component ApplicationSearch: FocusScope {
    id: applications
    required property T theme
    signal launched
    property alias query: search.text
    property bool powerSelected: false
    signal powerClicked
    property int visibleResultLimit: 6
    readonly property real resultHeight: applications.theme.dimM + applications.theme.dimS
    implicitHeight: Math.max(1, Math.min(results.count, visibleResultLimit)) * resultHeight
                    + applications.theme.dimS + searchRow.height

    function focusSearch() {
      search.forceActiveFocus();
    }

    function resetAndFocus() {
      search.text = "";
      results.currentIndex = 0;
      focusSearch();
    }

    function moveSelection(delta) {
      if (!results.count) {
        results.currentIndex = -1;
        return;
      }
      results.currentIndex = (results.currentIndex + delta + results.count) % results.count;
      results.positionViewAtIndex(results.currentIndex, ListView.Contain);
    }

    function activate(entry) {
      if (!entry)
        return;
      Quickshell.execDetached(["systemd-run", "--user", "--collect", "--slice=app.slice",
                               "--property=Type=exec", "--property=ExitType=cgroup",
                               "--property=PartOf=graphical-session.target",
                               "--property=After=graphical-session.target",
                               "--property=WorkingDirectory=" + Quickshell.env("HOME"), "--",
                               "gtk-launch", `${entry.id}.desktop`]);
      launched();
    }

    ScriptModel {
      id: resultModel
      objectProp: "id"
      values: {
        const query = search.text.trim().toLowerCase();
        return DesktopEntries.applications.values.filter(application => {
          const detail = String(application.genericName || application.comment || "");
          return !query || application.name.toLowerCase().includes(query) || detail.toLowerCase(
                ).includes(query);
        }).slice(0, 50);
      }
    }

    ListView {
      id: results
      anchors {
        top: parent.top
        bottom: searchRow.top
        left: parent.left
        right: parent.right
        bottomMargin: applications.theme.dimS
      }
      clip: true
      model: resultModel
      currentIndex: count ? 0 : -1
      onCountChanged: {
        if (!count)
          currentIndex = -1;
        else if (currentIndex < 0 || currentIndex >= count)
          currentIndex = 0;
      }
      delegate: Rectangle {
        id: resultItem
        required property var modelData
        readonly property bool current: ListView.isCurrentItem
        width: results.width
        height: applications.resultHeight
        color: resultHover.hovered || resultItem.current ? applications.theme.colO :
                                                           applications.theme.colB
        HoverHandler {
          id: resultHover
        }
        IconImage {
          id: applicationIcon
          anchors {
            left: parent.left
            leftMargin: applications.theme.dimS
            verticalCenter: parent.verticalCenter
          }
          width: applications.theme.dimM
          height: applications.theme.dimM
          source: Quickshell.iconPath(modelData.icon || "application-x-executable", "")
        }
        Lib.Label {
          theme: applications.theme
          anchors {
            left: applicationIcon.right
            right: parent.right
            verticalCenter: parent.verticalCenter
            leftMargin: applications.theme.dimS
            rightMargin: applications.theme.dimS
          }
          text: modelData.name
          color: resultItem.current ? applications.theme.colF : applications.theme.colM
          elide: Text.ElideRight
        }
        TapHandler {
          onTapped: applications.activate(modelData)
        }
      }
    }

    Lib.Label {
      theme: applications.theme
      anchors.centerIn: results
      visible: results.count === 0
      text: "No matching applications"
      color: applications.theme.colM
    }

    RowLayout {
      id: searchRow
      anchors {
        bottom: parent.bottom
        left: parent.left
        right: parent.right
      }
      height: applications.theme.dimM + applications.theme.dimS
      spacing: applications.theme.dimS
      Lib.MenuButton {
        theme: applications.theme
        symbol: "⏻"
        implicitHeight: theme.dimM + theme.dimS
        implicitWidth: implicitHeight
        Layout.alignment: Qt.AlignVCenter
        Accessible.name: "Power actions"
        selected: applications.powerSelected
        onClicked: applications.powerClicked()
      }
      Rectangle {
        id: searchBox
        Layout.fillWidth: true
        Layout.fillHeight: true
        color: applications.theme.colB
        TextInput {
          id: search
          activeFocusOnTab: true
          anchors {
            fill: parent
            leftMargin: applications.theme.dimS
            rightMargin: applications.theme.dimS
            topMargin: applications.theme.dimS / 2
            bottomMargin: applications.theme.dimS / 2
          }
          color: applications.theme.colF
          selectionColor: applications.theme.colP
          selectedTextColor: applications.theme.colB
          font.family: "sans-serif"
          font.pointSize: applications.theme.fontSizeM
          verticalAlignment: TextInput.AlignVCenter
          clip: true
          onTextChanged: results.currentIndex = resultModel.values.length ? 0 : -1
          onAccepted: applications.activate(results.currentItem?.modelData)
          Keys.onPressed: event => {
            if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
              applications.moveSelection(event.key === Qt.Key_Down ? 1 : -1);
              event.accepted = true;
            }
          }
          Text {
            anchors.fill: parent
            visible: !search.text.length
            text: "Search applications…"
            color: applications.theme.colM
            font: search.font
            verticalAlignment: Text.AlignVCenter
          }
        }
      }
    }
  }
}
