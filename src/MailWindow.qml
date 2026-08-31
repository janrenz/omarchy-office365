import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The plugin's window: folders on the left, that folder's mail in the middle,
// the message being read on the right.
//
// A real Hyprland toplevel rather than a surface hanging off the bar, so it
// tiles, fullscreens and goes to a workspace like any other window. Summon it
// with `omarchy-shell shell toggle caseonline.omarchy.office365`.
//
// The bar dropdown is unchanged and still the quick look: mail beside the
// agenda, gone as soon as you click away. This is the one you leave open.
//
// It has no settings of its own. The widget is multi-instance and the window
// is one per plugin, so it reads a widget's configuration out of shell.json
// and works that widget's mailboxes - the same mailboxes, the same tokens, one
// more reader of them.
Item {
  id: root

  readonly property string pluginId: "caseonline.omarchy.office365"

  // ---- host injections ----------------------------------------------------
  property var shell: null
  property var manifest: null

  // ---- plugin lifecycle ---------------------------------------------------
  property bool closingFromHost: false

  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
    return decodeURIComponent(url.replace(/\/$/, ""))
  }

  function open(payloadJson) {
    closingFromHost = false

    // Optional {"instance": "..."} picks which widget's mailboxes to open when
    // the bar carries more than one. Anything else opens the first.
    var requested = ""
    if (payloadJson) {
      try {
        var parsed = JSON.parse(String(payloadJson))
        if (parsed && typeof parsed.instance === "string") requested = parsed.instance
      } catch (e) { /* an unreadable payload is not worth refusing to open for */ }
    }
    wantedInstance = requested

    loadSettings()
    window.visible = true
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // Host-initiated close (`shell hide`). The host already knows.
  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  // User-initiated close (Esc, the window's own close button). Tell the shell,
  // so its open-panel map stays right and the next `toggle` opens rather than
  // silently closing something that is already gone.
  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(root.pluginId)
    else window.visible = false
  }

  // ---- the widget's settings ----------------------------------------------
  property string wantedInstance: ""
  property var settings: ({})
  property bool settingsLoaded: false
  property string settingsError: ""

  function loadSettings() {
    if (configProc.running || pluginDir === "") return
    configProc.command = ["python3", pluginDir + "/config.py", "--plugin-id", root.pluginId, "--list"]
    configProc.running = true
  }

  function applyWidgets(raw) {
    var parsed = Model.parseJson(raw, null)
    if (!parsed || parsed.ok === false) {
      settingsError = parsed && parsed.error ? String(parsed.error.message || "Could not read the bar layout")
                                             : "Could not read the bar layout"
      settingsLoaded = true
      return
    }
    var widgets = parsed.widgets || []
    if (widgets.length === 0) {
      settingsError = "No Office 365 widget in the bar. Add one, sign a mailbox in, and this window will show it."
      settings = ({})
      settingsLoaded = true
      return
    }
    var chosen = widgets[0]
    if (wantedInstance !== "") {
      for (var i = 0; i < widgets.length; i++)
        if (String((widgets[i].settings || {}).instance || "") === wantedInstance) { chosen = widgets[i]; break }
    }
    settingsError = ""
    settings = chosen.settings || {}
    settingsLoaded = true
  }

  Process {
    id: configProc
    running: false
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    stderr: StdioCollector { id: configErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyWidgets(configOut.text)
      else {
        root.settingsError = Model.oneLine(configErr.text || "Could not read the bar layout", 160)
        root.settingsLoaded = true
      }
    }
  }

  // ---- data ---------------------------------------------------------------
  Service {
    id: service
    settings: root.settings
    pluginDir: root.pluginDir
    fallbackColor: Color.accent
  }

  // Deliberately not called `service`: the shell assigns that name on every
  // panel it loads, from its own registry, and would overwrite this with null
  // for a plugin that declares no service kind. The dev harness drives the
  // window through it.
  readonly property alias mailService: service

  readonly property var views: service.views
  readonly property bool combined: service.combined
  // Whichever mailbox the sidebar cursor is in. With one mailbox this is just
  // that mailbox, which is the case the window is mostly opened in.
  readonly property string activeAlias: {
    var rows = service.folderRows
    for (var i = 0; i < rows.length; i++)
      if (rows[i].kind === "folder" && rows[i].selected === true) return String(rows[i].alias)
    return views.length > 0 ? String(views[0].alias) : ""
  }

  readonly property string folderTitle: {
    if (!service.configured) return "Office 365"
    var name = service.folderNameFor(activeAlias)
    if (name === "") name = "Inbox"
    if (!combined) return name
    var view = service.viewFor(activeAlias)
    var who = view && view.username !== "" ? view.username : activeAlias
    return name + " — " + who
  }

  // ---- keyboard -----------------------------------------------------------
  // Two panes, one cursor each. h/l moves between them, j/k inside one, Enter
  // acts on whichever is focused. The reading pane is not a cursor target: it
  // is what Enter in the mail list produces.
  property string pane: "mail"
  property int mailCursor: -1

  function focusPane(name) {
    pane = name
    if (name === "folders" && folders.cursorIndex < 0)
      folders.cursorIndex = Math.max(0, folders.selectedPickable)
  }

  function moveCursor(step) {
    if (pane === "folders") { folders.moveCursor(step); return }
    var count = service.mail.length
    if (count === 0) { mailCursor = -1; return }
    mailCursor = mailCursor < 0 ? (step > 0 ? 0 : count - 1)
                                : Math.max(0, Math.min(count - 1, mailCursor + step))
  }

  function activateCursor() {
    if (pane === "folders") { folders.activateCursor(); return }
    var rows = service.mail
    if (mailCursor >= 0 && mailCursor < rows.length) service.showPreview(rows[mailCursor])
  }

  function deleteAtCursor() {
    if (pane !== "mail") return
    var rows = service.mail
    if (mailCursor < 0 || mailCursor >= rows.length) return
    var row = rows[mailCursor]
    if (service.canWrite(row.alias)) service.deleteMail(row)
  }

  // Esc unwinds one layer at a time: the reading pane first, the window only
  // once there is nothing left inside it to close.
  function dismiss() {
    // Innermost first. A half-written reply is the last thing that should go
    // when someone reaches for Escape.
    if (service.composing) { service.cancelCompose(); return }
    if (service.previewMail !== null) { service.closePreview(); return }
    requestClose()
  }

  function pickFolder(alias, folderId) {
    service.selectFolder(alias, folderId)
    // The list underneath is about to be replaced; a cursor left pointing into
    // the old one would open a message from the folder just left.
    mailCursor = -1
    pane = "mail"
  }

  // ---- the window ---------------------------------------------------------
  FloatingWindow {
    id: window
    title: root.folderTitle === "Office 365" ? "Office 365" : ("Office 365 — " + root.folderTitle)
    color: Color.background
    implicitWidth: 1180
    implicitHeight: 760
    minimumSize: Qt.size(720, 480)

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide(root.pluginId)
    }

    FocusScope {
      anchors.fill: parent
      focus: true

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        // While a reply is open the catcher stands down: it consumes plain
        // letter keys to drive the cursor, so leaving it armed would eat the
        // j, k, h and l out of whatever was being typed.
        blocked: service.composing
        onMoveRequested: function(dx, dy) {
          if (dy !== 0) root.moveCursor(dy)
          else if (dx < 0) root.focusPane("folders")
          else if (dx > 0) root.focusPane("mail")
        }
        onActivateRequested: root.activateCursor()
        onDeleteRequested: root.deleteAtCursor()
        onCloseRequested: root.dismiss()
        onTabRequested: root.focusPane(root.pane === "folders" ? "mail" : "folders")

        Column {
          anchors.fill: parent
          anchors.margins: Style.spacing.panelPadding
          spacing: Style.spacing.panelGap

          // ---- header ----
          Item {
            width: parent.width
            height: header.implicitHeight

            Row {
              id: header
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.md

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.folderTitle
                textFormat: Text.PlainText
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: service.loading
                text: "loading…"
                textFormat: Text.PlainText
                color: Qt.darker(Color.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              // "Sent", or where the draft went. Cleared by the next compose.
              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: service.composeNotice !== ""
                text: service.composeNotice
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              FilterPill {
                label: "Unread"
                selected: service.unreadOnly
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onClicked: service.unreadOnly = !service.unreadOnly
              }

              // Focused/Other is a split Outlook draws across the inbox alone,
              // so the pill goes away in any other folder rather than sitting
              // there filtering on a property the folder has nothing to say
              // about.
              FilterPill {
                label: "Focused"
                visible: service.folderIdFor(root.activeAlias) === "inbox"
                selected: service.focusedOnly
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onClicked: service.focusedOnly = !service.focusedOnly
              }

              FilterPill {
                label: "Refresh"
                faded: service.loading
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onClicked: service.refresh()
              }
            }
          }

          PanelSeparator { width: parent.width }

          // ---- a reason there is nothing to show ----
          Text {
            width: parent.width
            visible: root.settingsError !== "" || (!service.configured && root.settingsLoaded)
            text: root.settingsError !== "" ? root.settingsError
                                            : "This widget has no mailbox yet. Add one from the bar panel's settings."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Qt.darker(Color.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          // ---- the three columns ----
          Row {
            id: columns
            width: parent.width
            height: parent.height - y
            spacing: Style.spacing.xxl
            visible: service.configured && root.settingsError === ""

            // A tiling window manager will hand this window whatever width the
            // layout has left, minimumSize or not, so the columns drop rather
            // than overlap. Sidebar first - a folder tree is worth less than
            // the mail in the folder - then the reading pane, which the list
            // gives way to while a message is open, the way the bar panel does
            // it. Nothing is ever squeezed below the width it needs to be read.
            readonly property bool showSidebar: width >= Style.space(620)
            readonly property real sidebarWidth: showSidebar
              ? Math.max(Style.space(170), Math.min(Style.space(260), width * 0.2)) : 0
            readonly property real rest: width
              - (showSidebar ? sidebarWidth + spacing * 2 + Style.space(1) : 0)
            readonly property bool showReader: rest >= Style.space(660)
            readonly property real listWidth: showReader
              ? Math.max(Style.space(300), Math.min(Style.space(440), rest * 0.42)) : rest
            readonly property real readerWidth: showReader
              ? rest - listWidth - spacing * 2 - Style.space(1) : rest
            // Whether the list is standing aside for the reading pane.
            readonly property bool listGivesWay: !showReader && service.previewMail !== null

            ScrollView {
              width: columns.sidebarWidth
              height: columns.height
              visible: columns.showSidebar
              clip: true

              FolderList {
                id: folders
                width: columns.sidebarWidth
                rows: service.folderRows
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onPicked: function(alias, folderId) { root.pickFolder(alias, folderId) }
              }
            }

            Rectangle {
              width: Style.space(1)
              height: columns.height
              visible: columns.showSidebar
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
            }

            // Placeholder rows while a folder switch is in flight. The rows
            // still in hand are the folder being left, and drawing those under
            // the new folder's name would read as "this is what is in Archive"
            // for as long as the fetch takes.
            SkeletonList {
              width: columns.listWidth
              // Also the very first fetch, which had nothing at all to show
              // for itself - an empty column while the mailbox loaded.
              visible: service.switchingFolder
                       || (service.mail.length === 0 && service.loading)
              fg: Color.foreground
              fontFamily: Style.font.family
              groups: [Math.max(3, Math.min(8, service.mails))]
              lines: service.previewLine
                ? [{ w: 0.42, small: false }, { w: 0.86, small: false }, { w: 0.62, small: true }]
                : [{ w: 0.42, small: false }, { w: 0.86, small: false }]
            }

            ScrollView {
              width: columns.listWidth
              height: columns.height
              visible: !columns.listGivesWay && !service.switchingFolder
                       && !(service.mail.length === 0 && service.loading)
              clip: true

              MailList {
                width: columns.listWidth
                mails: service.mail
                unreadOnly: service.unreadOnly
                showPreviewLine: service.previewLine
                showAccount: root.combined && service.filterAlias === ""
                selectedId: service.previewMail ? String(service.previewMail.id) : ""
                cursorIndex: root.pane === "mail" ? root.mailCursor : -1
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onActivated: function(mail) {
                  root.pane = "mail"
                  root.mailCursor = service.indexOfMail(mail.id)
                  service.showPreview(mail)
                }
                onDeleteRequested: function(mail) { service.deleteMail(mail) }
              }
            }

            Rectangle {
              width: Style.space(1)
              height: columns.height
              visible: columns.showReader
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
            }

            // The reading pane. Wide enough, it stands there empty until a
            // message is opened, so the list never moves under the cursor.
            // Too narrow for both, and it appears in the list's place instead.
            Item {
              width: columns.readerWidth
              height: columns.height
              visible: columns.showReader || columns.listGivesWay

              Text {
                anchors.centerIn: parent
                width: parent.width - Style.spacing.xxl
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                visible: columns.showReader && service.previewMail === null
                text: {
                  if (service.switchingFolder) return "Opening " + root.folderTitle + "…"
                  return service.mail.length === 0 ? "Nothing in this folder" : "Select a message"
                }
                textFormat: Text.PlainText
                color: Qt.darker(Color.foreground, 1.8)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Column {
                anchors.fill: parent
                spacing: Style.spacing.md
                visible: service.previewMail !== null

              ScrollView {
                width: parent.width
                // The reply takes its room off the bottom of the message being
                // answered rather than replacing it: quoting from a message you
                // can no longer see is how the wrong thing gets quoted.
                height: parent.height - (composeBox.visible ? composeBox.height + parent.spacing : 0)
                clip: true

                MailPreview {
                  width: columns.readerWidth
                  // Read out of the merged list, so an override applied to this
                  // id shows here as well as on the row.
                  mail: {
                    if (!service.previewMail) return null
                    var id = String(service.previewMail.id)
                    var list = service.mail
                    for (var i = 0; i < list.length; i++) if (String(list[i].id) === id) return list[i]
                    return service.previewMail
                  }
                  detail: service.previewDetail
                  loading: service.previewLoading
                  error: service.previewError
                  // A window is taller than a dropdown, so the body gets to use
                  // that height instead of being capped at the popup's.
                  maxBodyHeight: Math.max(Style.space(360), columns.height - Style.space(180))
                  fg: Color.foreground
                  accent: Color.accent
                  fontFamily: Style.font.family
                  canWrite: !!service.previewMail && service.canWrite(service.previewMail.alias)
                  // Only here: the bar dropdown has nowhere to type.
                  canCompose: true
                  actionRunning: service.actionRunning
                  actionError: service.actionError
                  onLinkActivated: function(url) {
                    if (service.previewMail) service.openUrl(url, service.previewMail.alias)
                  }
                  onReplyRequested: service.startCompose("reply", service.previewMail)
                  onReplyAllRequested: service.startCompose("reply-all", service.previewMail)
                  onForwardRequested: service.startCompose("forward", service.previewMail)
                  onCloseRequested: service.closePreview()
                  onOpenRequested: service.openPreviewed()
                  onMarkRequested: function(read) { service.markPreviewed(read) }
                  onDeleteRequested: service.deletePreviewed()
                  onWriteAccessRequested: {
                    if (service.previewMail) service.startLogin(service.previewMail.alias, true)
                  }
                }
              }

                // Rebuilt for each message rather than kept and cleared, so a
                // reply can never open holding what was typed at the last one.
                Loader {
                  id: composeBox
                  width: parent.width
                  active: service.composing
                  visible: active
                  sourceComponent: ComposeBox {
                    width: composeBox.width
                    mode: service.composeMode
                    subject: service.composeMail ? String(service.composeMail.subject || "") : ""
                    needsRecipient: service.composeNeedsRecipient
                    canSend: !!service.composeMail && service.canSend(service.composeMail.alias)
                    running: service.composeRunning
                    error: service.composeError
                    sendBlocked: service.composeSendBlocked
                    fg: Color.foreground
                    accent: Color.accent
                    fontFamily: Style.font.family
                    onToEdited: function(value) { service.composeTo = value }
                    onBodyEdited: function(value) { service.composeText = value }
                    onSendRequested: service.submitCompose(false)
                    onDraftRequested: service.submitCompose(true)
                    onCancelRequested: service.cancelCompose()
                    onPermissionRequested: {
                      if (service.composeMail) service.startLogin(service.composeMail.alias, true)
                    }
                    Component.onCompleted: Qt.callLater(focusBody)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
