import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One meeting, in the column the agenda usually occupies.
//
// The agenda answers "when" and "where" and stops there, which is enough right
// up to the moment somebody sends an invitation. Then the questions are who
// else is coming, what they said, what the organiser wrote - and whether you
// are going, which is the one thing that could not be done here at all. So
// this is the reading pane's shape applied to a meeting, with the answer where
// Reply would be.
Column {
  id: root

  property var event: null
  property var detail: null
  property bool loading: false
  property string error: ""
  property bool answering: false
  property string answerError: ""
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property color linkColor: Color.accent
  // What the body is drawn on, which is what decides whether a colour the
  // sender chose can be read here at all - see Model.legibleBody. The theme's
  // own background, because that is what is behind this pane in both hosts.
  property color bg: Color.background
  property string fontFamily: Style.font.family
  property real maxBodyHeight: Style.space(220)

  signal closeRequested()
  signal openRequested(string url)
  signal joinRequested(string url)
  signal linkActivated(string url)
  // "accept", "tentative" or "decline". The pane never sends one itself: what
  // reaches the calendar is the host's business, the same way it is for mail.
  signal answerRequested(string reply)

  readonly property string subject: detail && detail.subject ? String(detail.subject)
                                    : (event && event.subject ? String(event.subject) : "")
  readonly property string joinUrl: detail && detail.joinUrl ? String(detail.joinUrl)
                                    : (event && event.joinUrl ? String(event.joinUrl) : "")
  readonly property string webLink: detail && detail.webLink ? String(detail.webLink)
                                    : (event && event.webLink ? String(event.webLink) : "")

  // What this mailbox has already answered. "organizer" is not an answer -
  // it is the calendar saying the meeting is yours - and "none" is a plain
  // appointment nobody was invited to.
  readonly property string myResponse: detail ? String(detail.myResponse || "none") : ""
  readonly property bool answerable: !!detail && detail.isMeeting === true
                                     && detail.isOrganizer !== true
                                     && detail.cancelled !== true

  // Whether the mailbox this meeting came from may answer at all. The host
  // sets it; answering is a grant of its own, and a mailbox that never asked
  // for it gets the reason below instead of three buttons that would fail.
  property bool canAnswer: true
  readonly property bool answerBlocked: answerable && !canAnswer

  spacing: Style.spacing.md

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

  // ---- when, where, who ----
  Column {
    width: parent.width
    spacing: Style.spacing.xxs

    SelectableText {
      width: parent.width
      singleLine: true
      text: {
        if (root.detail && root.detail.start)
          return Model.meetingWhen(root.detail.start, root.detail.end, root.detail.isAllDay)
        return root.event ? String(root.event.timeRange || "") : ""
      }
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    SelectableText {
      width: parent.width
      singleLine: true
      visible: text !== ""
      text: {
        var where = root.detail ? String(root.detail.location || "")
                                : (root.event ? String(root.event.location || "") : "")
        return where === "" ? "" : where
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    SelectableText {
      width: parent.width
      singleLine: true
      visible: text !== ""
      text: {
        if (!root.detail) return ""
        var name = String(root.detail.organizer || "").trim()
        var address = String(root.detail.organizerAddress || "").trim()
        if (root.detail.isOrganizer === true) return "Your meeting"
        if (name !== "" && address !== "" && name !== address)
          return "Called by " + name + "  <" + address + ">"
        return name !== "" ? "Called by " + name : ""
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // What was answered, said plainly, because it is the thing the buttons
    // below are about and Outlook hides it behind a ribbon.
    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: text !== ""
      text: {
        if (!root.detail) return ""
        if (root.detail.cancelled === true) return "This meeting was cancelled"
        return Model.responseLabel(root.myResponse, true)
      }
      color: root.detail && root.detail.cancelled === true ? root.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  PanelSeparator { width: parent.width }

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
    wrapMode: Text.WordWrap
    color: root.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // ---- who is coming ----
  //
  // Names with what each of them said, because "three of seven have accepted"
  // is the thing you actually want to know before a meeting starts, and it is
  // nowhere in the agenda.
  Column {
    width: parent.width
    visible: !root.loading && !!root.detail && attendeeRows.count > 0
    spacing: Style.spacing.xxs

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: Model.attendeeSummary(root.detail)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // Capped: a pane is not a distribution list. The count above is the whole
    // truth whatever this shows.
    Flickable {
      width: parent.width
      height: Math.min(attendeeColumn.implicitHeight, Style.space(96))
      contentHeight: attendeeColumn.implicitHeight
      contentWidth: width
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: attendeeColumn
        width: parent.width
        spacing: Style.spacing.xxs

        Repeater {
          id: attendeeRows
          model: Model.attendeeRows(root.detail)

          delegate: Row {
            required property var modelData
            width: attendeeColumn.width
            spacing: Style.spacing.sm

            Text {
              textFormat: Text.PlainText
              text: Model.responseGlyph(modelData.response)
              color: Model.responseIsYes(modelData.response) ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width - Style.space(28)
              text: modelData.name + (modelData.optional === true ? "  (optional)" : "")
              elide: Text.ElideRight
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  // ---- what the organiser wrote ----
  Flickable {
    id: bodyPane
    width: parent.width
    visible: !root.loading && bodyText.text !== ""
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
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      // The meeting says which it is, exactly as a message does: "linked" is
      // markup graph.py built out of escaped text so the join link in an
      // invitation can be clicked, and nothing a sender wrote is markup.
      textFormat: bodyFormat === "html" || bodyFormat === "linked"
                  ? TextEdit.RichText : TextEdit.PlainText
      onLinkActivated: function(url) { root.linkActivated(url) }

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
    text: "The invitation continues - open it to read the rest."
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: root.answerError !== ""
    text: root.answerError
    wrapMode: Text.WordWrap
    color: root.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // Why the answer is missing. Without this the buttons are simply absent,
  // which reads as "this meeting cannot be answered" rather than "this
  // mailbox cannot".
  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: root.answerBlocked
    text: "This mailbox was signed in without permission to answer meetings. "
          + "Allow changes for it in settings to sign in again."
    wrapMode: Text.WordWrap
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // Everything on offer, measured against the width - the same bar the reading
  // pane uses, so a narrow popup puts what will not fit one press away instead
  // of off the edge.
  ActionBar {
    width: parent.width
    fg: root.fg
    dim: root.dim
    accent: root.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.caption

    actions: [
      { text: "Join", tooltip: root.detail && root.detail.onlineProvider === "skype"
                               ? "Open the Skype meeting" : "Open the Teams meeting",
        visible: root.joinUrl !== "", danger: true,
        trigger: function() { root.joinRequested(root.joinUrl) } },

      // The answer. Whichever one is already given is left out rather than
      // drawn as a no-op: accepting a meeting you have accepted tells the
      // organiser nothing they have not been told.
      { text: "Accept",
        tooltip: "Tell the organiser you are coming",
        visible: root.answerable && root.canAnswer && root.myResponse !== "accepted",
        enabled: !root.answering,
        trigger: function() { root.answerRequested("accept") } },

      { text: "Maybe",
        tooltip: "Answer tentatively - it goes in the calendar either way",
        visible: root.answerable && root.canAnswer && root.myResponse !== "tentativelyAccepted",
        enabled: !root.answering,
        trigger: function() { root.answerRequested("tentative") } },

      { text: "Decline",
        tooltip: "Tell the organiser you are not coming. It leaves your calendar.",
        visible: root.answerable && root.canAnswer && root.myResponse !== "declined",
        enabled: !root.answering, danger: true,
        trigger: function() { root.answerRequested("decline") } },

      { text: "Open", tooltip: "Open it in Outlook",
        visible: root.webLink !== "",
        trigger: function() { root.openRequested(root.webLink) } },

      { text: "Answering…", muted: true, visible: root.answering, enabled: false,
        trigger: function() {} }
    ]
  }
}
