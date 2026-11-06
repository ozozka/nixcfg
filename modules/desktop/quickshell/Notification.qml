import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Notifications

Scope {
  id: notificationModule
  required property var focusedScreen
  property var states: []

  function promote(state) {
    states = [state, ...states.filter(candidate => candidate !== state)];
    if (focusedScreen)
      popupWindow.screen = focusedScreen;
    Qt.callLater(() => stack.contentY = 0);
  }

  function remove(state) {
    states = states.filter(candidate => candidate !== state);
    Qt.callLater(() => state.destroy());
  }

  ScriptModel {
    id: popupModel
    values: notificationModule.states
  }

  PanelWindow {
    id: popupWindow
    visible: popupModel.values.length > 0
    color: "transparent"
    implicitWidth: Math.min(T.dimH, (screen?.width ?? 1920) - T.dimS * 2)
    implicitHeight: Math.min(popupColumn.implicitHeight, (screen?.height ?? 1080) - T.dimM
                             - T.dimS * 2)
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "quickshell-notifications"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    anchors {
      top: true
      left: true
    }
    margins {
      top: T.dimS
      left: T.dimS
    }

    Flickable {
      id: stack
      anchors.fill: parent
      contentHeight: popupColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      Column {
        id: popupColumn
        width: stack.width
        spacing: T.dimS
        Repeater {
          model: popupModel
          NotificationCard {
            required property var modelData
            width: popupColumn.width
            notificationState: modelData
          }
        }
      }
    }
  }

  IpcHandler {
    target: "notifications"
    function dismissAll(): void {
      for (const state of notificationModule.states.slice())
        state.notification?.dismiss();
    }
  }

  NotificationServer {
    keepOnReload: true
    persistenceSupported: true
    actionsSupported: true
    imageSupported: true
    onNotification: notification => {
      notification.tracked = true;
      notificationModule.promote(stateComponent.createObject(notificationModule, {
                                                               notification: notification,
                                                               receivedAt: new Date()
                                                             }));
    }
  }

  Component {
    id: stateComponent
    QtObject {
      id: state
      required property var notification
      required property date receivedAt
      property bool refreshPending: false
      // Any content change moves the notification back to the top.
      readonly property var content: [notification?.summary, notification?.body, notification
        ?.appName, notification?.image, notification?.appIcon, notification?.actions,
        notification?.urgency, notification?.desktopEntry, notification?.hints]

      onContentChanged: {
        if (refreshPending)
          return;
        refreshPending = true;
        Qt.callLater(() => {
          state.refreshPending = false;
          if (state.notification && notificationModule.states.includes(state))
            notificationModule.promote(state);
        });
      }

      property Connections closed: Connections {
        target: state.notification
        function onClosed() {
          notificationModule.remove(state);
        }
      }
    }
  }

  component NotificationCard: Rectangle {
    id: card

    required property var notificationState
    readonly property var notification: notificationState?.notification ?? null

    function imageSource() {
      if (!notification)
        return "";
      if (String(notification.image || "").length > 0)
        return notification.image;
      if (notification.appIcon.length > 0)
        return Quickshell.iconPath(notification.appIcon, "");
      return "";
    }

    implicitHeight: content.implicitHeight + T.dimS * 2
    color: cardHover.hovered ? T.colO : T.colB
    HoverHandler {
      id: cardHover
    }

    TapHandler {
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onTapped: (eventPoint, button) => {
        if (!card.notification)
          return;
        if (button === Qt.RightButton) {
          card.notification.dismiss();
        } else {
          const actions = card.notification.actions;
          const action = actions.find(action => action.identifier === "default") ?? actions[0];
          if (action) {
            const resident = card.notification.resident;
            action.invoke();
            if (resident && card.notification)
              card.notification.dismiss();
          } else {
            card.notification.dismiss();
          }
        }
      }
    }

    Column {
      id: content
      anchors {
        left: parent.left
        right: parent.right
        top: parent.top
        margins: T.dimS
      }
      spacing: T.dimS

      RowLayout {
        width: parent.width
        spacing: T.dimS

        Image {
          Layout.preferredWidth: T.dimM
          Layout.preferredHeight: T.dimM
          Layout.alignment: Qt.AlignTop
          visible: source.toString().length > 0
          source: card.imageSource()
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
        }

        Lib.SectionText {
          Layout.minimumWidth: 0
          Layout.alignment: Qt.AlignTop
          textFormat: Text.RichText

          function html(value) {
            return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g,
                                                                                      "&gt;").replace(
                  /\n/g, "<br>");
          }

          text: "<b>" + html(card.notification?.appName ?? "") + "</b>: " + html(
                  card.notification?.summary ?? "")
        }

        Lib.Label {
          Layout.alignment: Qt.AlignTop
          Layout.minimumWidth: implicitWidth
          text: Qt.formatDateTime(card.notificationState.receivedAt, "HH:mm")
          color: T.colM
          font.family: "monospace"
          horizontalAlignment: Text.AlignRight
        }
      }

      Lib.Message {
        width: parent.width
        font.family: "serif"
        text: card.notification?.body ?? ""
      }
    }
  }
}
