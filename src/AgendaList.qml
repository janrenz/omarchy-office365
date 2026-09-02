import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Merged agenda as a day-grouped list. Deliberately kept behind a small
// interface - day groups in, click-to-open out - so a drawn calendar can
// replace this view later without the panel changing.
Column {
  id: root

  property var agenda: ({ groups: [], hidden: 0 })
  property bool showAccount: false
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal openRequested(string url, string alias)
  signal joinRequested(string url, string alias)
  // A row was clicked. It used to open Outlook, which is the one thing this
  // panel exists to avoid: what a click wants is the meeting - who is coming
  // and whether you are - and Outlook is still one button away inside it.
  signal eventClicked(var event)

  spacing: Style.spacing.lg

  Text {
    textFormat: Text.PlainText
    visible: root.agenda.groups.length === 0
    text: "Nothing scheduled"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  Repeater {
    model: root.agenda.groups

    Column {
      required property var modelData
      width: parent.width
      spacing: Style.spacing.sm

      Text {
        textFormat: Text.PlainText
        text: modelData.label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.1
      }

      Repeater {
        model: modelData.events

        Rectangle {
          id: eventRow
          required property var modelData
          width: parent.width
          implicitHeight: content.implicitHeight + Style.spacing.md * 2
          radius: Style.space(5)
          color: hover.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08) : "transparent"

          // A meeting that came from two mailboxes shows both colours, split
          // down its rail, rather than picking a winner.
          Column {
            id: rail
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: Style.spacing.xxs
            anchors.bottomMargin: Style.spacing.xxs
            width: Style.space(2)

            Repeater {
              model: eventRow.modelData.colors

              Rectangle {
                required property var modelData
                width: rail.width
                height: rail.height / Math.max(1, eventRow.modelData.colors.length)
                radius: width
                color: modelData
              }
            }
          }

          // A Teams meeting is joinable straight from the row - at the moment
          // one starts, joining it is the only thing you want from the panel.
          // Always shown rather than on hover: this is the row's purpose, not
          // an extra like the trash can on a mail row.
          Button {
            id: joinButton
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            // Above the row's own click target, which covers the whole row and
            // would otherwise swallow this.
            z: 1
            visible: String(eventRow.modelData.joinUrl || "") !== ""
            text: "Join"
            tooltipText: eventRow.modelData.onlineProvider === "skype"
                         ? "Open the Skype meeting" : "Open the Teams meeting"
            bordered: true
            foreground: eventRow.modelData.current ? root.accent : root.dim
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: root.joinRequested(String(eventRow.modelData.joinUrl),
                                          String(eventRow.modelData.aliases[0] || ""))
          }

          Column {
            id: content
            anchors.left: rail.right
            anchors.right: joinButton.visible ? joinButton.left : parent.right
            anchors.leftMargin: Style.spacing.md
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Item {
              width: parent.width
              implicitHeight: timeText.implicitHeight

              Text {
                textFormat: Text.PlainText
                id: timeText
                anchors.left: parent.left
                text: eventRow.modelData.timeRange
                color: eventRow.modelData.current ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: eventRow.modelData.current
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.baseline: timeText.baseline
                visible: root.showAccount
                text: eventRow.modelData.shorts.join(" ")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: Model.oneLine(eventRow.modelData.subject, 90)
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              opacity: eventRow.modelData.free ? 0.75 : 1.0
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: text !== ""
              text: Model.oneLine(eventRow.modelData.location, 70)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.eventClicked(eventRow.modelData)
          }
        }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    visible: root.agenda.hidden > 0
    text: "+" + root.agenda.hidden + " more"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
