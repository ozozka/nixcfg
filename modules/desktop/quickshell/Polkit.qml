import QtQuick
import Quickshell
import Quickshell.Services.Polkit

Scope {
  required property T theme
  PolkitAgent {
    id: agent
  }

  FloatingWindow {
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

        Text {
          width: parent.width
          color: theme.colF
          font {
            family: "monospace"
            pointSize: theme.fontSizeL
            bold: true
          }
          wrapMode: Text.Wrap
          text: "Authentication required"
        }

        Text {
          width: parent.width
          color: theme.colF
          font {
            family: "sans-serif"
            pointSize: theme.fontSizeM
          }
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: agent.flow?.message ?? ""
        }

        Text {
          width: parent.width
          visible: text.length > 0
          color: theme.colM
          font {
            family: "sans-serif"
            pointSize: theme.fontSizeM
          }
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: agent.flow?.inputPrompt ?? ""
        }

        Text {
          width: parent.width
          visible: text.length > 0
          color: agent.flow?.supplementaryIsError ? theme.colS : theme.colM
          font {
            family: "sans-serif"
            pointSize: theme.fontSizeM
          }
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: agent.flow?.supplementaryMessage ?? ""
        }

        Text {
          width: parent.width
          visible: agent.flow?.failed ?? false
          color: theme.colS
          font {
            family: "sans-serif"
            pointSize: theme.fontSizeM
          }
          text: "Authentication failed"
        }

        Rectangle {
          width: parent.width
          height: theme.dimM * 1.5
          color: theme.colO

          TextInput {
            id: response
            anchors {
              fill: parent
              margins: theme.dimS
            }
            enabled: agent.flow?.isResponseRequired ?? false
            color: theme.colF
            selectionColor: theme.colP
            selectedTextColor: theme.colB
            font {
              family: "monospace"
              pointSize: theme.fontSizeM
            }
            echoMode: agent.flow?.responseVisible ? TextInput.Normal : TextInput.Password
            inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
            verticalAlignment: TextInput.AlignVCenter

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

          Rectangle {
            width: cancelText.implicitWidth + theme.dimS * 2
            height: theme.dimM
            color: theme.colO

            Text {
              id: cancelText
              anchors.centerIn: parent
              color: theme.colF
              font {
                family: "monospace"
                pointSize: theme.fontSizeM
              }
              text: "Cancel"
            }

            TapHandler {
              onTapped: agent.flow?.cancelAuthenticationRequest()
            }
          }

          Rectangle {
            width: authenticateText.implicitWidth + theme.dimS * 2
            height: theme.dimM
            color: agent.flow?.isResponseRequired ? theme.colP : theme.colM

            Text {
              id: authenticateText
              anchors.centerIn: parent
              color: theme.colB
              font {
                family: "monospace"
                pointSize: theme.fontSizeM
                bold: true
              }
              text: "Authenticate"
            }

            TapHandler {
              enabled: agent.flow?.isResponseRequired ?? false
              onTapped: response.submit()
            }
          }
        }
      }
    }

    Connections {
      target: agent

      function onFlowChanged() {
        response.text = "";
        if (agent.flow?.isResponseRequired)
          Qt.callLater(() => response.forceActiveFocus());
      }
    }

    Connections {
      target: agent.flow

      function onIsResponseRequiredChanged() {
        response.text = "";
        if (agent.flow?.isResponseRequired)
          Qt.callLater(() => response.forceActiveFocus());
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
