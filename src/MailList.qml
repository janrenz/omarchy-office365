import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Merged mail. Each row carries a coloured rail on its leading edge for the
// mailbox it came from, plus that mailbox's short label - colour is never the
// only signal, since themes can ship hues that sit close together.
//
// Backed by a ListModel that is diffed against each new fetch rather than
// rebuilt: a Repeater over a plain array resets wholesale, which makes rows
// blink on every refresh and leaves nothing to animate when one drops out.
Column {
  id: root

  property var mails: []
  property bool unreadOnly: false
  property bool showAccount: false
  property bool showPreviewLine: true
  property string selectedId: ""
  // Keyboard cursor, independent of what is open in the pane.
  property int cursorIndex: -1
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal activated(var mail)
  signal deleteRequested(var mail)

  spacing: Style.spacing.lg

  function mailById(id) {
    for (var i = 0; i < mails.length; i++) if (String(mails[i].id) === String(id)) return mails[i]
    return null
  }

  function indexOfId(id) {
    for (var i = 0; i < rows.count; i++) if (rows.get(i).mailId === id) return i
    return -1
  }

  function entryFor(mail) {
    return {
      mailId: String(mail.id),
      subject: String(mail.subject || ""),
      sender: Model.senderName(mail),
      received: String(mail.received || ""),
      preview: String(mail.preview || ""),
      shortLabel: String(mail.short || ""),
      railColor: String(mail.color),
      important: mail.important === true,
      hasAttachments: mail.hasAttachments === true,
      read: mail.read === true,
      canWrite: mail.write === true
    }
  }

  // Apply the new list as inserts, moves, removals and in-place edits, so the
  // view can animate what actually changed.
  function sync() {
    var list = mails || []
    var wanted = {}
    for (var i = 0; i < list.length; i++) wanted[String(list[i].id)] = true

    for (var r = rows.count - 1; r >= 0; r--)
      if (!wanted[rows.get(r).mailId]) rows.remove(r)

    for (var j = 0; j < list.length; j++) {
      var entry = entryFor(list[j])
      var at = indexOfId(entry.mailId)
      if (at < 0) {
        rows.insert(j, entry)
        continue
      }
      if (at !== j) rows.move(at, j, 1)
      var current = rows.get(j)
      if (current.read !== entry.read) rows.setProperty(j, "read", entry.read)
      if (current.canWrite !== entry.canWrite) rows.setProperty(j, "canWrite", entry.canWrite)
      if (current.subject !== entry.subject) rows.setProperty(j, "subject", entry.subject)
      if (current.railColor !== entry.railColor) rows.setProperty(j, "railColor", entry.railColor)
      if (current.shortLabel !== entry.shortLabel) rows.setProperty(j, "shortLabel", entry.shortLabel)
    }
  }

  onMailsChanged: sync()
  Component.onCompleted: sync()

  ListModel { id: rows }

  Text {
    visible: rows.count === 0
    text: root.unreadOnly ? "No unread mail" : "No mail"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  ListView {
    id: list
    width: parent.width
    height: contentHeight
    model: rows
    interactive: false
    spacing: Style.spacing.sm
    clip: true

    // The list's own height changes the moment a row goes; easing it keeps the
    // popup from snapping while the row is still fading.
    Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutQuad } }

    add: Transition {
      NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 160; easing.type: Easing.OutQuad }
    }

    // A message that has just been read slides out towards the pane that is
    // showing it, rather than blinking out of existence.
    remove: Transition {
      ParallelAnimation {
        NumberAnimation { property: "opacity"; to: 0; duration: 180; easing.type: Easing.InQuad }
        NumberAnimation { property: "x"; to: list.width * 0.25; duration: 180; easing.type: Easing.InQuad }
      }
    }

    displaced: Transition {
      NumberAnimation { properties: "x,y"; duration: 180; easing.type: Easing.OutQuad }
    }

    delegate: Rectangle {
      id: row
      // Taken as plain properties rather than read live from the model: during
      // a remove transition the delegate outlives its model row, and anything
      // still reading through the model would go undefined mid-animation.
      required property string mailId
      required property string subject
      required property string sender
      required property string received
      required property string preview
      required property string shortLabel
      required property string railColor
      required property bool important
      required property bool hasAttachments
      required property bool read
      required property bool canWrite
      required property int index

      width: list.width
      implicitHeight: content.implicitHeight + Style.spacing.md * 2
      radius: Style.space(5)
      readonly property bool selected: root.selectedId !== "" && root.selectedId === row.mailId
      readonly property bool cursored: root.cursorIndex === row.index
      // Worked out from the row's own hover position rather than a second
      // MouseArea over the button: a nested one steals the hover from this
      // row, which would hide the button, which would hand the hover back -
      // a flicker loop for as long as the pointer sat there.
      readonly property bool overTrash: row.canWrite && hover.containsMouse
                                        && hover.mouseX >= trashButton.x
      readonly property bool showTrash: row.canWrite
                                        && (hover.containsMouse || row.selected || row.cursored)
      color: selected ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14)
                      : ((hover.containsMouse || cursored) ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08) : "transparent")

      Behavior on color { ColorAnimation { duration: 120 } }

      Rectangle {
        id: rail
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: Style.spacing.xxs
        anchors.bottomMargin: Style.spacing.xxs
        width: Style.space(2)
        radius: width
        color: row.railColor
        // Hue says which mailbox; strength says whether it still wants you.
        // Weight and colour on the text carry the same distinction, so the
        // faded rail is reinforcement rather than the only signal.
        opacity: row.read ? 0.35 : 1.0

        Behavior on opacity { NumberAnimation { duration: 160 } }
      }

      Column {
        id: content
        anchors.left: rail.right
        // Anchored to the button, which is zero-wide until it is wanted, so
        // the timestamp slides aside to make room rather than the row keeping
        // a permanent gap.
        anchors.right: row.canWrite ? trashButton.left : parent.right
        anchors.leftMargin: Style.spacing.md
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs

        Item {
          width: parent.width
          implicitHeight: senderText.implicitHeight

          Text {
            id: senderText
            anchors.left: parent.left
            anchors.right: meta.left
            anchors.rightMargin: Style.spacing.sm
            text: row.sender
            color: row.important ? root.accent : (row.read ? root.dim : root.fg)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: !row.read
            elide: Text.ElideRight
          }

          Text {
            id: meta
            anchors.right: parent.right
            anchors.baseline: senderText.baseline
            text: (root.showAccount ? row.shortLabel + "  " : "") + Model.relativeTime(row.received)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          text: (row.hasAttachments ? "󰏢  " : "") + Model.oneLine(row.subject, 90)
          color: row.read ? root.dim : root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        // Shown for read and unread alike, and kept even when a message has
        // no preview text, so every row is the same height.
        Text {
          width: parent.width
          visible: root.showPreviewLine
          text: {
            var line = Model.oneLine(row.preview, 90)
            return line !== "" ? line : " "
          }
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
        onClicked: {
          var mail = root.mailById(row.mailId)
          if (!mail) return
          if (row.overTrash) root.deleteRequested(mail)
          else root.activated(mail)
        }
      }

      // Delete without opening the message first. Spans the row so it is a
      // large target, and appears only on the row being pointed at, keyboard-
      // cursored or read - a trash can on every row is noise.
      Rectangle {
        id: trashButton
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        // Zero-wide when not wanted: it takes no room until it is shown, and
        // widening pushes the row's text aside instead of overlapping it.
        // Safe to drive from hover now that the row has the only MouseArea.
        width: row.showTrash ? Style.space(30) : 0
        visible: row.canWrite
        radius: parent.radius
        color: row.overTrash ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                             : "transparent"
        opacity: row.showTrash ? 1.0 : 0.0

        Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
        Behavior on color { ColorAnimation { duration: 120 } }

        Text {
          anchors.centerIn: parent
          text: "󰩹"
          color: row.overTrash ? root.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}
