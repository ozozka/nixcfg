import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland

Scope {
  id: lockModule
  required property T theme

  property string pendingResponse: ""
  property bool authenticating: false
  property bool authenticationFailed: false
  property bool awaitingUserResponse: false
  property bool suspendPending: false

  function engage() {
    if (pam.active)
      pam.abort();
    pendingResponse = "";
    authenticating = false;
    authenticationFailed = false;
    awaitingUserResponse = false;
    sessionLock.locked = true;
  }

  function submit(response) {
    if (!sessionLock.locked || response.length === 0)
      return;
    authenticationFailed = false;

    if (pam.active) {
      if (awaitingUserResponse && pam.responseRequired) {
        awaitingUserResponse = false;
        pam.respond(response);
      }
      return;
    }

    pendingResponse = response;
    awaitingUserResponse = false;
    authenticating = pam.start();
    if (!authenticating) {
      pendingResponse = "";
      authenticationFailed = true;
    }
  }

  function suspendWhenSecure() {
    suspendPending = true;
    engage();
    if (sessionLock.secure)
      suspend();
    else
      suspendTimeout.restart();
  }

  function suspend() {
    if (!suspendPending || !sessionLock.secure)
      return;
    suspendPending = false;
    suspendTimeout.stop();
    Quickshell.execDetached(["systemctl", "suspend-then-hibernate"]);
  }

  IpcHandler {
    target: "lock"
    function lock(): void {
      lockModule.engage();
    }
    function suspend(): void {
      lockModule.suspendWhenSecure();
    }
  }

  PamContext {
    id: pam
    config: "quickshell"

    onPamMessage: {
      if (responseRequired && lockModule.pendingResponse.length > 0) {
        const response = lockModule.pendingResponse;
        lockModule.pendingResponse = "";
        lockModule.awaitingUserResponse = false;
        respond(response);
      } else {
        lockModule.awaitingUserResponse = responseRequired;
      }
    }

    onCompleted: result => {
      lockModule.pendingResponse = "";
      lockModule.authenticating = false;
      lockModule.awaitingUserResponse = false;

      if (result === PamResult.Success) {
        lockModule.authenticationFailed = false;
        sessionLock.locked = false;
      } else {
        lockModule.authenticationFailed = true;
      }
    }

    onError: error => console.error("Lock PAM error:", PamError.toString(error))
  }

  WlSessionLock {
    id: sessionLock
    locked: false

    onSecureChanged: {
      if (secure)
        lockModule.suspend();
    }

    WlSessionLockSurface {
      color: theme.colB

      Image {
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        source: Qt.resolvedUrl(theme.wallpaper)
      }

      Rectangle {
        color: theme.colB
        anchors.centerIn: parent
        width: 360
        height: lockContent.implicitHeight + theme.dimS * 2

        Column {
          id: lockContent
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
            horizontalAlignment: Text.AlignHCenter
            font {
              family: "monospace"
              pointSize: theme.fontSizeH
              bold: true
            }
            text: Quickshell.env("USER") || Quickshell.env("LOGNAME") || "User"
          }

          Rectangle {
            width: parent.width
            height: theme.dimM * 2
            color: theme.colB

            TextInput {
              id: password
              anchors {
                fill: parent
                margins: theme.dimS
              }
              focus: true
              enabled: !pam.active || lockModule.awaitingUserResponse
              color: theme.colF
              selectionColor: theme.colP
              selectedTextColor: theme.colB
              font {
                family: "monospace"
                pointSize: theme.fontSizeL
              }
              echoMode: pam.responseRequired && pam.responseVisible ? TextInput.Normal : TextInput.Password
              inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
              verticalAlignment: TextInput.AlignVCenter
              horizontalAlignment: TextInput.AlignHCenter

              onTextChanged: lockModule.authenticationFailed = false
              onAccepted: {
                lockModule.submit(text);
                text = "";
              }
            }
          }

          Text {
            width: parent.width
            visible: lockModule.authenticationFailed
            color: theme.colS
            horizontalAlignment: Text.AlignHCenter
            font {
              family: "sans-serif"
              pointSize: theme.fontSizeM
            }
            text: "Authentication failed"
          }

          Text {
            width: parent.width
            visible: lockModule.authenticating
            color: theme.colM
            horizontalAlignment: Text.AlignHCenter
            font {
              family: "sans-serif"
              pointSize: theme.fontSizeM
            }
            text: lockModule.awaitingUserResponse ? pam.message : "Authenticating"
          }
        }
      }

      Connections {
        target: lockModule

        function onAuthenticatingChanged() {
          if (!lockModule.authenticating) {
            password.text = "";
            password.forceActiveFocus();
          }
        }
      }
    }
  }

  Timer {
    id: suspendTimeout
    interval: 5000
    onTriggered: {
      if (lockModule.suspendPending)
        console.error("Session lock was not secured; refusing to suspend");
      lockModule.suspendPending = false;
    }
  }
}
