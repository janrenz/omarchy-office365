import QtQuick
import QtQuick.Controls
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

  Row {
    spacing: Style.spacing.sm

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
