import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The window's folder sidebar.
//
// Rows arrive from Model.folderRows already flattened, indented and in draw
// order, so this file only draws them and says which one was clicked. One
// mailbox is a plain tree; several are each tree under a header, and a header
// is never selectable - there is no "all folders of this mailbox" to show.
Column {
  id: root

  // Rows from Model.folderRows(views, selectedFolders).
  property var rows: []
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  // Keyboard cursor over the pickable rows. -1 until a key moves it, so a
  // sidebar opened with the mouse shows no cursor.
  property int cursorIndex: -1

  signal picked(string alias, string folderId)

  spacing: Style.spacing.xxs

  // Indices into `rows` a cursor may land on: folders, never headers.
  readonly property var pickable: {
    var out = []
    for (var i = 0; i < rows.length; i++) if (rows[i].kind === "folder") out.push(i)
    return out
  }

  readonly property int selectedPickable: {
    for (var i = 0; i < pickable.length; i++)
      if (rows[pickable[i]].selected === true) return i
    return -1
  }

  function moveCursor(step) {
    if (pickable.length === 0) return
    // The first move starts from whatever is selected rather than from the top
    // of the tree, so pressing down in a deep folder does not jump to Inbox.
    var from = cursorIndex >= 0 ? cursorIndex : selectedPickable
    var next = from < 0 ? (step > 0 ? 0 : pickable.length - 1) : from + step
    cursorIndex = Math.max(0, Math.min(pickable.length - 1, next))
  }

  // A folder's name from its id. The picked signal carries the id, which is
  // what a caller acts on; the name is what it then has to say about it.
  function nameFor(folderId) {
    var id = String(folderId)
    for (var i = 0; i < rows.length; i++)
      if (rows[i].kind === "folder" && String(rows[i].id) === id) return String(rows[i].name || "")
    return ""
  }

  // The row the cursor is on, for a caller that has to scroll it into view.
  // This tree draws itself at its full height inside somebody else's scroller,
  // so moving the cursor moves nothing by itself - and a window holding two
  // mailboxes has most of its tree below the fold.
  function cursorRow() {
    if (cursorIndex < 0) return null
    for (var i = 0; i < children.length; i++) {
      // The Repeater is a child here too, and a header is never cursored:
      // neither has a pickIndex that can match.
      if (children[i] && children[i].pickIndex === cursorIndex) return children[i]
    }
    return null
  }

  function activateCursor() {
    if (cursorIndex < 0 || cursorIndex >= pickable.length) return
    var row = rows[pickable[cursorIndex]]
    if (row) root.picked(String(row.alias), String(row.id))
  }

  Repeater {
    model: root.rows

    delegate: Rectangle {
      id: line
      required property var modelData
      required property int index

      readonly property bool isHeader: modelData.kind === "account"
      readonly property bool selected: modelData.selected === true
      // Position among the pickable rows, which is what the cursor counts in.
      readonly property int pickIndex: root.pickable.indexOf(index)
      readonly property bool cursored: !isHeader && root.cursorIndex >= 0
                                       && root.cursorIndex === pickIndex

      // How far in the text starts, and how much room is left for it. Kept
      // here, off the row's own width, rather than measured from the Row that
      // holds them: a Row sums its children to get an implicit width, so a
      // child sized from that Row is a cycle - and one Qt only trips over when
      // the tree is laid out a second time, which is what opening the move
      // picker over the window does.
      readonly property real labelIndent: Style.spacing.md + rail.width
                                          + Style.space(10) * modelData.depth
      readonly property real labelWidth: Math.max(0, width - labelIndent - Style.spacing.md)

      width: parent ? parent.width : 0
      implicitHeight: label.implicitHeight + Style.spacing.sm * 2
      radius: Style.space(5)
      color: {
        if (isHeader) return "transparent"
        if (selected) return Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14)
        if (hover.containsMouse || cursored) return Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
        return "transparent"
      }

      Behavior on color { ColorAnimation { duration: 120 } }

      // The mailbox's hue, on the folder rows as well as the header: in a
      // window holding two mailboxes the tree is the only thing saying which
      // one a message list belongs to.
      Rectangle {
        id: rail
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: Style.spacing.xxs
        anchors.bottomMargin: Style.spacing.xxs
        width: Style.space(2)
        radius: width
        // The merged rows at the top belong to no one mailbox and so have no
        // hue. The plain foreground stands in: an empty colour string is black
        // to Qt, which on a dark theme is a rail that is simply missing.
        color: String(line.modelData.color) !== "" ? line.modelData.color : root.dim
        opacity: line.isHeader ? 1 : (line.selected ? 0.9 : 0.35)
        visible: root.rows.length > 0 && (line.isHeader || line.modelData.depth > 0 || line.selected
                                          || String(line.modelData.color) !== "")
      }

      Row {
        id: label
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: line.labelIndent
        anchors.rightMargin: Style.spacing.md
        spacing: Style.spacing.sm

        Text {
          width: Math.max(0, line.labelWidth
                             - (counter.visible ? counter.implicitWidth + label.spacing : 0))
          text: String(line.modelData.name || "")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: line.isHeader ? root.dim : (line.selected ? root.fg : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.85))
          font.family: root.fontFamily
          font.pixelSize: line.isHeader ? Style.font.caption : Style.font.body
          font.bold: line.selected || (!line.isHeader && Number(line.modelData.unread || 0) > 0)
          font.capitalization: line.isHeader ? Font.AllUppercase : Font.MixedCase
        }

        // Unread, not total: a folder's interest is what has not been read in
        // it. Folders with none say nothing rather than drawing a zero.
        Text {
          id: counter
          anchors.verticalCenter: parent.verticalCenter
          visible: !line.isHeader && Number(line.modelData.unread || 0) > 0
          text: Number(line.modelData.unread || 0) > 999 ? "999+" : String(line.modelData.unread || 0)
          textFormat: Text.PlainText
          color: line.selected ? root.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: !line.isHeader
        enabled: !line.isHeader
        cursorShape: line.isHeader ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: {
          root.cursorIndex = line.pickIndex
          root.picked(String(line.modelData.alias), String(line.modelData.id))
        }
      }
    }
  }
}
