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

  // The plugin's one shared store, assigned by the shell on every panel it
  // loads because the manifest declares kind "service". The bar widget reads
  // the same object, which is how a message marked read here stops being bold
  // in the bar before the next fetch.
  property var service: null

  Service {
    id: mailView
    settings: root.settings
    pluginDir: root.pluginDir
    store: root.service
    fallbackColor: Color.accent
  }

  // The window's own view of those mailboxes. Deliberately not called
  // `service`: that name belongs to the shell's injection above. The dev
  // harness drives the window through this.
  readonly property alias mailService: mailView

  readonly property var views: mailView.views
  readonly property bool combined: mailView.combined
  // Whichever mailbox the sidebar cursor is in. With one mailbox this is just
  // that mailbox, which is the case the window is mostly opened in.
  readonly property string activeAlias: {
    var rows = mailView.folderRows
    for (var i = 0; i < rows.length; i++)
      if (rows[i].kind === "folder" && rows[i].selected === true) return String(rows[i].alias)
    return views.length > 0 ? String(views[0].alias) : ""
  }

  readonly property string folderTitle: {
    if (!mailView.configured) return "Office 365"
    var name = mailView.folderNameFor(activeAlias)
    if (name === "") name = "Inbox"
    if (!combined) return name
    var view = mailView.viewFor(activeAlias)
    var who = view && view.username !== "" ? view.username : activeAlias
    return name + " — " + who
  }

  // ---- keyboard -----------------------------------------------------------
  //
  // A focus ladder, the same one the Teams window uses so what is learned in
  // one works in the other: folders -> mail -> message. h and l step between
  // the rungs, Escape walks back out one at a time, and j/k always mean down
  // and up in whatever has focus.
  //
  // The message used to be the one place j and k did nothing: it was not a
  // cursor target at all, so a long mail could only be scrolled with the mouse.
  property string pane: "mail"
  property int mailCursor: -1
  property bool showHelp: false

  // One line of the message, near enough, for j and k while reading.
  readonly property int lineStep: Math.max(Style.space(18), Style.font.bodySmall * 2)

  // ---- filing a message ---------------------------------------------------
  //
  // The mailbox's folder tree again, over the window, with the message it
  // would file named above it. A layer of its own rather than a mode of the
  // sidebar: the sidebar picks what to read, and picking what to read is not
  // what Enter should do while a message is waiting to be filed.
  //
  // The row is held rather than the id, because the row carries the mailbox -
  // a folder id names a folder in one mailbox, so which mailbox is asking is
  // half the question.
  property var moveRow: null
  readonly property bool moving: moveRow !== null

  // Where it could go. Held here rather than read back off the picker: the
  // sheet around the tree - whether to draw the empty note, how much room the
  // list gets - is laid out from this, and laying an item out from a property
  // of the item being laid out is a binding loop.
  readonly property var moveTargets: moveRow ? mailView.moveTargetsFor(moveRow.alias) : []

  function startMove(row) {
    if (!row || !mailView.canWrite(row.alias)) return
    moveRow = row
  }

  function cancelMove() {
    moveRow = null
  }

  function moveToFolder(folderId, folderName) {
    var row = moveRow
    moveRow = null
    if (!row) return
    mailView.moveMail(row, folderId, folderName)
  }

  // What m acts on: the row under the cursor in the list, or the message being
  // read when the cursor is somewhere else.
  function moveAtCursor() {
    if (moving) return
    var rows = mailView.mail
    if (pane === "mail" && mailCursor >= 0 && mailCursor < rows.length) startMove(rows[mailCursor])
    else if (mailView.previewMail !== null) startMove(mailView.previewMail)
  }

  // Which scroller the scroll keys act on: whichever pane has focus.
  function scrollTarget() {
    // The picker is over everything else, so it is what the keys reach.
    if (moving) return movePicker.item ? movePicker.item.scroller : null
    if (pane === "message" && mailView.previewMail !== null) return readerScroll
    if (pane === "folders") return folderDrawer ? drawerFolderScroll : folderScroll
    return listScroll
  }

  function scrollBy(view, dy) {
    var flick = view ? view.contentItem : null
    if (!flick) return
    var limit = Math.max(0, flick.contentHeight - flick.height)
    flick.contentY = Math.max(0, Math.min(limit, flick.contentY + dy))
  }

  function scrollToEnd(view, toBottom) {
    var flick = view ? view.contentItem : null
    if (!flick) return
    flick.contentY = toBottom === true ? Math.max(0, flick.contentHeight - flick.height) : 0
  }

  // A tiling layout hands this window whatever width is left, and below a
  // point there is no room for a sidebar beside the mail. The folder tree is
  // not gone then - it takes the window until a folder is picked, opened by
  // the same Tab or h that would focus the sidebar and by the Folders pill in
  // the header. Without this the tree is unreachable on a half-screen window:
  // the keys still moved a cursor through it, invisibly.
  property bool folderDrawer: false

  // Whichever folder tree is on screen, since the keyboard drives whichever
  // one that is.
  readonly property var folderPane: columns.showSidebar ? folders : drawerFolders

  function toggleFolderDrawer() {
    if (folderDrawer) {
      folderDrawer = false
      pane = "mail"
      return
    }
    focusPane("folders")
  }

  function focusPane(name) {
    pane = name
    if (name !== "folders") {
      // Moving to the mail is how you leave the tree, so it should not stay
      // sitting over the list.
      folderDrawer = false
      return
    }
    if (!columns.showSidebar) folderDrawer = true
    if (folderPane.cursorIndex < 0)
      folderPane.cursorIndex = Math.max(0, folderPane.selectedPickable)
  }

  function moveCursor(step) {
    if (moving) { if (movePicker.item) movePicker.item.tree.moveCursor(step); return }
    if (pane === "folders") { folderPane.moveCursor(step); return }
    // In the message, down and up scroll it rather than moving off it.
    if (pane === "message" && mailView.previewMail !== null) {
      scrollBy(readerScroll, step * lineStep)
      return
    }
    var count = mailView.mail.length
    if (count === 0) { mailCursor = -1; return }
    mailCursor = mailCursor < 0 ? (step > 0 ? 0 : count - 1)
                                : Math.max(0, Math.min(count - 1, mailCursor + step))
  }

  function activateCursor() {
    if (moving) { if (movePicker.item) movePicker.item.tree.activateCursor(); return }
    if (pane === "folders") { folderPane.activateCursor(); return }
    if (pane === "message") return
    var rows = mailView.mail
    if (mailCursor >= 0 && mailCursor < rows.length) {
      mailView.showPreview(rows[mailCursor])
      // Opening is a step inwards: the keys should now be driving what was
      // opened rather than the list behind it.
      if (mailView.previewMail !== null) pane = "message"
    }
  }

  // Flagging reaches what the cursor is on, and what is being read when the
  // reading pane has focus - the same reach moving has, because a flag is
  // most often the thing one wants for the message just read.
  function flagAtCursor() {
    if (moving) return
    var rows = mailView.mail
    var row = pane === "mail" && mailCursor >= 0 && mailCursor < rows.length
              ? rows[mailCursor]
              : mailView.previewMail
    if (row && mailView.canWrite(row.alias)) mailView.flagMail(row, row.flagged !== true)
  }

  function deleteAtCursor() {
    if (moving || pane !== "mail") return
    var rows = mailView.mail
    if (mailCursor < 0 || mailCursor >= rows.length) return
    var row = rows[mailCursor]
    if (mailView.canWrite(row.alias)) mailView.deleteMail(row)
  }

  // Esc unwinds one layer at a time: the reading pane first, the window only
  // once there is nothing left inside it to close.
  function dismiss() {
    if (showHelp) { showHelp = false; return }
    // Over everything else, so it is the first layer Escape takes back.
    if (moving) { cancelMove(); return }
    // Innermost first. A half-written reply is the last thing that should go
    // when someone reaches for Escape.
    if (mailView.composing) { mailView.cancelCompose(); return }
    // The tree is over the list rather than beside it, so it is the layer
    // Escape should take back first.
    if (folderDrawer) { folderDrawer = false; pane = "mail"; return }
    // Back to the list with the message still open. Escape again closes it -
    // one rung at a time, rather than shutting the message outright.
    if (pane === "message") { pane = "mail"; return }
    if (mailView.previewMail !== null) { mailView.closePreview(); return }
    requestClose()
  }

  function pickFolder(alias, folderId) {
    mailView.selectFolder(alias, folderId)
    folderDrawer = false
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

      // PanelKeyCatcher's vocabulary is Escape, Tab, the arrows, j/k/h/l and
      // Return; Page, Home and End are not in it and arrive here instead.
      // AfterItem so the catcher still gets first refusal on what it knows.
      Keys.priority: Keys.AfterItem
      Keys.onPressed: function(event) {
        if (mailView.composing || root.showHelp) return
        var view = root.scrollTarget()
        if (!view) return
        var page = Math.max(Style.space(80), view.height * 0.9)
        var control = (event.modifiers & Qt.ControlModifier) !== 0

        if (event.key === Qt.Key_PageDown) root.scrollBy(view, page)
        else if (event.key === Qt.Key_PageUp) root.scrollBy(view, -page)
        else if (event.key === Qt.Key_Home) root.scrollToEnd(view, false)
        else if (event.key === Qt.Key_End) root.scrollToEnd(view, true)
        else if (control && event.key === Qt.Key_D) root.scrollBy(view, page / 2)
        else if (control && event.key === Qt.Key_U) root.scrollBy(view, -page / 2)
        else if (control && event.key === Qt.Key_F) root.scrollBy(view, page)
        else if (control && event.key === Qt.Key_B) root.scrollBy(view, -page)
        else return
        event.accepted = true
      }

      // Filing a message: this mailbox's folders, over the window, with what is
      // being filed named above them. Under the help sheet, so ? still works.
      //
      // Built when it is wanted rather than kept hidden. A folder tree that is
      // made visible after the fact lays its rows out again against widths
      // that have not settled yet, and Qt reports that as a binding loop;
      // built fresh, it lays out once. It also means the picker can never open
      // holding the cursor position it was left at for another message.
      Loader {
        id: movePicker
        anchors.fill: parent
        active: root.moving
        z: 110

        sourceComponent: Rectangle {
          // What the window drives from out here: the tree the keys move
          // through, and the scroller the page keys act on.
          property alias tree: pickerTree
          property alias scroller: pickerScroll

          color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.97)

          // Clicking off it is the same as Escape: nothing is filed.
          MouseArea { anchors.fill: parent; onClicked: root.cancelMove() }

          Column {
            id: movePane
            anchors.centerIn: parent
            width: Math.min(Style.space(440), parent.width - Style.spacing.xxl * 2)
            height: Math.min(Style.space(520), parent.height - Style.spacing.xxl * 2)
            spacing: Style.spacing.md

            Text {
              width: parent.width
              text: "Move to folder"
              textFormat: Text.PlainText
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            // Which message, because m can be pressed on a row that is not the
            // one open in the reading pane.
            Text {
              width: parent.width
              text: root.moveRow ? String(root.moveRow.subject || "(no subject)") : ""
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: Qt.darker(Color.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              visible: root.moveTargets.length === 0
              text: mailView.loading
                ? "Still reading this mailbox\u2019s folders\u2026"
                : "This mailbox has nowhere else to put it."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Qt.darker(Color.foreground, 1.8)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            ScrollView {
              id: pickerScroll
              width: parent.width
              height: parent.height - y
              visible: root.moveTargets.length > 0
              clip: true

              FolderList {
                id: pickerTree
                // Sized from the column, not from the scroller: a ScrollView
                // takes its implicit width from its content, so handing the
                // content that width back would be a loop.
                width: movePane.width
                rows: root.moveTargets
                // Straight onto the first folder, unlike the sidebar: this
                // list is opened to pick from, and has nothing already
                // selected in it to start from.
                cursorIndex: 0
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onPicked: function(alias, folderId) {
                  root.moveToFolder(folderId, pickerTree.nameFor(folderId))
                }
              }
            }
          }
        }
      }

      // The keyboard, listed. ? works from anywhere in the window.
      Item {
        anchors.fill: parent
        visible: root.showHelp
        z: 120

        Rectangle {
          anchors.fill: parent
          color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.97)

          MouseArea { anchors.fill: parent; onClicked: root.showHelp = false }

          KeyHelp {
            anchors.centerIn: parent
            fg: Color.foreground
            fontFamily: Style.font.family
          }
        }
      }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        // While a reply is open the catcher stands down: it consumes plain
        // letter keys to drive the cursor, so leaving it armed would eat the
        // j, k, h and l out of whatever was being typed.
        blocked: mailView.composing
        onMoveRequested: function(dx, dy) {
          if (dy !== 0) { root.moveCursor(dy); return }
          // Nothing to step between: the picker is the whole window.
          if (root.moving) return
          // Left steps back towards the folders, right steps in towards the
          // message, one rung per press.
          if (dx < 0) root.focusPane(root.pane === "message" ? "mail" : "folders")
          else if (dx > 0) {
            if (root.pane === "folders") root.focusPane("mail")
            else if (mailView.previewMail !== null) root.focusPane("message")
          }
        }
        onActivateRequested: root.activateCursor()
        onDeleteRequested: root.deleteAtCursor()
        onCloseRequested: root.dismiss()
        onTabRequested: root.focusPane(root.pane === "folders" ? "mail" : "folders")
        // The same letters the bar panel takes, so what is learned in one
        // works in the other. r is the window's own: the panel refreshes on
        // opening, and this stays put for hours.
        onTextKey: function(text) {
          var view = root.scrollTarget()
          // While the picker is up the only letters that mean anything are the
          // ones that move in it, which the catcher has already dealt with.
          // f, u and r would act on the list behind it, invisibly.
          if (root.moving) {
            if (text === "g") root.scrollToEnd(view, false)
            else if (text === "G") root.scrollToEnd(view, true)
            return
          }
          if (text === "f") mailView.focusedOnly = !mailView.focusedOnly
          else if (text === "u") mailView.unreadOnly = !mailView.unreadOnly
          else if (text === "t") mailView.threaded = !mailView.threaded
          else if (text === "r") mailView.refresh()
          else if (text === "m") root.moveAtCursor()
          // Capital, because f is already the Focused filter.
          else if (text === "F") root.flagAtCursor()
          else if (text === "?") root.showHelp = !root.showHelp
          else if (text === "g") root.scrollToEnd(view, false)
          else if (text === "G") root.scrollToEnd(view, true)
        }

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
              // Bounded by where the buttons start. Without this the row is
              // free to be as wide as it likes, elide has nothing to elide
              // against, and a title such as "Inbox — someone@example.com"
              // runs straight under Folders on any window narrower than about
              // half a screen - which is the width a tiling compositor hands
              // this window most of the time.
              anchors.right: headerActions.left
              anchors.rightMargin: Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.md

              Text {
                anchors.verticalCenter: parent.verticalCenter
                // Whatever the status bits beside it do not need. They are
                // short, they come and go, and they are the part somebody is
                // waiting to read - so the title is the part that gives way.
                width: Math.max(0, header.width - status.width
                                   - (status.width > 0 ? header.spacing : 0))
                text: root.folderTitle
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
              }

              // Grouped, so their combined width can be measured and taken off
              // the title's rather than each one pushing it along. A Row skips
              // children that are not visible, so this is nothing at all when
              // nothing is happening.
              Row {
                id: status
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.md

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: mailView.loading
                  text: "loading…"
                  textFormat: Text.PlainText
                  color: Qt.darker(Color.foreground, 1.5)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                // Where a moved message went. The one action with nothing left
                // on screen to show for itself: the row is gone, and the folder
                // it landed in is somewhere else entirely.
                //
                // Capped rather than free: "Moved to Gelöschte Elemente" is a
                // sentence, and a sentence that pushes the title out of the
                // window is a worse way to be told about it.
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: mailView.actionNotice !== ""
                  width: Math.min(implicitWidth, header.width * 0.45)
                  text: mailView.actionNotice
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                // "Sent", or where the draft went. Cleared by the next compose.
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: mailView.composeNotice !== ""
                  width: Math.min(implicitWidth, header.width * 0.45)
                  text: mailView.composeNotice
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Row {
              id: headerActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              // With no sidebar there is nothing to click a folder in, and the
              // keys that reach the tree are not something to have to know
              // about. Only there when the tree is not.
              FilterPill {
                label: "Folders"
                visible: !columns.showSidebar && mailView.configured
                selected: root.folderDrawer
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onClicked: root.toggleFolderDrawer()
              }

              FilterPill {
                label: "Unread"
                selected: mailView.unreadOnly
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onClicked: mailView.unreadOnly = !mailView.unreadOnly
              }

              // Only the window offers this: the bar dropdown has nowhere to
              // put a conversation once it opens. The count is conversations
              // rather than messages, which is what the list is showing.
              FilterPill {
                label: "Threads"
                detail: mailView.threaded && mailView.threads.length > 0
                  ? String(mailView.threads.length) : ""
                selected: mailView.threaded
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onClicked: mailView.threaded = !mailView.threaded
              }

              // Focused/Other is a split Outlook draws across the inbox alone,
              // so the pill goes away in any other folder rather than sitting
              // there filtering on a property the folder has nothing to say
              // about.
              FilterPill {
                label: "Focused"
                visible: mailView.folderIdFor(root.activeAlias) === "inbox"
                selected: mailView.focusedOnly
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onClicked: mailView.focusedOnly = !mailView.focusedOnly
              }

              FilterPill {
                label: "Refresh"
                faded: mailView.loading
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onClicked: mailView.refresh()
              }
            }
          }

          PanelSeparator { width: parent.width }

          // ---- a reason there is nothing to show ----
          Text {
            width: parent.width
            visible: root.settingsError !== "" || (!mailView.configured && root.settingsLoaded)
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
            visible: mailView.configured && root.settingsError === ""

            // A tiling window manager will hand this window whatever width the
            // layout has left, minimumSize or not, so the columns drop rather
            // than overlap. Sidebar first - a folder tree is worth less than
            // the mail in the folder - then the reading pane, which the list
            // gives way to while a message is open, the way the bar panel does
            // it. Nothing is ever squeezed below the width it needs to be read.
            readonly property bool showSidebar: width >= Style.space(620)
            // The folder tree standing in for the columns, because there is no
            // room for it beside them.
            readonly property bool folderPicking: root.folderDrawer && !showSidebar
            // A window widened back out has its sidebar again, and no reason
            // to be holding the tree over the mail as well.
            onShowSidebarChanged: if (showSidebar) root.folderDrawer = false
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
            readonly property bool listGivesWay: !showReader && mailView.previewMail !== null

            // The tree when there is no sidebar to put it in: the full width
            // of the window, over the mail, until a folder is picked or
            // Escape puts it away.
            ScrollView {
              id: drawerFolderScroll
              width: columns.width
              height: columns.height
              visible: columns.folderPicking
              clip: true

              FolderList {
                id: drawerFolders
                width: columns.width
                rows: mailView.folderRows
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                cursorIndex: -1
                onPicked: function(alias, folderId) { root.pickFolder(alias, folderId) }
              }
            }

            ScrollView {
              id: folderScroll
              width: columns.sidebarWidth
              height: columns.height
              visible: columns.showSidebar
              clip: true

              FolderList {
                id: folders
                width: columns.sidebarWidth
                rows: mailView.folderRows
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
              visible: !columns.folderPicking
                       && (mailView.switchingFolder
                           || (mailView.mail.length === 0 && mailView.loading))
              fg: Color.foreground
              fontFamily: Style.font.family
              groups: [Math.max(3, Math.min(8, mailView.mails))]
              lines: mailView.previewLine
                ? [{ w: 0.42, small: false }, { w: 0.86, small: false }, { w: 0.62, small: true }]
                : [{ w: 0.42, small: false }, { w: 0.86, small: false }]
            }

            ScrollView {
              id: listScroll
              width: columns.listWidth
              height: columns.height
              visible: !columns.folderPicking && !columns.listGivesWay
                       && !mailView.switchingFolder
                       && !(mailView.mail.length === 0 && mailView.loading)
              clip: true

              MailList {
                width: columns.listWidth
                mails: mailView.mail
                threads: mailView.threads
                threaded: mailView.threaded
                unreadOnly: mailView.unreadOnly
                showPreviewLine: mailView.previewLine
                showAccount: root.combined && mailView.filterAlias === ""
                selectedId: mailView.previewMail ? String(mailView.previewMail.id) : ""
                // By id rather than by index: a threaded list draws summary
                // rows the message list knows nothing about, so the two stop
                // counting in step the moment a conversation is grouped.
                cursorId: root.pane === "mail" && root.mailCursor >= 0
                          && root.mailCursor < mailView.mail.length
                  ? String(mailView.mail[root.mailCursor].id) : ""
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onActivated: function(mail) {
                  root.pane = "mail"
                  root.mailCursor = mailView.indexOfMail(mail.id)
                  mailView.showPreview(mail)
                }
                onDeleteRequested: function(mail) { mailView.deleteMail(mail) }
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
              visible: !columns.folderPicking && (columns.showReader || columns.listGivesWay)

              Text {
                anchors.centerIn: parent
                width: parent.width - Style.spacing.xxl
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                visible: columns.showReader && mailView.previewMail === null
                text: {
                  if (mailView.switchingFolder) return "Opening " + root.folderTitle + "…"
                  return mailView.mail.length === 0 ? "Nothing in this folder" : "Select a message"
                }
                textFormat: Text.PlainText
                color: Qt.darker(Color.foreground, 1.8)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Column {
                anchors.fill: parent
                spacing: Style.spacing.md
                visible: mailView.previewMail !== null

              ScrollView {
                id: readerScroll
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
                    if (!mailView.previewMail) return null
                    var id = String(mailView.previewMail.id)
                    var list = mailView.mail
                    for (var i = 0; i < list.length; i++) if (String(list[i].id) === id) return list[i]
                    return mailView.previewMail
                  }
                  detail: mailView.previewDetail
                  loading: mailView.previewLoading
                  error: mailView.previewError
                  // A window is taller than a dropdown, so the body gets to use
                  // that height instead of being capped at the popup's.
                  maxBodyHeight: Math.max(Style.space(360), columns.height - Style.space(180))
                  fg: Color.foreground
                  accent: Color.accent
                  fontFamily: Style.font.family
                  canWrite: !!mailView.previewMail && mailView.canWrite(mailView.previewMail.alias)
                  // Only here: the bar dropdown has nowhere to type, and no
                  // room to hold a folder tree open over itself either.
                  canCompose: true
                  canMove: true
                  actionRunning: mailView.actionRunning
                  actionError: mailView.actionError
                  onLinkActivated: function(url) {
                    if (mailView.previewMail) mailView.openUrl(url, mailView.previewMail.alias)
                  }
                  onReplyRequested: mailView.startCompose("reply", mailView.previewMail)
                  onReplyAllRequested: mailView.startCompose("reply-all", mailView.previewMail)
                  onForwardRequested: mailView.startCompose("forward", mailView.previewMail)
                  onCloseRequested: mailView.closePreview()
                  onOpenRequested: mailView.openPreviewed()
                  onMarkRequested: function(read) { mailView.markPreviewed(read) }
                  onFlagRequested: function(flagged) { mailView.flagPreviewed(flagged) }
                  onDeleteRequested: mailView.deletePreviewed()
                  onMoveRequested: root.startMove(mailView.previewMail)
                  onWriteAccessRequested: {
                    if (mailView.previewMail) mailView.startLogin(mailView.previewMail.alias, true)
                  }
                }
              }

                // Rebuilt for each message rather than kept and cleared, so a
                // reply can never open holding what was typed at the last one.
                Loader {
                  id: composeBox
                  width: parent.width
                  active: mailView.composing
                  visible: active
                  sourceComponent: ComposeBox {
                    width: composeBox.width
                    mode: mailView.composeMode
                    subject: mailView.composeMail ? String(mailView.composeMail.subject || "") : ""
                    needsRecipient: mailView.composeNeedsRecipient
                    canSend: !!mailView.composeMail && mailView.canSend(mailView.composeMail.alias)
                    running: mailView.composeRunning
                    error: mailView.composeError
                    sendBlocked: mailView.composeSendBlocked
                    fg: Color.foreground
                    accent: Color.accent
                    fontFamily: Style.font.family
                    onToEdited: function(value) { mailView.composeTo = value }
                    onBodyEdited: function(value) { mailView.composeText = value }
                    onSendRequested: mailView.submitCompose(false)
                    onDraftRequested: mailView.submitCompose(true)
                    onCancelRequested: mailView.cancelCompose()
                    onPermissionRequested: {
                      if (mailView.composeMail) mailView.startLogin(mailView.composeMail.alias, true)
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
