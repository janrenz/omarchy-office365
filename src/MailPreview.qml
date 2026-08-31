import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Reading pane for one message, in the column the agenda usually occupies.
// Deliberately plain: who it is from, who it went to, when, and the text.
// Anything richer is what Open is for.
Column {
  id: root

  property var mail: null
  property var detail: null
  property bool loading: false
  property string error: ""
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real maxBodyHeight: Style.space(360)

  property bool canWrite: false
  property bool canCompose: false
  property bool actionRunning: false
  property string actionError: ""

  signal openRequested()
  signal closeRequested()
  signal markRequested(bool read)
  signal deleteRequested()
  signal writeAccessRequested()
  // Answering a message. Offered only where there is somewhere to type: the
  // window sets canCompose, the bar dropdown leaves it off, since a popup that
  // closes the moment you click away is no place to write a reply.
  signal linkActivated(string url)
  signal replyRequested()
  signal replyAllRequested()
  signal forwardRequested()

  readonly property string subject: detail && detail.subject ? detail.subject
                                    : (mail && mail.subject ? mail.subject : "")

  function people(list) {
    var names = []
    for (var i = 0; i < (list || []).length; i++) {
      var person = list[i]
      names.push(String(person.name || person.address || "").trim())
    }
    return names.join(", ")
  }

  function when(value) {
    var date = Model.parseDate(value)
    return date ? Qt.formatDateTime(date, "ddd d MMM  HH:mm") : ""
  }

  spacing: Style.spacing.lg

  // ---- subject + close ----
  Item {
    width: parent.width
    implicitHeight: Math.max(subjectText.implicitHeight, closeButton.implicitHeight)

    SelectableText {
      id: subjectText
      anchors.left: parent.left
      anchors.right: closeButton.left
      anchors.rightMargin: Style.spacing.sm
      anchors.top: parent.top
      text: root.subject
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      // A TextEdit has no maximumLineCount, so an absurd subject is bounded by
      // height instead of by line count. Three lines' worth, then clipped.
      height: Math.min(implicitHeight, Style.font.body * 4.5)
      clip: true
    }

    PanelActionButton {
      id: closeButton
      anchors.right: parent.right
      anchors.top: parent.top
      iconText: "󰅖"
      tooltipText: "Back to the agenda"
      foreground: root.dim
      onClicked: root.closeRequested()
    }
  }

  // ---- who and when ----
  Column {
    width: parent.width
    spacing: Style.spacing.xxs

    SelectableText {
      width: parent.width
      singleLine: true
      text: {
        if (!root.detail) return root.mail ? Model.senderName(root.mail) : ""
        var name = String(root.detail.from || "").trim()
        var address = String(root.detail.fromAddress || "").trim()
        if (name !== "" && address !== "" && name !== address) return name + "  <" + address + ">"
        return name !== "" ? name : address
      }
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    SelectableText {
      width: parent.width
      singleLine: true
      visible: text !== ""
      text: root.detail ? "To  " + root.people(root.detail.to) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    SelectableText {
      width: parent.width
      singleLine: true
      visible: text !== ""
      text: root.detail && root.detail.cc && root.detail.cc.length > 0
            ? "Cc  " + root.people(root.detail.cc) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    SelectableText {
      width: parent.width
      singleLine: true
      text: root.when(root.detail ? root.detail.received : (root.mail ? root.mail.received : ""))
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  PanelSeparator { width: parent.width }

  // ---- body ----
  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: root.loading
    text: "Opening…"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: root.error !== ""
    text: root.error
    color: root.accent
    wrapMode: Text.WordWrap
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // Scrolls inside the pane rather than growing it: a long mail must not
  // stretch the popup past the screen.
  Flickable {
    width: parent.width
    visible: !root.loading && root.error === "" && !!root.detail
    height: Math.min(bodyText.implicitHeight, root.maxBodyHeight)
    contentHeight: bodyText.implicitHeight
    contentWidth: width
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    SelectableText {
      id: bodyText
      width: parent.width
      text: root.detail ? String(root.detail.body || "").trim() : ""
      color: root.fg
      // No linkColor: that is a Text property and this is a TextEdit, which
      // takes link colour from the markup. Links stay clickable either way.
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      // The message says which it is, not the setting: a plain-text message in
      // an HTML-enabled widget is still plain text, and rendering it as markup
      // would eat any < it happens to contain. AutoText is never the answer -
      // letting the content decide is what this is guarding against.
      textFormat: root.detail && root.detail.bodyFormat === "html" ? TextEdit.RichText : TextEdit.PlainText
      // Rich text makes links clickable. They open where every other link in
      // this plugin opens rather than in whatever Qt would do with them.
      onLinkActivated: function(url) { root.linkActivated(url) }

      // A link under the pointer should look like one.
      HoverHandler {
        enabled: bodyText.hoveredLink !== ""
        cursorShape: Qt.PointingHandCursor
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: !!root.detail && root.detail.truncated === true
    text: "Message continues - open it to read the rest."
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: root.actionError !== ""
    text: root.actionError
    color: root.accent
    wrapMode: Text.WordWrap
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Row {
    spacing: Style.spacing.sm

    Button {
      text: "Open"
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.openRequested()
    }

    // Writing needs the same Mail.ReadWrite that marking does - even a draft
    // is a write - so these keep company with the buttons above rather than
    // appearing on a read-only mailbox and failing.
    Button {
      visible: root.canCompose && root.canWrite
      enabled: !root.actionRunning
      text: "Reply"
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.replyRequested()
    }

    Button {
      visible: root.canCompose && root.canWrite
      enabled: !root.actionRunning
      text: "Reply all"
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.replyAllRequested()
    }

    Button {
      visible: root.canCompose && root.canWrite
      enabled: !root.actionRunning
      text: "Forward"
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.forwardRequested()
    }

    // Changing mail needs permission this plugin does not ask for by
    // default, so these appear only once a mailbox has granted it.
    Button {
      visible: root.canWrite
      text: root.mail && root.mail.read ? "Mark unread" : "Mark read"
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.markRequested(!(root.mail && root.mail.read))
    }

    Button {
      visible: root.canWrite
      enabled: !root.actionRunning
      text: "Delete"

      tooltipText: "Moves it to Deleted Items"
      bordered: true
      foreground: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.deleteRequested()
    }

    Button {
      visible: !root.canWrite
      text: "Allow changes…"
      tooltipText: "Sign in again to let this widget mark and delete mail"
      bordered: true
      foreground: root.dim
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.writeAccessRequested()
    }
  }
}
