import QtQuick
import Quickshell
import Quickshell.Services.Polkit

Scope {
  component ActionButton: Rectangle {
    id: button
    required property string text
    property color foreground: T.colF
    property bool bold: false
    signal clicked
    width: label.implicitWidth + T.dimS * 2
    height: T.dimM
    Lib.Label {
      id: label
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
    implicitHeight: content.implicitHeight

    onClosed: agent.flow?.cancelAuthenticationRequest()
    onVisibleChanged: {
      if (visible && agent.flow?.isResponseRequired)
        Qt.callLater(() => response.forceActiveFocus());
    }

    Lib.Panel {
      id: content
      anchors.fill: parent

      Lib.Heading {
        width: parent.width
        font.family: "monospace"
        font.pointSize: T.fontSizeL
        text: "Authentication required"
      }

      Lib.SectionText {
        width: parent.width
        textFormat: Text.PlainText
        text: agent.flow?.message ?? ""
      }

      Lib.Message {
        width: parent.width
        color: T.colM
        textFormat: Text.PlainText
        text: agent.flow?.inputPrompt ?? ""
      }

      Lib.Message {
        width: parent.width
        color: agent.flow?.supplementaryIsError ? T.colS : T.colM
        textFormat: Text.PlainText
        text: agent.flow?.supplementaryMessage ?? ""
      }

      Lib.Label {
        width: parent.width
        visible: agent.flow?.failed ?? false
        color: T.colS
        text: "Authentication failed"
      }

      Lib.AuthInput {
        id: response
        width: parent.width
        height: T.dimM * 1.5
        padding: T.dimS
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

      Row {
        anchors.right: parent.right
        spacing: T.dimS

        ActionButton {
          text: "Cancel"
          color: T.colO
          onClicked: agent.flow?.cancelAuthenticationRequest()
        }
        ActionButton {
          text: "Authenticate"
          color: agent.flow?.isResponseRequired ? T.colP : T.colM
          foreground: T.colB
          bold: true
          enabled: agent.flow?.isResponseRequired ?? false
          onClicked: response.submit()
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
