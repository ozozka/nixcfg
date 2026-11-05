import QtQuick
import Quickshell
import Quickshell.Io
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell.Wayland
import Quickshell.Networking
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import Quickshell.Services.Mpris

Scope {
  component MenuButton: Button {
    id: button
    required property T theme
    property bool selected: false
    property string symbol: ""
    property string symbolFamily: "monospace"
    property real symbolSize: theme.fontSizeM
    property string valueText: ""
    property bool muted: false
    implicitHeight: button.theme.dimM + button.theme.dimS
    implicitWidth: contentItem.implicitWidth + button.theme.dimS * 2
    padding: button.theme.dimS
    hoverEnabled: true
    contentItem: Item {
      id: content
      readonly property real sideWidth: Math.max(symbolText.visible ? symbolText.implicitWidth :
                                                                      0, valueLabel.visible
                                                 ? valueLabel.implicitWidth : 0)
      readonly property real labelInset: sideWidth > 0 ? sideWidth + button.theme.dimS : 0
      implicitWidth: label.visible ? label.implicitWidth + labelInset * 2 : sideWidth
      implicitHeight: Math.max(label.implicitHeight, symbolText.implicitHeight,
                               valueLabel.implicitHeight)
      Text {
        id: symbolText
        visible: button.symbol.length > 0
        text: button.symbol
        anchors.left: label.visible ? parent.left : undefined
        anchors.horizontalCenter: label.visible ? undefined : parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        color: label.color
        font.family: button.symbolFamily
        font.pointSize: button.symbolSize
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
        color: !button.enabled || button.muted ? button.theme.colM : button.theme.colF
        font.family: "sans-serif"
        font.pointSize: button.theme.fontSizeM
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
      color: button.selected || (button.enabled && (button.down || button.hovered))
             ? button.theme.colO : button.theme.colB
    }
  }

  component PlaybackButton: MenuButton {
    required property string description
    symbolSize: theme.fontSizeL
    implicitWidth: theme.dimM + theme.dimS
    implicitHeight: theme.dimM + theme.dimS
    padding: 0
    Accessible.name: description
    ToolTip.visible: hovered
    ToolTip.text: description
  }

  component PlaybackDetails: ColumnLayout {
    id: playbackView
    required property T theme
    required property var playback
    readonly property var player: playback.player
    spacing: theme.dimS

    Heading {
      theme: playbackView.theme
      text: "Playback"
    }
    SectionText {
      theme: playbackView.theme
      visible: !playbackView.player
      text: "No media player available"
      color: theme.colM
    }
    ColumnLayout {
      Layout.fillWidth: true
      visible: playbackView.playback.players.length > 1
      spacing: playbackView.theme.dimS
      Repeater {
        model: playbackView.playback.players
        MenuButton {
          required property var modelData
          theme: playbackView.theme
          Layout.fillWidth: true
          text: modelData.identity || modelData.dbusName
          selected: playbackView.player === modelData
          onClicked: playbackView.playback.select(modelData)
        }
      }
    }
    ColumnLayout {
      Layout.fillWidth: true
      visible: !!playbackView.player
      spacing: playbackView.theme.dimS

      ColumnLayout {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        spacing: playbackView.theme.dimS / 2

        SectionText {
          theme: playbackView.theme
          Layout.minimumWidth: 0
          text: playbackView.player?.identity || playbackView.player?.dbusName || ""
          visible: playbackView.playback.players.length === 1
          textFormat: Text.PlainText
          font.pointSize: theme.fontSizeS
          color: theme.colM
        }
        SectionText {
          theme: playbackView.theme
          Layout.minimumWidth: 0
          text: playbackView.player?.trackTitle || "No track information"
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          font.pointSize: theme.fontSizeS
          font.bold: true
          color: theme.colM
        }
      }
      RowLayout {
        Layout.fillWidth: true
        spacing: playbackView.theme.dimS
        SectionText {
          theme: playbackView.theme
          Layout.fillWidth: false
          text: playbackView.playback.timing || "Timing unavailable"
          font.family: "monospace"
          font.pointSize: theme.fontSizeS
          color: playbackView.playback.playing ? theme.colF : theme.colM
        }
        ThemedSlider {
          theme: playbackView.theme
          trackThickness: theme.dimT
          handleWidth: theme.dimT
          handleHeight: theme.dimS
          fillColor: enabled ? theme.colF : theme.colM
          Layout.fillWidth: true
          from: 0
          to: playbackView.player?.lengthSupported && playbackView.player.length > 0
              ? playbackView.player.length : 1
          value: playbackView.playback.position
          enabled: !!playbackView.player?.canControl && !!playbackView.player?.canSeek
                   && playbackView.playback.timing.length > 0
          onMoved: playbackView.player.position = value
          Accessible.name: "Playback position"
        }
        PlaybackButton {
          theme: playbackView.theme
          readonly property var player: playbackView.player
          readonly property int loopMode: player?.loopState ?? MprisLoopState.None
          symbol: loopMode === MprisLoopState.Track ? "↻¹" : "↻"
          description: "Repeat: " + (loopMode === MprisLoopState.Track ? "track" : loopMode
                                                                         === MprisLoopState.Playlist
                                                                         ? "playlist" : "off")
                       + " (click to cycle)"
          muted: loopMode === MprisLoopState.None
          selected: loopMode !== MprisLoopState.None
          enabled: !!player?.canControl && !!player?.loopSupported
          onClicked: {
            player.loopState = loopMode === MprisLoopState.None ? MprisLoopState.Track :
                                                                  loopMode
                                                                  === MprisLoopState.Track
                                                                  ? MprisLoopState.Playlist :
                                                                    MprisLoopState.None;
          }
        }
      }
      RowLayout {
        Layout.fillWidth: true
        spacing: playbackView.theme.dimS
        Item {
          Layout.fillWidth: true
        }
        PlaybackButton {
          theme: playbackView.theme
          symbol: "⏮"
          description: "Previous track"
          enabled: !!playbackView.player?.canGoPrevious && !!playbackView.player?.canControl
          onClicked: playbackView.player.previous()
        }
        PlaybackButton {
          theme: playbackView.theme
          symbol: playbackView.playback.playing ? "⏸" : "▶"
          description: playbackView.playback.playing ? "Pause" : "Play"
          enabled: !!playbackView.player?.canControl && !!playbackView.player?.canTogglePlaying
          onClicked: playbackView.player.togglePlaying()
        }
        PlaybackButton {
          theme: playbackView.theme
          symbol: "⏭"
          description: "Next track"
          enabled: !!playbackView.player?.canGoNext && !!playbackView.player?.canControl
          onClicked: playbackView.player.next()
        }
        Item {
          Layout.fillWidth: true
        }
      }
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
    property real anchorCenter: -1
    property bool barInteractive: false

    // Let clicks on the bar reach its controls while retaining outside dismissal.
    mask: Region {
      item: inputRegion
    }

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

      Item {
        id: inputRegion
        anchors.fill: parent
        anchors.bottomMargin: menu.barInteractive ? menu.theme.dimM : 0
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onClicked: menu.dismissRequested()
      }

      Rectangle {
        id: surface
        color: menu.theme.colB
        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
        }
        anchors.bottom: parent.bottom
        anchors.bottomMargin: menu.theme.dimM + menu.theme.dimS
        x: menu.anchorCenter < 0 ? menu.theme.dimS : Math.max(menu.theme.dimS, Math.min(
                                                                menu.anchorCenter - width / 2,
                                                                menu.width - width
                                                                - menu.theme.dimS))
        width: 480
      }

      Item {
        id: widgets
        anchors.fill: parent
      }
    }
  }

  component SystemControls: Scope {
    id: controls
    required property T theme
    required property var profiles
    readonly property alias audioMetadata: audioMetadata
    readonly property var output: Pipewire.defaultAudioSink
    readonly property bool outputAvailable: !!output?.ready && !!output?.audio
    property string expanded: ""
    property var selectionAnchor: null
    property var pendingNetwork: null
    property var passwordNetwork: null
    property string passwordText: ""
    property string pairingText: ""
    property string networkError: ""
    readonly property bool scanning: scan.running || scanSettling.running
    readonly property var wifiDevices: Networking.devices.values.filter(device => device.type
                                                                                  === DeviceType.Wifi)
    readonly property var wifiDevice: wifiDevices.find(device => device.connected)
                                      ?? wifiDevices[0] ?? null
    readonly property var connectedNetwork: wifiDevice?.networks.values.find(network
                                                                             => network.connected)
                                            ?? null
    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property var audioCandidates: Pipewire.nodes.values.filter(node => !node.isStream
                                                                                && node.audio)
    readonly property var audioDevices: audioCandidates.filter(node
                                                               => audioMetadata.availability(
                                                                    node) !== "no")
    signal passwordRequested
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
      const next = expanded === section && selectionAnchor === anchor ? "" : section;
      reset();
      selectionAnchor = anchor;
      expanded = next;
      if (next === "profiles")
        profiles.refresh();
    }

    readonly property string wifiStatus: {
      if (!wifiDevice)
        return "unavailable";
      if (!Networking.wifiHardwareEnabled)
        return "blocked";
      if (!Networking.wifiEnabled)
        return "off";
      return connectedNetwork?.name || "Not connected";
    }

    function summary(section) {
      return section === "wifi" ? "Wi-Fi · " + wifiStatus : "Speaker · " + audioMetadata.label(
                                    output);
    }

    function value(section) {
      return section !== "output" ? "" : outputAvailable ? "%" + Math.round(output.audio.volume
                                                                            * 100) : "—";
    }

    function muted(section) {
      return section === "wifi" ? !Networking.wifiEnabled || !Networking.wifiHardwareEnabled :
                                  outputAvailable && output.audio.muted;
    }

    function available(section) {
      return section === "wifi" ? wifiDevice !== null || adapter !== null : audioDevices.length
                                  > 0;
    }

    function refreshWifi() {
      if (!wifiDevice || !Networking.wifiEnabled || !Networking.wifiHardwareEnabled || scanning)
        return;
      networkError = "";
      scan.command = ["nmcli", "--wait", "15", "device", "wifi", "rescan", "ifname",
                      wifiDevice.name];
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
        if (controls.expanded !== "wifi")
          return;
        if (code === 0 && status === 0)
          scanSettling.restart();
        else
          controls.networkError = scanError.text.trim() || scanOutput.text.trim()
              || "Wi-Fi scan failed.";
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
      when: controls.expanded === "wifi" && controls.wifiDevice !== null
            && Networking.wifiEnabled

      restoreMode: Binding.RestoreBindingOrValue
    }
    Binding {
      target: controls.adapter
      property: "discovering"
      value: true
      when: controls.expanded === "wifi" && (controls.adapter?.enabled ?? false)
      restoreMode: Binding.RestoreBindingOrValue
    }
    Connections {
      target: controls.pendingNetwork
      function onConnectionFailed(reason) {
        if (reason === ConnectionFailReason.NoSecrets && [WifiSecurityType.WpaPsk,
                                                          WifiSecurityType.Wpa2Psk,
                                                          WifiSecurityType.Sae].includes(
              controls.pendingNetwork.security)) {
          controls.passwordNetwork = controls.pendingNetwork;
          controls.networkError = "Enter the Wi-Fi password.";
          controls.passwordRequested();
        } else {
          controls.networkError = reason === ConnectionFailReason.NoSecrets
              ? "This network requires credentials in a NetworkManager connection profile." :
                ConnectionFailReason.toString(reason);
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
      active: true
      nodes: controls.audioCandidates
    }

    // Only the selected view is instantiated; backend state remains shared.
    readonly property Component details: expanded === "wifi" ? connectionDetails : expanded
                                                               === "output" ? audioDetails :
                                                                              profileDetails

    Component {
      id: profileDetails
      ColumnLayout {
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
        Message {
          theme: controls.theme
          color: controls.theme.colS
          text: controls.profiles.error
        }
      }
    }

    Component {
      id: connectionDetails
      ColumnLayout {
        spacing: controls.theme.dimS
        ColumnLayout {
          Layout.fillWidth: true
          spacing: controls.theme.dimS
          Heading {
            theme: controls.theme
            text: "Bluetooth"
          }
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
              text: (modelData.name || modelData.address) + " · " + (modelData.pairing
                                                                     ? "Pairing…" :
                                                                       modelData.connected
                                                                       ? "Disconnect" :
                                                                         modelData.paired
                                                                         ? "Connect" : "Pair")
              selected: modelData.connected
              enabled: !!controls.adapter?.enabled && !pairing.busy && !modelData.pairing &&
                       ![BluetoothDeviceState.Connecting,
                BluetoothDeviceState.Disconnecting].includes(modelData.state)
              onClicked: {
                if (modelData.paired)
                  modelData.connected = !modelData.connected;
                else
                  pairing.pair(modelData);
              }
            }
          }
          Message {
            theme: controls.theme
            text: pairing.status
            color: controls.theme.colM
          }
          Message {
            theme: controls.theme
            text: pairing.prompt
            font.bold: true
          }
          Field {
            theme: controls.theme
            Layout.fillWidth: true
            visible: pairing.busy && pairing.prompt.length > 0 && !pairing.confirmation
            text: controls.pairingText
            onTextEdited: controls.pairingText = text
            placeholderText: "PIN / passkey"
            font.family: "monospace"
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
        ColumnLayout {
          Layout.fillWidth: true
          spacing: controls.theme.dimS
          Heading {
            theme: controls.theme
            text: "Wi-Fi"
          }
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
              enabled: !!controls.wifiDevice && Networking.wifiEnabled
                       && Networking.wifiHardwareEnabled && !controls.scanning

              onClicked: controls.refreshWifi()
            }
          }
          SectionText {
            theme: controls.theme
            visible: !controls.wifiDevice || !Networking.wifiHardwareEnabled ||
                     !Networking.wifiEnabled || !(controls.wifiDevice?.networks.values.length
                                                  ?? 0)
            text: !controls.wifiDevice ? "Wi-Fi device unavailable." :
                                         !Networking.wifiHardwareEnabled
                                         ? "Wi-Fi is blocked by the hardware switch." :
                                           !Networking.wifiEnabled ? "Wi-Fi is off." :
                                                                     controls.scanning
                                                                     ? "Looking for networks…" :
                                                                       "No networks found."
            color: controls.theme.colM
          }
          Repeater {
            model: controls.wifiDevice?.networks.values ?? []
            MenuButton {
              theme: controls.theme
              required property var modelData
              Layout.fillWidth: true
              text: modelData.name + (modelData.connected ? " · Disconnect" :
                                                            modelData.stateChanging
                                                            ? " · Working…" : "")
              valueText: `%${Math.round(modelData.signalStrength * 100)}`
              selected: modelData.connected
              enabled: Networking.wifiEnabled && !modelData.stateChanging
              onClicked: controls.connectNetwork(modelData)
            }
          }
          Message {
            theme: controls.theme
            text: controls.networkError
            color: controls.passwordNetwork ? controls.theme.colM : controls.theme.colS
          }
          Field {
            id: password
            theme: controls.theme
            Layout.fillWidth: true
            visible: controls.passwordNetwork !== null
            text: controls.passwordText
            onTextEdited: controls.passwordText = text
            placeholderText: "Wi-Fi password"
            font.pointSize: controls.theme.fontSizeM
            echoMode: TextInput.Password
            selectionColor: controls.theme.colP
            selectedTextColor: controls.theme.colB
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
      }
    }
    Component {
      id: audioDetails
      ColumnLayout {
        spacing: controls.theme.dimS
        Repeater {
          model: [true, false]
          AudioOptions {
            required property bool modelData
            controlOwner: controls
            input: modelData
            Layout.fillWidth: true
            Layout.topMargin: input ? 0 : theme.dimS
          }
        }
      }
    }
  }

  component Label: Text {
    required property T theme
    color: theme.colF
    font.family: "sans-serif"
    font.pointSize: theme.fontSizeM
  }

  component SectionText: Label {
    Layout.fillWidth: true
    wrapMode: Text.Wrap
  }

  component Message: SectionText {
    visible: text.length > 0
  }

  component Heading: SectionText {
    font.bold: true
  }

  component Field: TextField {
    required property T theme
    color: theme.colF
    placeholderTextColor: theme.colM
    font.family: "sans-serif"
    background: Rectangle {
      color: theme.colO
    }
  }

  component Input: TextInput {
    required property T theme
    color: theme.colF
    selectionColor: theme.colP
    selectedTextColor: theme.colB
    font.family: "sans-serif"
    font.pointSize: theme.fontSizeM
    verticalAlignment: TextInput.AlignVCenter
  }

  component AuthInput: Input {
    font.family: "monospace"
    inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
  }

  component ThemedSlider: Slider {
    id: slider
    required property T theme
    property bool muted: false
    property real trackThickness: 4
    property real handleWidth: 14
    property real handleHeight: 20
    property color fillColor: muted ? theme.colM : theme.colF
    background: Rectangle {
      x: slider.leftPadding
      y: slider.topPadding + slider.availableHeight / 2 - height / 2
      width: slider.availableWidth
      height: slider.trackThickness
      color: slider.theme.colO
      Rectangle {
        width: slider.visualPosition * parent.width
        height: parent.height
        color: slider.fillColor
      }
    }
    handle: Rectangle {
      x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
      y: slider.topPadding + slider.availableHeight / 2 - height / 2
      implicitWidth: slider.handleWidth
      implicitHeight: slider.handleHeight
      color: !slider.enabled || slider.muted ? slider.theme.colM : slider.theme.colF
    }
  }

  component ScrollColumn: Item {
    id: scroll
    required property T theme
    default property alias contents: column.data
    property real inset: theme.dimS
    implicitHeight: column.implicitHeight + inset * 2
    Flickable {
      anchors.fill: parent
      anchors.margins: scroll.inset
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      ColumnLayout {
        id: column
        width: parent.width
        spacing: scroll.theme.dimS
      }
    }
  }

  component AudioOptions: ColumnLayout {
    id: audioControl
    required property var controlOwner
    readonly property T theme: controlOwner.theme
    required property bool input
    readonly property var node: input ? Pipewire.defaultAudioSource : Pipewire.defaultAudioSink
    readonly property bool available: !!node?.ready && !!node?.audio
    readonly property bool muted: available && node.audio.muted
    readonly property var devices: audioControl.controlOwner.audioDevices.filter(device
                                                                                 => device.isSink
                                                                                    !== input)
    spacing: theme.dimS
    Heading {
      theme: audioControl.theme
      text: audioControl.input ? "Microphone" : "Speaker"
    }
    RowLayout {
      Layout.fillWidth: true
      spacing: audioControl.theme.dimS
      MenuButton {
        theme: audioControl.theme
        Layout.alignment: Qt.AlignVCenter
        text: audioControl.muted ? "Unmute" : "Mute"
        selected: audioControl.muted
        enabled: audioControl.available
        onClicked: audioControl.node.audio.muted = !audioControl.node.audio.muted
      }
      ThemedSlider {
        theme: audioControl.theme
        muted: audioControl.muted
        Layout.fillWidth: true
        from: 0
        to: 1.5
        value: audioControl.available ? audioControl.node.audio.volume : 0
        enabled: audioControl.available
        onMoved: audioControl.node.audio.volume = value
      }
      SectionText {
        theme: audioControl.theme
        Layout.fillWidth: false
        Layout.preferredWidth: 52
        horizontalAlignment: Text.AlignRight
        font.family: "monospace"
        text: audioControl.available ? `%${Math.round(audioControl.node.audio.volume * 100)}` :
                                       "—"

        color: audioControl.muted ? theme.colM : theme.colF
      }
    }
    Repeater {
      model: audioControl.devices
      MenuButton {
        theme: audioControl.theme
        required property var modelData
        Layout.fillWidth: true
        text: audioControl.controlOwner.audioMetadata.label(modelData) + (
                audioControl.controlOwner.audioMetadata.availability(modelData) === "unknown"
                ? " · Availability unknown" : "")
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
      return endpoints[node?.name]?.label || node?.description || node?.nickname || node?.name
          || "Unavailable";
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
        const mediaClass = props["media.class"];
        // Virtual/other audio classes must not inherit a physical port's disconnected status.
        if (props["node.virtual"] === true || props["node.virtual"] === "true" || !["Audio/Sink",
                                                                                    "Audio/Source"].includes(
              mediaClass))
          continue;
        const params = devices[String(props["device.id"])] ?? {};
        const profileDevice = props["card.profile.device"];
        const deviceId = String(profileDevice);
        const direction = mediaClass === "Audio/Sink" ? "Output" : "Input";
        const routes = profileDevice === undefined ? [] : (params.EnumRoute ?? []).filter(route
                                                                                          => {
                                                                                            return route.direction
                                                                                                === direction
                                                                                                && (route.devices
                                                                                                    ?? []).some(
                                                                                                  device => String(
                                                                                                              device)
                                                                                                            === deviceId);
                                                                                          });
        if (!routes.length)
          continue;
        const current = (params.Route ?? []).find(route => route.direction === direction
                                                           && String(route.device)
                                                           === deviceId);
        const route = routes.find(candidate => candidate.index === current?.index
                                               && candidate.available !== "no") ?? routes.find(
                candidate => candidate.available === "yes") ?? routes.find(candidate
                                                                           => candidate.available
                                                                              !== "no")
              ?? routes[0];
        const allUnavailable = routes.every(route => route.available === "no");
        const anyAvailable = routes.some(route => route.available === "yes");
        const availability = allUnavailable ? "no" : anyAvailable ? "yes" : "unknown";
        const product = routeInfo(route, "device.product.name");
        result[props["node.name"]] = {
          availability: availability,
          label: product ? `${product} · ${route.description}` : route.description
                           || props["node.description"]
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
      } else if (new RegExp("Failed to pair|AuthenticationFailed|"
                            + "AuthenticationCanceled|AuthenticationRejected").test(chunk)) {
        prompt = "";
        status = chunk.trim();
        agent.write("quit\n");
      } else {
        const display = chunk.match(/(?:Passkey|PIN code):\s*(\d+)/i);
        if (display)
          status = `Enter this code on your device: ${display[1]}`;
        const match = clean.match(new RegExp(
                                    "(?:Confirm passkey|Authorize service|Accept pairing|"
                                    + "Enter PIN code|Enter passkey)[^\\r\\n]*[:?]\\s*$", "i"));
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
    readonly property bool available: (backend.item?.available ?? false)
                                      && availableProfiles.length > 0
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
        onStreamFinished: {
          const servicePattern = new RegExp("^(net\\.hadess\\.PowerProfiles|"
                                            + "org\\.freedesktop\\.UPower\\.PowerProfiles)\\s",
                                            "m");
          profiles.backendPresent = servicePattern.test(text);
        }
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
            if (!available || busy || !availableProfiles.includes(profile) || profile
                === activeProfile)
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
