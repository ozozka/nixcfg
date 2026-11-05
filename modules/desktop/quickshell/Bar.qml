import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import Quickshell.Networking
import Quickshell.Hyprland

Scope {
  id: barModule
  required property T theme
  required property Lib lib
  readonly property alias cpu: cpu
  readonly property alias memory: memory
  readonly property alias network: network
  readonly property alias processes: processes
  readonly property alias temperature: temperature
  readonly property var controls: lib.controls
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
      return item && window ? item.parent.mapToItem(window.contentItem, item.x + item.width / 2, 0).x : -1;
    }
    menuWidth: Math.min(380, Math.max(0, width - theme.dimS * 2))
    menuHeight: Math.min(detailBody.implicitHeight + theme.dimS * 2, Math.max(0, height - theme.dimM - theme.dimS * 2))
    onDismissRequested: barModule.closeDetails()
    onKeyPressed: event => {
      if (event.key === Qt.Key_Escape) {
        barModule.closeDetails();
        event.accepted = true;
      }
    }

    Flickable {
      anchors.fill: parent
      anchors.margins: barModule.theme.dimS
      contentHeight: detailBody.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      ColumnLayout {
        id: detailBody
        width: parent.width
        spacing: barModule.theme.dimS

        Text {
          Layout.fillWidth: true
          text: barModule.controls.expanded === "profiles" ? "Battery" : barModule.controls.title(
                                                               barModule.controls.expanded)
          color: barModule.theme.colF
          font.family: "sans-serif"
          font.pointSize: barModule.theme.fontSizeM
          font.bold: true
        }
        ColumnLayout {
          Layout.fillWidth: true
          visible: barModule.controls.expanded === "profiles"
          spacing: barModule.theme.dimS

          Lib.SectionText {
            theme: barModule.theme
            Layout.fillWidth: true
            text: `Charge: %${Math.round(battery.percentage)}`
          }
          Lib.SectionText {
            theme: barModule.theme
            Layout.fillWidth: true
            text: `Status: ${battery.status}`
          }
          Lib.SectionText {
            theme: barModule.theme
            Layout.fillWidth: true
            visible: battery.status === "Charging" || battery.status === "Discharging"
            text: battery.remainingSeconds > 0 ? (battery.status === "Charging" ? "Time until full: " : "Time remaining: ")
                                                 + `${Math.floor(battery.remainingSeconds / 60)}m` :
                                                 "Estimate unavailable"
            color: theme.colM
          }
          Lib.SectionText {
            theme: barModule.theme
            Layout.fillWidth: true
            text: "Power profiles"
            font.bold: true
          }
          Lib.SectionText {
            theme: barModule.theme
            Layout.fillWidth: true
            visible: !barModule.controls.profiles.available
            text: "Power profiles unavailable"
            color: theme.colM
          }
        }
        Loader {
          Layout.fillWidth: true
          sourceComponent: details.visible ? barModule.controls.details : null
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

        Workspaces {

          theme: barModule.theme
        }
        BarItem {
          theme: barModule.theme
          text: bar.showingDate ? clockStats.date : clockStats.time
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
        Battery {
          theme: barModule.theme
          barWindow: bar
        }
        BarItem {
          theme: barModule.theme
          text: keyboard.layout
          textColor: theme.colM
        }
        Submap {
          theme: barModule.theme
        }
      }

      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Network {

          theme: barModule.theme
        }
        Temperature {
          theme: barModule.theme
        }
        Processes {
          theme: barModule.theme
        }
        Cpu {
          theme: barModule.theme
        }
        Memory {
          theme: barModule.theme
        }
      }
    }
  }

  Scope {
    id: battery

    property real percentage: 0
    property string status: "Unknown"
    property real energy: 0
    property real fullEnergy: 0
    property real power: 0

    readonly property real remainingSeconds: {
      if (power <= 0)
        return 0;
      const remainingEnergy = status === "Charging" ? fullEnergy - energy : energy;
      return Math.max(0, 3600 * remainingEnergy / power);
    }

    function updateNumber(file, propertyName) {
      const value = Number(file.text().trim());
      if (!Number.isNaN(value))
        battery[propertyName] = value;
    }

    FileView {
      id: capacityFile
      path: "/sys/class/power_supply/BAT1/capacity"
      onLoaded: battery.updateNumber(this, "percentage")
    }
    FileView {
      id: statusFile
      path: "/sys/class/power_supply/BAT1/status"
      onLoaded: battery.status = text().trim()
    }
    FileView {
      id: energyFile
      path: "/sys/class/power_supply/BAT1/energy_now"
      onLoaded: battery.updateNumber(this, "energy")
    }
    FileView {
      id: fullEnergyFile
      path: "/sys/class/power_supply/BAT1/energy_full"
      onLoaded: battery.updateNumber(this, "fullEnergy")
    }
    FileView {
      id: powerFile
      path: "/sys/class/power_supply/BAT1/power_now"
      onLoaded: battery.updateNumber(this, "power")
    }
    Timer {
      interval: 600
      running: true
      repeat: true
      onTriggered: {
        capacityFile.reload();
        statusFile.reload();
        energyFile.reload();
        fullEnergyFile.reload();
        powerFile.reload();
      }
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

  Scope {
    id: clockStats
    readonly property string time: Qt.formatTime(clock.date, "hh:mm:ss")
    readonly property string date: Qt.formatDate(clock.date, "yyyy-MM-dd")

    SystemClock {
      id: clock
      precision: SystemClock.Seconds
    }
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

    Timer {
      interval: 600
      running: true
      repeat: true
      onTriggered: statFile.reload()
    }
  }

  Scope {
    id: memory

    property real usedBytes: 0
    property real totalBytes: 0

    function update(text) {
      const values = {};
      for (const line of text.split("\n")) {
        const match = line.match(/^(MemTotal|MemAvailable):\s+(\d+)/);
        if (match)
          values[match[1]] = Number(match[2]) * 1024;
      }

      if (values.MemTotal && values.MemAvailable !== undefined) {
        totalBytes = values.MemTotal;
        usedBytes = values.MemTotal - values.MemAvailable;
      }
    }

    FileView {
      id: meminfoFile
      path: "/proc/meminfo"
      onLoaded: memory.update(text())
    }

    Timer {
      interval: 600
      running: true
      repeat: true
      onTriggered: meminfoFile.reload()
    }
  }

  Scope {
    id: network

    property string interfaceName: "wlan0"
    property real downloadBytesPerSecond: 0
    property real uploadBytesPerSecond: 0
    property real totalBytesPerSecond: 0
    property double previousReceived: 0
    property double previousTransmitted: 0
    property double previousTime: 0

    readonly property var device: Networking.devices.values.find(device => device.name === interfaceName)
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
          downloadBytesPerSecond = Math.max(0, (received - previousReceived) / elapsedSeconds);
          uploadBytesPerSecond = Math.max(0, (transmitted - previousTransmitted) / elapsedSeconds);
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

    Timer {
      interval: 600
      running: true
      repeat: true
      onTriggered: networkFile.reload()
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

  Scope {
    id: temperature

    property real celsius: 0

    FileView {
      id: temperatureFile
      path: "/sys/class/thermal/thermal_zone3/temp"
      onLoaded: {
        const millidegrees = Number(text().trim());
        if (!Number.isNaN(millidegrees))
          temperature.celsius = millidegrees / 1000;
      }
    }

    Timer {
      interval: 600
      running: true
      repeat: true
      onTriggered: temperatureFile.reload()
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
    implicitHeight: theme.dimM
    implicitWidth: text.length > 0 ? label.implicitWidth : 0
    visible: text.length > 0
    padding: 0
    focusPolicy: Qt.NoFocus
    font.family: "monospace"
    font.pointSize: theme.fontSizeM

    contentItem: Text {
      id: label
      text: item.text.length > 0 ? " " + item.text + " " : ""
      color: item.textColor
      font: item.font
      verticalAlignment: Text.AlignVCenter
    }
  }

  component ControlSummary: BarItem {
    id: summary
    required property string section
    required property var barWindow
    theme: barModule.theme
    enabled: barModule.controls.available(section)
    selected: barModule.controls.expanded === section && barModule.detailBar === barWindow
    muted: barModule.controls.muted(section)
    readonly property bool disconnected: section === "wifi" && !muted && barModule.controls.wifiDevice !== null &&
                                         !barModule.controls.connectedNetwork

    font.bold: disconnected
    textColor: !enabled || muted || disconnected ? theme.colM : theme.colF
    focusPolicy: Qt.StrongFocus
    Accessible.name: barModule.controls.summary(section)
    Accessible.description: (muted ? "Muted · " : "") + barModule.controls.value(section)
    onClicked: barModule.toggleDetails(section, summary, barWindow)

    text: {
      if (section === "wifi") {
        if (muted)
          return "-";
        if (disconnected)
          return "~";
      }
      if (section === "wifi" || section === "bluetooth")
        return barModule.controls.summary(section).replace(/^(Wi-Fi|Bluetooth) · /, "");
      return barModule.controls.value(section);
    }
  }

  component Workspaces: Row {
    id: workspaces
    required property T theme
    spacing: 0

    Repeater {
      model: 6

      BarItem {
        required property int index
        readonly property var ws: Hyprland.workspaces.values.find(w => w.id === index + 1)
        readonly property bool occupied: (ws?.toplevels.values.length ?? 0) > 0
        theme: workspaces.theme
        selected: Hyprland.focusedWorkspace?.id === (index + 1)
        text: "🞄"
        textColor: occupied ? theme.colF : theme.colM
        font.bold: true
      }
    }
  }

  component Submap: BarItem {
    id: submapDisplay
    property string submap: "default"

    text: submap
    visible: submap !== "default" && submap !== ""

    Process {
      id: submapProcess
      command: ["hyprctl", "submap"]
      running: true
      stdout: StdioCollector {
        onStreamFinished: submapDisplay.submap = this.text.trim()
      }
    }

    Connections {
      target: Hyprland
      function onRawEvent(event) {
        if (event.name === "submap")
          submapDisplay.submap = event.data || "default";
      }
    }
  }

  component Network: BarItem {
    text: barModule.network.connected ? `${barModule.formatRate(barModule.network.totalBytesPerSecond)}` : ""
  }

  component Temperature: BarItem {
    text: `${Math.round(barModule.temperature.celsius)}°C`
  }

  component Processes: BarItem {
    text: `${barModule.processes.count}`
    Accessible.name: `${barModule.processes.count} processes`
  }

  component Cpu: BarItem {
    text: `%${barModule.cpu.usage.toFixed(2)}`
  }

  component Memory: BarItem {
    text: `${(barModule.memory.usedBytes / (1024 * 1024 * 1024)).toFixed(2)}`
  }

  component Battery: BarItem {
    id: batteryButton
    required property var barWindow
    selected: barModule.controls.expanded === "profiles" && barModule.detailBar === barWindow
    textColor: battery.status === "Charging" || battery.status === "Discharging" ? theme.colF : theme.colM
    focusPolicy: Qt.StrongFocus
    Accessible.name: "Battery"

    Accessible.description: `%${Math.round(battery.percentage)} · ${battery.status}`
    onClicked: barModule.toggleDetails("profiles", batteryButton, barWindow)

    text: battery.status === "Full" ? "🞄" : (battery.status === "Discharging" ? "-" : "") + `%${Math.round(
                                        battery.percentage)}`
  }
}
