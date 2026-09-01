import QtQuick
import QtCore
import QtQuick.Controls
import QtQuick.Dialogs
import qs.Commons
import qs.Ui

// Writing a reply, a reply to everyone, or a forward.
//
// Two ways out, because they need different permission from Microsoft. Send
// needs Mail.Send, which a mailbox signed in for reading and writing does not
// have. Draft needs only Mail.ReadWrite, so it is always there: Graph builds
// the draft with its quoting and recipients already right, and Outlook is
// where it gets finished. A mailbox that cannot send is offered the draft and
// told why, rather than shown a Send button that would come back 403.
Column {
  id: root

  property string mode: "reply"
  property string subject: ""
  // Recipients. Only a forward needs them; a reply already knows where it goes.
  property bool needsRecipient: false
  property bool canSend: false
  property bool running: false
  property string error: ""
  // Set when a send failed for want of permission, so the way out is offered
  // instead of the error being repeated.
  property bool sendBlocked: false

  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  // Files to go with it, as paths. The host owns the list; this draws it and
  // says what was asked for.
  property var attachments: []

  signal attachRequested(string path)
  signal detachRequested(int index)
  signal sendRequested()
  signal draftRequested()
  signal cancelRequested()
  signal permissionRequested()
  signal toEdited(string value)
  signal bodyEdited(string value)

  spacing: Style.spacing.sm

  readonly property string title: {
    if (mode === "forward") return "Forward"
    if (mode === "reply-all") return "Reply to everyone"
    return "Reply"
  }

  function focusBody() { body.forceActiveFocus() }

  // Text this box should open holding - a draft a coding agent wrote. Applied
  // once, on completion, rather than bound: the binding belongs to what the
  // person types the moment they type it.
  property string initialBody: ""

  // The same thing for a draft that arrives while this box is already open.
  // Both paths exist because the reply box is built by a Loader the instant
  // `composing` turns true, and whether that happens before or after the draft
  // is set is not something to depend on - see MailWindow's fillCompose.
  function setBody(text) { body.text = String(text || "") }

  // The window's key catcher stands down while a reply is open - it claims
  // bare letters to move a cursor, and would eat them out of the text. So the
  // keys that get out of a reply have to be here: without them Escape does
  // nothing and the only way out of a half-written reply is the mouse.
  //
  // Enter is a newline. Shift+Enter and Ctrl+Enter post it - as Send where the
  // mailbox may send, and as the draft it would otherwise have to be.
  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      root.cancelRequested()
      event.accepted = true
      return
    }
    if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return
    if (!(event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier))) return
    event.accepted = true
    if (root.running) return
    if (root.canSend) root.sendRequested()
    else root.draftRequested()
  }

  // Escape typed in the recipients field, which the body's own handler below
  // never sees.
  Keys.onPressed: function(event) { root.handleKey(event) }

  Text {
    width: parent.width
    text: root.subject === "" ? root.title : (root.title + " · " + root.subject)
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.bold: true
  }

  TextField {
    id: toField
    width: parent.width
    visible: root.needsRecipient
    placeholderText: "To — comma separated"
    foreground: root.fg
    accent: root.accent
    onTextChanged: root.toEdited(text)
  }

  Rectangle {
    width: parent.width
    height: Style.space(120)
    radius: Style.space(5)
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
    border.width: Style.space(1)
    border.color: body.activeFocus ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.7)
                                   : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.15)

    ScrollView {
      anchors.fill: parent
      anchors.margins: Style.spacing.sm
      clip: true

      TextArea {
        id: body
        placeholderText: "Your message — the original is quoted underneath by Outlook"
        wrapMode: TextArea.Wrap
        color: root.fg
        placeholderTextColor: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        background: null
        onTextChanged: root.bodyEdited(text)
        // Before the TextArea itself, which would otherwise swallow Return as
        // a newline before anything here could look at the modifiers.
        Keys.onPressed: function(event) { root.handleKey(event) }
      }
    }
  }

  Text {
    width: parent.width
    visible: root.error !== ""
    text: root.error
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // What is attached, and a way to take one off again. Only there when there
  // is something: an empty row of nothing is worse than no row.
  Flow {
    width: parent.width
    visible: root.attachments.length > 0
    spacing: Style.spacing.sm

    Repeater {
      model: root.attachments

      Rectangle {
        id: chip
        required property string modelData
        required property int index
        // The name, not the path: where it came from is not what anybody needs
        // to read back, and a long path pushes the rest off the row.
        readonly property string fileName: String(chip.modelData).split("/").pop()

        radius: Style.space(4)
        color: Util.alpha(root.accent, 0.12)
        implicitWidth: chipRow.implicitWidth + Style.spacing.md
        implicitHeight: chipRow.implicitHeight + Style.spacing.sm

        Row {
          id: chipRow
          anchors.centerIn: parent
          spacing: Style.spacing.xs

          // The same glyph the list draws on a message that has one.
          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "󰏢"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.accent
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: chip.fileName
            textFormat: Text.PlainText
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "✕"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption

            MouseArea {
              anchors.fill: parent
              // Bigger than the glyph: a 6-pixel target is a target nobody
              // hits on the first try.
              anchors.margins: -Style.spacing.xs
              cursorShape: Qt.PointingHandCursor
              onClicked: root.detachRequested(chip.index)
            }
          }
        }
      }
    }
  }

  FileDialog {
    id: attachDialog
    title: "Attach a file"
    fileMode: FileDialog.OpenFile
    currentFolder: StandardPaths.writableLocation(StandardPaths.DocumentsLocation)
    onAccepted: root.attachRequested(
      decodeURIComponent(String(selectedFile).replace(/^file:\/\//, "")))
  }

  Row {
    spacing: Style.spacing.sm

    Button {
      enabled: !root.running
      text: "Attach"
      tooltipText: "A file to send with this - up to 3 MB in total, which is what one request to Outlook can carry"
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: attachDialog.open()
    }

    Button {
      visible: root.canSend
      enabled: !root.running
      text: root.running ? "Sending…" : "Send"
      bordered: true
      foreground: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.sendRequested()
    }

    Button {
      enabled: !root.running
      text: "Save as draft"
      tooltipText: "Builds it in Outlook and opens it there"
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.draftRequested()
    }

    Button {
      visible: !root.canSend || root.sendBlocked
      text: "Allow sending…"
      tooltipText: "Sign in again to let this widget send mail"
      bordered: true
      foreground: root.dim
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.permissionRequested()
    }

    Button {
      enabled: !root.running
      text: "Cancel"
      bordered: true
      foreground: root.dim
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.cancelRequested()
    }
  }
}
