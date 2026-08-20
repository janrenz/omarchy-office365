import QtQuick
import qs.Commons
import qs.Ui

// Placeholder rows for the gap between a mailbox being signed in and its first
// fetch coming back.
//
// It stands in for the shape of what is coming - the same row heights, in the
// same two columns - so the panel opens at the size it will keep instead of as
// a narrow box that grows and reflows the moment data lands. That reflow is
// what pushed the filter pills onto a second line.
//
// Deliberately wordless: bars read as "not yet" without pretending to be
// content, and there is nothing here that could be misread as real mail.
Column {
  id: root

  property color fg: Color.foreground
  // Rows per group. More than one group draws a heading bar each, the way the
  // agenda is grouped by day.
  property var groups: [5]
  property bool headings: false
  // One entry per line in a row: how wide a share of the row it takes, and
  // whether it is set in the caption size rather than the body size.
  property var lines: [{ w: 0.42, small: false }, { w: 0.86, small: false }, { w: 0.62, small: true }]
  property string fontFamily: Style.font.family

  spacing: Style.spacing.lg

  // Line boxes measured from the fonts the real rows use, so a placeholder row
  // is exactly as tall as the row that will replace it.
  TextMetrics {
    id: bodyMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    text: "Ag"
  }

  TextMetrics {
    id: captionMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    text: "Ag"
  }

  readonly property real bodyLine: bodyMetrics.height
  readonly property real captionLine: captionMetrics.height

  function wash(alpha) {
    return Qt.rgba(root.fg.r, root.fg.g, root.fg.b, alpha)
  }

  // Rows all the same width would read as a table rather than as text waiting
  // to arrive. Varied from the position rather than at random, so the bars sit
  // still instead of twitching every time a binding is re-evaluated.
  function jitter(seed) {
    return 0.80 + 0.20 * ((seed * 37 % 7) / 6)
  }

  // Breathing, rather than a travelling shimmer: one animation for the whole
  // column is quieter next to a bar that is already showing a spinning icon.
  SequentialAnimation on opacity {
    running: root.visible
    loops: Animation.Infinite
    NumberAnimation { to: 0.45; duration: 850; easing.type: Easing.InOutQuad }
    NumberAnimation { to: 0.95; duration: 850; easing.type: Easing.InOutQuad }
  }

  Repeater {
    model: root.groups

    Column {
      id: group
      required property var modelData
      required property int index
      width: parent.width
      spacing: Style.spacing.sm

      Rectangle {
        visible: root.headings
        width: Style.space(46)
        height: Math.max(Style.space(2), Math.round(root.captionLine * 0.6))
        radius: height / 2
        color: root.wash(0.16)
      }

      Repeater {
        model: group.modelData

        Rectangle {
          id: skeletonRow
          required property int index
          width: group.width
          implicitHeight: rowLines.implicitHeight + Style.spacing.md * 2
          radius: Style.space(5)
          color: root.wash(0.05)

          Rectangle {
            id: skeletonRail
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: Style.spacing.xxs
            anchors.bottomMargin: Style.spacing.xxs
            width: Style.space(2)
            radius: width
            color: root.wash(0.14)
          }

          Column {
            id: rowLines
            anchors.left: skeletonRail.right
            anchors.right: parent.right
            anchors.leftMargin: Style.spacing.md
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Repeater {
              model: root.lines

              Item {
                id: lineBox
                required property var modelData
                required property int index
                width: rowLines.width
                implicitHeight: lineBox.modelData.small ? root.captionLine : root.bodyLine

                Rectangle {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: lineBox.width * lineBox.modelData.w
                         * root.jitter(group.index * 5 + skeletonRow.index * 3 + lineBox.index)
                  height: Math.max(Style.space(2), Math.round(lineBox.height * 0.6))
                  radius: height / 2
                  color: root.wash(lineBox.modelData.small ? 0.09 : 0.13)
                }
              }
            }
          }
        }
      }
    }
  }
}
