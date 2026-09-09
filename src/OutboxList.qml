import QtQuick
import qs.Commons
import qs.Ui

// The mail on its way out, drawn as a list.
//
// It stands in the place of the message list, because it answers the same
// question in the same column: what is in this folder. The Outbox is not a
// folder on any server - it is this shell's own queue, and a message is in it
// only for as long as it takes to leave - but from the reader's side it is one
// more thing to look in, which is why it sits in the folder tree with the
// rest.
//
// Rows come from Model.outboxRows already shaped, so this file only draws
// them and says what was pressed. Three states, and each of them offers what
// can be done about it:
//
//   waiting  - Edit, Discard. It has not gone anywhere yet.
//   sending  - neither. The message may already be in somebody's mailbox, so
//              there is nothing honest to offer: no Cancel, no Discard.
//   failed   - Retry, Edit, Discard, and what went wrong.
Column {
  id: root

  // Rows from Model.outboxRows(jobs).
  property var rows: []
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  // Keyboard cursor, as an index into `rows`. -1 until a key moves it, so a
  // list opened with the mouse shows no cursor.
  property int cursorIndex: -1

  signal retryRequested(string jobId)
  signal editRequested(string jobId)
  signal discardRequested(string jobId)

  spacing: Style.spacing.xs

  function moveCursor(step) {
    if (rows.length === 0) return
    var next = cursorIndex < 0 ? (step > 0 ? 0 : rows.length - 1) : cursorIndex + step
    cursorIndex = Math.max(0, Math.min(rows.length - 1, next))
  }

  // The row the cursor is on, for a caller that has to scroll it into view.
  function cursorRow() {
    if (cursorIndex < 0) return null
    for (var i = 0; i < children.length; i++)
      if (children[i] && children[i].rowIndex === root.cursorIndex) return children[i]
    return null
  }

  // What the keys act on: whatever the cursor is on, or the one row there is.
  readonly property var currentRow: {
    if (cursorIndex >= 0 && cursorIndex < rows.length) return rows[cursorIndex]
    return rows.length === 1 ? rows[0] : null
  }

  // Nothing waiting is the ordinary state of an outbox, and an empty column
  // with a folder name over it reads as a list that failed to load.
  Text {
    width: parent.width
    visible: root.rows.length === 0
    text: "Nothing waiting to go out."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    leftPadding: Style.spacing.md
    topPadding: Style.spacing.md
  }

  Repeater {
    model: root.rows

    delegate: Rectangle {
      id: line
      required property var modelData
      required property int index

      readonly property int rowIndex: index
      readonly property bool cursored: root.cursorIndex === index

      width: parent ? parent.width : 0
      implicitHeight: body.implicitHeight + Style.spacing.md * 2
      radius: Style.space(6)
      color: {
        if (hover.containsMouse || cursored) return Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
        return "transparent"
      }

      Behavior on color { ColorAnimation { duration: 120 } }

      // The mark down the left, in the accent for a message that did not go
      // out. A queue is read at a glance and the one row that wants a person
      // has to be the one that is visible from across the room.
      Rectangle {
        id: rail
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: Style.spacing.xxs
        anchors.bottomMargin: Style.spacing.xxs
        width: Style.space(2)
        radius: width
        color: line.modelData.failed ? root.accent : root.dim
        opacity: line.modelData.failed ? 0.9 : (line.modelData.sending ? 0.6 : 0.3)
      }

      Column {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.md + rail.width + Style.spacing.sm
        anchors.rightMargin: Style.spacing.md
        spacing: Style.spacing.xs

        Text {
          width: parent.width
          text: String(line.modelData.title || "")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: line.modelData.failed
        }

        // Who it is going to, and what is riding with it. As typed - a To
        // field is elided here rather than parsed, see Model.outboxRecipient.
        Text {
          width: parent.width
          visible: text !== ""
          text: {
            var who = String(line.modelData.recipient || "")
            var files = Number(line.modelData.attachments || 0)
            var carrying = files === 1 ? "1 file" : files + " files"
            if (who === "") return files > 0 ? carrying : ""
            return files > 0 ? "to " + who + " · " + carrying : "to " + who
          }
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // The bar, for a send that has said how far along it is. A phase the
        // helper reported is drawn beside it rather than instead of it: "60%"
        // says how long is left and "Attaching report.pdf" says what the wait
        // is for, and neither answers the other's question.
        Item {
          width: parent.width
          visible: line.modelData.sending
          implicitHeight: Math.max(track.height, phase.implicitHeight)

          Rectangle {
            id: track
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: line.modelData.determinate ? Math.round(parent.width * 0.34) : 0
            visible: line.modelData.determinate
            height: Style.space(4)
            radius: height
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14)

            Rectangle {
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Math.max(parent.height,
                              Math.round(parent.width * Number(line.modelData.progress || 0)))
              radius: parent.radius
              color: root.accent
              Behavior on width { NumberAnimation { duration: 180 } }
            }
          }

          // A send that has not reported a phase yet turns instead of
          // advancing. A bar that moves on a timer while nothing is happening
          // is how "nearly done" comes to mean nothing.
          SpinIcon {
            id: turning
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: !line.modelData.determinate
            text: "\u{F0450}"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            color: root.dim
            spinning: visible
          }

          Text {
            id: phase
            anchors.left: line.modelData.determinate ? track.right : turning.right
            anchors.leftMargin: Style.spacing.sm
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: String(line.modelData.status || "")
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // Waiting, or not sent at all and why. The error is the helper's own
        // words: they say what to do about a mailbox that may not send, which
        // "Failed" does not.
        Text {
          width: parent.width
          visible: !line.modelData.sending
          text: line.modelData.failed && String(line.modelData.error || "") !== ""
            ? String(line.modelData.error)
            : String(line.modelData.status || "")
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          maximumLineCount: 3
          elide: Text.ElideRight
          color: line.modelData.failed ? root.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ActionBar {
          width: parent.width
          visible: !line.modelData.sending
          fg: root.fg
          dim: root.dim
          accent: root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.caption

          actions: [
            { text: "Retry", visible: line.modelData.failed === true, danger: true,
              tooltip: "Send it again, from the beginning",
              trigger: function() { root.retryRequested(String(line.modelData.id)) } },

            { text: "Edit",
              tooltip: "Put it back in the compose box, with everything as you left it",
              trigger: function() { root.editRequested(String(line.modelData.id)) } },

            { text: "Discard", muted: true,
              tooltip: "Throw the message away without sending it",
              trigger: function() { root.discardRequested(String(line.modelData.id)) } }
          ]
        }
      }

      MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        // The row itself is not a button - every action on it is one of the
        // three above, and a click that did something else would be a click
        // that sent or discarded somebody's mail by accident. It moves the
        // cursor, so the keys act on what the pointer is over.
        acceptedButtons: Qt.LeftButton
        onClicked: root.cursorIndex = line.rowIndex
      }
    }
  }
}
