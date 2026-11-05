import QtQuick
import Quickshell
import Quickshell.Services.Polkit

Scope {
  id: polkitModule
  required property T theme

  component ActionButton: Rectangle {
    id: button
    required property T theme
    required property string text
    property color foreground: theme.colF
    property bool bold: false
    signal clicked
    width: label.implicitWidth + theme.dimS * 2
    height: theme.dimM
    Lib.Label {
      id: label
      theme: button.theme
      anchors.centerIn: parent
      text: button.text
      color: button.foreground
      font.family: "monospace"
      font.bold: button.bold
    }
    TapHandler {
      onTapped: button.clicked()
    }
  }

  PolkitAgent {
    id: agent
  }

  FloatingWindow {
    id: dialog
    visible: agent.isActive
    title: "quickshell-polkit"
    color: "transparent"
    implicitWidth: 420
    implicitHeight: content.implicitHeight + theme.dimS * 2

    onClosed: agent.flow?.cancelAuthenticationRequest()
    onVisibleChanged: {
      if (visible && agent.flow?.isResponseRequired)
        Qt.callLater(() => response.forceActiveFocus());
    }

    Rectangle {
      color: theme.colB
      anchors.fill: parent

      Column {
        id: content
        anchors {
          top: parent.top
          left: parent.left
          right: parent.right
          margins: theme.dimS
        }
        spacing: theme.dimS

        Lib.Heading {
          theme: polkitModule.theme
          width: parent.width
          font.family: "monospace"
          font.pointSize: theme.fontSizeL
          text: "Authentication required"
        }

        Lib.SectionText {
          theme: polkitModule.theme
          width: parent.width
          textFormat: Text.PlainText
          text: agent.flow?.message ?? ""
        }

        Lib.Message {
          theme: polkitModule.theme
          width: parent.width
          color: theme.colM
          textFormat: Text.PlainText
          text: agent.flow?.inputPrompt ?? ""
        }

        Lib.Message {
          theme: polkitModule.theme
          width: parent.width
          color: agent.flow?.supplementaryIsError ? theme.colS : theme.colM
          textFormat: Text.PlainText
          text: agent.flow?.supplementaryMessage ?? ""
        }

        Lib.Label {
          theme: polkitModule.theme
          width: parent.width
          visible: agent.flow?.failed ?? false
          color: theme.colS
          text: "Authentication failed"
        }

        Rectangle {
          width: parent.width
          height: theme.dimM * 1.5
          color: theme.colB

          Lib.AuthInput {
            id: response
            theme: polkitModule.theme
            anchors {
              fill: parent
              margins: theme.dimS
            }
            enabled: agent.flow?.isResponseRequired ?? false
            echoMode: agent.flow?.responseVisible ? TextInput.Normal : TextInput.Password

            function submit() {
              if (!agent.flow?.isResponseRequired)
                return;
              agent.flow.submit(text);
              text = "";
            }

            onAccepted: submit()
            Keys.onEscapePressed: agent.flow?.cancelAuthenticationRequest()
          }
        }

        Row {
          anchors.right: parent.right
          spacing: theme.dimS

          ActionButton {
            theme: polkitModule.theme
            text: "Cancel"
            color: theme.colO
            onClicked: agent.flow?.cancelAuthenticationRequest()
          }
          ActionButton {
            theme: polkitModule.theme
            text: "Authenticate"
            color: agent.flow?.isResponseRequired ? theme.colP : theme.colM
            foreground: theme.colB
            bold: true
            enabled: agent.flow?.isResponseRequired ?? false
            onClicked: response.submit()
          }
        }
      }
    }

    function resetResponse() {
      response.text = "";
      if (agent.flow?.isResponseRequired)
        Qt.callLater(() => response.forceActiveFocus());
    }

    Connections {
      target: agent
      function onFlowChanged() {
        dialog.resetResponse();
      }
    }

    Connections {
      target: agent.flow

      function onIsResponseRequiredChanged() {
        dialog.resetResponse();
      }

      function onAuthenticationSucceeded() {
        response.text = "";
      }
      function onAuthenticationRequestCancelled() {
        response.text = "";
      }
    }
  }
}
