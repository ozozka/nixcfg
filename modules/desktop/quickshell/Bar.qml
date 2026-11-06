import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import Quickshell.Networking
import Quickshell.Hyprland
import Quickshell.Services.Mpris

Scope {
  id: barModule
  property var detailBar: null
  signal controlsOpened

  function closeDetails() {
    controls.reset();
    detailBar = null;
  }

  function toggleDetails(section, item, window) {
    detailBar = window;
    details.screen = window.screen;
    controls.toggleDetails(section, item);
    if (controls.expanded === "profiles")
      powerProfiles.refresh();
    if (controls.expanded !== "") {
      controlsOpened();
      Qt.callLater(() => detailBody.forceActiveFocus());
    }
  }

  Lib.SystemControls {
    id: controls
  }

  Lib.PowerProfiles {
    id: powerProfiles
  }

  Lib.MenuWindow {
    id: details
    visible: controls.expanded !== ""
    barInteractive: true
    WlrLayershell.namespace: "quickshell-controls"
    anchorCenter: {
      const item = controls.selectionAnchor;
      const bar = barModule.detailBar;
      return item && bar ? item.parent.mapToItem(bar.contentItem, item.x + item.width / 2, 0).x :
                           -1;
    }
    menuWidth: Math.min(380, Math.max(0, width - T.dimS * 2))
    menuHeight: Math.min(detailBody.implicitHeight, Math.max(0, height - T.dimM - T.dimS * 2))
    onDismissRequested: barModule.closeDetails()
    onEscapePressed: barModule.closeDetails()

    Lib.ScrollColumn {
      id: detailBody
      anchors.fill: parent

      Loader {
        Layout.fillWidth: true
        sourceComponent: ({
                            profiles: batteryDetails,
                            output: outputDetails,
                            wifi: controls.wifiDetails
                          })[controls.expanded] ?? null
      }
    }
  }

  Component {
    id: batteryDetails
    ColumnLayout {
      spacing: T.dimS
      Lib.Heading {
        text: "Battery"
      }
      Lib.SectionText {
        text: `Charge: %${Math.round(battery.percentage)}`
      }
      Lib.SectionText {
        text: `Status: ${battery.status}`
      }
      Lib.SectionText {
        readonly property bool charging: battery.status === "Charging"
        visible: charging || battery.status === "Discharging"
        readonly property string prefix: charging ? "Time until full" : "Time remaining"
        readonly property int minutes: Math.floor(battery.remainingSeconds / 60)
        text: battery.remainingSeconds > 0 ? `${prefix}: ${minutes}m` : "Estimate unavailable"
        color: T.colM
      }
      Lib.Heading {
        text: "Power profiles"
      }
      Lib.SectionText {
        visible: !powerProfiles.available
        text: "Power profiles unavailable"
        color: T.colM
      }
      Repeater {
        model: powerProfiles.availableProfiles
        Lib.MenuButton {
          required property string modelData
          Layout.fillWidth: true
          text: modelData
          selected: powerProfiles.activeProfile === modelData
          enabled: powerProfiles.available && !powerProfiles.busy
          onClicked: powerProfiles.setProfile(modelData)
        }
      }
      Lib.Message {
        color: T.colS
        text: powerProfiles.error
      }
    }
  }

  Component {
    id: outputDetails
    ColumnLayout {
      spacing: T.dimS
      Lib.PlaybackDetails {
        Layout.fillWidth: true
        Layout.bottomMargin: T.dimS
        playback: media
      }
      Lib.AudioOptions {
        Layout.fillWidth: true
        controlOwner: controls
        input: true
      }
      Lib.AudioOptions {
        Layout.fillWidth: true
        Layout.topMargin: T.dimS
        controlOwner: controls
        input: false
      }
    }
  }

  Scope {
    id: media
    // playerctld mirrors the active real player, including its identity and metadata.
    readonly property var players: Mpris.players.values.filter(player => player.dbusName
                                                                         !== "org.mpris.MediaPlayer2.playerctld")
    property var selectedPlayer: null
    readonly property var player: players.includes(selectedPlayer) ? selectedPlayer : null
    readonly property bool playing: player?.isPlaying ?? false
    property int positionTick: 0
    readonly property real position: {
      // MPRIS extrapolates position on read; it does not notify every elapsed second.
      positionTick;
      return player?.positionSupported ? Math.max(0, Math.min(player.length > 0 ? player.length :
                                                                                  Infinity, player.position)) :
                                         0;
    }
    readonly property string timing: player?.lengthSupported && player?.positionSupported
                                     && Number.isFinite(player.length) && player.length > 0
                                     ? formatTime(player.length) + "-" + formatTime(position) :
                                       ""

    function formatTime(seconds) {
      const total = Math.max(0, Math.floor(seconds));
      const minutes = Math.floor(total / 60);
      return `${minutes}:${String(total % 60).padStart(2, "0")}`;
    }

    function select(target) {
      if (players.includes(target))
        selectedPlayer = target;
    }

    function reconcile() {
      if (!players.includes(selectedPlayer)) {
        selectedPlayer = players.find(candidate => candidate.isPlaying) ?? players[0] ?? null;
      } else if (!selectedPlayer.isPlaying) {
        selectedPlayer = players.find(candidate => candidate.isPlaying) ?? selectedPlayer;
      }
    }

    onPlayersChanged: reconcile()
    Component.onCompleted: reconcile()

    Timer {
      interval: 1000
      running: media.playing && (media.player?.positionSupported ?? false)
      repeat: true
      onTriggered: media.positionTick++
    }
    Variants {
      model: media.players
      Scope {
        required property var modelData
        Connections {
          target: modelData
          function onIsPlayingChanged() {
            // New playback activity always takes precedence over manual selection.
            if (modelData.isPlaying)
              media.select(modelData);
            else
              media.reconcile();
          }
        }
      }
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: bar
      required property var modelData
      screen: modelData

      property bool showingDate: false

      WlrLayershell.namespace: "quickshell-bar"

      color: T.colB

      implicitHeight: T.dimM
      anchors {
        bottom: true
        left: true
        right: true
      }

      Row {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Row {
          spacing: 0
          Repeater {
            model: 6
            BarItem {
              required property int index
              readonly property var ws: Hyprland.workspaces.values.find(w => w.id === index + 1)
              readonly property bool occupied: (ws?.toplevels.values.length ?? 0) > 0
              selected: Hyprland.focusedWorkspace?.id === (index + 1)
              text: "🞄"
              foreground: occupied ? T.colF : T.colM
              font.bold: true
            }
          }
        }
        BarItem {
          text: bar.showingDate ? Qt.formatDate(clock.date, "yyyy-MM-dd") : Qt.formatTime(
                                    clock.date, "hh:mm:ss")
          focusPolicy: Qt.StrongFocus
          onClicked: Quickshell.execDetached(["qs", "ipc", "call", "menu", "toggle"])

          TapHandler {
            acceptedButtons: Qt.RightButton
            onTapped: bar.showingDate = !bar.showingDate
          }
        }
        DetailItem {
          readonly property bool off: !Networking.wifiEnabled || !Networking.wifiHardwareEnabled
          readonly property bool disconnected: !off && !!controls.wifiDevice &&
                                               !controls.connectedNetwork
          section: "wifi"
          barWindow: bar
          enabled: !!controls.wifiDevice || !!controls.adapter
          muted: off
          foreground: !enabled || off || disconnected ? T.colM : T.colF
          font.bold: disconnected
          text: off ? "-" : disconnected ? "~" : controls.wifiStatus
          Accessible.name: "Wi-Fi · " + controls.wifiStatus
          Accessible.description: off ? "Muted · " : ""
        }
        DetailItem {
          section: "output"
          barWindow: bar
          enabled: controls.audioDevices.length > 0 || media.player !== null
          muted: controls.outputAvailable && controls.output.audio.muted
          text: controls.outputAvailable ? `%${Math.round(controls.output.audio.volume * 100)}` :
                                           "—"
          suffixText: media.timing
          suffixColor: media.playing ? T.colF : T.colM
          Accessible.name: "Speaker · " + controls.audioMetadata.label(controls.output)
          Accessible.description: (muted ? "Muted · " : "") + text + (suffixText ? " · " + suffixText :
                                                                                   "")
        }
        DetailItem {
          section: "profiles"
          barWindow: bar
          Accessible.name: "Battery"
          Accessible.description: `%${Math.round(battery.percentage)} · ${battery.status}`
          text: battery.status === "Full" ? "🞄" : (battery.status === "Discharging" ? "-%" : "%")
                                            + Math.round(battery.percentage)
        }
        BarItem {
          text: keyboard.layout
        }
        BarItem {
          text: submap.name
          visible: text !== "default" && text !== ""
        }
      }

      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        BarItem {
          text: network.connected ? barModule.formatRate(network.totalBytesPerSecond) : ""
        }
        BarItem {
          text: Math.round(temperatureFile.value / 1000) + "°C"
        }
        BarItem {
          text: processes.count
          Accessible.name: processes.count + " processes"
        }
        BarItem {
          text: "%" + cpu.usage.toFixed(2)
        }
        BarItem {
          text: (memory.usedBytes / (1024 * 1024 * 1024)).toFixed(2)
        }
      }
    }
  }

  Timer {
    interval: 600
    running: true
    repeat: true
    onTriggered: {
      for (const file of [capacityFile, statusFile, energyFile, fullEnergyFile, powerFile, cpu,
                          memory, network, temperatureFile])
        file.reload();
    }
  }

  Scope {
    id: battery
    readonly property string dir: "/sys/class/power_supply/BAT1/"
    readonly property real percentage: capacityFile.value
    property string status: "Unknown"

    readonly property real remainingSeconds: {
      const energy = energyFile.value;
      const power = powerFile.value;
      if (power <= 0)
        return 0;
      const remainingEnergy = status === "Charging" ? fullEnergyFile.value - energy : energy;
      return Math.max(0, 3600 * remainingEnergy / power);
    }

    NumberFile {
      id: capacityFile
      path: battery.dir + "capacity"
    }
    FileView {
      id: statusFile
      path: battery.dir + "status"
      onLoaded: battery.status = text().trim()
    }
    NumberFile {
      id: energyFile
      path: battery.dir + "energy_now"
    }
    NumberFile {
      id: fullEnergyFile
      path: battery.dir + "energy_full"
    }
    NumberFile {
      id: powerFile
      path: battery.dir + "power_now"
    }
  }

  Scope {
    id: keyboard
    property string layout: ""

    function updateLayout(devices) {
      const main = devices.keyboards.find(keyboard => keyboard.main);
      if (!main)
        return;
      const layouts = main.layout.split(",");
      layout = layouts[main.active_layout_index] || main.active_keymap;
    }

    Process {
      id: devicesProcess
      command: ["hyprctl", "-j", "devices"]
      running: true
      stdout: StdioCollector {
        onStreamFinished: {
          try {
            keyboard.updateLayout(JSON.parse(this.text));
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

  SystemClock {
    id: clock
    precision: SystemClock.Seconds
  }

  FileView {
    id: cpu
    path: "/proc/stat"

    property real usage: 0
    property double previousTotal: 0
    property double previousIdle: 0

    onLoaded: {
      const line = text().split("\n").find(line => line.startsWith("cpu "));
      if (!line)
        return;
      const values = line.trim().split(/\s+/).slice(1).map(Number);
      const total = values.reduce((sum, value) => sum + value, 0);
      const idle = values[3] + values[4];

      if (previousTotal > 0) {
        const totalDelta = total - previousTotal;
        const idleDelta = idle - previousIdle;
        if (totalDelta > 0)
          usage = 100 * (totalDelta - idleDelta) / totalDelta;
      }

      previousTotal = total;
      previousIdle = idle;
    }
  }

  FileView {
    id: memory
    path: "/proc/meminfo"

    property real usedBytes: 0

    onLoaded: {
      const values = {};
      for (const line of text().split("\n")) {
        const match = line.match(/^(MemTotal|MemAvailable):\s+(\d+)/);
        if (match)
          values[match[1]] = Number(match[2]) * 1024;
      }
      if (values.MemTotal && values.MemAvailable !== undefined)
        usedBytes = values.MemTotal - values.MemAvailable;
    }
  }

  FileView {
    id: network
    path: "/proc/net/dev"

    property string interfaceName: "wlan0"
    property real totalBytesPerSecond: 0
    property double previousReceived: 0
    property double previousTransmitted: 0
    property double previousTime: 0

    readonly property var device: Networking.devices.values.find(device => device.name
                                                                           === interfaceName)
    readonly property bool connected: device?.connected ?? false

    onLoaded: {
      const line = text().split("\n").find(line => line.trim().startsWith(`${interfaceName}:`));
      if (!line)
        return;
      const values = line.replace(/.*:\s*/, "").trim().split(/\s+/).map(Number);
      const received = values[0];
      const transmitted = values[8];
      const now = Date.now();
      const elapsedSeconds = (now - previousTime) / 1000;

      if (previousTime > 0 && elapsedSeconds > 0) {
        const download = Math.max(0, (received - previousReceived) / elapsedSeconds);
        const upload = Math.max(0, (transmitted - previousTransmitted) / elapsedSeconds);
        totalBytesPerSecond = download + upload;
      }

      previousReceived = received;
      previousTransmitted = transmitted;
      previousTime = now;
    }
  }

  Scope {
    id: processes
    property int count: 0

    Process {
      id: snapshot
      // One PID per process, not one entry per thread or cumulative forks.
      command: ["ps", "-e", "-o", "pid="]
      running: true
      stdout: StdioCollector {
        onStreamFinished: processes.count = text.trim() ? text.trim().split(/\s+/).length : 0
      }
    }

    Timer {
      interval: 2000
      running: true
      repeat: true
      onTriggered: {
        if (!snapshot.running)
          snapshot.running = true;
      }
    }
  }

  NumberFile {
    id: temperatureFile
    path: "/sys/class/thermal/thermal_zone3/temp"
  }

  component NumberFile: FileView {
    property real value: 0
    onLoaded: {
      const number = Number(text().trim());
      if (!Number.isNaN(number))
        value = number;
    }
  }

  function formatRate(bytesPerSecond) {
    if (bytesPerSecond < 1024)
      return `${Math.round(bytesPerSecond)}B/s`;
    if (bytesPerSecond < 1024 * 1024)
      return `${(bytesPerSecond / 1024).toFixed(1)}K/s`;
    return `${(bytesPerSecond / (1024 * 1024)).toFixed(1)}M/s`;
  }

  component BarItem: Lib.MenuButton {
    id: item
    property string suffixText: ""
    property color suffixColor: foreground
    implicitHeight: T.dimM
    implicitWidth: label.implicitWidth + suffix.implicitWidth
    visible: text.length > 0
    padding: 0
    focusPolicy: Qt.NoFocus
    font.family: "monospace"

    contentItem: Row {
      Text {
        id: label
        text: " " + item.text + (item.suffixText ? "" : " ")
        textFormat: Text.PlainText
        color: item.foreground
        font: item.font
        height: item.height
        verticalAlignment: Text.AlignVCenter
      }
      Text {
        id: suffix
        text: item.suffixText ? " " + item.suffixText + " " : ""
        textFormat: Text.PlainText
        color: item.suffixColor
        font: item.font
        height: item.height
        verticalAlignment: Text.AlignVCenter
      }
    }
  }

  // Bar item that toggles its section in the details popup.
  component DetailItem: BarItem {
    id: detailItem
    required property string section
    required property var barWindow
    selected: controls.expanded === section && barModule.detailBar === barWindow
    focusPolicy: Qt.StrongFocus
    onClicked: barModule.toggleDetails(section, detailItem, barWindow)
  }

  Scope {
    id: submap
    property string name: "default"

    Process {
      command: ["hyprctl", "submap"]
      running: true
      stdout: StdioCollector {
        onStreamFinished: submap.name = text.trim()
      }
    }
    Connections {
      target: Hyprland
      function onRawEvent(event) {
        if (event.name === "submap")
          submap.name = event.data || "default";
      }
    }
  }
}
