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
  required property T theme
  readonly property alias controls: systemControls

  Lib.SystemControls {
    id: systemControls
    theme: barModule.theme
    profiles: powerProfiles
  }

  Lib.PowerProfiles {
    id: powerProfiles
  }
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
    if (controls.expanded !== "") {
      controlsOpened();
      Qt.callLater(() => detailBody.forceActiveFocus());
    }
  }

  Lib.MenuWindow {
    id: details
    theme: barModule.theme
    visible: barModule.controls.expanded !== ""
    barInteractive: true
    WlrLayershell.namespace: "quickshell-controls"
    anchorCenter: {
      const item = barModule.controls.selectionAnchor;
      const window = barModule.detailBar;
      return item && window ? item.parent.mapToItem(window.contentItem, item.x + item.width / 2,
                                                    0).x : -1;
    }
    menuWidth: Math.min(380, Math.max(0, width - theme.dimS * 2))
    menuHeight: Math.min(detailBody.implicitHeight, Math.max(0, height - theme.dimM - theme.dimS
                                                             * 2))
    onDismissRequested: barModule.closeDetails()
    onKeyPressed: event => {
      if (event.key === Qt.Key_Escape) {
        barModule.closeDetails();
        event.accepted = true;
      }
    }

    Lib.ScrollColumn {
      id: detailBody
      theme: barModule.theme
      anchors.fill: parent

      Lib.Heading {
        theme: barModule.theme
        visible: barModule.controls.expanded === "profiles"
        text: "Battery"
      }
      ColumnLayout {
        Layout.fillWidth: true
        visible: barModule.controls.expanded === "profiles"
        spacing: barModule.theme.dimS

        Lib.SectionText {
          theme: barModule.theme
          text: `Charge: %${Math.round(battery.percentage)}`
        }
        Lib.SectionText {
          theme: barModule.theme
          text: `Status: ${battery.status}`
        }
        Lib.SectionText {
          theme: barModule.theme
          visible: battery.status === "Charging" || battery.status === "Discharging"
          text: battery.remainingSeconds > 0 ? (battery.status === "Charging"
                                                ? "Time until full: " : "Time remaining: ")
                                               + Math.floor(battery.remainingSeconds / 60)
                                               + "m" : "Estimate unavailable"
          color: theme.colM
        }
        Lib.SectionText {
          theme: barModule.theme
          text: "Power profiles"
          font.bold: true
        }
        Lib.SectionText {
          theme: barModule.theme
          visible: !barModule.controls.profiles.available
          text: "Power profiles unavailable"
          color: theme.colM
        }
      }
      Loader {
        Layout.fillWidth: true
        Layout.bottomMargin: visible ? barModule.theme.dimS : 0
        visible: barModule.controls.expanded === "output"
        sourceComponent: visible ? playbackDetails : null
      }
      Loader {
        Layout.fillWidth: true
        sourceComponent: details.visible ? barModule.controls.details : null
      }
    }
  }

  Component {
    id: playbackDetails
    Lib.PlaybackDetails {
      theme: barModule.theme
      playback: media
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

      color: barModule.theme.colB

      implicitHeight: barModule.theme.dimM
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
              theme: barModule.theme
              selected: Hyprland.focusedWorkspace?.id === (index + 1)
              text: "🞄"
              textColor: occupied ? theme.colF : theme.colM
              font.bold: true
            }
          }
        }
        BarItem {
          theme: barModule.theme
          text: bar.showingDate ? Qt.formatDate(clock.date, "yyyy-MM-dd") : Qt.formatTime(
                                    clock.date, "hh:mm:ss")
          focusPolicy: Qt.StrongFocus
          onClicked: Quickshell.execDetached(["qs", "ipc", "call", "menu", "toggle"])

          TapHandler {
            acceptedButtons: Qt.RightButton
            onTapped: bar.showingDate = !bar.showingDate
          }
        }
        Repeater {
          model: ["wifi", "output"]

          ControlSummary {
            required property string modelData
            section: modelData
            barWindow: bar
          }
        }
        BarItem {
          id: batteryButton
          theme: barModule.theme
          selected: barModule.controls.expanded === "profiles" && barModule.detailBar === bar
          textColor: battery.status === "Charging" || battery.status === "Discharging"
                     ? theme.colF : theme.colM
          focusPolicy: Qt.StrongFocus
          Accessible.name: "Battery"
          Accessible.description: `%${Math.round(battery.percentage)} · ${battery.status}`
          onClicked: barModule.toggleDetails("profiles", batteryButton, bar)
          text: battery.status === "Full" ? "🞄" : (battery.status === "Discharging" ? "-%" : "%")
                                            + Math.round(battery.percentage)
        }
        BarItem {
          theme: barModule.theme
          text: keyboard.layout
        }
        BarItem {
          theme: barModule.theme
          text: submap.name
          visible: text !== "default" && text !== ""
        }
      }

      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        BarItem {
          theme: barModule.theme
          text: network.connected ? barModule.formatRate(network.totalBytesPerSecond) : ""
        }
        BarItem {
          theme: barModule.theme
          text: Math.round(temperatureFile.value / 1000) + "°C"
        }
        BarItem {
          theme: barModule.theme
          text: processes.count
          Accessible.name: processes.count + " processes"
        }
        BarItem {
          theme: barModule.theme
          text: "%" + cpu.usage.toFixed(2)
        }
        BarItem {
          theme: barModule.theme
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
      for (const file of [capacityFile, statusFile, energyFile, fullEnergyFile, powerFile,
                          statFile, meminfoFile, networkFile, temperatureFile])
        file.reload();
    }
  }

  Scope {
    id: battery

    readonly property real percentage: capacityFile.value
    property string status: "Unknown"
    readonly property real energy: energyFile.value
    readonly property real fullEnergy: fullEnergyFile.value
    readonly property real power: powerFile.value

    readonly property real remainingSeconds: {
      if (power <= 0)
        return 0;
      const remainingEnergy = status === "Charging" ? fullEnergy - energy : energy;
      return Math.max(0, 3600 * remainingEnergy / power);
    }

    NumberFile {
      id: capacityFile
      path: "/sys/class/power_supply/BAT1/capacity"
    }
    FileView {
      id: statusFile
      path: "/sys/class/power_supply/BAT1/status"
      onLoaded: battery.status = text().trim()
    }
    NumberFile {
      id: energyFile
      path: "/sys/class/power_supply/BAT1/energy_now"
    }
    NumberFile {
      id: fullEnergyFile
      path: "/sys/class/power_supply/BAT1/energy_full"
    }
    NumberFile {
      id: powerFile
      path: "/sys/class/power_supply/BAT1/power_now"
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

  Scope {
    id: cpu

    property real usage: 0
    property double previousTotal: 0
    property double previousIdle: 0

    function update(text) {
      const line = text.split("\n").find(line => line.startsWith("cpu "));
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

    FileView {
      id: statFile
      path: "/proc/stat"
      onLoaded: cpu.update(text())
    }
  }

  Scope {
    id: memory

    property real usedBytes: 0

    function update(text) {
      const values = {};
      for (const line of text.split("\n")) {
        const match = line.match(/^(MemTotal|MemAvailable):\s+(\d+)/);
        if (match)
          values[match[1]] = Number(match[2]) * 1024;
      }

      if (values.MemTotal && values.MemAvailable !== undefined) {
        usedBytes = values.MemTotal - values.MemAvailable;
      }
    }

    FileView {
      id: meminfoFile
      path: "/proc/meminfo"
      onLoaded: memory.update(text())
    }
  }

  Scope {
    id: network

    property string interfaceName: "wlan0"
    property real totalBytesPerSecond: 0
    property double previousReceived: 0
    property double previousTransmitted: 0
    property double previousTime: 0

    readonly property var device: Networking.devices.values.find(device => device.name
                                                                           === interfaceName)
    readonly property bool connected: device?.connected ?? false

    function update(text) {
      const line = text.split("\n").find(line => line.trim().startsWith(`${interfaceName}:`));
      if (!line)
        return;
      const values = line.replace(/.*:\s*/, "").trim().split(/\s+/).map(Number);
      const received = values[0];
      const transmitted = values[8];
      const now = Date.now();

      if (previousTime > 0) {
        const elapsedSeconds = (now - previousTime) / 1000;
        if (elapsedSeconds > 0) {
          const downloadBytesPerSecond = Math.max(0, (received - previousReceived)
                                                  / elapsedSeconds);
          const uploadBytesPerSecond = Math.max(0, (transmitted - previousTransmitted)
                                                / elapsedSeconds);
          totalBytesPerSecond = downloadBytesPerSecond + uploadBytesPerSecond;
        }
      }

      previousReceived = received;
      previousTransmitted = transmitted;
      previousTime = now;
    }

    FileView {
      id: networkFile
      path: "/proc/net/dev"
      onLoaded: network.update(text())
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
    property color textColor: !enabled || muted ? theme.colM : theme.colF
    property string suffixText: ""
    property color suffixColor: textColor
    implicitHeight: theme.dimM
    implicitWidth: text.length > 0 ? label.implicitWidth + suffix.implicitWidth : 0
    visible: text.length > 0
    padding: 0
    focusPolicy: Qt.NoFocus
    font.family: "monospace"
    font.pointSize: theme.fontSizeM

    contentItem: Row {
      Text {
        id: label
        text: item.text.length > 0 ? " " + item.text + (item.suffixText ? "" : " ") : ""
        textFormat: Text.PlainText
        color: item.textColor
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

  component ControlSummary: BarItem {
    id: summary
    required property string section
    required property var barWindow
    readonly property var owner: barModule.controls
    theme: barModule.theme
    enabled: owner.available(section) || (section === "output" && media.player !== null)
    selected: owner.expanded === section && barModule.detailBar === barWindow
    muted: owner.muted(section)
    readonly property bool disconnected: section === "wifi" && !muted && owner.wifiDevice
                                         !== null && !owner.connectedNetwork

    font.bold: disconnected
    textColor: !enabled || muted || disconnected ? theme.colM : theme.colF
    focusPolicy: Qt.StrongFocus
    Accessible.name: owner.summary(section)
    suffixText: section === "output" ? media.timing : ""
    suffixColor: media.playing ? theme.colF : theme.colM
    Accessible.description: (muted ? "Muted · " : "") + owner.value(section) + (suffixText
                                                                                ? " · " + suffixText :
                                                                                  "")
    onClicked: barModule.toggleDetails(section, summary, barWindow)

    text: section !== "wifi" ? owner.value(section) : muted ? "-" : disconnected ? "~" :
                                                                                   owner.wifiStatus

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
