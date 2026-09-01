import QtQuick
import qs.Commons
import qs.Ui

// The four things that can be done to a folder, for the pointer.
//
// The same four the keyboard does with n, R, m and x - one definition, used
// both beside the tree in a wide window and under it in the drawer a narrow
// one gets, because a feature that is only in the wide layout is a feature
// half the windows do not have.
//
// It names the folder it would act on. The keyboard cursor and the folder
// being read are not always the same row, and **Delete** is not a button to
// press while guessing which one is meant.
//
// Nothing here is disabled: a pill that cannot act now is faded, and pressing
// it says why on the notice line rather than doing nothing. Read-only is a
// sign-in choice and the inbox is untouchable by every mail server there is -
// both are worth being told once, in words.
Column {
  id: root

  // The row from Model.folderRows these act on, or null when the tree has
  // nothing under its cursor yet.
  property var target: null
  property bool busy: false
  // Whether this mailbox was signed in with permission to change mail.
  property bool writable: false

  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  // `what` is new, rename, move or delete; `topLevel` only means anything to
  // new, and the prompt can still change its mind about it.
  signal act(string what, bool topLevel)

  readonly property string targetName: target ? String(target.name || "") : ""
  // The inbox cannot be renamed, moved or deleted anywhere - not a rule this
  // plugin invented, and one worth showing rather than only saying afterwards.
  readonly property bool canTouch: writable && !!target && target.isInbox !== true

  spacing: Style.spacing.xs

  Text {
    width: parent.width
    visible: root.targetName !== ""
    text: root.targetName
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Flow {
    width: parent.width
    spacing: Style.spacing.xs

    FilterPill {
      label: "New"
      faded: root.busy || !root.writable
      fg: root.fg
      dim: root.dim
      accent: root.accent
      fontFamily: root.fontFamily
      onClicked: root.act("new", false)
    }

    FilterPill {
      label: "Rename"
      faded: root.busy || !root.canTouch
      fg: root.fg
      dim: root.dim
      accent: root.accent
      fontFamily: root.fontFamily
      onClicked: root.act("rename", false)
    }

    FilterPill {
      label: "Move"
      faded: root.busy || !root.canTouch
      fg: root.fg
      dim: root.dim
      accent: root.accent
      fontFamily: root.fontFamily
      onClicked: root.act("move", false)
    }

    FilterPill {
      label: "Delete"
      faded: root.busy || !root.canTouch
      fg: root.fg
      dim: root.dim
      accent: root.accent
      fontFamily: root.fontFamily
      onClicked: root.act("delete", false)
    }
  }
}
