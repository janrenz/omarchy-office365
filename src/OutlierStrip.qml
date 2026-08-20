import QtQuick
import qs.Commons
import qs.Ui

// A thin line standing in for meetings the visible hours are hiding.
//
// The window has to have edges or a popup-sized grid is unreadable, but
// nothing may silently vanish behind them - one line saying how many, and
// opening the window when clicked, costs far less than fifteen empty hours.
Item {
  id: root

  property int count: 0
  property string direction: "earlier"
  property real leftInset: 0
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property string fontFamily: Style.font.family

  signal clicked()

  Rectangle {
    anchors.fill: parent
    color: hover.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.07) : "transparent"

    Behavior on color { ColorAnimation { duration: 120 } }
  }

  Text {
    anchors.left: parent.left
    anchors.leftMargin: root.leftInset + Style.spacing.xs
    anchors.verticalCenter: parent.verticalCenter
    text: (root.direction === "earlier" ? "↑  " : "↓  ") + root.count + " " + root.direction
    color: root.dim
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
