import Quickshell
import Quickshell.Wayland
import QtQuick
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

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: bar
      required property var modelData
      screen: modelData

      property bool showingDate: false

      WlrLayershell.namespace: "quickshell-bar"

      color: barModule.theme.colO

      implicitHeight: barModule.theme.dimM
      anchors {
        bottom: true
        left: true
        right: true
      }

      Row {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: barModule.theme.dimS

        Workspaces {

          theme: barModule.theme
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: bar.showingDate ? clockStats.date : clockStats.time
          color: barModule.theme.colF
          font.family: "monospace"
          font.pointSize: barModule.theme.fontSizeM

          TapHandler {
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onTapped: (eventPoint, button) => {
              if (button === Qt.LeftButton)
                Quickshell.execDetached(["qs", "ipc", "call", "menu", "toggle"]);
              else if (button === Qt.RightButton)
                bar.showingDate = !bar.showingDate;
            }
          }
        }
        Submap {
          theme: barModule.theme
        }
      }

      Row {
        anchors.right: parent.right
        anchors.rightMargin: barModule.theme.dimS
        anchors.verticalCenter: parent.verticalCenter
        spacing: barModule.theme.dimS

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
        Battery {
          theme: barModule.theme
        }
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

  component Workspaces: Row {
    required property T theme
    spacing: 0

    Repeater {
      model: 6

      Rectangle {
        id: workspace
        required property int index
        readonly property var ws: Hyprland.workspaces.values.find(w => w.id === index + 1)
        readonly property bool isActive: Hyprland.focusedWorkspace?.id === (index + 1)
        readonly property bool occupied: (ws?.toplevels.values.length ?? 0) > 0
        width: glyph.implicitWidth
        height: theme.dimM
        color: workspace.isActive ? theme.colB : theme.colO

        Text {
          id: glyph
          anchors.centerIn: parent
          text: " 🞄 "
          color: workspace.occupied ? theme.colF : theme.colM
          font {
            family: "monospace"
            pointSize: theme.fontSizeM
            bold: true
          }
        }
      }
    }
  }

  component Submap: Text {
    id: submapDisplay
    required property T theme

    property string submap: "default"

    color: theme.colF
    font {
      family: "monospace"
      pointSize: theme.fontSizeM
    }
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

  component Network: Text {
    required property T theme

    color: theme.colF
    font {
      family: "monospace"
      pointSize: theme.fontSizeM
    }
    text: barModule.network.connected ? `${barModule.formatRate(barModule.network.totalBytesPerSecond)}` : ""
  }

  component Temperature: Text {
    required property T theme
    color: theme.colF
    font {
      family: "monospace"
      pointSize: theme.fontSizeM
    }
    text: `${Math.round(barModule.temperature.celsius)}°C`
  }

  component Processes: Text {
    required property T theme
    color: theme.colF
    font {
      family: "monospace"
      pointSize: theme.fontSizeM
    }
    text: `${barModule.processes.count}`
    Accessible.name: `${barModule.processes.count} processes`
  }

  component Cpu: Text {
    required property T theme
    color: theme.colF
    font {
      family: "monospace"
      pointSize: theme.fontSizeM
    }
    text: `%${barModule.cpu.usage.toFixed(2)}`
  }

  component Memory: Text {
    required property T theme

    color: theme.colF
    font {
      family: "monospace"
      pointSize: theme.fontSizeM
    }
    text: `${(barModule.memory.usedBytes / (1024 * 1024 * 1024)).toFixed(2)}`
  }

  component Battery: Text {
    required property T theme
    readonly property bool charging: barModule.lib.battery.status === "Charging"
    readonly property bool full: barModule.lib.battery.status === "Full"

    color: theme.colF
    font {
      family: "monospace"
      pointSize: theme.fontSizeM
    }
    text: full ? "🞄" : "%" + Math.round(barModule.lib.battery.percentage) + (charging ? "🞄" : "◦")
  }
}
