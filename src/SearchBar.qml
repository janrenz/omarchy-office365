import QtQuick
import qs.Commons
import qs.Ui

// The field the window searches from, and the line under it saying what came
// back.
//
// Its own row rather than a control in the header, and not for want of space
// alone: the header collapses when the pills outgrow the width beside the
// title - see the Item that measures both rows in MailWindow - and a text
// field is the widest control there is. A row of its own also gives the
// summary somewhere to live, and the summary is the half that makes the field
// honest: "12 of 84" says the query narrowed something, "nothing in the 84
// loaded" says where to press Enter.
//
// It knows nothing about mailboxes. Everything it shows is handed in and
// everything it does is a signal, so the window keeps the one copy of what a
// search means.
Column {
  id: root

  property string query: ""
  property bool running: false
  // Whether the rows below are a search's answer or a folder's.
  property bool showing: false
  // The query those rows answer, which is not always what is in the field:
  // typing on after a search narrows the results, and Enter asks again.
  property string answered: ""
  property bool complete: true
  property string error: ""
  property int matched: 0
  property int total: 0
  // "all" or "folder". The folder's name, for saying which one that is.
  property string scope: "all"
  property string folderName: ""

  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal edited(string text)
  signal submitted()
  signal dismissed()
  signal scopeToggled()

  // Focus arrives from outside: / opens this and puts the cursor in it, and
  // the window has to be able to take it back when Escape closes the row.
  function takeFocus() { field.forceActiveFocus() }
  readonly property bool typing: field.activeFocus

  spacing: Style.spacing.xs

  Row {
    width: parent.width
    spacing: Style.spacing.sm

    TextField {
      id: field
      // Whatever the pills beside it do not need. The summary is short and the
      // scope pill is two words; the field is the part that should grow.
      width: Math.max(Style.space(160), parent.width - controls.width - parent.spacing)
      text: root.query
      placeholderText: root.scope === "folder"
        ? "Search " + (root.folderName !== "" ? root.folderName : "this folder")
        : "Search this mailbox — Enter to ask the server"
      foreground: root.fg
      accent: root.accent
      onTextChanged: if (text !== root.query) root.edited(text)
      onAccepted: root.submitted()
      Keys.onEscapePressed: root.dismissed()
    }

    Row {
      id: controls
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.sm

      // Where Enter will look. A pill rather than a setting: which one is
      // wanted changes per search, and the answer is usually visible in the
      // question - somebody who knew the folder would have gone to it.
      FilterPill {
        label: root.scope === "folder" ? "This folder" : "Whole mailbox"
        selected: root.scope === "folder"
        fg: root.fg
        dim: root.dim
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.scopeToggled()
      }

      // Words, not glyphs. The header opposite has to use pictures because it
      // runs out of width - see the Item that measures it - and this row has
      // width to spare, so it can say what it does instead of asking anybody
      // to recognise a codepoint.
      FilterPill {
        label: "Search"
        faded: root.running || root.query.trim() === ""
        fg: root.fg
        dim: root.dim
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.submitted()
      }

      FilterPill {
        label: "Close"
        fg: root.fg
        dim: root.dim
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.dismissed()
      }
    }
  }

  // What came back, in one line.
  //
  // Counting is the whole point of it. Without the second number a short list
  // is ambiguous in the way that matters: three rows may be three hits in a
  // mailbox of thousands, or all that a query left of the twenty on screen -
  // and only the second is a reason to press Enter.
  Text {
    width: parent.width
    text: {
      if (root.error !== "") return root.error
      if (root.running) return "searching…"
      var typed = root.query.trim() !== ""
      if (root.showing) {
        var where = "for “" + root.answered + "”"
        var found = root.matched === 0
          ? ("Nothing " + where)
          : (root.matched + (root.matched === root.total ? "" : " of " + root.total)
             + (root.matched === 1 ? " message " : " messages ") + where)
        if (!root.complete) found += " — there may be more"
        // The field has moved on from the query the rows answer, so the rows
        // are being narrowed by hand and Enter would go back to the server.
        if (typed && root.query.trim() !== root.answered) found += ". Enter searches again"
        return found
      }
      if (!typed) return ""
      if (root.matched === 0)
        return "Nothing in the " + root.total + " loaded here — Enter searches the mailbox"
      return root.matched + " of " + root.total + " loaded here — Enter searches the mailbox"
    }
    visible: text !== ""
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.error !== "" ? root.accent : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
