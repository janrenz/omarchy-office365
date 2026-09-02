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
    // A window opens on a page of mail, not on the bar's own list length -
    // see Service.mailPage. Scrolling to the end asks for the next page.
    mailView.openPage()

    // Optional {"instance": "..."} picks which widget's mailboxes to open when
    // the bar carries more than one. Anything else opens the first.
    var requested = ""
    var payload = null
    if (payloadJson) {
      try {
        payload = JSON.parse(String(payloadJson))
        if (payload && typeof payload.instance === "string") requested = payload.instance
      } catch (e) { /* an unreadable payload is not worth refusing to open for */ }
    }
    wantedInstance = requested

    loadSettings()
    if (payload) applyPayload(payload)
    window.visible = true
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // The rest of what the shell may deliver with a summon: a message to read -
  // what a clicked notification passes, as `account`, `folderId` and
  // `messageId` - a draft reply a coding agent wrote, and an `action` to start
  // on arrival. All of them have to survive arriving twice, because the shell
  // drains its payload queue in a loop and delivers to a window that is
  // already open.
  //
  // `action` is what makes the bar dropdown able to offer Reply, Forward, Move
  // and the rest without being able to do any of them: the dropdown closes the
  // moment you click away, so it hands the message here with the action
  // already chosen rather than leaving those buttons off itself.
  function applyPayload(payload) {
    var alias = String(payload.account || "")
    var messageId = String(payload.messageId || "")
    var action = String(payload.action || "")
    if (alias !== "") {
      // An empty folderId is the inbox, which is also what selectFolder makes
      // of it - and it is a no-op when that folder is already the one open.
      mailView.selectFolder(alias, String(payload.folderId || ""))
      if (messageId !== "") revealMessage(alias, messageId, action)
    }
    if (payload.draft) {
      agentDraftPending = payload.draft
      flushAgentDraft()
    }
    // An action with no message to act on. Writing one is the only such action,
    // and callLater because the mailbox that was just selected has to have
    // become the active one before startNewMessage reads it.
    if (messageId === "" && action === "new") Qt.callLater(root.startNewMessage)
  }

  // What to do with a message once it is on screen. Kept to the actions the
  // dropdown cannot perform itself, so this is not a second way to do
  // everything - the buttons in the reading pane are still the only ones.
  function runAction(action, row) {
    if (!row) return
    if (action === "reply" || action === "reply-all" || action === "forward") {
      if (mailView.canWrite(row.alias)) mailView.startCompose(action, row)
      return
    }
    if (action === "move") {
      if (mailView.canWrite(row.alias)) startMove(row)
      return
    }
    if (action === "agent") askAgent()
  }

  // A message named by id alone. Switching folder is a fetch, so the row it
  // lives in is usually not here yet when the payload is; the request is kept
  // and answered by the Connections below when the list lands. Kept as one
  // request rather than a queue: a second notification supersedes the first,
  // because it is the newer thing the person clicked.
  property string pendingMessageAlias: ""
  property string pendingMessageId: ""
  // Held with the request rather than acted on at once: an action wants the
  // message it acts on to be the one being read, and that is not true until
  // the folder's fetch has landed.
  property string pendingAction: ""

  function revealMessage(alias, id, action) {
    pendingMessageAlias = String(alias || "")
    pendingMessageId = String(id || "")
    pendingAction = String(action || "")
    flushPendingMessage()
  }

  function flushPendingMessage() {
    if (pendingMessageId === "") return
    var at = mailView.indexOfMail(pendingMessageId)
    if (at < 0) return
    var row = mailView.mail[at]
    var action = pendingAction
    pendingMessageAlias = ""
    pendingMessageId = ""
    pendingAction = ""
    pane = "mail"
    mailCursor = at
    // showPreview toggles the message it is already showing closed, which is
    // the opposite of what a notification asked for.
    if (!mailView.previewMail || String(mailView.previewMail.id) !== String(row.id))
      mailView.showPreview(row)
    // After the pane has the message: startCompose and startMove both act on
    // the row, and askAgent reads what is being previewed.
    if (action !== "") Qt.callLater(function() { root.runAction(action, row) })
  }

  Connections {
    target: mailView
    function onMailChanged() { root.flushPendingMessage() }
  }

  // Host-initiated close (`shell hide`). The host already knows.
  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  // Back to the bar's own list length the moment the window is gone. The fetch
  // is shared with the widget, so a window left paged to a hundred would have
  // the background poll reading a hundred messages a mailbox for the rest of
  // the day for nobody to look at.
  function stopPaging() { mailView.paged = 0 }

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
  // A draft that came in before the settings did has been waiting for them.
  onSettingsChanged: flushAgentDraft()
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

  // The toplevel itself, so a harness can photograph what this draws without
  // the shell in the way. Nothing in the plugin uses it.
  readonly property alias floatingWindow: window

  readonly property var views: mailView.views
  readonly property bool combined: mailView.combined
  // Whichever mailbox the sidebar is reading. With one mailbox this is just
  // that mailbox, which is the case the window is mostly opened in. One source
  // for it rather than two: the sidebar lights exactly this mailbox's folder,
  // and reading the answer back out of the rows it drew would be a way for the
  // two to disagree.
  readonly property string activeAlias: mailView.activeAlias

  // The address a message being written goes out from, for the line above the
  // box. The alias is a name this widget made up; the mailbox's own address is
  // what tells somebody which of several mailboxes they are writing from.
  readonly property string composeFrom: {
    var view = mailView.viewFor(mailView.composeAlias)
    return view && view.username !== "" ? String(view.username) : String(mailView.composeAlias)
  }

  readonly property string folderTitle: {
    if (!mailView.configured) return "Office 365"
    // Every mailbox on the same folder is the merged view, and naming one
    // mailbox's address there was the whole reason a window showing three
    // inboxes at once read as though it were showing one. It is also the state
    // the window opens in, so this was the usual case, not the corner.
    if (mailView.unifiedFolderName !== "")
      return mailView.unifiedFolderName + " — all mailboxes"
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

  // ---- folders as things that can be made and unmade ----------------------
  //
  // One at a time, over everything else, the way the move picker is. Naming a
  // folder needs a text field and the other two do not, which is the only
  // reason the modes are told apart anywhere below: while a field is up the
  // key catcher has to stand down or it eats what is being typed.

  property string folderAction: ""          // new | rename | move | delete
  property string folderActionAlias: ""
  property string folderActionId: ""        // the folder acted on; "" for a new one
  property string folderActionName: ""      // what it is called now
  // Where a new one would go. An offer rather than a decision: N asks for the
  // top level from the keyboard, and the prompt carries the same choice as a
  // toggle, because the pointer has no shift key on a pill.
  property string folderActionParentOffer: ""
  property string folderActionParentOfferName: ""
  property bool folderActionNestIn: true
  readonly property string folderActionParent: folderActionNestIn ? folderActionParentOffer : ""
  readonly property string folderActionParentName: folderActionNestIn ? folderActionParentOfferName : ""
  readonly property bool folderActing: folderAction !== ""
  readonly property bool folderNaming: folderAction === "new" || folderAction === "rename"
  readonly property var folderActionTargets: folderAction === "move"
    ? mailView.folderMoveTargetsFor(folderActionAlias, folderActionId) : []

  // Which folder these act on: the row under the sidebar cursor once the
  // keyboard has been in the tree, and otherwise whichever folder the mailbox
  // is reading. Never a header - those are mailboxes, not folders.
  //
  // A property rather than only a function, because the buttons beside the
  // tree fade themselves against it and a binding cannot follow a call.
  readonly property var cursorFolder: {
    var tree = folderPane
    if (!tree) return null
    var index = tree.cursorIndex >= 0 ? tree.cursorIndex : tree.selectedPickable
    if (index < 0 || index >= tree.pickable.length) return null
    return tree.rows[tree.pickable[index]] || null
  }

  function folderUnderCursor() {
    return cursorFolder
  }

  function startFolderAction(what, topLevel) {
    if (folderActing) return
    var row = folderUnderCursor()
    if (!row) return
    // The merged rows at the top of the tree are every mailbox's version of one
    // folder - see Model.folderRows - so there is no single folder there to
    // make, rename, move or delete. Said, rather than falling through to
    // "signed in for reading only", which is what a mailbox called "*" looks
    // like from canWrite.
    if (row.unifiedRow === true) {
      mailView.noteActionError("Pick a folder inside a mailbox - these rows are every mailbox at once")
      return
    }
    var alias = String(row.alias || "")
    // Read-only is a sign-in choice rather than a fault, and it is written
    // nowhere else on this screen - so it is said rather than done silently.
    if (!mailView.canWrite(alias)) {
      mailView.noteActionError("This mailbox is signed in for reading only")
      return
    }
    if (what !== "new" && row.isInbox === true) {
      mailView.noteActionError("The inbox cannot be renamed, moved or deleted")
      return
    }
    if (what !== "new" && String(row.id || "") === "") return
    if (what === "move" && mailView.folderMoveTargetsFor(alias, String(row.id)).length === 0) {
      mailView.noteActionError("There is nowhere else to put this folder")
      return
    }
    folderActionAlias = alias
    folderActionId = what === "new" ? "" : String(row.id)
    folderActionName = what === "new" ? "" : String(row.name || "")
    // A new folder goes inside the one under the cursor unless it is asked to
    // go to the top level - by N, or by turning the toggle off in the prompt.
    folderActionParentOffer = what === "new" ? String(row.id || "") : ""
    folderActionParentOfferName = what === "new" ? String(row.name || "") : ""
    folderActionNestIn = topLevel !== true
    folderAction = what
  }

  function cancelFolderAction() {
    folderAction = ""
  }

  // `text` is the typed name for new and rename; `parentId` is the picked
  // destination for a move. Both are ignored by the actions that have no use
  // for them, so there is one way out of the overlay rather than four.
  function commitFolderAction(text, parentId) {
    var what = folderAction
    var alias = folderActionAlias
    var id = folderActionId
    var parent = folderActionParent
    folderAction = ""
    if (what === "new") mailView.newFolder(alias, text, parent)
    else if (what === "rename") mailView.renameFolder(alias, id, text)
    else if (what === "move") mailView.moveFolder(alias, id, parentId)
    else if (what === "delete") mailView.deleteFolder(alias, id)
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
    if (folderAction === "move") return folderOverlay.item ? folderOverlay.item.scroller : null
    if (moving) return movePicker.item ? movePicker.item.scroller : null
    if (pane === "message" && mailView.previewMail !== null) return readerScroll
    // folderPicking rather than folderDrawer: a tree that was asked for and
    // had room to become a sidebar is drawn by the sidebar's copy, and the
    // keys have to act on the one on screen.
    if (pane === "folders") return columns.folderPicking ? drawerFolderScroll : folderScroll
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
    if (folderAction === "move") {
      if (folderOverlay.item && folderOverlay.item.tree) folderOverlay.item.tree.moveCursor(step)
      return
    }
    if (folderActing) return
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
    if (folderAction === "move") {
      if (folderOverlay.item && folderOverlay.item.tree) folderOverlay.item.tree.activateCursor()
      return
    }
    // Return on the warning is the yes. Escape is the no, and it is the key
    // that is already under everybody's finger.
    if (folderAction === "delete") { commitFolderAction("", ""); return }
    if (folderActing) return
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
  // ---- the coding agent ---------------------------------------------------
  //
  // Omarchy's own handover, pointed at a message: omarchy-agent starts
  // whichever agent was chosen with `omarchy default agent`, and handover.sh
  // writes the prompt. Nothing out of the mail goes into that prompt - not even
  // the subject - because the agent is told which message to read and reads it
  // through graph.py, the same helper this window uses. src/handover.sh says
  // why.
  //
  // Split in two so the fixtures can be checked without an agent starting.
  // Empty means there is nothing to hand over, or the setting says not to.
  function agentArgv() {
    if (!mailView.agentHandover || moving) return []
    // The message under the cursor when the list has the keyboard, the one
    // being read otherwise - the same choice flagging makes.
    var rows = mailView.mail
    var row = pane === "mail" && mailCursor >= 0 && mailCursor < rows.length
              ? rows[mailCursor]
              : mailView.previewMail
    if (!row) return []
    var alias = String(row.alias || "")
    return [pluginDir + "/handover.sh",
            "--account", alias,
            "--message", String(row.id || ""),
            "--folder", mailView.folderIdFor(alias)]
  }

  function askAgent() {
    var argv = agentArgv()
    if (argv.length === 0) return
    Quickshell.execDetached(argv)
  }

  // A draft reply an agent wrote, arriving from outside:
  //   omarchy-shell shell summon caseonline.omarchy.office365 '{"draft":{...}}'
  //   omarchy-shell shell call   caseonline.omarchy.office365 agentDraft '{...}'
  // It opens the reply box on that message with the text in it, unsent. Sending
  // stays a button a person presses, which is the whole reason this is a draft.
  property var agentDraftPending: null

  function agentDraft(argJson) {
    var payload = Model.parseJson(argJson, null)
    if (!payload) return "bad-json"
    agentDraftPending = payload.draft ? payload.draft : payload
    return flushAgentDraft()
  }

  // Held rather than applied when it arrives before the settings, or before the
  // folder it names has been read: the setting is what says whether a draft may
  // be taken at all, and the message has to be in hand before there is anything
  // to reply to.
  function flushAgentDraft() {
    if (!agentDraftPending) return "ok"
    if (!settingsLoaded) return "waiting"
    if (!mailView.agentHandover) { agentDraftPending = null; return "off" }
    var draft = agentDraftPending
    var text = String(draft.text || "")
    if (text === "") { agentDraftPending = null; return "empty" }

    var id = String(draft.messageId || "")
    var row = null
    if (id !== "") {
      var at = mailView.indexOfMail(id)
      if (at >= 0) row = mailView.mail[at]
    } else {
      row = mailView.previewMail
    }

    if (!row) {
      // Not in the list this window is holding. When the payload says which
      // mailbox the message is in, that folder can be fetched and this
      // answered again once it lands - which is what revealMessage arranges.
      var alias = String(draft.account || "")
      if (alias !== "" && id !== "") {
        mailView.selectFolder(alias, String(draft.folderId || ""))
        revealMessage(alias, id)
        return "waiting"
      }
      agentDraftPending = null
      return "no-message"
    }

    agentDraftPending = null
    // Even a draft is a write as far as Graph is concerned, so a read-only
    // mailbox cannot hold one. Saying so beats opening a reply box whose every
    // button would fail.
    if (!mailView.canWrite(row.alias)) return "read-only"

    if (!mailView.previewMail || String(mailView.previewMail.id) !== String(row.id))
      mailView.showPreview(row)
    var mode = String(draft.mode || "reply")
    if (mode !== "reply" && mode !== "reply-all" && mode !== "forward") mode = "reply"
    mailView.startCompose(mode, row)
    // After startCompose, which clears both.
    fillCompose(text)
    if (draft.to) mailView.composeTo = String(draft.to)
    return "ok"
  }

  // The reply box is rebuilt for each message, so the text has to reach both
  // the state it is kept in and the box itself when one is already open.
  function fillCompose(text) {
    mailView.composeText = String(text || "")
    if (composeBox.item && typeof composeBox.item.setBody === "function")
      composeBox.item.setBody(mailView.composeText)
  }

  // Writing a message that answers nothing. The mailbox is the one being read:
  // this window can carry several, and a fresh message has no row to say which
  // of them it should leave from.
  //
  // Any picker or half-written reply already on screen goes first - two things
  // wanting the same column is how one of them ends up drawn under the other.
  function startNewMessage() {
    if (folderActing || moving) return
    if (mailView.composing) mailView.cancelCompose()
    var alias = root.activeAlias
    if (alias === "" || !mailView.canWrite(alias)) return
    // The reading pane is where it is written, so what was in it stands aside
    // the same way it does for a meeting.
    mailView.closePreview()
    mailView.closeMeeting()
    folderDrawer = false
    mailView.startNewMessage(alias)
  }

  function flagAtCursor() {
    if (moving) return
    var rows = mailView.mail
    var row = pane === "mail" && mailCursor >= 0 && mailCursor < rows.length
              ? rows[mailCursor]
              : mailView.previewMail
    if (row && mailView.canWrite(row.alias)) mailView.flagMail(row, row.flagged !== true)
  }

  function deleteAtCursor() {
    // In the tree the delete key is about the folder under the cursor, which
    // is the only thing there to delete.
    if (folderActing) return
    if (pane === "folders") { startFolderAction("delete"); return }
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
    // Over everything, including the move picker, because it is the newest
    // thing on screen whenever it is there at all.
    if (folderActing) { cancelFolderAction(); return }
    // Over everything else, so it is the first layer Escape takes back.
    if (moving) { cancelMove(); return }
    // Innermost first. A half-written reply is the last thing that should go
    // when someone reaches for Escape.
    if (mailView.composing) { mailView.cancelCompose(); return }
    // A tree that was asked for is the layer Escape takes back first, whether
    // it ended up over the list or beside it.
    if (folderDrawer) { folderDrawer = false; pane = "mail"; return }
    // Back to the list with the message still open. Escape again closes it -
    // one rung at a time, rather than shutting the message outright.
    if (pane === "message") { pane = "mail"; return }
    if (mailView.previewMail !== null) { mailView.closePreview(); return }
    // The meeting opened for its details, then the one merely picked in the
    // grid. Back to the agenda before back out of the window.
    if (mailView.meetingOpen) { mailView.closeMeeting(); return }
    if (mailView.selectedEvent) { mailView.selectEvent(null); return }
    requestClose()
  }

  function pickFolder(alias, folderId) {
    // "*" is one of the merged rows at the top of the tree - see
    // Model.folderRows - and means this folder in every mailbox.
    if (String(alias) === "*") mailView.selectFolderEverywhere(folderId)
    else mailView.selectFolder(alias, folderId)
    // Only while the tree is covering the mail, where it stands between you
    // and the folder just picked. Beside the mail it is in nobody's way, and
    // taking it away at every click is what made picking a second folder mean
    // opening the tree all over again.
    if (columns.folderPicking) folderDrawer = false
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
      if (!visible) root.stopPaging()
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
      // Making and unmaking folders. Built fresh each time, like the move
      // picker below and for the same reasons: a prompt that opens holding the
      // name it was left with last time is a prompt that renames the wrong
      // folder the first time somebody presses Return without reading it.
      Loader {
        id: folderOverlay
        anchors.fill: parent
        active: root.folderActing
        z: 120

        sourceComponent: Rectangle {
          property alias tree: folderTree
          property alias scroller: folderTreeScroll

          readonly property bool imap: {
            var view = mailView.viewFor(root.folderActionAlias)
            return !!view && view.imap === true
          }
          readonly property string title: ({
            "new": root.folderActionParentName !== ""
                   ? ("New folder in " + root.folderActionParentName) : "New folder",
            "rename": "Rename " + root.folderActionName,
            "move": "Move " + root.folderActionName,
            "delete": "Delete " + root.folderActionName
          })[root.folderAction] || ""

          color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.97)

          // Clicking off it is the same as Escape: nothing is changed.
          MouseArea { anchors.fill: parent; onClicked: root.cancelFolderAction() }

          Column {
            id: folderPane2
            anchors.centerIn: parent
            width: Math.min(Style.space(440), parent.width - Style.spacing.xxl * 2)
            height: root.folderAction === "move"
              ? Math.min(Style.space(520), parent.height - Style.spacing.xxl * 2)
              : implicitHeight
            spacing: Style.spacing.md

            Text {
              width: parent.width
              text: parent.parent.title
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            // Inside the folder the cursor was on, or not. Only when there is
            // a folder to be inside: at the top of a tree there is no choice
            // to offer, and a toggle with one setting is furniture.
            FilterPill {
              visible: root.folderAction === "new" && root.folderActionParentOffer !== ""
              label: root.folderActionNestIn
                ? ("Inside " + root.folderActionParentOfferName) : "At the top level"
              selected: root.folderActionNestIn
              fg: Color.foreground
              dim: Qt.darker(Color.foreground, 1.5)
              accent: Color.accent
              fontFamily: Style.font.family
              onClicked: {
                root.folderActionNestIn = !root.folderActionNestIn
                folderName.forceActiveFocus()
              }
            }

            // What a name is typed into, and the one place Return means yes.
            TextField {
              id: folderName
              width: parent.width
              visible: root.folderNaming
              text: root.folderAction === "rename" ? root.folderActionName : ""
              placeholderText: "Folder name"
              foreground: Color.foreground
              accent: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              onAccepted: if (text.trim() !== "") root.commitFolderAction(text.trim(), "")
              Keys.onEscapePressed: root.cancelFolderAction()
              // Straight into it, and with the old name selected so typing
              // replaces it - renaming is usually a new word, not an edit.
              Component.onCompleted: {
                forceActiveFocus()
                selectAll()
              }
            }

            // What deleting one actually does, which is not the same thing on
            // the two transports and is not a question to answer afterwards.
            Text {
              width: parent.width
              visible: root.folderAction === "delete"
              text: parent.parent.imap
                ? "This deletes the folder and the mail in it. IMAP has no wastebasket for folders, so it does not come back."
                : "This puts the folder and everything in it in Deleted Items, where Outlook can take it back out."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Qt.darker(Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              width: parent.width
              visible: root.folderAction !== "move"
              text: root.folderAction === "delete"
                ? "Return deletes it. Escape leaves it alone."
                : "Return saves it. Escape leaves it alone."
              textFormat: Text.PlainText
              color: Qt.darker(Color.foreground, 1.8)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            ScrollView {
              id: folderTreeScroll
              width: parent.width
              height: parent.height - y
              visible: root.folderAction === "move"
              clip: true

              FolderList {
                id: folderTree
                width: folderPane2.width
                rows: root.folderActionTargets
                cursorIndex: 0
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                // The id is empty for the "Top level" row, which is exactly
                // what the helper wants for "no parent".
                onPicked: function(alias, folderId) { root.commitFolderAction("", folderId) }
              }
            }
          }
        }
      }

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
            agentHandover: mailView.agentHandover
            canFocus: mailView.canFocus
          }
        }
      }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        // While a reply is open the catcher stands down: it consumes plain
        // letter keys to drive the cursor, so leaving it armed would eat the
        // j, k, h and l out of whatever was being typed.
        // ...and while a folder is being named, for the same reason. The
        // other two folder prompts have no field to type into and keep the
        // catcher armed, so j/k still walk the destinations and Escape still
        // backs out through dismiss().
        blocked: mailView.composing || root.folderNaming
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
          if (root.moving || root.folderActing) {
            if (text === "g") root.scrollToEnd(view, false)
            else if (text === "G") root.scrollToEnd(view, true)
            return
          }
          // In the tree these letters are about folders; everywhere else the
          // same ones are about messages. The pane is what tells them apart,
          // which is how m already worked.
          if (root.pane === "folders") {
            if (text === "n") { root.startFolderAction("new", false); return }
            if (text === "N") { root.startFolderAction("new", true); return }
            if (text === "R") { root.startFolderAction("rename"); return }
            if (text === "m") { root.startFolderAction("move"); return }
            if (text === "x") { root.startFolderAction("delete"); return }
          }
          // Only where there is a split to filter on. A key that answers
          // nothing is indistinguishable from a key that is broken.
          if (text === "f") { if (mailView.canFocus) mailView.focusedOnly = !mailView.focusedOnly }
          else if (text === "u") mailView.unreadOnly = !mailView.unreadOnly
          else if (text === "t") mailView.threaded = !mailView.threaded
          else if (text === "r") mailView.refresh()
          else if (text === "m") root.moveAtCursor()
          else if (text === "a") root.askAgent()
          // c for compose, because r is Refresh here and always has been.
          else if (text === "c") root.startNewMessage()
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

              // Leading, because it is the only thing in this row that makes
              // something rather than filtering what is already there. Gone on
              // a read-only mailbox: even a draft is a write, so the button
              // would open a box that could not post.
              FilterPill {
                // A word, like the pills beside it. An icon here replaces the
                // label rather than joining it - see FilterPill - and the one
                // this had was a clock: F0954 is nf-md-clock_time_two, not the
                // pencil the comment claimed. Checked by drawing it.
                label: "Write"
                visible: mailView.configured && mailView.canWrite(root.activeAlias)
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onClicked: root.startNewMessage()
              }

              // With no sidebar there is nothing to click a folder in, and the
              // keys that reach the tree are not something to have to know
              // about. Only there when the tree is not.
              FilterPill {
                label: "Folders"
                // Keyed on the width, not on showSidebar: asking for the tree
                // makes showSidebar true, and this is the control that then
                // has to still be here to put it away again.
                visible: !columns.sidebarAlways && mailView.configured
                selected: root.folderDrawer
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onClicked: root.toggleFolderDrawer()
              }

              FilterPill {
                label: "Unread"
                // The count belongs on the pill that filters by it: "Unread"
                // alone made you turn the filter on to find out whether it was
                // worth turning on. Messages, which is what the list counts.
                detail: mailView.unreadCount > 0 ? String(mailView.unreadCount) : ""
                alert: mailView.unreadCount > 0
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
              // about. And in any mailbox that has no such split at all -
              // Outlook computes it server-side and only Graph hands it over,
              // so an IMAP mailbox has nothing to be on either side of.
              //
              // With one of each on screen the pill stays and names the
              // mailbox it cannot speak for: its mail is all still in the
              // list, and that is a surprise worth heading off.
              FilterPill {
                label: "Focused"
                detail: mailView.focusedOnly && mailView.unsplitMailboxes.length > 0
                        ? (mailView.unsplitMailboxes.join(", ") + ": all") : ""
                // Merged or not, the question is whether an inbox is what is
                // on screen: with every mailbox on its inbox that is more true
                // than ever, and reading it off one alias happened to give the
                // right answer only because that alias was on its inbox too.
                visible: (mailView.unifiedFolder !== ""
                          ? mailView.unifiedFolder === "inbox"
                          : mailView.folderIdFor(root.activeAlias) === "inbox")
                         && mailView.canFocus
                selected: mailView.focusedOnly
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onClicked: mailView.focusedOnly = !mailView.focusedOnly
              }

              FilterPill {
                icon: "\u{F0450}"   // nf-md-refresh
                label: "Refresh"     // still what the tooltip-less pill is named
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
            // Wide enough that the tree is simply always there.
            readonly property bool sidebarAlways: width >= Style.space(620)
            // Not that wide, but wide enough for the tree to stand beside the
            // mail rather than over it. So a tree that was asked for becomes a
            // real sidebar and the list gives up the width for it, which is
            // what stops the tree vanishing at every folder picked. 470 keeps
            // the list at roughly the 300 that counts as a column elsewhere in
            // here; below it there is no room for both and the tree has to
            // cover the mail.
            readonly property bool sidebarFits: width >= Style.space(470)
            readonly property bool showSidebar: sidebarAlways
              || (root.folderDrawer && sidebarFits)
            // The folder tree standing in for the columns, because there is no
            // room for it beside them.
            readonly property bool folderPicking: root.folderDrawer && !showSidebar
            // A window widened back out has its sidebar without being asked,
            // and no reason to be holding a tree open on top of that. Keyed on
            // the width alone: on showSidebar it would fire the instant the
            // tree was asked for and put it straight back away.
            onSidebarAlwaysChanged: if (sidebarAlways) root.folderDrawer = false
            readonly property real sidebarWidth: showSidebar
              ? Math.max(Style.space(170), Math.min(Style.space(260), width * 0.2)) : 0
            readonly property real rest: width
              - (showSidebar ? sidebarWidth + spacing * 2 + Style.space(1) : 0)
            readonly property bool showReader: rest >= Style.space(660)
            readonly property real listWidth: showReader
              ? Math.max(Style.space(300), Math.min(Style.space(440), rest * 0.42)) : rest
            readonly property real readerWidth: showReader
              ? rest - listWidth - spacing * 2 - Style.space(1) : rest
            // Whether the list is standing aside for the reading pane - or for
            // a message being written, which wants the same column and in a
            // window too narrow for two of them wants the list's.
            readonly property bool listGivesWay: !showReader
              && (mailView.previewMail !== null || mailView.composingNew)

            // The tree when there is no sidebar to put it in: the full width
            // of the window, over the mail, until a folder is picked or
            // Escape puts it away.
            Column {
              width: columns.width
              height: columns.height
              visible: columns.folderPicking
              spacing: Style.spacing.sm

              ScrollView {
                id: drawerFolderScroll
                width: parent.width
                height: parent.height - drawerTools.height - parent.spacing
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

              // The same tools the sidebar carries. A narrow window is where
              // the tree lives in this drawer rather than beside the mail, and
              // leaving them out of it would put folder actions behind a
              // window width.
              FolderTools {
                id: drawerTools
                width: parent.width
                visible: mailView.configured
                target: root.cursorFolder
                busy: mailView.folderBusy
                writable: !!root.cursorFolder && mailView.canWrite(root.cursorFolder.alias)
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onAct: function(what, topLevel) { root.startFolderAction(what, topLevel) }
              }
            }

            Column {
              id: sidebar
              width: columns.sidebarWidth
              height: columns.height
              visible: columns.showSidebar
              spacing: Style.spacing.sm

              ScrollView {
                id: folderScroll
                width: parent.width
                height: parent.height - folderTools.height - parent.spacing
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

              FolderTools {
                id: folderTools
                width: parent.width
                visible: mailView.configured
                target: root.cursorFolder
                busy: mailView.folderBusy
                writable: !!root.cursorFolder && mailView.canWrite(root.cursorFolder.alias)
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onAct: function(what, topLevel) { root.startFolderAction(what, topLevel) }
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

            // Scrolled to the end means "give me more". The list is a page of
            // the mailbox rather than all of it, and the next page is asked
            // for by reading rather than by pressing anything.
            //
            // Also when the page does not fill the column: a mailbox whose
            // first twenty rows leave white space below them can never be
            // scrolled, so it would sit there half full with more to give.
            function askForMore() {
              if (!listScroll.visible || !mailView.moreToLoad) return
              var flick = listScroll.contentItem
              if (!flick) return
              if (flick.contentHeight > flick.height
                  && flick.contentY + flick.height < flick.contentHeight - Style.space(320))
                return
              mailView.loadMore()
            }

            Connections {
              target: listScroll.contentItem
              function onContentYChanged() { columns.askForMore() }
              function onContentHeightChanged() { columns.askForMore() }
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

              // One definition of the box for the two places it opens: under
              // the message being answered, and alone in the column when there
              // is no message because it is being written from nothing. They
              // differ in where they sit and how tall the text is, not in what
              // the box does, so they share it rather than repeating thirty
              // lines of wiring twice and drifting apart.
              Component {
                id: composeForm

                ComposeBox {
                  width: columns.readerWidth
                  mode: mailView.composeMode
                  subject: mailView.composeMail ? String(mailView.composeMail.subject || "") : ""
                  fromAddress: root.composeFrom
                  needsRecipient: mailView.composeNeedsRecipient
                  needsSubject: mailView.composingNew
                  addressBook: mailView.addressBook
                  // A reply is a strip under the message it answers. A new
                  // message has the column to itself and no reason to be
                  // written through a slot.
                  bodyHeight: mailView.composingNew
                    ? Math.max(Style.space(160), columns.height - Style.space(320))
                    : Style.space(120)
                  canSend: mailView.canSend(mailView.composeAlias)
                  running: mailView.composeRunning
                  error: mailView.composeError
                  sendBlocked: mailView.composeSendBlocked
                  fg: Color.foreground
                  accent: Color.accent
                  fontFamily: Style.font.family
                  attachments: mailView.composeAttachments
                  onAttachRequested: function(path) { mailView.attachToCompose(path) }
                  onDetachRequested: function(index) { mailView.detachFromCompose(index) }
                  onToEdited: function(value) { mailView.composeTo = value }
                  onCcEdited: function(value) { mailView.composeCc = value }
                  onSubjectEdited: function(value) { mailView.composeSubject = value }
                  onBodyEdited: function(value) { mailView.composeText = value }
                  onSendRequested: mailView.submitCompose(false)
                  onDraftRequested: mailView.submitCompose(true)
                  onCancelRequested: mailView.cancelCompose()
                  onPermissionRequested: {
                    if (mailView.composeAlias !== "") mailView.startLogin(mailView.composeAlias, true)
                  }
                  initialBody: mailView.composeText
                  Component.onCompleted: {
                    if (initialBody !== "") setBody(initialBody)
                    Qt.callLater(focusFirst)
                  }
                }
              }

              // A message being written from nothing, where the agenda and a
              // meeting go: it is the thing being looked at, and the same
              // column is the only one wide enough to write in.
              ScrollView {
                anchors.fill: parent
                clip: true
                visible: mailView.composingNew

                Loader {
                  id: newMessageBox
                  width: columns.readerWidth
                  active: mailView.composingNew
                  sourceComponent: composeForm
                }
              }

              // Nothing open, so the column shows the calendar.
              //
              // It used to say "Select a message" at a column of empty space,
              // which is a whole third of a window spent on an instruction.
              // The bar's popup has had mail beside the agenda from the start
              // and the window - the bigger surface, the one people leave open
              // - had only the mail. So the agenda moves in here, and stands
              // aside for a message or a meeting exactly as it does there.
              Column {
                anchors.fill: parent
                spacing: Style.spacing.md
                visible: mailView.previewMail === null && !mailView.meetingOpen
                         && !mailView.composingNew

                Text {
                  width: parent.width
                  visible: text !== ""
                  text: {
                    if (mailView.switchingFolder) return "Opening " + root.folderTitle + "…"
                    return ""
                  }
                  textFormat: Text.PlainText
                  color: Qt.darker(Color.foreground, 1.8)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                ScrollView {
                  id: agendaScroll
                  width: parent.width
                  height: parent.height - y
                  clip: true

                  // The drawn grid where the setting asks for it and the column
                  // is wide enough to draw one - a three-day grid in 200 pixels
                  // is not a grid. Otherwise the day-grouped list, which reads
                  // perfectly well in a column.
                  readonly property bool grid: mailView.agendaView === "timeline"
                                               && columns.readerWidth >= Style.space(520)

                  AgendaTimeline {
                    width: agendaScroll.width
                    visible: agendaScroll.grid
                    grid: mailView.timeline
                    showAccount: mailView.combined
                    selectedEvent: mailView.selectedEvent
                    availableHeight: agendaScroll.height
                    fg: Color.foreground
                    accent: Color.accent
                    fontFamily: Style.font.family
                    onEventClicked: function(event) { mailView.selectEvent(event) }
                    onDetailsRequested: function(event) { mailView.showMeeting(event) }
                    onExpandRequested: mailView.expandWindow()
                    onOpenRequested: function(url, alias) { mailView.openUrl(url, alias) }
                    onJoinRequested: function(url, alias) { mailView.openUrl(url, alias) }
                  }

                  AgendaList {
                    width: agendaScroll.width
                    visible: !agendaScroll.grid
                    agenda: mailView.agenda
                    showAccount: mailView.combined
                    fg: Color.foreground
                    accent: Color.accent
                    fontFamily: Style.font.family
                    onOpenRequested: function(url, alias) { mailView.openUrl(url, alias) }
                    onJoinRequested: function(url, alias) { mailView.openUrl(url, alias) }
                    onEventClicked: function(event) { mailView.showMeeting(event) }
                  }
                }
              }

              // The meeting being read, in the same column, for the same
              // reason the reading pane is here: it is the thing being looked
              // at, and answering an invitation is not a popup's job.
              ScrollView {
                anchors.fill: parent
                clip: true
                visible: mailView.meetingOpen

                MeetingPane {
                  width: columns.readerWidth
                  event: mailView.openMeeting
                  detail: mailView.meetingDetail
                  loading: mailView.meetingLoading
                  error: mailView.meetingError
                  answering: mailView.answeringMeeting
                  answerError: mailView.meetingAnswerError
                  // A window is taller than a dropdown, so the invitation gets
                  // to use that height.
                  maxBodyHeight: Math.max(Style.space(220), columns.height - Style.space(320))
                  fg: Color.foreground
                  accent: Color.accent
                  fontFamily: Style.font.family
                  onCloseRequested: mailView.closeMeeting()
                  onOpenRequested: function(url) {
                    mailView.openUrl(url, mailView.meetingAlias(mailView.openMeeting))
                  }
                  onJoinRequested: function(url) {
                    mailView.openUrl(url, mailView.meetingAlias(mailView.openMeeting))
                  }
                  onLinkActivated: function(url) {
                    mailView.openUrl(url, mailView.meetingAlias(mailView.openMeeting))
                  }
                  onAnswerRequested: function(reply) { mailView.answerMeeting(reply, "") }
                }
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
                  canAgent: mailView.agentHandover
                  onAgentRequested: root.askAgent()
                  onCloseRequested: mailView.closePreview()
                  onOpenRequested: mailView.openPreviewed()
                  onMarkRequested: function(read) { mailView.markPreviewed(read) }
                  onFlagRequested: function(flagged) { mailView.flagPreviewed(flagged) }
                  onDeleteRequested: mailView.deletePreviewed()
                  onMoveRequested: root.startMove(mailView.previewMail)
                  onWriteAccessRequested: {
                    if (mailView.previewMail) mailView.startLogin(mailView.previewMail.alias, true)
                  }
                  onLoadImagesRequested: mailView.loadPreviewImages()
                  htmlAlways: mailView.htmlAlways
                  senderHtml: mailView.senderAllowsHtml(mailView.previewMail)
                  htmlShown: mailView.previewIsHtml
                  htmlAvailable: mailView.previewHasHtml
                  htmlAuto: mailView.previewHtmlAuto
                  onShowHtmlRequested: mailView.showPreviewHtml()
                  onShowTextRequested: mailView.showPreviewText()
                  onAllowHtmlSenderRequested: mailView.allowHtmlFromSender()
                  onStopHtmlSenderRequested: mailView.stopHtmlFromSender()
                }
              }

                // Rebuilt for each message rather than kept and cleared, so a
                // reply can never open holding what was typed at the last one.
                // Only the three answering modes: a message that answers
                // nothing has no message to sit under, and is loaded into the
                // column above instead.
                Loader {
                  id: composeBox
                  width: parent.width
                  active: mailView.composing && !mailView.composingNew
                  visible: active
                  sourceComponent: composeForm
                }
              }
            }
          }
        }
      }
    }
  }
}
