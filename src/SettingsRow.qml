import QtQuick
import qs.Commons
import qs.Ui

// A row on the settings index that opens a page: a mailbox, mail, the
// calendar. One shape for all of them, so the index reads as a list of places
// to go rather than three things that happen to look similar.
Rectangle {
  id: root

  property string title: ""
  property string detail: ""
  // Draws attention to the detail line - a mailbox waiting to be signed in.
  property bool alert: false
  property bool showDot: false
  property color dotColor: "transparent"
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal clicked()

  implicitHeight: body.implicitHeight + Style.spacing.lg * 2
  radius: Style.space(6)
  color: hover.containsMouse ? Qt.rgba(fg.r, fg.g, fg.b, 0.09)
                             : Qt.rgba(fg.r, fg.g, fg.b, 0.04)

  Behavior on color { ColorAnimation { duration: 120 } }

  Rectangle {
    id: dot
    anchors.left: parent.left
    anchors.leftMargin: Style.spacing.lg
    anchors.verticalCenter: parent.verticalCenter
    visible: root.showDot
    width: Style.space(9)
    height: width
    radius: width / 2
    color: root.dotColor
  }

  Column {
    id: body
    anchors.left: root.showDot ? dot.right : parent.left
    anchors.right: chevron.left
    anchors.leftMargin: Style.spacing.lg
    anchors.rightMargin: Style.spacing.sm
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.spacing.xxs

    Text {
      width: parent.width
      text: root.title
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: root.detail
      color: root.alert ? root.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  Text {
    id: chevron
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.lg
    anchors.verticalCenter: parent.verticalCenter
    text: "󰅂"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
