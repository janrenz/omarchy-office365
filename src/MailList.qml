import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Merged mail. Each row carries a coloured rail on its leading edge for the
// mailbox it came from, plus that mailbox's short label - colour is never the
// only signal, since themes can ship hues that sit close together.
//
// Two shapes, one list. Flat, every row is a message. Threaded, a conversation
// of more than one message collapses to a summary row that opens to show its
// messages underneath; a conversation of one is drawn as the message itself,
// because a fold with nothing behind it is a lie about there being more.
//
// Backed by a ListModel that is diffed against each new fetch rather than
// rebuilt: a Repeater over a plain array resets wholesale, which makes rows
// blink on every refresh and leaves nothing to animate when one drops out.
Column {
  id: root

  property var mails: []
  // Conversations, in the order they are drawn. Ignored while `threaded` is
  // off, and empty on hosts that never group.
  property var threads: []
  property bool threaded: false
  property bool unreadOnly: false
  property bool showAccount: false
  property bool showPreviewLine: true
  property string selectedId: ""
  // Keyboard cursor. By id where the caller has one, because a threaded list
  // draws more rows than there are messages and an index into the messages
  // stops meaning an index into the rows.
  property string cursorId: ""
  property int cursorIndex: -1
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal activated(var mail)
  signal deleteRequested(var mail)

  spacing: Style.spacing.lg

  // Which conversations are open, by thread key. A plain object rather than a
  // model property: it is written by a click and read by the next sync, and
  // nothing binds to it.
  property var openThreads: ({})

  function toggleThread(key) {
    if (key === "") return
    var next = {}
    for (var k in openThreads) next[k] = openThreads[k]
    if (next[key] === true) delete next[key]
    else next[key] = true
    openThreads = next
    sync()
  }

  function mailById(id) {
    for (var i = 0; i < mails.length; i++) if (String(mails[i].id) === String(id)) return mails[i]
    return null
  }

  function indexOfKey(key) {
    for (var i = 0; i < rows.count; i++) if (rows.get(i).rowKey === key) return i
    return -1
  }

  // Every row carries every field whatever its kind. A ListModel takes its
  // roles from the first row it is given, so a head row that left out the
  // fields only a message has would leave those roles undefined for every
  // message row after it.
  function blankEntry() {
    return {
      rowKey: "",
      kind: "mail",
      mailId: "",
      threadKey: "",
      subject: "",
      sender: "",
      received: "",
      preview: "",
      shortLabel: "",
      railColor: "",
      important: false,
      hasAttachments: false,
      flagged: false,
      read: true,
      canWrite: false,
      canTrash: false,
      threadCount: 0,
      threadUnread: 0,
      expanded: false,
      indented: false
    }
  }

  function entryFor(mail) {
    var entry = blankEntry()
    entry.rowKey = "m:" + String(mail.id)
    entry.kind = "mail"
    entry.mailId = String(mail.id)
    entry.subject = String(mail.subject || "")
    entry.sender = Model.senderName(mail)
    entry.received = String(mail.received || "")
    entry.preview = String(mail.preview || "")
    entry.shortLabel = String(mail.short || "")
    entry.railColor = String(mail.color)
    entry.important = mail.important === true
    entry.hasAttachments = mail.hasAttachments === true
    entry.flagged = mail.flagged === true
    entry.read = mail.read === true
    entry.canWrite = mail.write === true
    entry.canTrash = mail.write === true
    return entry
  }

  function headEntry(group, open) {
    var entry = blankEntry()
    entry.rowKey = "t:" + String(group.key)
    entry.kind = "head"
    entry.threadKey = String(group.key)
    entry.subject = String(group.subject || "")
    entry.sender = String(group.senders || "")
    entry.received = String(group.received || "")
    entry.preview = String(group.preview || "")
    entry.shortLabel = String(group.short || "")
    entry.railColor = String(group.color)
    entry.important = group.important === true
    entry.hasAttachments = group.hasAttachments === true
    entry.flagged = group.flagged === true
    // A conversation counts as read only once all of it is.
    entry.read = group.unread === 0
    entry.canWrite = group.write === true
    // No trash on a summary: the button deletes one message, and the row it
    // would sit on stands for several.
    entry.canTrash = false
    entry.threadCount = group.count
    entry.threadUnread = group.unread
    entry.expanded = open === true
    return entry
  }

  function childEntry(group, mail) {
    var entry = entryFor(mail)
    entry.rowKey = "c:" + String(group.key) + ":" + String(mail.id)
    entry.kind = "child"
    entry.threadKey = String(group.key)
    entry.indented = true
    return entry
  }

  // A conversation opens itself when what is being read or cursored is inside
  // it: the alternative is a cursor on a row nobody can see.
  function holdsWatched(group) {
    for (var i = 0; i < group.mails.length; i++) {
      var id = String(group.mails[i].id)
      if (id !== "" && (id === root.selectedId || id === root.cursorId)) return true
    }
    return false
  }

  function wantedRows() {
    var wanted = []
    if (!threaded) {
      var flat = mails || []
      for (var i = 0; i < flat.length; i++) wanted.push(entryFor(flat[i]))
      return wanted
    }

    var groups = threads || []
    for (var g = 0; g < groups.length; g++) {
      var group = groups[g]
      // One message is a message. Folding it would cost a click to reach
      // something the row could have shown in the first place.
      if (group.count <= 1) {
        wanted.push(entryFor(group.mails[0]))
        continue
      }
      var open = openThreads[group.key] === true || holdsWatched(group)
      wanted.push(headEntry(group, open))
      if (!open) continue
      for (var m = 0; m < group.mails.length; m++) wanted.push(childEntry(group, group.mails[m]))
    }
    return wanted
  }

  // Apply the new list as inserts, moves, removals and in-place edits, so the
  // view can animate what actually changed.
  function sync() {
    var list = wantedRows()
    var wanted = {}
    for (var i = 0; i < list.length; i++) wanted[list[i].rowKey] = true

    for (var r = rows.count - 1; r >= 0; r--)
      if (!wanted[rows.get(r).rowKey]) rows.remove(r)

    for (var j = 0; j < list.length; j++) {
      var entry = list[j]
      var at = indexOfKey(entry.rowKey)
      if (at < 0) {
        rows.insert(j, entry)
        continue
      }
      if (at !== j) rows.move(at, j, 1)
      var current = rows.get(j)
      for (var field in entry)
        if (current[field] !== entry[field]) rows.setProperty(j, field, entry[field])
    }
  }

  onMailsChanged: sync()
  onThreadsChanged: sync()
  onThreadedChanged: sync()
  onSelectedIdChanged: sync()
  onCursorIdChanged: sync()
  Component.onCompleted: sync()

  ListModel { id: rows }

  Text {
    textFormat: Text.PlainText
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
      required property string rowKey
      required property string kind
      required property string mailId
      required property string threadKey
      required property string subject
      required property string sender
      required property string received
      required property string preview
      required property string shortLabel
      required property string railColor
      required property bool important
      required property bool hasAttachments
      required property bool flagged
      required property bool read
      required property bool canWrite
      required property bool canTrash
      required property int threadCount
      required property int threadUnread
      required property bool expanded
      required property bool indented
      required property int index

      readonly property bool isHead: row.kind === "head"

      width: list.width
      implicitHeight: content.implicitHeight + Style.spacing.md * 2
      radius: Style.space(5)
      readonly property bool selected: !row.isHead && root.selectedId !== ""
                                       && root.selectedId === row.mailId
      readonly property bool cursored: root.cursorId !== ""
        ? (!row.isHead && root.cursorId === row.mailId)
        : (root.cursorIndex === row.index)
      // Worked out from the row's own hover position rather than a second
      // MouseArea over the button: a nested one steals the hover from this
      // row, which would hide the button, which would hand the hover back -
      // a flicker loop for as long as the pointer sat there.
      readonly property bool overTrash: row.canTrash && hover.containsMouse
                                        && hover.mouseX >= trashButton.x
      readonly property bool showTrash: row.canTrash
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
        anchors.right: row.canTrash ? trashButton.left : parent.right
        // A message inside a conversation is stepped in, so the summary above
        // it reads as the thing it belongs to.
        anchors.leftMargin: Style.spacing.md + (row.indented ? Style.space(14) : 0)
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs

        Item {
          width: parent.width
          implicitHeight: senderText.implicitHeight

          // The fold. Only a summary has one, and it is the whole row that
          // toggles - a target the width of the list rather than a glyph.
          Text {
            textFormat: Text.PlainText
            id: chevron
            anchors.left: parent.left
            anchors.baseline: senderText.baseline
            visible: row.isHead
            text: row.expanded ? "󰅀" : "󰅂"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            id: senderText
            anchors.left: row.isHead ? chevron.right : parent.left
            anchors.leftMargin: row.isHead ? Style.spacing.sm : 0
            anchors.right: row.flagged ? flagMark.left : meta.left
            anchors.rightMargin: Style.spacing.sm
            text: row.sender
            color: row.important ? root.accent : (row.read ? root.dim : root.fg)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: !row.read
            elide: Text.ElideRight
          }

          // The follow-up flag, in the accent and at the right where Outlook
          // draws it. It keeps its colour when the row goes read, which is the
          // point of it: a flag outlives having been read.
          Text {
            textFormat: Text.PlainText
            id: flagMark
            visible: row.flagged
            anchors.right: meta.left
            anchors.rightMargin: visible ? Style.spacing.sm : 0
            anchors.baseline: senderText.baseline
            text: visible ? "\u{F023B}" : ""
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            id: meta
            anchors.right: parent.right
            anchors.baseline: senderText.baseline
            text: (root.showAccount ? row.shortLabel + "  " : "") + Model.relativeTime(row.received)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // The subject, and on a summary how many messages are behind it. A
        // message inside an open conversation goes without: it is the subject
        // of the row above, repeated once per reply.
        Item {
          width: parent.width
          visible: row.kind !== "child"
          implicitHeight: visible ? subjectText.implicitHeight : 0

          Text {
            textFormat: Text.PlainText
            id: subjectText
            anchors.left: parent.left
            anchors.right: countText.left
            anchors.rightMargin: countText.visible ? Style.spacing.sm : 0
            text: (row.hasAttachments ? "󰏢  " : "") + Model.oneLine(row.subject, 90)
            color: row.read ? root.dim : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          // How many messages, and how much of it is still waiting: the count
          // is tinted only while something in the conversation is unread.
          Text {
            textFormat: Text.PlainText
            id: countText
            anchors.right: parent.right
            anchors.baseline: subjectText.baseline
            visible: row.isHead
            text: String(row.threadCount)
            color: row.threadUnread > 0 ? root.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: row.threadUnread > 0
          }
        }

        // Shown for read and unread alike, and kept even when a message has
        // no preview text, so every row is the same height.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.showPreviewLine && row.kind !== "child"
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
          if (row.isHead) { root.toggleThread(row.threadKey); return }
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
        visible: row.canTrash
        radius: parent.radius
        color: row.overTrash ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                             : "transparent"
        opacity: row.showTrash ? 1.0 : 0.0

        Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
        Behavior on color { ColorAnimation { duration: 120 } }

        Text {
          textFormat: Text.PlainText
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
