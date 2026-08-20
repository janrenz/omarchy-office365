import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One meeting on the grid.
//
// Tinted rather than filled solid the way Outlook does: colour already means
// "which mailbox" on the mail rows and should keep meaning that here, and a
// tint over the panel background keeps the text readable in every theme, which
// a solid fill in an arbitrary account colour would not.
Rectangle {
  id: root

  property var event: null
  property bool selected: false
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal clicked()

  readonly property color hue: event && event.colors && event.colors.length > 0
                               ? event.colors[0] : root.dim
  readonly property bool past: !!event && event.past === true && event.current !== true
  // Time you are not really booked for - a birthday blocking six hours should
  // not read as six hours of meetings.
  readonly property bool free: !!event && event.free === true

  radius: Style.space(4)
  color: free ? "transparent"
              : Qt.rgba(hue.r, hue.g, hue.b, root.selected ? 0.40 : (root.past ? 0.12 : 0.24))
  border.width: free ? Style.space(1) : 0
  border.color: Qt.rgba(hue.r, hue.g, hue.b, root.past ? 0.35 : 0.7)
  opacity: root.past && !root.selected ? 0.65 : 1.0

  Behavior on color { ColorAnimation { duration: 120 } }
  Behavior on opacity { NumberAnimation { duration: 120 } }

  // A meeting from two mailboxes carries both colours, the same way its row in
  // the list does.
  Column {
    id: rail
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(1)
    width: Style.space(2)

    Repeater {
      model: root.event ? root.event.colors : []

      Rectangle {
        required property var modelData
        width: rail.width
        height: rail.height / Math.max(1, root.event.colors.length)
        color: modelData
        opacity: root.past ? 0.5 : 1.0
      }
    }
  }

  // A meeting cut off by the edge of the grid, or by midnight, gets a solid
  // bar along that edge. An arrow in the corner was the obvious thing and the
  // wrong one: it lands on top of the subject in exactly the tall blocks that
  // are most likely to run over.
  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: Style.space(2)
    visible: !!root.event && (root.event.continuesBefore === true || root.event.clippedBefore === true)
    color: root.hue
  }

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Style.space(2)
    visible: !!root.event && (root.event.continuesAfter === true || root.event.clippedAfter === true)
    color: root.hue
  }

  // Hover lifts the tint a little rather than changing the colour, so blocks
  // stay comparable while the pointer travels across them. Declared before the
  // text so it washes the block rather than covering what it says.
  Rectangle {
    anchors.fill: parent
    radius: parent.radius
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.07)
    visible: hover.containsMouse && !root.selected
  }

  // Selection is a ring rather than a bigger fill, so a selected block does not
  // look like a different kind of meeting.
  Rectangle {
    anchors.fill: parent
    radius: parent.radius
    color: "transparent"
    border.width: Style.space(1)
    border.color: root.accent
    visible: root.selected
  }

  // What fits: subject alone in a short block, time above it when there is
  // room, location last of all.
  readonly property bool roomForTime: height >= Style.space(30)
  readonly property bool roomForLocation: height >= Style.space(46)

  Column {
    id: label
    anchors.left: rail.right
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.leftMargin: Style.spacing.xs
    anchors.rightMargin: Style.spacing.xs
    anchors.topMargin: Style.space(2)
    clip: true

    Text {
      width: parent.width
      visible: root.roomForTime
      // The real start time even when the grid cuts the block short of it, so
      // the edge bar says "cut" and this says where it actually began.
      text: root.event ? Model.clockFromMinutes(root.event.startMinutes) : ""
      color: root.event && root.event.current ? root.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: !!root.event && root.event.current
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      text: root.event ? Model.oneLine(root.event.subject, 80) : ""
      color: root.past ? root.dim : root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: !root.past
      wrapMode: Text.Wrap
      maximumLineCount: root.roomForLocation ? 2 : (root.roomForTime ? 2 : 1)
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      visible: root.roomForLocation && text !== ""
      text: root.event ? Model.oneLine(root.event.location, 40) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  // A meeting you can join, marked so it can be picked out of the grid at a
  // glance. Joining itself is a button in the bar below: blocks get narrow
  // enough that a button inside one would be a coin toss to hit.
  Text {
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: Style.space(2)
    anchors.topMargin: Style.space(1)
    visible: !!root.event && String(root.event.joinUrl || "") !== ""
             && root.width >= Style.space(40)
    text: "󰕧"
    color: root.past ? root.dim : root.hue
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
