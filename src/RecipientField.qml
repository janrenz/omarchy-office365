import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A To or Cc field that completes as you type.
//
// The book it completes from is harvested from mail already fetched - see
// Store.qml's rememberAddresses for why it is not a contacts API - and only the
// entry being typed is completed, because the field holds a list. Accepting a
// suggestion writes the `Name <address>` form: it is what the person reading
// the field back recognises, and graph.py parses it apart again.
//
// The suggestions are a column under the field rather than a floating popup.
// The reply box lives inside a ScrollView inside a window; a popup would have
// to escape whatever is clipping it and would have to be dismissed, while more
// column is just more column. The same reasoning as ActionBar's overflow.
Column {
  id: root

  property string placeholder: ""
  // {lowercased address: {address, name, count, at}} - see Store.qml.
  property var book: ({})
  property int maxSuggestions: 6

  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal edited(string value)
  // Raised for a key this field has no use for, so the box around it can still
  // act on Escape and on Shift+Enter. Everything the suggestion list needs is
  // taken first; everything else is passed on untouched.
  signal unhandledKey(var event)

  readonly property alias text: field.text
  readonly property bool listOpen: matches.length > 0 && field.activeFocus && !dismissed

  // What is being typed, and what it matches. Recomputed from the text rather
  // than kept in step by hand: the field is edited by typing, by accepting a
  // suggestion and by paste, and only one of those is easy to remember.
  readonly property var split: Model.lastAddressFragment(field.text)
  readonly property var matches: Model.matchAddresses(root.book, split.fragment, maxSuggestions)

  // Set when the list has been dismissed for what is currently typed, so
  // Escape can close it without also closing the reply box - and cleared by
  // the next keystroke, which is a new question.
  property bool dismissed: false
  property int cursor: 0

  function focusField() { field.forceActiveFocus() }

  function accept(entry) {
    if (!entry) return
    var formatted = Model.formatRecipient(entry)
    if (formatted === "") return
    // The separator goes in too: the next address is the likely next thing to
    // be typed, and a field that needs a comma typed after every completion is
    // a field that produces one long unparseable entry.
    var head = String(root.split.head)
    field.text = (head === "" ? "" : head + " ") + formatted + ", "
    field.cursorPosition = field.text.length
    dismissed = true
    cursor = 0
  }

  spacing: Style.spacing.xs

  TextField {
    id: field
    width: parent.width
    placeholderText: root.placeholder
    foreground: root.fg
    accent: root.accent
    onTextChanged: {
      root.edited(text)
      root.cursor = 0
    }

    // Before the field itself: the arrow keys move a text cursor and Return
    // would be swallowed, so the list has to be asked first. Only ever while
    // it is open, which is what keeps a field with nothing to suggest behaving
    // exactly like the plain one it used to be.
    Keys.onPressed: function(event) {
      if (root.listOpen) {
        if (event.key === Qt.Key_Down) {
          root.cursor = (root.cursor + 1) % root.matches.length
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Up) {
          root.cursor = (root.cursor - 1 + root.matches.length) % root.matches.length
          event.accepted = true
          return
        }
        // Tab completes as well as Enter. Tab is what a shell has taught
        // everybody to press, and there is nowhere useful for focus to go from
        // a half-typed address anyway.
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Tab) {
          // Not a plain Enter when a modifier is down: that is the box's
          // "send", and somebody holding Shift means to post the message.
          if ((event.key !== Qt.Key_Tab)
              && (event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier))) {
            root.unhandledKey(event)
            return
          }
          root.accept(root.matches[root.cursor])
          event.accepted = true
          return
        }
        // The first Escape closes the list, and the box's own handler never
        // sees it - so a second one still backs out of the message.
        if (event.key === Qt.Key_Escape) {
          root.dismissed = true
          event.accepted = true
          return
        }
      } else if (event.key === Qt.Key_Down && root.matches.length > 0) {
        // Reopening a list that was dismissed, without retyping.
        root.dismissed = false
        root.cursor = 0
        event.accepted = true
        return
      }
      root.unhandledKey(event)
    }

    // Any edit is a new question, so a dismissed list comes back. Keyed off the
    // fragment rather than the whole text: adding a second address should not
    // reopen the list for the first one.
    readonly property string fragment: root.split.fragment
    onFragmentChanged: root.dismissed = false
  }

  Repeater {
    model: root.listOpen ? root.matches : []

    Rectangle {
      id: row
      required property var modelData
      required property int index

      width: root.width
      implicitHeight: line.implicitHeight + Style.spacing.sm
      height: implicitHeight
      radius: Style.space(4)
      color: root.cursor === row.index
        ? Util.alpha(root.accent, 0.16)
        : (hover.containsMouse ? Util.alpha(root.fg, 0.07) : "transparent")

      Row {
        id: line
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.spacing.sm
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.sm

        Text {
          anchors.verticalCenter: parent.verticalCenter
          // The name where there is one, since that is what somebody is
          // looking for, and the address alone where there is not.
          text: String(row.modelData.name || row.modelData.address)
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          width: Math.min(implicitWidth, line.width * 0.5)
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          // ...and the address beside it, always: two people with one name is
          // exactly when a suggestion list has to be checked before it is
          // trusted.
          visible: String(row.modelData.name || "") !== ""
          text: String(row.modelData.address)
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          width: Math.max(0, line.width - x)
        }
      }

      MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: root.cursor = row.index
        onClicked: {
          root.accept(row.modelData)
          // The field keeps focus, so the next address can be typed straight
          // away rather than after clicking back into it.
          field.forceActiveFocus()
        }
      }
    }
  }
}
