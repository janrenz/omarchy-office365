import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// One host's view of the mailboxes: the bar widget has one, the window has
// another, and a bar surface per monitor means one more of these each.
//
// The data itself is not here. It lives in Store.qml, one per plugin for the
// whole shell, and this registers what it needs and reads the answers back
// out - so several hosts on the same mailbox share one fetch and one optimistic
// overlay instead of each polling Graph on a timer of its own.
//
// What stays here is what belongs to one host: which widget's settings it is
// working from, the filters, the folder each mailbox is showing, the message
// being read, and a reply being written. Two hosts looking at different
// folders, or one filtered and one not, is the point rather than a problem.
//
// Everything a host's UI touches is still on this object, under the names it
// always had. That the fetching moved is not something Panel.qml or the window
// has to know.
Item {
  id: root

  property var settings: ({})
  property string pluginDir: ""
  property color fallbackColor: "#7aa2f7"

  // ---- the shared store -----------------------------------------------
  //
  // Handed in by the host: the window gets it from the shell's service loader,
  // the bar widget asks `bar.shell` for it. A shell too old to know about
  // service plugins hands over nothing, and then this makes a private one and
  // behaves exactly as it did before there was anything to share.
  property var store: null
  property var localStore: null
  readonly property var hub: store ? store : localStore

  Component {
    id: storeComponent
    Store {}
  }

  Timer {
    // Not immediately: the host injects the shared store a beat after this is
    // built, and a private store made in that gap would fetch everything once
    // for nothing before being thrown away.
    id: fallbackDelay
    interval: 1200
    repeat: false
    running: !root.store && !root.localStore
    onTriggered: if (!root.store && !root.localStore) root.localStore = storeComponent.createObject(root)
  }

  onStoreChanged: {
    if (!store || !localStore) return
    localStore.destroy()
    localStore = null
  }

  // ---- configuration --------------------------------------------------

  // v2 stores a list of mailboxes. A v1 entry has a single "account" string
  // with its per-mailbox keys at the top level; fold that into a one-element
  // list so existing setups keep working untouched.
  readonly property var accountConfigs: {
    var list = Model.arrayFrom(settings ? settings["accounts"] : undefined)
    if (list.length > 0) {
      var cleaned = []
      for (var i = 0; i < list.length; i++) {
        if (list[i] && String(list[i].account || "").trim() !== "") cleaned.push(list[i])
      }
      return cleaned
    }
    var legacy = String(setting("account", "")).trim()
    if (legacy === "") return []
    return [{
      account: legacy,
      short: setting("short", ""),
      color: setting("color", ""),
      webUrl: setting("webUrl", ""),
      openCommand: setting("openCommand", ""),
      focusMatch: setting("focusMatch", ""),
      clientId: setting("clientId", ""),
      authority: setting("authority", ""),
      transport: setting("transport", "")
    }]
  }

  readonly property var aliases: {
    var list = []
    for (var i = 0; i < accountConfigs.length; i++) {
      var alias = String(accountConfigs[i].account || "").trim()
      if (alias !== "") list.push(alias)
    }
    return list
  }

  readonly property int mails: intSetting("mails", 5, 1, 25)

  // How long the list actually is.
  //
  // `mails` is the bar's own list, where seven is plenty and twenty is a wall.
  // A window is a different question: it opens on a page of `mailPage` and
  // asks for another every time it is scrolled to the end, up to `mailCeiling`
  // - past which asking for more is asking the helper to read the whole
  // mailbox again on every poll, and search is the better tool for that.
  //
  // One number for both the fetch and the cap on what is drawn, so the list
  // never shows fewer rows than were paid for.
  readonly property int mailPage: 20
  readonly property int mailCeiling: 100
  // Zero until a host asks for a page rather than the setting's worth, and
  // back to zero when it closes: the fetch is shared, so a window left paged
  // to a hundred would keep the bar's poll reading a hundred as well.
  property int paged: 0
  readonly property int wantedMails: Math.max(mails, Math.min(paged, mailCeiling))

  // Whether there is any point asking for more. A mailbox that handed back a
  // full page probably has more behind it; one that did not has been read to
  // the end, and a spinner at the bottom of it would never stop.
  readonly property bool moreToLoad: {
    if (wantedMails >= mailCeiling) return false
    for (var i = 0; i < filteredViews.length; i++)
      if ((filteredViews[i].mail || []).length >= wantedMails) return true
    return false
  }

  // The window opens on a page rather than on the bar's seven.
  function openPage() {
    if (paged < mailPage) paged = mailPage
  }

  // ...and asks for one more page when it is scrolled to the end. Refreshing
  // rather than appending: the store fetches the newest `wantedMails` per
  // mailbox in one call, so a longer list is one longer fetch rather than a
  // second one to stitch on - which also means the rows above cannot drift out
  // of order while the page below them arrives.
  function loadMore() {
    if (!moreToLoad || loading) return
    paged = Math.min(mailCeiling, wantedMails + mailPage)
    refresh()
  }
  readonly property string calendarMode: String(setting("calendar", "3day"))
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 180, 60, 3600)
  readonly property bool notifyOnNew: setting("notify", true) !== false
  readonly property bool pausePolling: setting("pausePolling", true) !== false
  readonly property bool dedupeEvents: setting("dedupeEvents", true) !== false
  // Off unless asked for: turning it on is what makes the plugin want
  // permission to change mail, and the default stays read-only.
  readonly property bool markReadOnOpen: setting("markReadOnOpen", false) === true
  // Whether the coding-agent handover is on offer at all. Off takes away the a
  // key, the button, and the route an agent uses to hand a draft reply back -
  // see the README's "Your coding agent" section.
  readonly property bool agentHandover: setting("agentHandover", true) !== false
  readonly property bool previewLine: setting("previewLine", true) !== false
  // Keep every message's own formatting - headings, lists, tables, links -
  // without being asked. Off, and meant to stay off: a reading pane is for
  // reading, and a sender's layout is mostly the sender's business. What is
  // left instead is a button on the message, and a way to say "always from
  // this one". Everything that would fetch or run is stripped in graph.py
  // before any markup gets near the pane, on all three paths.
  readonly property bool htmlAlways: setting("htmlBody", false) === true
  // The senders whose mail opens formatted, as the reading pane's "Always
  // from this sender" button leaves them. A widget setting rather than
  // something under ~/.local/state: it is a preference, it belongs beside the
  // rest of them, and it is then editable and clearable from the shell's
  // settings panel like anything else.
  readonly property var htmlSenders: Model.addressList(setting("htmlSenders", ""))

  function senderAllowsHtml(mail) {
    if (!mail) return false
    var address = String(mail.fromAddress || "").trim().toLowerCase()
    return address !== "" && htmlSenders.indexOf(address) >= 0
  }
  // Whether the panel opens already narrowed to Outlook's Focused mail.
  readonly property bool focusedByDefault: setting("focusedByDefault", false) === true
  // The same for the unread filter, for a widget you keep as an inbox rather
  // than as a record of everything that arrived.
  readonly property bool unreadByDefault: setting("unreadByDefault", false) === true
  // Group the list by conversation. A view rather than a setting: it is set by
  // whichever host can draw it and left alone by the ones that cannot, so it
  // is deliberately not read from the widget's configuration.
  property bool threaded: false
  // The agenda as a day-grouped list or as a drawn time grid. The list is the
  // default until the grid has earned it.
  readonly property string agendaView: String(setting("agendaView", "list")) === "timeline" ? "timeline" : "list"
  readonly property int dayStartMinutes: Model.minutesFromClock(setting("dayStart", "07:00"), 7 * 60)
  readonly property int dayEndMinutes: Model.minutesFromClock(setting("dayEnd", "22:00"), 22 * 60)
  readonly property bool showWeekends: setting("showWeekends", true) !== false
  readonly property bool demo: setting("demo", false) === true
  readonly property bool configured: accountConfigs.length > 0
  readonly property bool combined: accountConfigs.length > 1

  // ---- subscription ---------------------------------------------------
  //
  // What this host wants fetched. The store merges it with every other host's
  // and asks Graph once for the union.

  property string token: ""

  readonly property var request: ({
    aliases: aliases,
    folders: selectedFolders,
    mails: wantedMails,
    days: Model.calendarDays(calendarMode),
    demo: demo,
    intervalSec: refreshIntervalSec,
    // Asked for per host, answered once by the store: the widget and the
    // window watching the same inbox share one fetch, so they must also share
    // one announcement of what that fetch found.
    notify: notifyOnNew,
    // Whether this host is content for the store to stop polling while nobody
    // is at the machine. One host saying no is enough to keep it polling - the
    // fetch is shared, so the most demanding subscriber decides.
    pausePolling: pausePolling
  })

  function syncRequest() {
    if (!hub) return
    if (token === "") token = hub.claim()
    hub.put(token, configured ? request : null)
  }

  onRequestChanged: syncRequest()
  onHubChanged: {
    // A store this host has not registered with yet, so the old token means
    // nothing to it.
    token = ""
    syncRequest()
  }

  Component.onDestruction: if (hub && token !== "") hub.release(token)

  // ---- state ----------------------------------------------------------

  // The mailboxes this host is showing, in the folder it is showing them in,
  // shaped as the snapshot the model has always been given. Null until the
  // first of them answers, so a first load still reads as loading rather than
  // as a set of empty mailboxes.
  readonly property var snapshot: {
    if (!hub) return null
    var accounts = []
    var answered = false
    for (var i = 0; i < aliases.length; i++) {
      var data = hub.dataFor(aliases[i], folderIdFor(aliases[i]))
      if (!data) continue
      accounts.push(data)
      answered = true
    }
    return answered ? { ok: true, accounts: accounts } : null
  }

  // The theme's named colours, for resolving a mailbox's "blue" or "magenta".
  // Not called `palette`: this is an Item, and QQuickItem has a palette of its
  // own that a property of that name would shadow.
  readonly property var themePalette: hub ? hub.themePalette : ({})

  // Why the store is not polling, when it is not. Empty while it is.

  readonly property string pollReason: hub ? hub.pollReason : ""


  readonly property bool loading: {
    if (!hub) return false
    for (var i = 0; i < aliases.length; i++)
      if (hub.loadingFor(aliases[i], folderIdFor(aliases[i]))) return true
    return false
  }

  // The helper itself having failed, as opposed to a mailbox answering with a
  // problem of its own - those live inside the snapshot and are drawn per
  // mailbox. The first one is enough: the panel shows one line either way.
  readonly property var fetchError: {
    if (!hub) return null
    for (var i = 0; i < aliases.length; i++) {
      var problem = hub.errorFor(aliases[i], folderIdFor(aliases[i]))
      if (problem) return problem
    }
    return null
  }

  // A sign-in that failed says so here too, since it is the same banner.
  readonly property string errorCode: {
    if (hub && hub.loginErrorCode !== "") return hub.loginErrorCode
    return fetchError ? String(fetchError.code) : ""
  }

  readonly property string errorMessage: {
    if (hub && hub.loginErrorCode !== "") return hub.loginErrorMessage
    return fetchError ? String(fetchError.message) : ""
  }

  property bool saving: false
  property string saveError: ""
  signal settingsSaved()

  // Mailboxes whose sign-in just landed and whose first fetch is still in
  // flight. They are signed in but have no data yet, which is neither of the
  // states the panel would otherwise show.
  readonly property var busy: hub ? hub.busy : ({})

  // ---- derived --------------------------------------------------------

  readonly property var views: Model.accountViews(accountConfigs, snapshot, themePalette, fallbackColor, busy, loading)

  // Partial failures inside mailboxes that did answer. Taken from every
  // mailbox rather than the filtered ones: a calendar nobody can read is still
  // unreadable while you are looking at another account.
  readonly property var warnings: Model.collectWarnings(views)

  // View filters. Deliberately not persisted: they are a way to look at the
  // panel right now, and both reset when it is reopened.
  property string filterAlias: ""
  property bool unreadOnly: false
  property bool focusedOnly: false

  // Settings arrive after this object is built, so pick the defaults up when
  // they resolve rather than only at construction. Never Focused-only where
  // there is no such split to be on the right side of.
  onFocusedByDefaultChanged: focusedOnly = focusedByDefault && canFocus
  onUnreadByDefaultChanged: unreadOnly = unreadByDefault

  function toggleFilter(alias) {
    filterAlias = filterAlias === alias ? "" : alias
  }

  function clearFilters() {
    filterAlias = ""
    unreadOnly = unreadByDefault
    focusedOnly = focusedByDefault && canFocus
    selectedEvent = null
    expandedStart = -1
    expandedEnd = -1
    closePreview()
    // Only what this host was holding open. The read and deleted overrides are
    // shared with every other host now, and are retired against the server as
    // each fetch lands rather than by anyone closing a panel.
    held = ({})
  }

  // ---- reading pane ---------------------------------------------------

  // The message being read, its fetched body, and the state of getting it.
  // Bodies are far too big to carry in the list fetch, so one is pulled only
  // when a message is opened - by the store, which keeps it, so opening the
  // same message in the window that was just read in the bar costs nothing.
  property var previewMail: null
  property var previewDetail: null
  property bool previewLoading: false
  property string previewError: ""
  // The body this host is waiting for, so an answer to somebody else's request
  // - or to one this host has since moved on from - is ignored.
  property string previewKey: ""
  // Whether the pictures on the sender's servers were asked for, for the one
  // message being read. Reset by every other way into the pane.
  property bool previewImages: false
  // The reader's choice about markup for this one message: "" until they make
  // one, then "html" or "text". Overrides both the setting and the sender
  // list, in either direction, and is forgotten with the message.
  property string previewHtmlChoice: ""

  // What to ask graph.py for. "auto" is the ordinary case: the plain-text
  // part where the message has one, its own markup where it has none, since
  // flattening a message that was only ever markup produces a pane of
  // run-together link labels rather than a letter.
  function bodyModeFor(mail) {
    if (previewHtmlChoice === "html" || previewHtmlChoice === "text") return previewHtmlChoice
    return (htmlAlways || senderAllowsHtml(mail)) ? "html" : "auto"
  }

  // Whether the body on screen is the message's own markup, as opposed to
  // markup this plugin built out of its plain text.
  readonly property bool previewIsHtml: !!previewDetail
                                        && String(previewDetail.bodyFormat || "") === "html"
  // Whether there is any markup to offer. Absent from an older answer, and on
  // the Graph path a "probably" rather than a fact - see cmd_message.
  readonly property bool previewHasHtml: !!previewDetail && previewDetail.hasHtml !== false
  // Whether the markup on screen was chosen for the reader because the message
  // carried no plain-text part at all.
  readonly property bool previewHtmlAuto: !!previewDetail && previewDetail.htmlAuto === true

  function showPreview(mail) {
    if (!mail || !mail.id) return
    // Clicking the message already open closes it, the same way the filter
    // pills toggle.
    if (previewMail && previewMail.id === mail.id) {
      closePreview()
      return
    }
    // One pane, one thing in it - see showMeeting.
    closeMeeting()
    previewMail = mail
    holdOnly(mail.id)
    previewDetail = null
    previewError = ""
    if (!hub) {
      previewLoading = false
      previewError = "Nothing to read this message with yet"
      return
    }
    previewImages = false
    previewHtmlChoice = ""
    previewLoading = true
    previewKey = hub.requestBody(mail.alias, mail.id, bodyModeFor(mail), demo, false)
  }

  // Re-read the message being read, in whatever way the reader has just asked
  // for. The store keys its cache by mode, so going back to one already seen
  // costs nothing and the pane does not blink.
  function refetchPreview() {
    if (!previewMail || !hub) return
    previewLoading = true
    previewError = ""
    previewKey = hub.requestBody(previewMail.alias, previewMail.id,
                                 bodyModeFor(previewMail), demo, previewImages)
  }

  // Show this message as its sender wrote it, or go back to the words. For
  // this message only: the choice dies with it, which is what makes it a
  // button rather than a setting.
  function showPreviewHtml() {
    if (!previewMail) return
    previewHtmlChoice = "html"
    refetchPreview()
  }

  function showPreviewText() {
    if (!previewMail) return
    previewHtmlChoice = "text"
    // Remote pictures were a decision about a message that is no longer on
    // screen in the form they were fetched for, and there is nowhere to put
    // them in a plain-text body anyway.
    previewImages = false
    refetchPreview()
  }

  // The same, remembered for everyone at this address. Written into
  // shell.json, so it outlives the shell - and the pane switches at once
  // rather than waiting for the save to come back round, since a button that
  // does nothing for a second reads as a button that did not work.
  function allowHtmlFromSender() {
    if (!previewMail) return
    var address = String(previewMail.fromAddress || "").trim().toLowerCase()
    if (address === "") return
    var next = htmlSenders.slice()
    if (next.indexOf(address) < 0) next.push(address)
    saveSettings({ htmlSenders: Model.addressListText(next) })
    previewHtmlChoice = "html"
    refetchPreview()
  }

  function stopHtmlFromSender() {
    if (!previewMail) return
    var address = String(previewMail.fromAddress || "").trim().toLowerCase()
    var next = []
    for (var i = 0; i < htmlSenders.length; i++)
      if (htmlSenders[i] !== address) next.push(htmlSenders[i])
    // An empty string removes the key, which is how config.py spells "back to
    // the default" - see its module docstring.
    saveSettings({ htmlSenders: Model.addressListText(next) })
    // "text" rather than "no choice": the save is another process and the new
    // settings reach this object well after it returns, so leaving the choice
    // empty would re-read the sender list that still has this address in it
    // and put the message straight back the way it was.
    previewHtmlChoice = "text"
    previewImages = false
    refetchPreview()
  }

  // Go back for the pictures this message points at on somebody else's server.
  //
  // Per message and never remembered: the reader decides about this sender,
  // this once. Anything stickier would be a setting, and a setting that says
  // "tell every mailing list when I open their mail" is not one this offers.
  function loadPreviewImages() {
    if (!previewMail || !hub || previewImages) return
    previewImages = true
    previewLoading = true
    previewError = ""
    previewKey = hub.requestBody(previewMail.alias, previewMail.id,
                                 bodyModeFor(previewMail), demo, true)
  }

  function closePreview() {
    previewImages = false
    previewHtmlChoice = ""
    holdOnly("")
    previewMail = null
    previewDetail = null
    previewError = ""
    previewLoading = false
    previewKey = ""
  }

  Connections {
    target: root.hub

    function onBodyReady(cacheKey, detail) {
      if (cacheKey !== root.previewKey) return
      root.previewLoading = false
      root.previewDetail = detail
      root.previewError = ""
      // Only after the message really opened, and only where it was asked for
      // and permitted.
      if (root.markReadOnOpen && root.previewMail && root.previewMail.read !== true
          && root.canWrite(root.previewMail.alias))
        root.markMessage(root.previewMail.id, root.previewMail.alias, true)
    }

    function onBodyFailed(cacheKey, message) {
      if (cacheKey !== root.previewKey) return
      root.previewLoading = false
      root.previewError = message
    }

    function onMessageDeleted(id, alias) {
      root.afterRemoval(id)
    }

    function onMessageMoved(id, alias) {
      root.afterRemoval(id)
    }
  }

  readonly property string actionError: hub ? hub.actionError : ""
  readonly property string actionNotice: hub ? hub.actionNotice : ""
  readonly property bool actionRunning: hub ? hub.actionRunning : false

  function markMessage(id, alias, read) {
    if (!id || !hub || !canWrite(alias)) return
    hub.markMessage(id, alias, read)
  }

  function markPreviewed(read) {
    if (!previewMail) return
    markMessage(previewMail.id, previewMail.alias, read)
  }

  // Flagging works on any row, the way deleting and moving do: the list offers
  // it under the cursor and the reading pane offers it for what is open.
  function flagMail(row, flagged) {
    if (!row || !hub || !canWrite(row.alias)) return
    hub.flagMessage(row.id, row.alias, flagged)
  }

  function flagPreviewed(flagged) {
    flagMail(previewMail, flagged)
  }

  function indexOfMail(id) {
    for (var i = 0; i < mail.length; i++) if (String(mail[i].id) === String(id)) return i
    return -1
  }

  // Deleting works on any row, not only the one being read: the list offers
  // it directly, and so does the keyboard.
  function deleteMail(row) {
    if (!row || !hub || !canWrite(row.alias)) return
    hub.deleteMessage(row.alias, row.id)
  }

  function deletePreviewed() {
    deleteMail(previewMail)
  }

  // Filing a message somewhere else. Like deleting, this works on any row
  // rather than only on the one being read.
  function moveMail(row, folderId, folderName) {
    if (!row || !hub || !canWrite(row.alias)) return
    hub.moveMessage(row.alias, row.id, folderId, folderName)
  }

  function movePreviewed(folderId, folderName) {
    moveMail(previewMail, folderId, folderName)
  }

  // Where a message in this mailbox could go: its own folder tree, less the
  // folder it is already in.
  function moveTargetsFor(alias) {
    return Model.moveTargets(views, String(alias || ""), folderIdFor(alias))
  }

  // ---- folders as things that can be made and unmade --------------------

  readonly property bool folderBusy: hub ? hub.folderBusy : false

  // Something a host refused to do, said where every other action failure is
  // said. A window that does nothing when a key is pressed is a window that
  // looks broken, even when not doing it was the right answer.
  function noteActionError(message) {
    if (hub) hub.actionError = String(message || "")
  }

  // Where a folder could be put: the same tree, less itself and everything
  // inside it, plus the top level.
  function folderMoveTargetsFor(alias, folderId) {
    return Model.folderMoveTargets(views, String(alias || ""), String(folderId || ""))
  }

  function newFolder(alias, name, parentId) {
    if (!hub || !canWrite(alias) || String(name || "").trim() === "") return
    hub.folderAction(String(alias), "new", "", String(name).trim(), String(parentId || ""))
  }

  function renameFolder(alias, folderId, name) {
    if (!hub || !canWrite(alias) || !folderId || String(name || "").trim() === "") return
    hub.folderAction(String(alias), "rename", String(folderId), String(name).trim(), "")
  }

  function moveFolder(alias, folderId, parentId) {
    if (!hub || !canWrite(alias) || !folderId) return
    hub.folderAction(String(alias), "move", String(folderId), "", String(parentId || ""))
  }

  function deleteFolder(alias, folderId) {
    if (!hub || !canWrite(alias) || !folderId) return
    hub.folderAction(String(alias), "delete", String(folderId), "", "")
  }

  // A folder that was being read and is now renamed, moved or gone leaves this
  // host pointing at an id that means nothing. On IMAP a folder id is its path,
  // so a rename changes it; on Graph it survives. Either way the fetch that
  // follows would fall back to the inbox and the sidebar would say the mailbox
  // is somewhere it is not.
  Connections {
    target: hub
    ignoreUnknownSignals: true
    function onFolderChanged(alias, action, folderId, was) {
      if (was === "" || folderIdFor(alias) !== was) return
      if (action === "delete") selectFolder(alias, "inbox")
      else if (folderId !== "" && folderId !== was) selectFolder(alias, folderId)
    }
  }

  // Every host hears about every message that leaves the folder it is reading,
  // deleted or moved, including the one that asked for it. Carry on down the
  // list rather than dropping back to the agenda - but only where the message
  // that left was the one being read here. A row deleted in the window while
  // the bar was reading something else must not move the bar's pane.
  function afterRemoval(id) {
    if (!previewMail || String(previewMail.id) !== String(id)) return
    // The row is still listed at this moment; the store hides it as soon as
    // this returns. The message that takes its place is then the one at the
    // index this one is leaving.
    var at = indexOfMail(id)
    Qt.callLater(function() {
      var next = Model.nextAfterRemoval(root.mail, at)
      if (next) root.showPreview(next)
      else root.closePreview()
    })
  }

  // Outlook Web on this message where the transport can name it, and on the
  // mailbox otherwise. Only Graph mints a per-message web address - an IMAP
  // mailbox reports webLinks false and every message carries an empty one - so
  // without the fallback this button did nothing at all on those accounts,
  // which reads as a broken app rather than as a missing capability.
  function openPreviewed() {
    if (!previewMail) return
    var link = String((previewDetail && previewDetail.webLink) || previewMail.webLink || "").trim()
    if (link === "") link = webUrlFor(previewMail.alias)
    openUrl(link, previewMail.alias)
  }

  // Where this mailbox lives on the web. Shared with focusApp so the button
  // and the bar icon cannot disagree about it.
  function webUrlFor(alias) {
    var config = alias ? configFor(alias) : (accountConfigs.length > 0 ? accountConfigs[0] : null)
    return String((config && config.webUrl) || "https://outlook.office.com/mail/")
  }

  readonly property var filteredViews: {
    if (filterAlias === "") return views
    var kept = []
    for (var i = 0; i < views.length; i++) if (views[i].alias === filterAlias) kept.push(views[i])
    return kept
  }

  // Whether Focused/Other means anything for what is on screen. Any rather
  // than every: with a Graph mailbox and an IMAP one both showing, the filter
  // still does something to half the list - and unsplitMailboxes names the
  // half it cannot speak for, so nobody is left wondering why mail they did
  // not ask for is still there.
  readonly property bool canFocus: {
    for (var i = 0; i < filteredViews.length; i++)
      if (filteredViews[i].canFocus === true) return true
    return false
  }

  readonly property var unsplitMailboxes: {
    var out = []
    for (var i = 0; i < filteredViews.length; i++)
      if (filteredViews[i].canFocus !== true)
        out.push(String(filteredViews[i].short || filteredViews[i].alias))
    return out
  }

  // A filter that cannot mean anything must not be left switched on: a lit
  // pill over an unfiltered list is worse than no pill at all.
  onCanFocusChanged: if (!canFocus) focusedOnly = false

  // Exactly one message is held in the unread view at a time: the one open
  // here. Unlike the read and deleted overrides this is not shared, because
  // which message a host is reading is the host's own business.
  property var held: ({})

  // What the user has done that the server has not confirmed yet, keyed by
  // message id - the shared read, flagged and deleted overrides, plus this
  // host's held row. Keyed by id rather than by whatever is open, so a slow
  // reply about one message can never land on another.
  readonly property var mailState: ({
    read: hub ? hub.overrides.read : ({}),
    flagged: hub ? hub.overrides.flagged : ({}),
    deleted: hub ? hub.overrides.deleted : ({}),
    held: held
  })

  // The state the list is actually built from: the pending changes above, plus
  // the row being read so it keeps its place in the list.
  readonly property var listState: ({
    read: mailState.read,
    flagged: mailState.flagged,
    deleted: mailState.deleted,
    held: mailState.held,
    pinned: previewMail
  })

  function holdOnly(id) {
    var next = {}
    if (id) next[String(id)] = true
    held = next
  }

  // ---- composing ------------------------------------------------------
  //
  // One message at a time, held here rather than in the window so that closing
  // the window mid-reply does not throw the text away.
  //
  // Two ways out, because they need different permission. Sending needs
  // Mail.Send, which a mailbox signed in for reading and writing does not
  // have; leaving a draft needs only Mail.ReadWrite, which it does. So the
  // draft is always offered and Send appears when the mailbox can.
  property string composeMode: ""
  property var composeMail: null
  property string composeTo: ""
  property string composeText: ""
  property bool composeRunning: false
  property string composeError: ""
  property string composeNotice: ""

  readonly property bool composing: composeMode !== ""
  readonly property bool composeNeedsRecipient: composeMode === "forward"

  function canSend(alias) {
    var view = viewFor(String(alias || ""))
    return !!view && view.send === true
  }

  // Files to attach, as paths. Per host rather than in the store: two windows
  // writing two replies are writing two different messages, and the store's
  // job is what they must agree on.
  property var composeAttachments: []

  function attachToCompose(path) {
    var file = String(path || "").trim()
    if (!composing || file === "") return
    // The same file twice is a mistake, not a request - Outlook would send it
    // twice under the same name.
    if (composeAttachments.indexOf(file) !== -1) return
    var next = composeAttachments.slice()
    next.push(file)
    composeAttachments = next
    composeError = ""
  }

  function detachFromCompose(index) {
    if (index < 0 || index >= composeAttachments.length) return
    var next = composeAttachments.slice()
    next.splice(index, 1)
    composeAttachments = next
  }

  function startCompose(mode, mail) {
    if (!mail) return
    composeMode = String(mode || "reply")
    composeMail = mail
    composeTo = ""
    composeText = ""
    composeAttachments = []
    composeError = ""
    composeNotice = ""
  }

  function cancelCompose() {
    composeMode = ""
    composeMail = null
    composeTo = ""
    composeText = ""
    composeAttachments = []
    composeError = ""
  }

  // asDraft: build it in Outlook and open it there, rather than sending from
  // here. Also the fallback when the mailbox may not send.
  function submitCompose(asDraft) {
    if (!composing || composeRunning || !composeMail || pluginDir === "") return
    var alias = String(composeMail.alias || "")
    if (alias === "") return
    if (composeNeedsRecipient && composeTo.trim() === "" ) {
      composeError = "A forward needs somebody to forward it to"
      return
    }
    composeRunning = true
    composeError = ""
    composeNotice = ""
    // What was written goes over stdin; only the ids stay on the command line.
    // Anyone on this machine can read /proc/<pid>/cmdline for as long as the
    // call runs, and a reply is somebody's words - see composeProc below.
    var command = ["python3", helper(), "compose",
                   "--account", alias,
                   "--id", String(composeMail.id),
                   "--mode", composeMode,
                   "--stdin"]
    if (asDraft === true) command.push("--draft")
    // A harness runs with this on. Without it, pressing Send there reaches the
    // mailbox with a real token - see graph.py's demo line in cmd_compose.
    if (demo) command.push("--demo")
    for (var i = 0; i < composeAttachments.length; i++)
      command = command.concat(["--attach", String(composeAttachments[i])])
    composeProc.command = command
    composeProc.running = true
  }

  Process {
    id: composeProc
    running: false
    stdinEnabled: true
    onStarted: composeProc.write(JSON.stringify({ comment: root.composeText,
                                                  to: root.composeTo }) + "\n")
    stdout: StdioCollector { id: composeOut; waitForEnd: true }
    stderr: StdioCollector { id: composeErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.composeRunning = false
      var parsed = Model.parseJson(composeOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        var code = parsed && parsed.error ? String(parsed.error.code || "") : ""
        root.composeError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(composeErr.text || "Could not write this message", 160)
        // The one failure with an obvious next step, so the window can offer
        // it instead of only reporting the problem.
        root.composeSendBlocked = code === "send_permission_required"
        return
      }
      if (parsed.drafted === true) {
        // The draft is on the server with its quoting and recipients already
        // right; Outlook is where it gets finished.
        root.openUrl(String(parsed.webLink || ""), String(root.composeMail ? root.composeMail.alias : ""))
        root.composeNotice = parsed.warning ? String(parsed.warning) : "Draft opened in Outlook"
      } else {
        root.composeNotice = "Sent"
      }
      root.cancelCompose()
      // A reply changes the conversation and a forward marks nothing, but both
      // are worth a fresh look - a sent reply usually means the message is
      // dealt with.
      root.refresh()
    }
  }

  // Set when a send failed for want of permission, so the window can say what
  // to do about it rather than repeating the error.
  property bool composeSendBlocked: false

  // ---- folders --------------------------------------------------------
  //
  // Which folder each mailbox is reading, as {alias: folder id}. A mailbox
  // missing from the map is on its inbox, which is why the map is empty until
  // something is picked and why "inbox" is removed rather than stored.
  //
  // Kept per mailbox because a folder id names a folder in one mailbox only:
  // there is no single id that could mean "Archive" across several. Kept per
  // host too: the window reading Archive is not a reason for the bar to stop
  // showing the inbox.
  property var selectedFolders: ({})

  // Which mailbox is being read. Only its folder is lit in the sidebar: every
  // mailbox is on some folder at all times, and a highlight in each account
  // says several are open when only one of them is where you are.
  //
  // Empty until something is picked, and then it is whatever was picked last.
  property string pickedAlias: ""

  readonly property string activeAlias: pickedAlias !== ""
    ? pickedAlias : (views.length > 0 ? String(views[0].alias) : "")

  // The mailbox whose folder was last picked here, until the fetch answering
  // that pick lands. The rows still in hand belong to the folder being left,
  // so anything drawing them has to stand something else in their place rather
  // than leave the old folder's mail sitting under the new folder's name.
  //
  // A folder read before is already in the store, and switching back to it
  // shows its rows at once rather than a pulse of placeholders.
  property string awaitingFolderFor: ""

  readonly property bool switchingFolder: {
    if (!hub || awaitingFolderFor === "") return false
    var folder = folderIdFor(awaitingFolderFor)
    return !hub.dataFor(awaitingFolderFor, folder) && !hub.errorFor(awaitingFolderFor, folder)
  }

  readonly property var folderRows: Model.folderRows(views, selectedFolders, activeAlias)

  function folderIdFor(alias) {
    return String(selectedFolders[String(alias || "")] || "inbox")
  }

  function folderNameFor(alias) {
    return Model.folderNameFor(views, String(alias || ""), selectedFolders)
  }

  function selectFolder(alias, folderId) {
    var key = String(alias || "")
    if (key === "") return
    var id = String(folderId || "inbox")
    // Before the early return below: picking the folder another mailbox is
    // already on changes nothing about what is fetched, and is still somebody
    // saying which mailbox they are now reading.
    pickedAlias = key
    if (folderIdFor(key) === id) return

    var next = {}
    for (var k in selectedFolders) next[k] = selectedFolders[k]
    if (id === "inbox") delete next[key]
    else next[key] = id
    selectedFolders = next

    // Read, deleted and held overrides name messages in the folder being left,
    // and the reading pane is showing one of them. Both would otherwise be
    // applied to whatever lands in their place.
    if (hub) {
      hub.forgetOverrides(key)
      // "Moved to Archive" said over Archive reads as though it just happened
      // here. The notice belonged to the folder being left.
      hub.actionNotice = ""
    }
    closePreview()
    awaitingFolderFor = key
  }

  // Everything that was fetched and passes the filters, before the cap. The
  // flat list takes the newest `mails` of these; the threaded one groups all
  // of them and takes the newest `mails` conversations, which is why the cap
  // cannot be applied before the grouping.
  readonly property var mailAll: Model.mergeMailAll(filteredViews, unreadOnly, listState, focusedOnly)

  // Empty unless the list is threaded, so nothing is grouped for a host that
  // will not draw it - the bar dropdown has no room to expand a conversation.
  readonly property var threads: threaded
    ? Model.groupThreads(mailAll, wantedMails, listState)
    : []

  // The messages on offer, in the order they are drawn. Grouping moves rows
  // around; it never hides a message, so the keyboard can keep walking this
  // one list either way.
  readonly property var mail: threaded
    ? Model.threadMessages(threads)
    : Model.capMail(mailAll, wantedMails, listState)

  readonly property var agenda: Model.mergeEvents(filteredViews, new Date(), 20, dedupeEvents)

  // ---- timeline -------------------------------------------------------

  // Opening the window up to fit a stray early meeting lasts as long as the
  // panel is open, no longer: it is a way of looking at today, not a setting.
  property int expandedStart: -1
  property int expandedEnd: -1
  readonly property int windowStart: expandedStart >= 0 ? expandedStart : dayStartMinutes
  readonly property int windowEnd: expandedEnd >= 0 ? expandedEnd : dayEndMinutes

  readonly property int agendaDays: Model.calendarDays(calendarMode)

  readonly property var timeline: Model.dayGrid(filteredViews, new Date(), {
    days: agendaDays,
    startMinutes: windowStart,
    endMinutes: windowEnd,
    showWeekends: showWeekends,
    dedupe: dedupeEvents
  })

  // The meeting whose details are showing. Clicking the one already selected
  // clears it, the same way the filter pills and the reading pane toggle.
  property var selectedEvent: null

  function selectEvent(event) {
    if (!event) { selectedEvent = null; return }
    selectedEvent = selectedEvent && String(selectedEvent.id) === String(event.id) ? null : event
  }

  function expandWindow() {
    expandedStart = timeline.fits.startMinutes
    expandedEnd = timeline.fits.endMinutes
  }

  // ---- one meeting, opened ------------------------------------------------
  //
  // The agenda says when and where. Who else is coming, what they answered,
  // what the organiser wrote - and the one thing there was no way to do here
  // at all, saying whether you are coming - are this.

  property var openMeeting: null
  property var meetingDetail: null
  property bool meetingLoading: false
  property string meetingError: ""
  // Which meeting this host is waiting for, so an answer to somebody else's
  // request, or to one this host has moved on from, is ignored.
  property string meetingKey: ""

  readonly property bool meetingOpen: openMeeting !== null

  function showMeeting(event) {
    if (!event || !event.id) return
    // Opening the meeting already open closes it, the way the reading pane and
    // the filter pills toggle.
    if (openMeeting && String(openMeeting.id) === String(event.id)) {
      closeMeeting()
      return
    }
    // One pane, one thing in it: a message being read and a meeting being
    // answered want the same column.
    closePreview()
    openMeeting = event
    selectedEvent = event
    meetingDetail = null
    meetingError = ""
    if (!hub) {
      meetingLoading = false
      meetingError = "Nothing to read this meeting with yet"
      return
    }
    meetingLoading = true
    meetingKey = hub.requestMeeting(String(event.aliases && event.aliases.length
                                           ? event.aliases[0] : event.alias || ""),
                                    String(event.id), demo)
  }

  function closeMeeting() {
    openMeeting = null
    meetingDetail = null
    meetingError = ""
    meetingLoading = false
    meetingKey = ""
  }

  readonly property bool answeringMeeting: hub ? hub.answering : false
  readonly property string meetingAnswerError: hub ? hub.answerError : ""

  // Accept, tentatively accept or decline what is open. The organiser is
  // always told: an answer nobody was sent looks exactly like no answer from
  // where they are sitting.
  function answerMeeting(reply, comment) {
    if (!openMeeting || !hub) return
    hub.answerMeeting(meetingAlias(openMeeting), String(openMeeting.id),
                      String(reply), String(comment || ""), demo)
  }

  // Which mailbox a meeting belongs to. A merged agenda carries `aliases`,
  // since one meeting can arrive from two mailboxes at once; answering is
  // done from the first of them, which is the one whose invitation it is.
  function meetingAlias(event) {
    if (!event) return ""
    if (event.aliases && event.aliases.length > 0) return String(event.aliases[0])
    return String(event.alias || "")
  }

  Connections {
    target: root.hub

    function onMeetingReady(id, detail) {
      if (id !== root.meetingKey) return
      root.meetingLoading = false
      root.meetingDetail = detail
      root.meetingError = ""
    }

    function onMeetingFailed(id, message) {
      if (id !== root.meetingKey) return
      root.meetingLoading = false
      root.meetingError = message
    }

    function onMeetingAnswered(id, response) {
      if (id !== root.meetingKey || !root.openMeeting) return
      // Straight back for the meeting as it now stands: the answer changed
      // what the pane is mostly about, and the cached copy said the old one.
      root.meetingLoading = true
      root.meetingKey = root.hub.requestMeeting(root.meetingAlias(root.openMeeting),
                                                String(root.openMeeting.id), root.demo)
    }
  }

  readonly property int unreadCount: {
    var total = 0
    for (var i = 0; i < views.length; i++) total += views[i].unreadCount
    return total
  }
  // Of that, how much is actually in the list - mail that has just arrived, as
  // against a backlog sitting further down the mailbox. The bar tints on this
  // rather than on unreadCount: one old unread message nobody intends to open
  // would otherwise keep the icon lit for good, and an icon that never goes
  // out cannot tell you that something came in.
  //
  // Every mailbox rather than filteredViews, and mailState rather than
  // listState, for the same reason: the alias filter and the reading pane are
  // ways of looking at the panel, and neither should change what the bar says
  // is waiting.
  readonly property var freshUnread: Model.freshUnread(views, mails, mailState)
  readonly property int newUnreadCount: freshUnread.total
  readonly property int shownMailCount: mail.length
  readonly property bool anySignedIn: {
    for (var i = 0; i < views.length; i++) if (views[i].ok) return true
    return false
  }
  readonly property bool anyNeedsSignIn: {
    for (var i = 0; i < views.length; i++) if (views[i].loaded && views[i].errorCode === "auth_required") return true
    return false
  }
  readonly property string primaryTitle: {
    if (!configured) return "Office 365"
    if (combined) return String(setting("label", "")).trim() || "Mail"
    var view = views.length > 0 ? views[0] : null
    if (!view) return "Office 365"
    if (view.displayName !== "") return view.displayName
    if (view.username !== "") return view.username
    return view.alias
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var parsed = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(parsed)) parsed = fallback
    return Math.max(min, Math.min(max, parsed))
  }

  function helper() {
    return pluginDir + "/graph.py"
  }

  function viewFor(alias) {
    for (var i = 0; i < views.length; i++) if (views[i].alias === alias) return views[i]
    return null
  }

  // Whether this mailbox may change mail. Read-only mailboxes hide the
  // actions rather than offering buttons that would fail.
  function canWrite(alias) {
    var view = viewFor(String(alias || ""))
    return !!view && view.write === true
  }

  // ---- fetching -------------------------------------------------------
  //
  // The store owns the timers and the processes. What is left here is asking
  // it for a fresh look at this host's own mailboxes.

  function refresh() {
    if (!configured || !hub) return
    hub.refresh(aliases)
  }

  function loadPalette() {
    if (hub) hub.loadPalette()
  }

  // A refresh asked for that could not be started yet.
  //
  // Saving settings is the case this exists for. The write finishing means
  // shell.json is on disk, not that the shell has noticed and handed the new
  // values to this object - so refreshing there fetches the accounts and range
  // being replaced. Both are waited out here.
  property bool refreshQueued: false

  function queueRefresh() {
    refreshQueued = true
    // In case the settings never arrive: saving values identical to the
    // current ones gives the watcher nothing to report, and the panel would
    // sit stale until the next poll. Deliberately not run here: waiting for
    // the settings is the whole point.
    refreshDeadline.restart()
  }

  function runQueuedRefresh() {
    if (!refreshQueued || !configured || !hub) return
    refreshQueued = false
    refreshDeadline.stop()
    refresh()
  }

  // The settings this object was waiting for. Anything else that changes them
  // gets the same treatment, which is what it should have had anyway.
  onSettingsChanged: runQueuedRefresh()

  Timer {
    id: refreshDeadline
    interval: 2000
    onTriggered: root.runQueuedRefresh()
  }

  // ---- sign-in --------------------------------------------------------
  //
  // Run by the store, one mailbox at a time for the whole shell, so two hosts
  // cannot start competing device-code flows for the same mailbox. Surfaced
  // here because the buttons and the code live in the panel.

  readonly property string loginAlias: hub ? hub.loginAlias : ""
  readonly property bool loggingIn: hub ? hub.loggingIn : false
  readonly property string userCode: hub ? hub.userCode : ""
  readonly property string verificationUri: hub ? hub.verificationUri : ""
  readonly property string loginMessage: hub ? hub.loginMessage : ""

  function startLogin(alias, wantWrite, calendar) {
    if (!configured || !hub) return
    var config = configFor(alias)
    if (!config) return
    hub.startLogin(alias, wantWrite, config, calendar)
  }

  function configFor(alias) {
    for (var i = 0; i < accountConfigs.length; i++)
      if (String(accountConfigs[i].account).trim() === alias) return accountConfigs[i]
    return null
  }

  function cancelLogin() {
    if (hub) hub.cancelLogin()
  }

  function openVerificationPage() {
    if (hub) hub.openVerificationPage()
  }

  function signOut(alias) {
    if (hub) hub.signOut(alias)
  }

  // ---- actions --------------------------------------------------------

  function openUrl(url, alias) {
    var target = String(url || "").trim()
    // The last of the three checks a link is meant to pass: Python sanitises
    // the body, Model.js writes the anchor, and this is the final place a
    // scheme can be refused before a browser is handed it. It was missing.
    if (!/^(?:https?|mailto):/i.test(target)) return
    var config = alias ? configFor(alias) : (accountConfigs.length > 0 ? accountConfigs[0] : null)
    Quickshell.execDetached(Model.openArgv(config ? config.openCommand : "", target))
  }

  // Bring a mailbox's own Outlook window forward when it has a match
  // configured; otherwise just open it on the web.
  function focusApp(alias) {
    var config = alias ? configFor(alias) : (accountConfigs.length > 0 ? accountConfigs[0] : null)
    if (!config) return
    var webUrl = webUrlFor(config.account)
    var match = String(config.focusMatch || "").trim()
    if (match === "") {
      openUrl(webUrl, config.account)
      return
    }
    // One string, because that is what omarchy-launch-or-focus takes - and it
    // evaluates it as shell text, so the argument boundaries have to be put
    // back in as quotes rather than lost to a plain join.
    var launch = Model.shellCommand(Model.openArgv(config.openCommand, webUrl))
    Quickshell.execDetached(["omarchy-launch-or-focus", match, launch])
  }

  // ---- settings -------------------------------------------------------
  //
  // Stays here rather than in the store: a save names one widget's entry in
  // shell.json, and which widget that is only this host knows.

  // Starts a save, and says whether it started: writing shell.json is another
  // process, so a caller that wants to know the outcome has to wait for
  // settingsSaved or saveError rather than for this to return.
  function saveSettings(patch) {
    if (saveProc.running || pluginDir === "") return false
    saving = true
    saveError = ""
    // The instance id is what tells two widgets holding the same mailbox
    // apart. It is empty until the first save, which is when config.py stamps
    // one into this entry.
    saveProc.command = ["python3", pluginDir + "/config.py",
                        "--plugin-id", "caseonline.omarchy.office365",
                        "--instance", String(setting("instance", "")),
                        "--match", JSON.stringify(settings || {}),
                        "--set", JSON.stringify(patch || {})]
    saveProc.running = true
    return true
  }

  Process {
    id: saveProc
    running: false
    stdout: StdioCollector { id: saveOut; waitForEnd: true }
    stderr: StdioCollector { id: saveErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.saving = false
      var parsed = Model.parseJson(saveOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.saveError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(saveErr.text || "Could not save settings", 160)
        return
      }
      root.saveError = ""
      root.settingsSaved()
      // Not refresh(): shell.json is written, but the new settings have not
      // reached this object yet.
      root.queueRefresh()
    }
  }
}
