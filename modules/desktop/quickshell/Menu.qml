import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import QtQuick.Controls
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland
import Quickshell.Networking
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire

Scope {
  id: menuModule
  required property T theme
  required property Lib lib
  required property var focusedScreen
  property string pendingAction: ""
  readonly property bool powerExpanded: controls.expanded === "power"
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
    controls.reset();
    applications.focusSearch();
  }

  function togglePower() {
    controls.toggleDetails("power", powerButton);
  }

  function open() {
    pendingAction = "";
    controls.reset();
    if (focusedScreen)
      panel.screen = focusedScreen;
    panel.visible = true;
    powerProfiles.refresh();
    Qt.callLater(() => {
      applications.resetAndFocus();
      const bottom = applications.mapToItem(content, 0, applications.height).y;
      scroll.contentY = Math.max(0, Math.min(scroll.contentHeight - scroll.height, bottom - scroll.height));
    });
  }

  function close() {
    panel.visible = false;
    pendingAction = "";
    applications.query = "";
    controls.reset();
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
        MenuButton {
          theme: menuModule.theme
          required property var modelData
          Layout.fillWidth: true
          symbol: modelData.symbol
          text: menuModule.pendingAction === modelData.key ? `Confirm ${modelData.name}` : modelData.name
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

    MenuWindow {
      id: panel

      theme: menuModule.theme
      menuWidth: Math.min(980, width - menuModule.theme.dimS * 2)
      menuHeight: Math.min(content.height + menuModule.theme.dimS * 2, Math.max(0, height - menuModule.theme.dimM
                                                                                - menuModule.theme.dimS * 2))
      onDismissRequested: menuModule.close()
      widgetContent: SelectionWidget {
        id: selection
        theme: menuModule.theme
        menuWindow: panel
        visible: panel.visible && controls.expanded !== ""
        anchorItem: controls.selectionAnchor
        title: menuModule.powerExpanded ? "Power actions" : ({
                                                               wifi: "Wi-Fi",
                                                               bluetooth: "Bluetooth",
                                                               profiles: "Power profile",
                                                               output: "Speaker",
                                                               input: "Microphone"
                                                             })[controls.expanded] ?? ""
        content: menuModule.powerExpanded ? powerDetails : controls.details
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
        contentHeight: content.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        GridLayout {
          id: content
          width: scroll.width
          readonly property real controlsHeight: controls.implicitHeight + footer.implicitHeight + menuModule.theme.dimS
          height: columns === 2 ? Math.max(controlsHeight, applications.implicitHeight) : controlsHeight
                                  + applications.implicitHeight + menuModule.theme.dimS
          columns: width < 760 ? 1 : 2
          columnSpacing: menuModule.theme.dimS
          rowSpacing: menuModule.theme.dimS

          ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignBottom
            Layout.preferredWidth: 1
            Layout.preferredHeight: content.controlsHeight
            Layout.minimumWidth: 0
            spacing: menuModule.theme.dimS

            Flickable {
              id: controlsScroll
              Layout.fillWidth: true
              Layout.preferredHeight: controls.implicitHeight
              Layout.minimumHeight: 0
              contentHeight: controls.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              SystemControls {
                id: controls
                theme: menuModule.theme
                profiles: powerProfiles
                width: controlsScroll.width
                height: implicitHeight
                active: panel.visible
                onDetailsRequested: {
                  menuModule.pendingAction = "";
                  if (expanded)
                    Qt.callLater(() => selection.forceActiveFocus());
                  else
                    applications.focusSearch();
                }
              }
            }

            RowLayout {
              id: footer
              Layout.fillWidth: true
              spacing: menuModule.theme.dimS
              MenuButton {
                id: powerButton
                theme: menuModule.theme
                symbol: "⏻"
                Accessible.name: "Power actions"
                selected: menuModule.powerExpanded
                onClicked: menuModule.togglePower()
              }
              Text {
                Layout.fillWidth: true
                Layout.minimumWidth: 0

                function formatRemaining(seconds) {
                  if (seconds <= 0)
                    return "";
                  return `${String(Math.floor(seconds / 60))}m`;
                }

                text: `▰ %${Math.round(menuModule.lib.battery.percentage)} · ${menuModule.lib.battery.status}` + (
                        menuModule.lib.battery.status === "Full" ? "" : " " + formatRemaining(
                                                                     menuModule.lib.battery.remainingSeconds))
                color: menuModule.theme.colM
                font.family: "sans-serif"
                font.pointSize: menuModule.theme.fontSizeM
                elide: Text.ElideRight
              }
              Row {
                spacing: menuModule.theme.dimS
                Text {
                  text: "⌨"
                  color: menuModule.theme.colM
                  font.family: "monospace"
                  font.pointSize: menuModule.theme.fontSizeM
                }
                Language {
                  theme: menuModule.theme
                  font.family: "sans-serif"
                  color: menuModule.theme.colM
                }
              }
            }
          }

          ApplicationSearch {
            id: applications

            theme: menuModule.theme
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignBottom
            Layout.preferredWidth: 1
            Layout.minimumWidth: 0
            Layout.preferredHeight: implicitHeight
            onLaunched: menuModule.close()
            onQueryChanged: menuModule.pendingAction = ""
          }
        }
      }
    }

    PowerProfiles {
      id: powerProfiles
    }

    component MenuButton: Button {
      id: button
      required property T theme
      property bool selected: false
      property string symbol: ""
      property string symbolFamily: "monospace"
      property string valueText: ""
      property bool muted: false
      implicitHeight: button.theme.dimM + button.theme.dimS
      implicitWidth: contentItem.implicitWidth + button.theme.dimS * 2
      padding: button.theme.dimS
      hoverEnabled: true
      contentItem: Item {
        id: content
        readonly property real sideWidth: Math.max(symbolText.visible ? symbolText.implicitWidth : 0, valueLabel.visible
                                                   ? valueLabel.implicitWidth : 0)
        readonly property real labelInset: sideWidth > 0 ? sideWidth + button.theme.dimS : 0
        implicitWidth: label.visible ? label.implicitWidth + labelInset * 2 : sideWidth
        implicitHeight: Math.max(label.implicitHeight, symbolText.implicitHeight, valueLabel.implicitHeight)
        Text {
          id: symbolText
          visible: button.symbol.length > 0
          text: button.symbol
          anchors.left: label.visible ? parent.left : undefined
          anchors.horizontalCenter: label.visible ? undefined : parent.horizontalCenter
          anchors.verticalCenter: parent.verticalCenter
          color: label.color
          font.family: button.symbolFamily
          font.pointSize: button.theme.fontSizeM
        }
        Text {
          id: label
          visible: button.text.length > 0
          anchors {
            fill: parent
            leftMargin: content.labelInset
            rightMargin: content.labelInset
          }
          text: button.text
          color: !button.enabled || button.muted ? button.theme.colM : button.selected || button.activeFocus
                                                   ? button.theme.colP : button.theme.colF
          font.family: "sans-serif"
          font.pointSize: button.theme.fontSizeM
          font.bold: button.selected || button.activeFocus
          elide: Text.ElideRight
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }
        Text {
          id: valueLabel
          visible: button.valueText.length > 0
          anchors {
            right: parent.right
            verticalCenter: parent.verticalCenter
          }
          text: button.valueText
          color: label.color
          font.family: "monospace"
          font.pointSize: button.theme.fontSizeM
        }
      }
      background: Rectangle {
        color: button.selected || (button.enabled && (button.down || button.hovered)) ? button.theme.colB :
                                                                                        button.theme.colO
      }
    }

    component MenuWindow: PanelWindow {
      id: menu
      required property T theme

      default property alias menuContent: surface.data
      property alias menuHeight: surface.height
      property alias menuWidth: surface.width
      property alias widgetContent: widgets.data
      readonly property real menuX: surface.x
      readonly property real menuY: surface.y

      signal keyPressed(var event)
      signal dismissRequested

      visible: false
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "quickshell-menu"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

      anchors {
        top: true
        bottom: true
        left: true
        right: true
      }

      data: FocusScope {
        anchors.fill: parent
        Keys.onPressed: event => menu.keyPressed(event)

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onClicked: menu.dismissRequested()
        }

        Rectangle {
          id: surface
          color: menu.theme.colO
          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
          }
          anchors.bottom: parent.bottom
          anchors.bottomMargin: menu.theme.dimM + menu.theme.dimS
          anchors.left: parent.left
          anchors.leftMargin: menu.theme.dimS
          width: 480
        }

        Item {
          id: widgets
          anchors.fill: parent
        }
      }
    }

    component SelectionWidget: Rectangle {
      id: widget
      required property T theme
      color: widget.theme.colO
      required property var menuWindow
      property var anchorItem: null
      property string title: ""
      property Component content: null
      readonly property real inset: widget.theme.dimS
      readonly property real anchorY: anchorItem ? anchorItem.mapToItem(parent, 0, 0).y : menuWindow.menuY

      width: Math.min(380, menuWindow.width - inset * 2)
      height: Math.min(body.implicitHeight + inset * 2, menuWindow.height - widget.theme.dimM - inset * 2)
      x: {
        const beside = menuWindow.menuX + menuWindow.menuWidth + widget.theme.dimS;
        return beside + width + inset <= menuWindow.width ? beside : Math.max(inset, menuWindow.width - width - inset);
      }
      y: Math.max(inset, Math.min(anchorY, menuWindow.height - widget.theme.dimM - inset - height))

      // Consume blank-area clicks, but leave child controls interactive.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
      }

      Flickable {
        anchors {
          fill: parent
          margins: widget.inset
        }
        contentHeight: body.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ColumnLayout {
          id: body
          width: parent.width
          spacing: widget.theme.dimS
          Text {
            Layout.fillWidth: true
            text: widget.title
            color: widget.theme.colF
            font.family: "sans-serif"
            font.pointSize: widget.theme.fontSizeM
            font.bold: true
          }
          Loader {
            Layout.fillWidth: true
            sourceComponent: widget.visible ? widget.content : null
          }
        }
      }
    }

    component ApplicationSearch: FocusScope {
      id: applications
      required property T theme
      signal launched
      property alias query: search.text
      property int visibleResultLimit: 6
      readonly property real resultHeight: applications.theme.dimM + applications.theme.dimS
      implicitHeight: Math.max(1, Math.min(results.count, visibleResultLimit)) * resultHeight + applications.theme.dimS
                      + searchBox.height

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
        Quickshell.execDetached(["systemd-run", "--user", "--collect", "--slice=app.slice", "--property=Type=exec",
                                 "--property=ExitType=cgroup", "--property=PartOf=graphical-session.target",
                                 "--property=After=graphical-session.target", "--property=WorkingDirectory="
                                 + Quickshell.env("HOME"), "--", "gtk-launch", `${entry.application.id}.desktop`]);
        launched();
      }

      ScriptModel {
        id: resultModel
        objectProp: "key"
        values: {
          const query = search.text.trim().toLowerCase();
          return DesktopEntries.applications.values.map(application => ({
            key: application.id,
            name: application.name,
            detail: application.genericName || application.comment,
            icon: application.icon,
            application: application
          })).filter(entry => !query || entry.name.toLowerCase().includes(query) || String(entry.detail
          || "").toLowerCase().includes(query)).slice(0, 50);
        }
        }

          ListView {
          id: results
          anchors {
          top: parent.top
          bottom: searchBox.top
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
          color: resultHover.hovered || resultItem.current ? applications.theme.colB : applications.theme.colO
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
          Text {
          anchors {
          left: applicationIcon.right
          right: parent.right
          verticalCenter: parent.verticalCenter
          leftMargin: applications.theme.dimS
          rightMargin: applications.theme.dimS
        }
          text: modelData.name
          color: resultItem.current ? applications.theme.colF : applications.theme.colM
          font.bold: resultItem.current
          font.family: "sans-serif"
          font.pointSize: applications.theme.fontSizeM
          elide: Text.ElideRight
        }
          TapHandler {
          onTapped: applications.activate(modelData)
        }
        }
        }

          Text {
          anchors.centerIn: results
          visible: results.count === 0
          text: "No matching applications"
          color: applications.theme.colM
          font.family: "sans-serif"
          font.pointSize: applications.theme.fontSizeM
        }

          Rectangle {
          id: searchBox
          anchors {
          bottom: parent.bottom
          left: parent.left
          right: parent.right
        }
          height: applications.theme.dimM + applications.theme.dimS * 2
          color: applications.theme.colO
          TextInput {
          id: search
          activeFocusOnTab: true
          anchors {
          fill: parent
          margins: applications.theme.dimS
        }
          color: applications.theme.colF
          selectionColor: applications.theme.colP
          selectedTextColor: applications.theme.colO
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

          component Language: Text {
          id: language
          required property T theme

          property string layout: ""

          function updateLayout(devices) {
          const keyboard = devices.keyboards.find(keyboard => keyboard.main);
          if (!keyboard)
          return;
          const layouts = keyboard.layout.split(",");
          layout = layouts[keyboard.active_layout_index] || keyboard.active_keymap;
        }

          color: language.theme.colF
          font {
          family: "monospace"
          pointSize: language.theme.fontSizeM
        }
          text: layout

          Process {
          id: devicesProcess
          command: ["hyprctl", "-j", "devices"]
          running: true
          stdout: StdioCollector {
          onStreamFinished: {
          try {
          language.updateLayout(JSON.parse(this.text));
        } catch (error) {
          console.warn(`Failed to read keyboard layout: ${error}`);
        }
        }
        }
        }

          Connections {
          target: Hyprland
          function onRawEvent(event) {
          if (event.name === "activelayout")
          devicesProcess.running = true;
        }
        }
        }

          component SystemControls: ColumnLayout {
          id: controls
          required property T theme
          required property var profiles
          readonly property alias audioMetadata: audioMetadata
          property bool active: false
          property string expanded: ""
          property var selectionAnchor: null
          property var pendingNetwork: null
          property var passwordNetwork: null
          property string passwordText: ""
          property string pairingText: ""
          property string networkError: ""
          readonly property bool scanning: scan.running || scanSettling.running
          readonly property var wifiDevices: Networking.devices.values.filter(device => device.type === DeviceType.Wifi)
          readonly property var wifiDevice: wifiDevices.find(device => device.connected) ?? wifiDevices[0] ?? null
          readonly property var connectedNetwork: wifiDevice?.networks.values.find(network => network.connected) ?? null
          readonly property var adapter: Bluetooth.defaultAdapter
          readonly property var audioCandidates: Pipewire.nodes.values.filter(node => !node.isStream && node.audio)
          readonly property var audioDevices: audioCandidates.filter(node => audioMetadata.availability(node) !== "no")
          signal detailsRequested
          signal passwordRequested
          spacing: controls.theme.dimS

          function reset() {
          expanded = "";
          selectionAnchor = null;
          passwordNetwork = null;
          passwordText = "";
          pairingText = "";
          pendingNetwork = null;
          networkError = "";
          scan.running = false;
          scanSettling.stop();
          if (pairing.busy)
          pairing.cancel();
        }

          function toggleDetails(section, anchor = null) {
          const next = expanded === section ? "" : section;
          reset();
          selectionAnchor = anchor;
          expanded = next;
          detailsRequested();
        }

          function refreshWifi() {
          if (!wifiDevice || !Networking.wifiEnabled || !Networking.wifiHardwareEnabled || scanning)
          return;
          networkError = "";
          scan.command = ["nmcli", "--wait", "15", "device", "wifi", "rescan", "ifname", wifiDevice.name];
          scan.running = true;
        }

          function connectNetwork(network) {
          networkError = "";
          passwordNetwork = null;
          pendingNetwork = network;
          if (network.connected)
          network.disconnect();
          else
          network.connect();
        }

          function submitPassword() {
          if (!passwordNetwork || !passwordText.length)
          return;
          pendingNetwork = passwordNetwork;
          pendingNetwork.connectWithPsk(passwordText);
          passwordText = "";
          passwordNetwork = null;
        }

          Process {
          id: scan
          stdout: StdioCollector {
          id: scanOutput
        }
          stderr: StdioCollector {
          id: scanError
        }
          onExited: (code, status) => {
          if (!controls.active || controls.expanded !== "wifi")
          return;
          if (code === 0 && status === 0)
          scanSettling.restart();
          else
          controls.networkError = scanError.text.trim() || scanOutput.text.trim() || "Wi-Fi scan failed.";
        }
        }
          // nmcli acknowledges the request before NetworkManager publishes the results.
          Timer {
          id: scanSettling
          interval: 3000
        }

          Binding {
          target: controls.wifiDevice
          property: "scannerEnabled"
          value: true
          when: controls.active && controls.expanded === "wifi" && controls.wifiDevice !== null
          && Networking.wifiEnabled

          restoreMode: Binding.RestoreBindingOrValue
        }
          Binding {
          target: controls.adapter
          property: "discovering"
          value: true
          when: controls.active && controls.expanded === "bluetooth" && (controls.adapter?.enabled ?? false)
          restoreMode: Binding.RestoreBindingOrValue
        }
          Connections {
          target: controls.pendingNetwork
          function onConnectionFailed(reason) {
          if (reason === ConnectionFailReason.NoSecrets && [WifiSecurityType.WpaPsk, WifiSecurityType.Wpa2Psk,
          WifiSecurityType.Sae].includes(controls.pendingNetwork.security)) {
          controls.passwordNetwork = controls.pendingNetwork;
          controls.networkError = "Enter the Wi-Fi password.";
          controls.passwordRequested();
        } else {
          controls.networkError = reason === ConnectionFailReason.NoSecrets
          ? "This network requires credentials in a NetworkManager connection profile." : ConnectionFailReason.toString(
          reason);
        }
        }
        }
          BluetoothPairing {
          id: pairing
        }
          PwObjectTracker {
          objects: controls.audioCandidates
        }
          AudioDevices {
          id: audioMetadata
          active: controls.active
          nodes: controls.audioCandidates
        }
          Connections {
          target: controls.profiles
          function onBackendPresentChanged() {
          if (!controls.profiles.backendPresent && controls.expanded === "profiles")
          controls.toggleDetails("profiles");
        }
        }

          MenuButton {
          id: wifiButton

          theme: controls.theme
          Layout.fillWidth: true
          symbol: "≋"
          text: {
          if (!controls.wifiDevice)
          return "Wi-Fi · unavailable";
          if (!Networking.wifiHardwareEnabled)
          return "Wi-Fi · blocked";
          if (!Networking.wifiEnabled)
          return "Wi-Fi · off";
          return "Wi-Fi · " + (controls.connectedNetwork?.name || "Not connected");
        }
          selected: controls.expanded === "wifi"
          enabled: controls.wifiDevice !== null
          onClicked: controls.toggleDetails("wifi", wifiButton)
        }
          MenuButton {
          id: bluetoothButton
          theme: controls.theme
          Layout.fillWidth: true
          symbol: "⋈"
          text: !controls.adapter ? "Bluetooth · unavailable" : !controls.adapter.enabled ? "Bluetooth · off" :
          "Bluetooth · " + controls.adapter.devices.values.filter(device => device.connected).length + " connected"
          selected: controls.expanded === "bluetooth"
          enabled: controls.adapter !== null
          onClicked: controls.toggleDetails("bluetooth", bluetoothButton)
        }
          MenuButton {
          id: profilesButton
          theme: controls.theme
          visible: controls.profiles.backendPresent
          Layout.fillWidth: true
          symbol: "⚡︎"
          text: controls.profiles.available ? `Power · ${controls.profiles.activeProfile}` :
          "Power profile · unavailable"
          selected: controls.expanded === "profiles"
          enabled: controls.profiles.available
          onClicked: controls.toggleDetails("profiles", profilesButton)
        }
          AudioSummary {
          controlOwner: controls
          input: false
        }
          AudioSummary {
          controlOwner: controls
          input: true
        }

          // Instantiated by the selection widget, not laid out inside the main menu.
          property Component details: Component {
          ColumnLayout {
          spacing: controls.theme.dimS
          ColumnLayout {
          Layout.fillWidth: true
          visible: controls.expanded === "profiles"
          spacing: controls.theme.dimS
          Repeater {
          model: controls.profiles.availableProfiles
          MenuButton {
          theme: controls.theme
          required property string modelData
          Layout.fillWidth: true
          text: modelData
          selected: controls.profiles.activeProfile === modelData
          enabled: controls.profiles.available && !controls.profiles.busy
          onClicked: controls.profiles.setProfile(modelData)
        }
        }
          SectionText {
          theme: controls.theme
          Layout.fillWidth: true
          visible: text.length > 0
          color: controls.theme.colS
          text: controls.profiles.error
        }
        }

          ColumnLayout {
          Layout.fillWidth: true
          visible: controls.expanded === "wifi"
          spacing: controls.theme.dimS
          RowLayout {
          Layout.fillWidth: true
          MenuButton {
          theme: controls.theme
          symbol: "⏻"
          Accessible.name: Networking.wifiEnabled ? "Turn Wi-Fi off" : "Turn Wi-Fi on"
          muted: !Networking.wifiEnabled
          enabled: !!controls.wifiDevice && Networking.wifiHardwareEnabled
          onClicked: Networking.wifiEnabled = !Networking.wifiEnabled
        }
          Item {
          Layout.fillWidth: true
        }
          MenuButton {
          theme: controls.theme
          symbol: "↻"
          Accessible.name: controls.scanning ? "Refreshing Wi-Fi" : "Scan / Refresh Wi-Fi"
          selected: controls.scanning
          enabled: !!controls.wifiDevice && Networking.wifiEnabled && Networking.wifiHardwareEnabled &&
          !controls.scanning

          onClicked: controls.refreshWifi()
        }
        }
          SectionText {
          theme: controls.theme
          Layout.fillWidth: true
          visible: !controls.wifiDevice || !Networking.wifiHardwareEnabled || !Networking.wifiEnabled || !(
          controls.wifiDevice?.networks.values.length ?? 0)
          text: !controls.wifiDevice ? "Wi-Fi device unavailable." : !Networking.wifiHardwareEnabled
          ? "Wi-Fi is blocked by the hardware switch." : !Networking.wifiEnabled ? "Wi-Fi is off." : controls.scanning
          ? "Looking for networks…" : "No networks found."
          color: controls.theme.colM
        }
          Repeater {
          model: controls.wifiDevice?.networks.values ?? []
          MenuButton {
          theme: controls.theme
          required property var modelData
          Layout.fillWidth: true
          text: modelData.name + (modelData.connected ? " · Disconnect" : modelData.stateChanging ? " · Working…" : "")
          valueText: `${Math.round(modelData.signalStrength * 100)}%`
          selected: modelData.connected
          enabled: Networking.wifiEnabled && !modelData.stateChanging
          onClicked: controls.connectNetwork(modelData)
        }
        }
          SectionText {
          theme: controls.theme
          Layout.fillWidth: true
          visible: text.length > 0
          text: controls.networkError
          color: controls.passwordNetwork ? controls.theme.colM : controls.theme.colS
        }
          TextField {
          id: password
          Layout.fillWidth: true
          visible: controls.passwordNetwork !== null
          text: controls.passwordText
          onTextEdited: controls.passwordText = text
          placeholderText: "Wi-Fi password"
          echoMode: TextInput.Password
          color: controls.theme.colF
          placeholderTextColor: controls.theme.colM
          selectionColor: controls.theme.colP
          selectedTextColor: controls.theme.colO
          font.family: "sans-serif"
          font.pointSize: controls.theme.fontSizeM
          background: Rectangle {
          color: controls.theme.colB
        }
          onAccepted: controls.submitPassword()
          Connections {
          target: controls
          function onPasswordRequested() {
          Qt.callLater(() => password.forceActiveFocus());
        }
        }
        }
          MenuButton {
          theme: controls.theme
          visible: controls.passwordNetwork !== null
          text: "Connect"
          onClicked: controls.submitPassword()
        }
        }

          ColumnLayout {
          Layout.fillWidth: true
          visible: controls.expanded === "bluetooth"
          spacing: controls.theme.dimS
          MenuButton {
          theme: controls.theme
          Layout.fillWidth: true
          text: controls.adapter?.enabled ? "Turn Bluetooth off" : "Turn Bluetooth on"
          enabled: controls.adapter !== null && !pairing.busy
          onClicked: controls.adapter.enabled = !controls.adapter.enabled
        }
          Repeater {
          model: controls.adapter?.devices.values ?? []
          MenuButton {
          theme: controls.theme
          required property var modelData
          Layout.fillWidth: true
          text: (modelData.name || modelData.address) + " · " + (modelData.pairing ? "Pairing…" : modelData.connected ? "Disconnect" :
          modelData.paired ? "Connect" : "Pair")
          selected: modelData.connected
          enabled: !!controls.adapter?.enabled && !pairing.busy && !modelData.pairing && ![BluetoothDeviceState.Connecting,
          BluetoothDeviceState.Disconnecting].includes(modelData.state)
          onClicked: {
          if (modelData.paired)
          modelData.connected = !modelData.connected;
          else
          pairing.pair(modelData);
        }
        }
        }
          SectionText {
          theme: controls.theme
          Layout.fillWidth: true
          visible: text.length > 0
          text: pairing.status
          color: controls.theme.colM
        }
          SectionText {
          theme: controls.theme
          Layout.fillWidth: true
          visible: text.length > 0
          text: pairing.prompt
          font.bold: true
        }
          TextField {
          Layout.fillWidth: true
          visible: pairing.busy && pairing.prompt.length > 0 && !pairing.confirmation
          text: controls.pairingText
          onTextEdited: controls.pairingText = text
          placeholderText: "PIN / passkey"
          color: controls.theme.colF
          placeholderTextColor: controls.theme.colM
          font.family: "monospace"
          background: Rectangle {
          color: controls.theme.colB
        }
          onAccepted: {
          pairing.respond(text);
          controls.pairingText = "";
        }
        }
          RowLayout {
          visible: pairing.busy && pairing.prompt.length > 0
          MenuButton {
          theme: controls.theme
          text: pairing.confirmation ? "Confirm" : "Send"
          onClicked: {
          pairing.respond(pairing.confirmation ? "yes" : controls.pairingText);
          controls.pairingText = "";
        }
        }
          MenuButton {
          theme: controls.theme
          text: "Cancel"
          onClicked: pairing.cancel()
        }
        }
          MenuButton {
          theme: controls.theme
          visible: pairing.busy && !pairing.prompt
          text: "Cancel pairing"
          onClicked: pairing.cancel()
        }
        }
          AudioOptions {
          controlOwner: controls
          Layout.fillWidth: true
          visible: controls.expanded === "output" || controls.expanded === "input"
          input: controls.expanded === "input"
        }
        }
        }
        }

          component SectionText: Text {
          required property T theme
          color: theme.colF
          font.family: "sans-serif"
          font.pointSize: theme.fontSizeM
          wrapMode: Text.Wrap
        }

          component AudioSummary: MenuButton {
          id: summary
          required property var controlOwner
          theme: controlOwner.theme
          required property bool input
          readonly property var node: input ? Pipewire.defaultAudioSource : Pipewire.defaultAudioSink
          readonly property bool available: !!node?.ready && !!node?.audio
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          symbol: input ? "♩" : "♫"
          text: (input ? "Microphone · " : "Speaker · ") + controlOwner.audioMetadata.label(node)
          valueText: available ? `${Math.round(node.audio.volume * 100)}%` : "—"
          Accessible.description: (muted ? "Muted · " : "") + valueText
          muted: available && node.audio.muted
          enabled: controlOwner.audioDevices.some(device => device.isSink !== input)
          selected: controlOwner.expanded === (input ? "input" : "output")
          onClicked: controlOwner.toggleDetails(input ? "input" : "output", summary)
        }

          component AudioOptions: ColumnLayout {
          id: audioControl
          required property var controlOwner
          readonly property T theme: controlOwner.theme
          required property bool input
          readonly property var node: input ? Pipewire.defaultAudioSource : Pipewire.defaultAudioSink
          readonly property bool available: !!node?.ready && !!node?.audio
          readonly property var devices: audioControl.controlOwner.audioDevices.filter(device => device.isSink
          !== input)
          spacing: audioControl.controlOwner.theme.dimS
          SectionText {
          theme: audioControl.theme
          Layout.fillWidth: true
          text: audioControl.controlOwner.audioMetadata.label(audioControl.node)
          color: audioControl.available && audioControl.node.audio.muted ? audioControl.controlOwner.theme.colM :
          audioControl.controlOwner.theme.colF
        }
          RowLayout {
          Layout.fillWidth: true
          Slider {
          id: volume
          Layout.fillWidth: true
          from: 0
          to: 1.5
          value: audioControl.available ? audioControl.node.audio.volume : 0
          enabled: audioControl.available
          onMoved: audioControl.node.audio.volume = value
          background: Rectangle {
          x: volume.leftPadding
          y: volume.topPadding + volume.availableHeight / 2 - height / 2
          width: volume.availableWidth
          height: 4
          color: audioControl.controlOwner.theme.colB
          Rectangle {
          width: volume.visualPosition * parent.width
          height: parent.height
          color: audioControl.available && audioControl.node.audio.muted ? audioControl.controlOwner.theme.colM :
          audioControl.controlOwner.theme.colP
        }
        }
          handle: Rectangle {
          x: volume.leftPadding + volume.visualPosition * (volume.availableWidth - width)
          y: volume.topPadding + volume.availableHeight / 2 - height / 2
          implicitWidth: 14
          implicitHeight: 20
          color: !volume.enabled || audioControl.node.audio.muted ? audioControl.controlOwner.theme.colM :
          volume.activeFocus ? audioControl.controlOwner.theme.colF : audioControl.controlOwner.theme.colP
        }
        }
          SectionText {
          theme: audioControl.theme
          Layout.preferredWidth: 52
          horizontalAlignment: Text.AlignRight
          font.family: "monospace"
          text: audioControl.available ? `${Math.round(audioControl.node.audio.volume * 100)}%` : "—"
          color: audioControl.available && audioControl.node.audio.muted ? audioControl.controlOwner.theme.colM :
          audioControl.controlOwner.theme.colF
        }
        }
          MenuButton {
          theme: audioControl.theme
          text: audioControl.available && audioControl.node.audio.muted ? "Unmute" : "Mute"
          selected: audioControl.available && audioControl.node.audio.muted
          enabled: audioControl.available
          onClicked: audioControl.node.audio.muted = !audioControl.node.audio.muted
        }
          SectionText {
          theme: audioControl.theme
          text: "Devices"
          font.bold: true
        }
          Repeater {
          model: audioControl.devices
          MenuButton {
          theme: audioControl.theme
          required property var modelData
          Layout.fillWidth: true
          text: audioControl.controlOwner.audioMetadata.label(modelData) + (
          audioControl.controlOwner.audioMetadata.availability(modelData) === "unknown" ? " · Availability unknown" :
          "")
          selected: audioControl.node === modelData
          onClicked: {
          if (audioControl.input)
          Pipewire.preferredDefaultAudioSource = modelData;
          else
          Pipewire.preferredDefaultAudioSink = modelData;
        }
        }
        }
        }

          component AudioDevices: Scope {
          id: metadata
          property bool active: false
          required property var nodes
          property var endpoints: ({})

          function availability(node) {
          return endpoints[node?.name]?.availability ?? "unreported";
        }

          function label(node) {
          return endpoints[node?.name]?.label || node?.description || node?.nickname || node?.name || "Unavailable";
        }

          function routeInfo(route, key) {
          const info = route?.info ?? [];
          for (let index = 1; index + 1 < info.length; index += 2) {
          if (info[index] === key)
          return info[index + 1];
        }
          return "";
        }

          function parse(objects) {
          const devices = {};
          for (const object of objects) {
          if (object.type === "PipeWire:Interface:Device")
          devices[String(object.id)] = object.info?.params ?? {};
        }
          const result = {};
          for (const object of objects) {
          if (object.type !== "PipeWire:Interface:Node")
          continue;
          const props = object.info?.props ?? {};
          // Virtual/other audio classes must not inherit a physical port's disconnected status.
          if (props["node.virtual"] === true || props["node.virtual"] === "true" || !["Audio/Sink", "Audio/Source"].includes(
          props["media.class"]))
          continue;
          const params = devices[String(props["device.id"])] ?? {};
          const profileDevice = props["card.profile.device"];
          const direction = props["media.class"] === "Audio/Sink" ? "Output" : "Input";
          const routes = profileDevice === undefined ? [] : (params.EnumRoute ?? []).filter(route => route.direction
          === direction && (route.devices ?? []).some(device => String(device) === String(profileDevice)));
          if (!routes.length)
          continue;
          const current = (params.Route ?? []).find(route => route.direction === direction && String(route.device) === String(
          profileDevice));
          const route = routes.find(candidate => candidate.index === current?.index && candidate.available !== "no")
          ?? routes.find(candidate => candidate.available === "yes") ?? routes.find(candidate => candidate.available
          !== "no") ?? routes[0];
          const availability = routes.every(candidate => candidate.available === "no") ? "no" : routes.some(candidate
          => candidate.available === "yes") ? "yes" : "unknown";
          const product = routeInfo(route, "device.product.name");
          result[props["node.name"]] = {
          availability: availability,
          label: product ? `${product} · ${route.description}` : route.description || props["node.description"]
        };
        }
          endpoints = result;
        }

          function refresh() {
          if (active && !snapshot.running)
          snapshot.running = true;
        }

          onActiveChanged: {
          if (active)
          refresh();
          else
          snapshot.running = false;
        }
          onNodesChanged: refresh()
          Timer {
          interval: 5000
          running: metadata.active
          repeat: true
          onTriggered: metadata.refresh()
        }
          Process {
          id: snapshot
          // Quickshell exposes nodes, but not the device route availability used here.
          command: ["pw-dump"]
          stdout: StdioCollector {
          onStreamFinished: {
          try {
          metadata.parse(JSON.parse(text));
        } catch (error) {
          if (metadata.active)
          metadata.endpoints = {};
        }
        }
        }
          onExited: (code, status) => {
          if (metadata.active && (code !== 0 || status !== 0))
          metadata.endpoints = {};
        }
        }
        }

          component BluetoothPairing: Scope {
          id: pairing
          property var device: null
          property string prompt: ""
          property string status: ""
          property bool confirmation: false
          readonly property bool busy: agent.running
          property bool requested: false
          property bool succeeded: false
          property int handledLength: 0

          function pair(target) {
          if (busy)
          return;
          device = target;
          prompt = "";
          status = `Pairing with ${target.name || target.address}…`;
          requested = false;
          succeeded = false;
          handledLength = 0;
          agent.running = true;
        }

          function respond(value) {
          if (!busy || !prompt)
          return;
          prompt = "";
          agent.write(`${String(value).replace(/[\r\n]/g, "")}\n`);
        }

          function cancel() {
          if (device?.pairing)
          device.cancelPair();
          agent.running = false;
          prompt = "";
          status = "Pairing cancelled.";
        }

          function consume(text) {
          if (!device)
          return;
          const chunk = text.slice(handledLength).replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
          handledLength = text.length;
          if (!requested && text.includes("Agent registered")) {
          requested = true;
          agent.write(`pair ${device.address}\n`);
        }
          const clean = text.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
          if (chunk.includes("Pairing successful")) {
          succeeded = true;
          prompt = "";
          status = "Paired successfully.";
          device.connect();
          agent.write("quit\n");
        } else if (/Failed to pair|AuthenticationFailed|AuthenticationCanceled|AuthenticationRejected/.test(chunk)) {
          prompt = "";
          status = chunk.trim();
          agent.write("quit\n");
        } else {
          const display = chunk.match(/(?:Passkey|PIN code):\s*(\d+)/i);
          if (display)
          status = `Enter this code on your device: ${display[1]}`;
          const match = clean.match(
          /(?:Confirm passkey|Authorize service|Accept pairing|Enter PIN code|Enter passkey)[^\r\n]*[:?]\s*$/i);
          if (match) {
          prompt = match[0].trim();
          confirmation = /Confirm|Authorize|Accept/i.test(prompt);
        }
        }
        }

          Process {
          id: agent
          command: ["bluetoothctl", "--agent", "KeyboardDisplay"]
          stdinEnabled: true
          stdout: StdioCollector {
          waitForEnd: false
          onDataChanged: pairing.consume(text)
        }
          stderr: StdioCollector {
          onStreamFinished: {
          if (text.trim())
          pairing.status = text.trim();
        }
        }
          onExited: (exitCode, exitStatus) => {
          pairing.prompt = "";
          if (!pairing.succeeded && pairing.status.startsWith("Pairing with"))
          pairing.status = "Pairing failed or was cancelled. Check the device and try again.";
        }
        }

          Timer {
          interval: 60000
          running: pairing.busy
          onTriggered: pairing.cancel()
        }
        }

          component PowerProfiles: Scope {
          id: profiles
          property bool backendPresent: false
          readonly property var availableProfiles: backend.item?.availableProfiles ?? []
          readonly property string activeProfile: backend.item?.activeProfile ?? ""
          readonly property bool available: (backend.item?.available ?? false) && availableProfiles.length > 0
          readonly property string error: backend.item?.error ?? ""
          readonly property bool busy: backend.item?.busy ?? false

          function refresh() {
          if (!probe.running)
          probe.running = true;
          backend.item?.refresh();
        }

          function setProfile(profile) {
          backend.item?.setProfile(profile);
        }

          // Check owned bus names, not activatable services: opening the menu must not start PPD.
          Process {
          id: probe
          command: ["sh", "-c",
          "command -v powerprofilesctl >/dev/null 2>&1 && exec busctl --system --acquired --no-pager --no-legend list"]
          running: true
          stdout: StdioCollector {
          onStreamFinished: profiles.backendPresent =
          /^(net\.hadess\.PowerProfiles|org\.freedesktop\.UPower\.PowerProfiles)\s/m.test(text)
        }
          onExited: (code, status) => {
          if (code !== 0 || status !== 0)
          profiles.backendPresent = false;
        }
        }
          Timer {
          interval: 30000
          running: true
          repeat: true
          onTriggered: {
          if (!probe.running)
          probe.running = true;
        }
        }

          Loader {
          id: backend
          active: profiles.backendPresent
          sourceComponent: Component {
          Scope {
          id: controller
          property var availableProfiles: []
          property string activeProfile: ""
          property bool available: false
          property string error: ""
          readonly property bool busy: setProcess.running

          function refresh() {
          if (!setProcess.running && !listProcess.running && !getProcess.running) {
          listProcess.running = true;
          getProcess.running = true;
        }
        }

          function setProfile(profile) {
          if (!available || busy || !availableProfiles.includes(profile) || profile === activeProfile)
          return;
          error = "";
          setProcess.command = ["powerprofilesctl", "set", profile];
          setProcess.running = true;
        }

          Component.onCompleted: refresh()
          Timer {
          interval: 10000
          running: true
          repeat: true
          onTriggered: controller.refresh()
        }

          Process {
          id: listProcess
          command: ["powerprofilesctl", "list"]
          stdout: StdioCollector {
          onStreamFinished: {
          const expression = /^\s*\*?\s*(power-saver|balanced|performance):/gm;
          const result = [];
          let match;
          while ((match = expression.exec(text)) !== null)
          result.push(match[1]);
          controller.availableProfiles = result;
        }
        }
          onExited: (code, status) => {
          if (code !== 0 || status !== 0) {
          controller.available = false;
          controller.availableProfiles = [];
        }
        }
        }
          Process {
          id: getProcess
          command: ["powerprofilesctl", "get"]
          stdout: StdioCollector {
          onStreamFinished: controller.activeProfile = text.trim()
        }
          onExited: (code, status) => controller.available = code === 0 && status === 0
          && controller.activeProfile.length > 0
        }
          Process {
          id: setProcess
          property string failure: ""
          onStarted: failure = ""
          stderr: StdioCollector {
          onStreamFinished: setProcess.failure = text.trim()
        }
          onExited: (code, status) => {
          if (code !== 0 || status !== 0)
          controller.error = failure || "Could not change the power profile.";
          controller.refresh();
        }
        }
        }
        }
        }
        }
        }
