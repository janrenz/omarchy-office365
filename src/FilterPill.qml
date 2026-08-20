import QtQuick
import qs.Commons

// A toggle in the panel's filter row. Selected pills carry a soft fill;
// once any filter is on, the ones not chosen fade back so the active one
// reads as the subject of what is below.
Rectangle {
  id: root

  property string label: ""
  property string detail: ""
  property color dotColor: "transparent"
  property bool selected: false
  property bool faded: false
  property bool alert: false
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal clicked()

  implicitWidth: content.implicitWidth + Style.spacing.controlPaddingX * 2
  implicitHeight: content.implicitHeight + Style.spacing.sm * 2
  radius: height / 2
  color: selected ? Qt.rgba(fg.r, fg.g, fg.b, 0.14)
                  : (hover.containsMouse ? Qt.rgba(fg.r, fg.g, fg.b, 0.07) : "transparent")
  opacity: faded ? 0.45 : 1.0

  Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
  Behavior on color { ColorAnimation { duration: 120 } }

  Row {
    id: content
    anchors.centerIn: parent
    spacing: Style.spacing.sm

    Rectangle {
      width: Style.space(7)
      height: width
      radius: width / 2
      color: root.dotColor
      visible: root.dotColor !== "transparent"
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      text: root.label
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      text: root.detail
      visible: text !== ""
      color: root.alert ? root.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
