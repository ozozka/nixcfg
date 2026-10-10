import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Notifications

Scope {
  id: notificationModule
  required property T theme
  required property var focusedScreen

  Connections {
    target: store
    function onPromoted() {
      if (focusedScreen)
        popupWindow.screen = focusedScreen;
      Qt.callLater(() => stack.contentY = 0);
    }
  }

  ScriptModel {
    id: popupModel
    values: store.states
  }

  PanelWindow {
    id: popupWindow
    visible: popupModel.values.length > 0
    color: "transparent"
    implicitWidth: Math.min(notificationModule.theme.dimH, (screen?.width ?? 1920) - notificationModule.theme.dimS * 2)
    implicitHeight: Math.min(popupColumn.implicitHeight, (screen?.height ?? 1080) - notificationModule.theme.dimM
                             - notificationModule.theme.dimS * 2)
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "quickshell-notifications"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    anchors {
      bottom: true
      right: true
    }
    margins {
      bottom: notificationModule.theme.dimM + notificationModule.theme.dimS
      right: notificationModule.theme.dimS
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
        spacing: notificationModule.theme.dimS
        Repeater {
          model: popupModel
          NotificationCard {
            theme: notificationModule.theme
            required property var modelData
            width: popupColumn.width
            notificationState: modelData
          }
        }
      }
    }
  }

  NotificationStore {
    id: store
  }

  component NotificationCard: Rectangle {
    id: card
    required property T theme

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

    implicitHeight: content.implicitHeight + card.theme.dimS * 2
    color: cardHover.hovered ? card.theme.colB : card.theme.colO
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
        margins: card.theme.dimS
      }
      spacing: card.theme.dimS

      Row {
        width: parent.width
        spacing: card.theme.dimS

        Image {
          id: notificationImage
          width: card.theme.dimM
          height: card.theme.dimM
          visible: source.toString().length > 0
          source: card.imageSource()
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
        }

        Text {
          width: parent.width - (notificationImage.visible ? notificationImage.width + parent.spacing : 0)
                 - arrivalTime.width - parent.spacing
          color: card.theme.colF
          font.family: "sans-serif"
          font.pointSize: card.theme.fontSizeM
          wrapMode: Text.Wrap
          textFormat: Text.RichText

          function escapeHeading(value) {
            return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/\n/g,
                                                                                                            "<br>");
          }

          text: "<b>" + escapeHeading(card.notification?.appName ?? "") + "</b> - " + escapeHeading(card.notification
                                                                                                    ?.summary ?? "")
        }

        Text {
          id: arrivalTime
          text: Qt.formatDateTime(card.notificationState.receivedAt, "HH:mm")
          color: card.theme.colM
          font.family: "monospace"
          font.pointSize: card.theme.fontSizeM
          horizontalAlignment: Text.AlignRight
        }
      }

      Text {
        width: parent.width
        visible: text.length > 0
        color: card.theme.colF
        font {
          family: "serif"
          pointSize: card.theme.fontSizeM
        }
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        text: card.notification?.body ?? ""
      }
    }
  }

  component NotificationStore: Scope {
    id: store
    property var states: []
    signal promoted

    function promote(state) {
      states = [state, ...states.filter(candidate => candidate !== state)];
      promoted();
    }

    function remove(state) {
      states = states.filter(candidate => candidate !== state);
      Qt.callLater(() => state.destroy());
    }

    NotificationServer {
      keepOnReload: true
      persistenceSupported: true
      actionsSupported: true
      imageSupported: true
      onNotification: notification => {
        notification.tracked = true;
        const state = stateComponent.createObject(store, {
                                                    notification: notification,
                                                    receivedAt: new Date()
                                                  });
        store.promote(state);
      }
    }

    Component {
      id: stateComponent
      QtObject {
        id: state
        required property var notification
        required property date receivedAt
        property bool refreshPending: false

        function refresh() {
          if (refreshPending)
            return;
          refreshPending = true;
          Qt.callLater(() => {
            state.refreshPending = false;
            if (state.notification && store.states.includes(state))
              store.promote(state);
          });
        }

        property Connections notificationConnections: Connections {
          target: state.notification
          function onSummaryChanged() {
            state.refresh();
          }
          function onBodyChanged() {
            state.refresh();
          }
          function onAppNameChanged() {
            state.refresh();
          }
          function onImageChanged() {
            state.refresh();
          }
          function onAppIconChanged() {
            state.refresh();
          }
          function onActionsChanged() {
            state.refresh();
          }
          function onUrgencyChanged() {
            state.refresh();
          }
          function onDesktopEntryChanged() {
            state.refresh();
          }
          function onHintsChanged() {
            state.refresh();
          }
          function onClosed() {
            store.remove(state);
          }
        }
      }
    }
  }
}
