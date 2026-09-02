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
  // Links in the body. Its own property rather than `accent` read directly, so
  // a host that wants its links to sit differently against its ground can say
  // so without moving every other accented thing in the pane with it.
  property color linkColor: Color.accent
  // What the body is drawn on, which is what decides whether a colour the
  // sender chose can be read here at all - see Model.legibleBody. The theme's
  // own background, because that is what is behind this pane in both hosts.
  property color bg: Color.background
  property string fontFamily: Style.font.family
  property real maxBodyHeight: Style.space(360)

  property bool canWrite: false
  property bool canCompose: false
  property bool canMove: false
  // Whether this surface can carry the action out itself, or is handing the
  // message to the window to do it.
  //
  // The bar dropdown offers the same actions the window does - a pane that
  // silently has five fewer buttons than the same pane elsewhere is the sort
  // of difference nobody can explain - but it cannot perform them: it closes
  // the moment you click away, which is no place to write a reply or hold a
  // folder tree open. So there it summons the window with the action already
  // chosen, and says so in the tooltips rather than looking like it changed
  // its mind about what a button does.
  property bool actsHere: true
  // Whether to offer the coding-agent handover. Only the window sets this: the
  // bar dropdown has no reply box for a draft to come back into.
  property bool canAgent: false
  property bool actionRunning: false
  property string actionError: ""

  // What the message is carrying: [{name, size, contentType, key}], as the
  // helper listed it. `attachmentsPartial` is whether that list is all of
  // them - over IMAP the pane reads two megabytes of a message, and a file
  // further in than that is missing from the list rather than merely
  // unopenable. `attachmentBusy` is the key of the one being fetched.
  property var attachments: []
  property bool attachmentsPartial: false
  property string attachmentBusy: ""
  property string attachmentNotice: ""
  property string attachmentError: ""

  // One file, asked for by key. What the host does with it - save it, open it
  // - is the host's business; this only says which one was clicked.
  signal attachmentRequested(string key)

  signal openRequested()
  signal closeRequested()
  signal markRequested(bool read)
  signal flagRequested(bool flagged)
  signal deleteRequested()
  // Filing it in another folder. Offered only where there is room to pick one:
  // the window sets canMove, the bar dropdown leaves it off, the same way it
  // leaves composing off.
  signal moveRequested()
  signal writeAccessRequested()
  // Go and get the pictures this message points at elsewhere. Only raised by
  // the button below, and only for the message being read.
  signal loadImagesRequested()
  // The reader's decision about this message's own markup. The first two are
  // for this message alone; the last two write a rule about its sender.
  signal showHtmlRequested()
  signal showTextRequested()
  signal allowHtmlSenderRequested()
  signal stopHtmlSenderRequested()
  // Answering a message. Offered only where there is somewhere to type: the
  // window sets canCompose, the bar dropdown leaves it off, since a popup that
  // closes the moment you click away is no place to write a reply.
  signal linkActivated(string url)
  signal replyRequested()
  signal replyAllRequested()
  signal forwardRequested()
  signal agentRequested()

  readonly property string subject: detail && detail.subject ? detail.subject
                                    : (mail && mail.subject ? mail.subject : "")

  // How many pictures were left out because fetching them would have told the
  // sender the message was open. Zero on a plain-text body, and zero once they
  // have been fetched, which is what takes the button away again.
  readonly property int blockedImages: detail && detail.blockedImages
                                       ? Number(detail.blockedImages) : 0

  // ---- the message's own markup, which is off until it is asked for -------
  //
  // Set by the host from the service. `htmlAlways` is the widget setting that
  // takes the decision away entirely, `senderHtml` says this sender already
  // has a standing rule, and the other three describe what is on screen now.
  property bool htmlAlways: false
  property bool senderHtml: false
  property bool htmlShown: false
  property bool htmlAvailable: false
  // Markup that nobody asked for, shown because the message carried no
  // plain-text part. Worth saying out loud: it is the one case where the pane
  // renders a sender's layout without being told to.
  property bool htmlAuto: false
  // Only where the reader still has a decision to make. With the setting on,
  // every message is already formatted and there is nothing to offer.
  readonly property bool htmlOffered: !htmlAlways && !!detail

  // A tooltip that says where the action is going to happen. Saying it in the
  // tooltip rather than in the label keeps the two panes' buttons named the
  // same thing, which is the point of them being the same buttons.
  function elsewhere(text) {
    return root.actsHere ? text : (text + " — opens the window on it")
  }

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

  // ---- what the message is carrying ----
  //
  // Under the headers, above the message. The paperclip on the list row used
  // to be the only sign an attachment existed at all: the pane never showed
  // one, nothing fetched one, and the file could not be reached from here by
  // any route. First thing somebody wants on opening such a message is the
  // file, so it goes where they are already looking.
  //
  // A click saves it and opens it, which is the one action a click on an
  // attachment means everywhere else. A save that only saves leaves the
  // reader hunting for what they just saved.
  Column {
    width: parent.width
    spacing: Style.spacing.xxs
    visible: root.attachments.length > 0 || root.attachmentsPartial
             || root.attachmentNotice !== "" || root.attachmentError !== ""

    Flow {
      width: parent.width
      spacing: Style.spacing.sm

      Repeater {
        model: root.attachments

        FilterPill {
          required property var modelData

          label: String(modelData.name || "file")
          detail: Model.fileSize(modelData.size)
          // Bounded, because this label is the one string in the pane that
          // whoever sent the message chose the length of.
          maxLabelWidth: Math.max(Style.space(80), root.width - Style.space(140))
          selected: root.attachmentBusy === String(modelData.key)
          // While one is being fetched the others are not what is happening.
          faded: root.attachmentBusy !== "" && root.attachmentBusy !== String(modelData.key)
          fg: root.fg
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.attachmentRequested(String(modelData.key))
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: text !== ""
      wrapMode: Text.WordWrap
      text: {
        if (root.attachmentError !== "") return root.attachmentError
        if (root.attachmentNotice !== "") return root.attachmentNotice
        if (root.attachmentsPartial)
          return root.attachments.length > 0
            ? "This message is longer than the pane reads, so it may carry more than these."
            : "This message carries files, further into it than the pane reads."
        return ""
      }
      color: root.attachmentError !== "" ? root.accent : root.dim
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

  // The message, with the address of whatever link is under the pointer drawn
  // across the foot of it. This wrapper is what keeps the two apart: the
  // address appears and disappears with the pointer, and anything that changed
  // size when it did would walk the buttons below up and down the pane.
  Item {
    width: parent.width
    // The condition belongs here, on the wrapper, and must not be read off the
    // Flickable inside it. An item's `visible` is ANDed with its parent's, so
    // a parent reading its child's visibility is a circular binding: `detail`
    // is null until the body arrives, the child starts invisible, the parent
    // follows it to false - and then the child can never come back, because
    // its own visibility is now held down by the parent's. The body never
    // appeared at all.
    visible: !root.loading && root.error === "" && !!root.detail
    implicitHeight: bodyPane.height

  // Scrolls inside the pane rather than growing it: a long mail must not
  // stretch the popup past the screen.
  Flickable {
    id: bodyPane
    width: parent.width
    height: Math.min(bodyText.implicitHeight, root.maxBodyHeight)
    contentHeight: bodyText.implicitHeight
    contentWidth: width
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    SelectableText {
      id: bodyText
      width: parent.width
      readonly property string bodyFormat: root.detail ? String(root.detail.bodyFormat || "") : ""
      text: root.detail
            ? Model.bodyMarkup(String(root.detail.body || "").trim(), bodyFormat,
                               root.linkColor, root.bg)
            : ""
      color: root.fg
      // Link colour is SelectableText's business - through the palette, since
      // linkColor is a Text property and this is a TextEdit. A message that
      // colours its own anchors keeps its own colour; the rest come out in the
      // theme's accent instead of Qt's blue.
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      // The message says which it is, not the setting: a plain-text message in
      // an HTML-enabled widget is still plain text. AutoText is never the
      // answer - letting the content decide is what this is guarding against.
      //
      // "html" is the message's own markup, sanitised. "linked" is markup
      // graph.py built out of the message's plain text, so that the links the
      // text conversion leaves unusable can be clicked. Both are rich text.
      textFormat: bodyFormat === "html" || bodyFormat === "linked"
                  ? TextEdit.RichText : TextEdit.PlainText
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

    // Where the link under the pointer actually goes. A link's visible text is
    // shortened - nobody can read a safelink at full length - so this is the
    // one place the whole address can be seen before it is followed.
    //
    // Over the message rather than under it, on a ground of its own so it
    // stays readable against whatever it covers.
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: hoveredAddress.implicitHeight + Style.spacing.xs * 2
      visible: bodyText.hoveredLink !== ""
      color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.92)

      Text {
        id: hoveredAddress
        anchors.fill: parent
        anchors.margins: Style.spacing.xs
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: bodyText.hoveredLink
        elide: Text.ElideMiddle
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: root.htmlAuto && !root.htmlAlways && !root.senderHtml
    text: "Shown as the sender wrote it - this message carried no plain-text version. "
          + "Nothing was fetched from them."
    wrapMode: Text.WordWrap
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
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

  // Every action the pane offers, as data rather than as ten Buttons in a Row
  // that does not wrap. ActionBar measures them against the width it is given
  // and puts what will not fit behind a button that reveals it, which is what
  // makes this usable in the bar's popup as well as in the window.
  //
  // Order is priority: what is listed first is what survives on one line.
  //
  // The three ways of answering lead, because they are what a message that has
  // just been read is for. They did not: Open led, the formatting offers came
  // next, and Forward sat behind Mark read and Flag - which on the window's
  // 510-pixel reading column meant Reply, Reply all and Forward were all
  // behind "+8 more" on any message with markup in it. Open has moved down
  // with the rest: it leaves for Outlook, and the point of the buttons above
  // it is that the answer can be written here.
  //
  // Delete still trails, because reaching past a "+3 more" for it is a
  // feature.
  ActionBar {
    width: parent.width
    fg: root.fg
    dim: root.dim
    accent: root.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.caption

    actions: [
      // Writing needs the same Mail.ReadWrite that marking does - even a draft
      // is a write - so these are absent on a read-only mailbox rather than
      // present and failing. Forward keeps company with the other two: it is
      // the third answer to a message, not a filing action.
      { text: "Reply", visible: root.canCompose && root.canWrite,
        tooltip: root.elsewhere("Reply to this message"),
        enabled: !root.actionRunning,
        trigger: function() { root.replyRequested() } },
      { text: "Reply all", visible: root.canCompose && root.canWrite,
        tooltip: root.elsewhere("Reply to everybody on this message"),
        enabled: !root.actionRunning,
        trigger: function() { root.replyAllRequested() } },
      { text: "Forward", visible: root.canCompose && root.canWrite,
        tooltip: root.elsewhere("Send this message on to somebody else"),
        enabled: !root.actionRunning,
        trigger: function() { root.forwardRequested() } },

      { text: "Open", trigger: function() { root.openRequested() } },

      // Reading a message as its sender laid it out is a choice made per
      // message, not a mode the pane is left in - so this is a button here
      // rather than a switch in the settings. Nothing remote is fetched
      // either way; the pictures below are the separate, louder decision.
      { text: "Show formatting",
        tooltip: "Headings, lists, tables and the pictures the message carries "
                 + "itself. Nothing is fetched from the sender.",
        visible: root.htmlOffered && !root.htmlShown && root.htmlAvailable,
        enabled: !root.loading,
        trigger: function() { root.showHtmlRequested() } },

      { text: "Plain text", muted: true,
        tooltip: "Back to the words, with the links kept",
        visible: root.htmlOffered && root.htmlShown && !root.senderHtml,
        enabled: !root.loading,
        trigger: function() { root.showTextRequested() } },

      // The standing version of the same decision. Kept separate from the
      // one-off above because "this once" and "from now on" are not the same
      // answer, and a reader should not have to give the stronger one to see
      // what a message looks like.
      { text: "Always from this sender",
        tooltip: "Remember it, so mail from this address opens formatted",
        visible: root.htmlOffered && !root.senderHtml && root.htmlAvailable,
        enabled: !root.loading,
        trigger: function() { root.allowHtmlSenderRequested() } },

      { text: "Stop for this sender", muted: true,
        tooltip: "Forget the rule, and read this one as text again",
        visible: root.htmlOffered && root.senderHtml,
        enabled: !root.loading,
        trigger: function() { root.stopHtmlSenderRequested() } },

      // Only where there is something to load, and gone again once it is
      // loaded. Says how many, because "load 14 images" and "load 1 image"
      // are different decisions about how much of this the sender learns.
      { text: root.blockedImages === 1 ? "Load 1 image"
                                       : ("Load " + root.blockedImages + " images"),
        tooltip: "Fetches them from the sender's servers, which tells them the "
                 + "message was opened. Pictures it carries itself are already shown.",
        visible: root.blockedImages > 0,
        enabled: !root.loading,
        trigger: function() { root.loadImagesRequested() } },

      // Changing mail needs permission this plugin does not ask for by
      // default, so these appear only once a mailbox has granted it.
      { text: root.mail && root.mail.read ? "Mark unread" : "Mark read",
        visible: root.canWrite,
        trigger: function() { root.markRequested(!(root.mail && root.mail.read)) } },

      // The follow-up flag Outlook shows in its own column. Separate from read
      // state on purpose: flagging is "come back to this", which is most often
      // what one wants for a message one has just read.
      { text: root.mail && root.mail.flagged ? "Unflag" : "Flag",
        tooltip: root.mail && root.mail.flagged
                 ? "Clear the follow-up flag"
                 : "Flag it for follow-up, in Outlook too",
        visible: root.canWrite, enabled: !root.actionRunning,
        danger: !!(root.mail && root.mail.flagged),
        trigger: function() { root.flagRequested(!(root.mail && root.mail.flagged)) } },

      // Reading does not need write access and neither does asking about it,
      // which is why this one is not gated on canWrite the way the three
      // answers above are.
      { text: "Ask agent",
        tooltip: root.elsewhere("Open your coding agent on this message"),
        visible: root.canAgent,
        trigger: function() { root.agentRequested() } },

      { text: "Move\u2026",
        tooltip: root.elsewhere("File it in another folder of this mailbox"),
        visible: root.canMove && root.canWrite, enabled: !root.actionRunning,
        trigger: function() { root.moveRequested() } },

      { text: "Delete", tooltip: "Moves it to Deleted Items",
        visible: root.canWrite, enabled: !root.actionRunning, danger: true,
        trigger: function() { root.deleteRequested() } },

      { text: "Allow changes\u2026", muted: true,
        tooltip: "Sign in again to let this widget mark, move and delete mail",
        visible: !root.canWrite,
        trigger: function() { root.writeAccessRequested() } }
    ]
  }
}
