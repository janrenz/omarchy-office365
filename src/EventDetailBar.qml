import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// What is selected, in one horizontal strip under the grid.
//
// A grid is too dense to be sure of a click, so clicking a block selects it and
// this says what was hit before Open acts on it. Fixed height whether or not
// anything is selected, so selecting does not resize the panel.
Item {
  id: root

  property var event: null
  property bool showAccount: false
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal openRequested(string url, string alias)
  signal joinRequested(string url, string alias)
  signal closeRequested()

  readonly property string joinUrl: event && event.joinUrl ? String(event.joinUrl) : ""

  implicitHeight: Style.space(34)
  height: implicitHeight

  Rectangle {
    anchors.fill: parent
    anchors.topMargin: Style.spacing.xs
    radius: Style.space(4)
    color: root.event ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06) : "transparent"

    Behavior on color { ColorAnimation { duration: 120 } }

    Text {
      anchors.left: parent.left
      anchors.right: joinButton.visible ? joinButton.left : openButton.left
      anchors.rightMargin: Style.spacing.sm
      anchors.leftMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.event
      text: "Pick a meeting to see its details"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Column {
      anchors.left: parent.left
      anchors.right: joinButton.visible ? joinButton.left : openButton.left
      anchors.rightMargin: Style.spacing.sm
      anchors.leftMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      visible: !!root.event
      spacing: Style.spacing.xxs

      Text {
        width: parent.width
        text: root.event ? Model.oneLine(root.event.subject, 90) : ""
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
      }

      // Everything else on one line, in the order you would ask about it:
      // when, where, who, and whose calendar it came from.
      Text {
        width: parent.width
        text: {
          if (!root.event) return ""
          var parts = [root.event.timeRange]
          if (root.event.location !== "") parts.push(Model.oneLine(root.event.location, 40))
          if (root.event.organizer !== "") parts.push(Model.oneLine(root.event.organizer, 30))
          if (root.showAccount && root.event.shorts) parts.push(root.event.shorts.join(" "))
          return parts.join("  ·  ")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    // Joining is the thing you actually want at the moment a meeting starts,
    // so it leads and takes the accent.
    Button {
      id: joinButton
      anchors.right: openButton.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      visible: root.joinUrl !== ""
      text: "Join"
      tooltipText: root.event && root.event.onlineProvider === "skype"
                   ? "Open the Skype meeting" : "Open the Teams meeting"
      bordered: true
      foreground: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.joinRequested(root.joinUrl, String(root.event.aliases[0] || ""))
    }

    Button {
      id: openButton
      anchors.right: closeButton.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      visible: !!root.event
      text: "Open"
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: {
        if (!root.event) return
        root.openRequested(String(root.event.webLink || ""), String(root.event.aliases[0] || ""))
      }
    }

    PanelActionButton {
      id: closeButton
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.xs
      anchors.verticalCenter: parent.verticalCenter
      visible: !!root.event
      iconText: "󰅖"
      tooltipText: "Clear selection"
      foreground: root.dim
      onClicked: root.closeRequested()
    }
  }
}
