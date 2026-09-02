import QtQuick
import qs.Commons
import qs.Ui

// What the keyboard does, on the keyboard.
//
// Omarchy is keyboard-first, and a shortcut nobody can find is a shortcut
// nobody has. ? brings this up from anywhere in the window.
//
// The same component and the same ladder as the Teams plugin's, so what is
// learned in one window works in the other.
Column {
  id: root

  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property string fontFamily: Style.font.family
  // The a key is only there when the handover setting is on, so the list must
  // not promise it either.
  property bool agentHandover: true
  // And f only where there is a Focused/Other split to filter on, which an
  // IMAP mailbox does not have.
  property bool canFocus: true

  // [key, what it does, which section]
  readonly property var bindings: [
    ["j / k", "Down and up, in whatever has focus", "Moving"],
    ["Enter", "Open the message, and follow it in", "Moving"],
    ["h", "Back a step: message to list, list to folders", "Moving"],
    ["l", "In a step: folders to list, list to message", "Moving"],
    ["Tab", "Between the folders and the list", "Moving"],
    ["Esc", "Back one step: reply, folders, message, list, window", "Moving"],

    ["Page up / down", "A screenful of whatever has focus", "Scrolling"],
    ["Ctrl-d / Ctrl-u", "Half a screen", "Scrolling"],
    ["Ctrl-f / Ctrl-b", "A screen", "Scrolling"],
    ["g / G", "To the top / to the bottom", "Scrolling"],

    ["c", "Write a new message from this mailbox", "Doing"],
    ["x", "Delete the message under the cursor", "Doing"],
    ["m", "Move it to another folder", "Doing"],
    ["a", "Hand this message to your coding agent", "Doing"],
    ["F", "Flag it for follow-up, or clear the flag", "Doing"],
    ["u", "Show only unread mail", "Doing"],
    ["f", "Show only Focused mail", "Doing"],
    ["t", "Group the list by conversation", "Doing"],
    ["r", "Refresh", "Doing"],
    ["?", "This list", "Doing"],

    // In the folder tree the same letters are about folders. Listed as their
    // own section rather than mixed in, because which one a key means depends
    // on where the cursor is.
    ["n / N", "New folder, inside this one / at the top level", "Folders"],
    ["R", "Rename the folder under the cursor", "Folders"],
    ["m", "Put it under another folder, or back at the top", "Folders"],
    ["x", "Delete it, and the mail in it", "Folders"]
  ]

  spacing: Style.spacing.md

  Text {
    text: "Keyboard"
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.subtitle
    font.bold: true
  }

  Repeater {
    model: ["Moving", "Scrolling", "Doing", "Folders"]

    delegate: Column {
      required property string modelData
      spacing: Style.spacing.xs

      PanelSectionHeader { width: Style.space(420); text: parent.modelData }

      Repeater {
        model: root.bindings.filter(function(row) {
          return row[2] === modelData
                 && (root.agentHandover || row[0] !== "a")
                 && (root.canFocus || row[0] !== "f")
        })

        delegate: Row {
          required property var modelData
          spacing: Style.spacing.md

          Text {
            width: Style.space(120)
            text: modelData[0]
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignRight
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            text: modelData[1]
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  Text {
    text: "Esc closes this"
    textFormat: Text.PlainText
    color: Qt.darker(root.fg, 1.8)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
