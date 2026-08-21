import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The agenda drawn as a time grid: hours down the side, days across, meetings
// as blocks in the position and at the size their times give them.
//
// Sits behind the same small interface as the list it replaces - days in,
// click out - so the panel does not care which one it is showing.
Item {
  id: root

  property var grid: ({ days: [], window: { startMinutes: 420, endMinutes: 1320 }, fits: {} })
  property bool showAccount: false
  property var selectedEvent: null
  // How much room the panel can spare. The grid scales the hour to fill it
  // rather than picking a height of its own and leaving a gap beside the mail.
  property real availableHeight: Style.space(420)
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal eventClicked(var event)
  signal openRequested(string url, string alias)
  signal joinRequested(string url, string alias)
  signal expandRequested()

  readonly property var days: grid && grid.days ? grid.days : []
  readonly property int windowStart: grid && grid.window ? grid.window.startMinutes : 420
  readonly property int windowEnd: grid && grid.window ? grid.window.endMinutes : 1320
  readonly property int windowMinutes: Math.max(60, windowEnd - windowStart)

  // Aggregate across days: one strip for the whole grid reads better than a
  // count per column, and clicking it opens the window for all of them.
  readonly property int earlierCount: {
    var total = 0
    for (var i = 0; i < days.length; i++) total += days[i].earlier
    return total
  }
  readonly property int laterCount: {
    var total = 0
    for (var i = 0; i < days.length; i++) total += days[i].later
    return total
  }

  // Tallest all-day stack across the visible days; the band is that many rows
  // for every day, so the grid below it starts level.
  readonly property int allDayRows: {
    var rows = 0
    for (var i = 0; i < days.length; i++)
      for (var j = 0; j < days[i].allDay.length; j++)
        rows = Math.max(rows, days[i].allDay[j].row + 1)
    return Math.min(rows, 3)
  }

  readonly property real gutterWidth: Style.space(22)
  // Hour labels sit centred on their line, so the first and last need half a
  // line of room above and below the grid or they are sliced in half.
  readonly property real labelInset: Style.space(6)
  readonly property real allDayRowHeight: Style.space(15)
  readonly property real allDayHeight: allDayRows === 0 ? 0
                                       : allDayRows * allDayRowHeight + (allDayRows - 1) * Style.space(2)
                                         + Style.spacing.xs * 2
  readonly property real stripHeight: Style.space(13)

  // Whatever is left after the chrome, turned into a scale. Clamped so a long
  // window never squeezes an hour into something unreadable - the grid scrolls
  // instead.
  readonly property real chromeHeight: dayHeader.height + allDayHeight + detailBar.height
                                       + (earlierCount > 0 ? stripHeight : 0)
                                       + (laterCount > 0 ? stripHeight : 0)
  readonly property real hourHeight: Math.max(Style.space(26),
                                              (availableHeight - chromeHeight - labelInset * 2)
                                              / (windowMinutes / 60))
  readonly property real gridHeight: hourHeight * (windowMinutes / 60)

  function minutesToY(minutes) {
    return (Math.max(windowStart, Math.min(windowEnd, minutes)) - windowStart) / 60 * hourHeight
  }

  implicitHeight: dayHeader.height + allDayHeight
                  + (earlierCount > 0 ? stripHeight : 0)
                  + gridViewport.height
                  + (laterCount > 0 ? stripHeight : 0)
                  + detailBar.height

  // ---------------- day headers ----------------
  Row {
    id: dayHeader
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: root.days.length > 1 || root.showAccount ? Style.space(22) : Style.space(16)

    Item { width: root.gutterWidth; height: 1 }

    Repeater {
      model: root.days

      Item {
        required property var modelData
        width: (dayHeader.width - root.gutterWidth) / Math.max(1, root.days.length)
        height: dayHeader.height

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.xs
          anchors.verticalCenter: parent.verticalCenter
          text: {
            var date = new Date(modelData.date)
            if (root.days.length === 1) return Model.dayLabel(date, new Date())
            return Qt.formatDateTime(date, "ddd d")
          }
          color: modelData.isToday ? root.fg : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: modelData.isToday
          font.letterSpacing: 1.1
          elide: Text.ElideRight
        }
      }
    }
  }

  // ---------------- all-day band ----------------
  Item {
    id: allDayBand
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: dayHeader.bottom
    height: root.allDayHeight
    visible: height > 0
    clip: true

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)
    }

    Repeater {
      model: root.days

      Item {
        id: allDayColumn
        required property var modelData
        required property int index
        x: root.gutterWidth + index * columnWidth
        y: Style.spacing.xs
        width: columnWidth
        height: parent.height - Style.spacing.xs * 2

        readonly property real columnWidth: (allDayBand.width - root.gutterWidth) / Math.max(1, root.days.length)

        Repeater {
          model: allDayColumn.modelData.allDay

          EventBlock {
            required property var modelData
            visible: modelData.row < root.allDayRows
            x: Style.space(1)
            // A bar that carries on into the next day runs to the column edge,
            // so a multi-day event reads as one bar rather than as several.
            width: allDayColumn.width - Style.space(1) - (modelData.continuesAfter ? 0 : Style.space(2))
            y: modelData.row * (root.allDayRowHeight + Style.space(2))
            height: root.allDayRowHeight
            event: modelData
            selected: !!root.selectedEvent && root.selectedEvent.id === modelData.id
            fg: root.fg
            dim: root.dim
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.eventClicked(modelData)
          }
        }
      }
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Style.space(1)
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14)
    }
  }

  // ---------------- earlier than the window ----------------
  OutlierStrip {
    id: earlierStrip
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: allDayBand.visible ? allDayBand.bottom : dayHeader.bottom
    height: root.earlierCount > 0 ? root.stripHeight : 0
    visible: root.earlierCount > 0
    count: root.earlierCount
    direction: "earlier"
    leftInset: root.gutterWidth
    fg: root.fg
    dim: root.dim
    fontFamily: root.fontFamily
    onClicked: root.expandRequested()
  }

  // ---------------- the grid ----------------
  Item {
    id: gridViewport
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: earlierStrip.visible ? earlierStrip.bottom
                                      : (allDayBand.visible ? allDayBand.bottom : dayHeader.bottom)
    height: Math.min(root.gridHeight + root.labelInset * 2,
                     Math.max(Style.space(120), root.availableHeight - root.chromeHeight))
    clip: true

    Flickable {
      anchors.fill: parent
      contentHeight: root.gridHeight + root.labelInset * 2
      contentWidth: width
      interactive: contentHeight > height
      boundsBehavior: Flickable.StopAtBounds

      Item {
        width: parent.width
        y: root.labelInset
        height: root.gridHeight

        // ---- hour lines ----
        Repeater {
          model: Math.floor(root.windowMinutes / 60) + 1

          Item {
            required property int index
            width: parent.width
            height: 1
            y: index * root.hourHeight

            Text {
              textFormat: Text.PlainText
              anchors.right: parent.left
              anchors.rightMargin: -root.gutterWidth + Style.spacing.xs
              anchors.verticalCenter: parent.verticalCenter
              width: root.gutterWidth - Style.spacing.xs * 2
              horizontalAlignment: Text.AlignRight
              text: Model.clockFromMinutes(root.windowStart + index * 60).substring(0, 2)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Rectangle {
              x: root.gutterWidth
              width: parent.width - root.gutterWidth
              height: Style.space(1)
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)
            }

            // Half hours, hinted only, and only when there is room for them to
            // mean anything.
            Rectangle {
              x: root.gutterWidth
              y: root.hourHeight / 2
              width: parent.width - root.gutterWidth
              height: Style.space(1)
              visible: root.hourHeight >= Style.space(34) && index * 60 < root.windowMinutes
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
            }
          }
        }

        // ---- day columns ----
        Repeater {
          model: root.days

          Item {
            id: dayColumn
            required property var modelData
            required property int index
            x: root.gutterWidth + index * width
            width: (gridViewport.width - root.gutterWidth) / Math.max(1, root.days.length)
            height: root.gridHeight

            // Weekends read as background rather than as working time.
            Rectangle {
              anchors.fill: parent
              visible: dayColumn.modelData.isWeekend
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
            }

            Rectangle {
              anchors.left: parent.left
              width: Style.space(1)
              height: parent.height
              visible: dayColumn.index > 0
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)
            }

            Repeater {
              model: dayColumn.modelData.timed

              EventBlock {
                required property var modelData
                readonly property real slot: (dayColumn.width - Style.space(2)) / Math.max(1, modelData.columns)
                x: Style.space(1) + modelData.column * slot
                width: Math.max(Style.space(12), slot * modelData.span - Style.space(1))
                y: root.minutesToY(modelData.startMinutes)
                // A floor height, so a fifteen-minute meeting is still
                // readable and still worth aiming at.
                height: Math.max(Style.space(15),
                                 root.minutesToY(modelData.endMinutes) - root.minutesToY(modelData.startMinutes)
                                 - Style.space(1))
                event: modelData
                selected: !!root.selectedEvent && root.selectedEvent.id === modelData.id
                fg: root.fg
                dim: root.dim
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.eventClicked(modelData)
              }
            }
          }
        }

        // ---- now ----
        Item {
          id: nowLine
          width: parent.width
          height: Style.space(1)
          y: root.minutesToY(nowLine.minutes)
          visible: root.days.length > 0 && root.days[0].isToday
                   && minutes >= root.windowStart && minutes <= root.windowEnd

          property int minutes: 0
          function sync() {
            var now = new Date()
            minutes = now.getHours() * 60 + now.getMinutes()
          }
          Component.onCompleted: sync()

          Timer {
            interval: 60000
            repeat: true
            running: nowLine.visible
            onTriggered: nowLine.sync()
          }

          Rectangle {
            x: root.gutterWidth
            width: parent.width - root.gutterWidth
            height: Style.space(1)
            color: root.accent
          }

          Rectangle {
            x: root.gutterWidth - Style.space(2)
            y: -Style.space(2)
            width: Style.space(5)
            height: width
            radius: width / 2
            color: root.accent
          }
        }
      }
    }
  }

  // ---------------- later than the window ----------------
  OutlierStrip {
    id: laterStrip
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: gridViewport.bottom
    height: root.laterCount > 0 ? root.stripHeight : 0
    visible: root.laterCount > 0
    count: root.laterCount
    direction: "later"
    leftInset: root.gutterWidth
    fg: root.fg
    dim: root.dim
    fontFamily: root.fontFamily
    onClicked: root.expandRequested()
  }

  // ---------------- what is selected ----------------
  EventDetailBar {
    id: detailBar
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: laterStrip.visible ? laterStrip.bottom : gridViewport.bottom
    event: root.selectedEvent
    showAccount: root.showAccount
    fg: root.fg
    dim: root.dim
    accent: root.accent
    fontFamily: root.fontFamily
    onOpenRequested: function(url, alias) { root.openRequested(url, alias) }
    onJoinRequested: function(url, alias) { root.joinRequested(url, alias) }
    onCloseRequested: root.eventClicked(null)
  }

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: gridViewport
    visible: root.days.length > 0 && root.earlierCount === 0 && root.laterCount === 0
             && !hasAnything()
    text: "Nothing scheduled"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  function hasAnything() {
    for (var i = 0; i < days.length; i++)
      if (days[i].timed.length > 0 || days[i].allDay.length > 0) return true
    return false
  }
}
