import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Everything the plugin knows, once, for the whole shell.
//
// The bar widget and the window are separate hosts: one Service per bar
// surface (so one per monitor) and another in the window. Each used to own its
// own fetch loop, which meant the same mailbox polled two or three times over,
// and marking a message read in the window left the bar showing it unread
// until the bar's own timer came round.
//
// So the data moved here. The shell builds one of these per plugin - see
// `kinds: ["service"]` in the manifest - and every Service registers what it
// needs and reads the answers back out. What lives here is what two readers
// must agree on: fetched mail, the optimistic read/deleted overlay, message
// bodies, the theme palette, and the sign-in state machine. What each host
// looks at - filters, which message is open, a half-written reply - stays with
// the host, because two windows looking at different folders is not a bug.
//
// Fetching is keyed by mailbox *and folder*, since the window may be reading
// Archive while the bar shows the inbox; two hosts on the same folder share
// one fetch. Requests for one mailbox are run one at a time whatever the
// folder: a fetch is also a token refresh, and Entra rotates refresh tokens,
// so two at once risks an avoidable sign-in.
Item {
  id: root

  // ---- host injections ----------------------------------------------------
  //
  // Set by the shell's service loader. Unused here, but accepting them keeps
  // the warnings out of the log and leaves the door open.
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
    return decodeURIComponent(url.replace(/\/$/, ""))
  }

  function helper() {
    return pluginDir + "/graph.py"
  }

  // ---- subscriptions ------------------------------------------------------
  //
  // A Service claims a token, keeps a request under it, and drops it when it
  // goes away. The union of the requests is what gets fetched.

  property var requests: ({})
  property int tokenSerial: 0

  function claim() {
    tokenSerial += 1
    return "sub" + tokenSerial
  }

  function put(token, request) {
    var key = String(token || "")
    if (key === "") return
    var next = {}
    for (var k in requests) next[k] = requests[k]
    next[key] = request || null
    requests = next
  }

  function release(token) {
    var key = String(token || "")
    if (!(key in requests)) return
    var next = {}
    for (var k in requests) if (k !== key) next[k] = requests[k]
    requests = next
  }

  // What every subscriber together wants fetched, as {key: spec}. The key
  // names a mailbox in a folder, which is the unit one fetch answers.
  readonly property var wants: {
    var out = {}
    for (var token in requests) {
      var request = requests[token]
      if (!request) continue
      var aliases = request.aliases || []
      for (var i = 0; i < aliases.length; i++) {
        var alias = String(aliases[i] || "").trim()
        if (alias === "") continue
        var folder = String((request.folders || {})[alias] || "inbox")
        var key = fetchKey(alias, folder)
        var spec = out[key]
        if (!spec) {
          spec = out[key] = {
            key: key, alias: alias, folder: folder,
            mails: 0, days: 0, demo: false, intervalSec: 3600,
            notify: false
          }
        }
        // The most anyone asked for, so a widget showing five messages and a
        // window showing twenty-five are answered by one fetch of twenty-five.
        spec.mails = Math.max(spec.mails, Number(request.mails) || 5)
        spec.days = Math.max(spec.days, Number(request.days) || 3)
        spec.demo = spec.demo || request.demo === true
        spec.intervalSec = Math.min(spec.intervalSec, Number(request.intervalSec) || 180)
        // One host wanting to be told is enough. The fetch is shared, so the
        // announcement has to be made once for all of them or not at all.
        spec.notify = spec.notify || request.notify === true
      }
    }
    return out
  }

  // The mailboxes with something to fetch. The fetch units are per mailbox
  // rather than per key so that one mailbox's folders take their turn.
  readonly property var wantAliases: {
    var seen = {}
    var list = []
    for (var key in wants) {
      var alias = wants[key].alias
      if (seen[alias]) continue
      seen[alias] = true
      list.push(alias)
    }
    list.sort()
    return list
  }

  function fetchKey(alias, folderId) {
    return String(alias || "") + " " + String(folderId || "inbox")
  }

  function keysForAlias(alias) {
    var list = []
    for (var key in wants) if (wants[key].alias === alias) list.push(key)
    list.sort()
    return list
  }

  // ---- fetched data -------------------------------------------------------
  //
  // {key: {data, error, loading}}. `data` is one mailbox's entry out of a
  // snapshot; `error` is the helper itself having failed, which leaves the
  // last good data in place rather than blanking the panel.
  property var entries: ({})

  function patchEntry(key, patch) {
    var next = {}
    for (var k in entries) next[k] = entries[k]
    var current = next[key] || { data: null, error: null, loading: false }
    var merged = {}
    for (var f in current) merged[f] = current[f]
    for (var p in patch) merged[p] = patch[p]
    next[key] = merged
    entries = next
  }

  // One mailbox's fetched data, or null before its first answer.
  function dataFor(alias, folderId) {
    var entry = entries[fetchKey(alias, folderId)]
    return entry ? entry.data : null
  }

  function loadingFor(alias, folderId) {
    var entry = entries[fetchKey(alias, folderId)]
    return !!entry && entry.loading === true
  }

  function errorFor(alias, folderId) {
    var entry = entries[fetchKey(alias, folderId)]
    return entry ? entry.error : null
  }

  // Mailboxes whose sign-in just landed and whose first fetch is still in
  // flight: signed in, but with nothing to show yet.
  property var busy: ({})

  function markBusy(alias) {
    var next = {}
    for (var key in busy) next[key] = busy[key]
    next[String(alias)] = true
    busy = next
  }

  function clearBusy(alias) {
    if (busy[String(alias)] !== true) return
    var next = {}
    for (var key in busy) if (key !== String(alias)) next[key] = busy[key]
    busy = next
  }

  // ---- optimistic overlay -------------------------------------------------
  //
  // What has been done here that the server has not confirmed yet, keyed by
  // message id and shared by every host, so a message marked read in the
  // window stops being bold in the bar at once.
  //
  // `held` is deliberately not here: it is the row being read staying put in
  // an unread list, and which message that is belongs to the host reading it.
  property var overrides: ({ read: ({}), flagged: ({}), deleted: ({}) })

  // Which mailbox each override belongs to, so a fetch of one mailbox retires
  // only its own and leaves the others alone.
  property var overrideOwner: ({})

  function setOverride(field, id, alias, value) {
    var key = String(id)
    var next = { read: ({}), flagged: ({}), deleted: ({}) }
    for (var group in next) for (var k in overrides[group]) next[group][k] = overrides[group][k]
    var owners = {}
    for (var o in overrideOwner) owners[o] = overrideOwner[o]
    if (value === undefined) {
      delete next[field][key]
      if (next.read[key] === undefined && next.flagged[key] === undefined
          && next.deleted[key] === undefined) delete owners[key]
    } else {
      next[field][key] = value
      owners[key] = String(alias || "")
    }
    overrides = next
    overrideOwner = owners
  }

  // A folder switch leaves every override naming a message in the folder being
  // left, and they would otherwise be applied to whatever lands in its place.
  function forgetOverrides(alias) {
    var target = String(alias || "")
    var next = { read: ({}), flagged: ({}), deleted: ({}) }
    var owners = {}
    for (var group in next) {
      for (var key in overrides[group]) {
        if (overrideOwner[key] === target) continue
        next[group][key] = overrides[group][key]
      }
    }
    for (var o in overrideOwner) if (overrideOwner[o] !== target) owners[o] = overrideOwner[o]
    overrides = next
    overrideOwner = owners
  }

  function pruneOverrides(account) {
    var pruned = Model.pruneOwnedOverrides(account, overrides, overrideOwner)
    if (!pruned) return
    overrides = pruned.overrides
    overrideOwner = pruned.owner
  }

  // ---- message bodies -----------------------------------------------------
  //
  // Bodies are far too big to carry in the list fetch, so one is pulled when a
  // message is opened - and then kept, because opening in the window the
  // message just read in the bar should not ask Graph a second time.
  property var bodies: ({})
  property var bodyOrder: []
  readonly property int bodyCap: 40

  signal bodyReady(string cacheKey, var detail)
  signal bodyFailed(string cacheKey, string message)

  function bodyKey(id, wantHtml) {
    return String(id) + (wantHtml === true ? "|html" : "|text")
  }

  function cachedBody(id, wantHtml) {
    return bodies[bodyKey(id, wantHtml)] || null
  }

  function rememberBody(key, detail) {
    var next = {}
    for (var k in bodies) next[k] = bodies[k]
    next[key] = detail
    var order = bodyOrder.slice()
    var at = order.indexOf(key)
    if (at >= 0) order.splice(at, 1)
    order.push(key)
    while (order.length > bodyCap) delete next[order.shift()]
    bodies = next
    bodyOrder = order
  }

  // Bodies being fetched, so two hosts opening the same message make one call
  // and both hear about it.
  property var bodyPending: ({})
  property var bodyQueue: []

  function requestBody(alias, id, wantHtml, demo) {
    var key = bodyKey(id, wantHtml)
    var cached = bodies[key]
    if (cached) {
      // Still asynchronous, so a caller that sets its loading flag after this
      // returns is not left with it stuck on.
      Qt.callLater(function() { root.bodyReady(key, cached) })
      return key
    }
    if (bodyPending[key] === true) return key
    var next = {}
    for (var k in bodyPending) next[k] = bodyPending[k]
    next[key] = true
    bodyPending = next
    var queued = bodyQueue.slice()
    queued.push({ key: key, alias: String(alias), id: String(id), html: wantHtml === true, demo: demo === true })
    bodyQueue = queued
    pumpBodies()
    return key
  }

  function pumpBodies() {
    if (messageProc.running || bodyQueue.length === 0 || pluginDir === "") return
    var next = bodyQueue[0]
    var command = ["python3", helper(), "message", "--account", next.alias, "--id", next.id]
    // Demo mode has to reach the reading pane too, or opening a synthetic row
    // asks Graph about an id it has never seen.
    if (next.demo) command.push("--demo")
    if (next.html) command.push("--html")
    messageProc.command = command
    messageProc.running = true
  }

  function finishBody(key, detail, message) {
    var next = {}
    for (var k in bodyPending) if (k !== key) next[k] = bodyPending[k]
    bodyPending = next
    if (detail) {
      rememberBody(key, detail)
      bodyReady(key, detail)
    } else {
      bodyFailed(key, String(message || "Could not open this message"))
    }
  }

  Process {
    id: messageProc
    running: false
    stdout: StdioCollector { id: messageOut; waitForEnd: true }
    stderr: StdioCollector { id: messageErr; waitForEnd: true }
    onExited: function(exitCode) {
      var job = root.bodyQueue.length > 0 ? root.bodyQueue[0] : null
      root.bodyQueue = root.bodyQueue.slice(1)
      if (job) {
        var parsed = Model.parseJson(messageOut.text, null)
        if (exitCode !== 0 || !parsed || parsed.ok === false) {
          root.finishBody(job.key, null, parsed && parsed.error
            ? String(parsed.error.message)
            : Model.oneLine(messageErr.text || "Could not open this message", 160))
        } else {
          root.finishBody(job.key, parsed, "")
        }
      }
      root.pumpBodies()
    }
  }

  // ---- theme palette ------------------------------------------------------
  //
  // The theme's named colours, for resolving a mailbox's "blue" or "magenta".
  // One read for the shell rather than one per host.
  property var themePalette: ({})

  function loadPalette() {
    if (paletteProc.running || pluginDir === "") return
    paletteProc.command = ["python3", helper(), "palette"]
    paletteProc.running = true
  }

  Process {
    id: paletteProc
    running: false
    stdout: StdioCollector { id: paletteOut; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(paletteOut.text, null)
      if (exitCode === 0 && parsed && parsed.colors) root.themePalette = parsed.colors
    }
  }

  Component.onCompleted: loadPalette()

  // ---- fetching -----------------------------------------------------------

  // Ask for a fresh fetch of these mailboxes now, whatever their timers were
  // about to do. No argument means all of them.
  function refresh(aliases) {
    var wanted = aliases && aliases.length ? aliases : wantAliases
    for (var i = 0; i < fetchUnits.count; i++) {
      var unit = fetchUnits.objectAt(i)
      if (!unit) continue
      for (var a = 0; a < wanted.length; a++) {
        if (unit.mailbox !== String(wanted[a])) continue
        unit.refreshNow()
        break
      }
    }
  }

  function applyFetch(key, exitCode, stdout, stderr) {
    var spec = wants[key]
    var parsed = Model.parseJson(stdout, null)
    if (exitCode !== 0 || !parsed) {
      patchEntry(key, {
        loading: false,
        error: {
          code: exitCode === 0 ? "bad_output" : "helper_failed",
          message: exitCode === 0
            ? "Could not read the helper's response"
            : Model.oneLine(stderr || "The helper could not be run", 160)
        }
      })
      return false
    }
    if (parsed.ok === false) {
      var error = parsed.error || {}
      patchEntry(key, {
        loading: false,
        error: { code: String(error.code || "error"), message: String(error.message || "Something went wrong") }
      })
      return false
    }
    // One mailbox was asked for, so one comes back. A mailbox that failed on
    // its own account says so inside its entry, which is where the panel shows
    // it - the fetch itself is only in error when nothing came back at all.
    var accounts = parsed.accounts || []
    var account = accounts.length > 0 ? accounts[0] : null
    patchEntry(key, { loading: false, error: null, data: account })
    announceNewMail(key, spec, account)
    if (spec) clearBusy(spec.alias)
    if (account) pruneOverrides(account)
    return true
  }

  // One per mailbox: its timer, its fetch, and a queue of the folders wanted
  // for it, so two folders of one mailbox never refresh a token at once.
  Instantiator {
    id: fetchUnits
    model: root.wantAliases

    delegate: QtObject {
      id: unit
      required property string modelData
      readonly property string mailbox: modelData

      // The shortest interval anybody asked for, across this mailbox's folders.
      readonly property int intervalSec: {
        var keys = root.keysForAlias(mailbox)
        var shortest = 3600
        for (var i = 0; i < keys.length; i++)
          shortest = Math.min(shortest, root.wants[keys[i]].intervalSec)
        return Math.max(60, shortest)
      }

      property var queue: []

      function enqueue(keys) {
        var next = queue.slice()
        for (var i = 0; i < keys.length; i++)
          if (next.indexOf(keys[i]) === -1) next.push(keys[i])
        queue = next
        pump()
      }

      function refreshNow() {
        enqueue(root.keysForAlias(mailbox))
      }

      function pump() {
        if (proc.running || queue.length === 0 || root.pluginDir === "") return
        var key = queue[0]
        var spec = root.wants[key]
        if (!spec) { queue = queue.slice(1); pump(); return }
        var command = ["python3", root.helper(), "fetch",
                       "--mails", String(spec.mails),
                       "--days", String(spec.days),
                       "--account", spec.alias]
        // Only a folder that was actually picked: leaving the default off
        // keeps the command line what it was for anyone reading their inbox.
        if (spec.folder !== "" && spec.folder !== "inbox")
          command = command.concat(["--folder", spec.alias + "=" + spec.folder])
        // "demo": true in shell.json fills the panel with synthetic data, for
        // working on the layout without every mailbox being signed in.
        if (spec.demo) command.push("--demo")
        root.patchEntry(key, { loading: true })
        proc.command = command
        proc.running = true
      }

      property Process proc: Process {
        running: false
        stdout: StdioCollector { id: fetchOut; waitForEnd: true }
        stderr: StdioCollector { id: fetchErr; waitForEnd: true }
        onExited: function(exitCode) {
          var key = unit.queue.length > 0 ? unit.queue[0] : ""
          unit.queue = unit.queue.slice(1)
          if (key !== "") {
            // Retry sooner than the normal cadence after a failure, so a
            // laptop coming back from suspend refills the panel quickly.
            if (!root.applyFetch(key, exitCode, fetchOut.text, fetchErr.text)) retry.restart()
          }
          unit.pump()
        }
      }

      property Timer retry: Timer {
        interval: 20000
        repeat: false
        onTriggered: unit.refreshNow()
      }

      property Timer timer: Timer {
        interval: unit.intervalSec * 1000
        repeat: true
        running: root.pluginDir !== ""
        triggeredOnStart: true
        onTriggered: unit.refreshNow()
      }

      // A folder picked for the first time has nothing cached, so fetch it as
      // soon as somebody asks for it rather than at the next tick.
      readonly property string keySignature: root.keysForAlias(mailbox).join(",")
      onKeySignatureChanged: Qt.callLater(unit.refreshNow)
    }
  }

  // ---- telling you something arrived --------------------------------------

  property Notifier notifier: Notifier {
    appName: "Mail"
    plural: "new emails"
  }

  // Everything this fetch found, against everything the last one did. New ids
  // that are also unread are what there is to be told about; the rest is there
  // so that a message going from unread to read is not mistaken for one that
  // has just landed.
  function announceNewMail(key, spec, account) {
    if (!account) return
    var rows = account.mail || []
    var fresh = []
    var present = []

    // Which mailbox, and which folder, but only when either is in doubt. One
    // inbox needs no label; three mailboxes and a Sent folder do.
    var place = wantAliases.length > 1 ? String(account.alias || "") : ""
    var folder = String(account.folderName || "")
    if (folder !== "" && folder.toLowerCase() !== "inbox")
      place = place === "" ? folder : place + " · " + folder

    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var id = String(row.id || "")
      if (id === "") continue
      present.push(id)
      if (row.read === true) continue
      var from = String(row["from"] || "")
      fresh.push({
        id: id,
        summary: (place !== "" ? place + " · " : "") + (from !== "" ? from : "New mail"),
        body: String(row.subject || "")
      })
    }

    // Demo data is invented, and a screenshot run should not push six
    // notifications about people who do not exist onto a real desktop.
    notifier.observe(key, fresh, present,
                     !spec || spec.notify !== true || spec.demo === true)
  }

  // ---- marking, deleting and moving ---------------------------------------

  property string actionError: ""
  // What the last action did, for a host that wants to say so. A move is the
  // one action with nothing left on screen to show for it: the row is gone and
  // the folder it went to is somewhere else entirely.
  property string actionNotice: ""
  // Marks are queued rather than dropped while one is in flight: opening the
  // next message before the previous mark returned must still mark both.
  property var markQueue: []
  // Flags are queued for the same reason marks are: flagging three rows in a
  // row must flag three rows, not whichever one the process happened to be
  // free for.
  property var flagQueue: []
  readonly property bool actionRunning: markProc.running || flagProc.running
                                        || deleteProc.running || moveProc.running
                                        || markQueue.length > 0 || flagQueue.length > 0

  // Deleting is announced before the row is hidden, so a host reading that
  // message can work out which one takes its place while it is still listed.
  signal messageDeleted(string id, string alias)
  // A move takes the message out of the folder being read just as finally, and
  // hosts have the same work to do about it.
  signal messageMoved(string id, string alias)

  function markMessage(id, alias, read) {
    if (!id) return
    actionError = ""
    actionNotice = ""
    // Show it at once; the queue catches up and a failure puts it back.
    setOverride("read", id, alias, read === true)
    var queued = markQueue.slice()
    queued.push({ id: String(id), alias: String(alias), read: read === true })
    markQueue = queued
    pumpMarks()
  }

  function pumpMarks() {
    if (markProc.running || markQueue.length === 0 || pluginDir === "") return
    var next = markQueue[0]
    markProc.command = ["python3", helper(), "mark",
                        "--account", next.alias,
                        "--id", next.id,
                        next.read ? "--read" : "--unread"]
    markProc.running = true
  }

  // Outlook's follow-up flag, raised and cleared. Deliberately not tied to
  // read state: a flag is "come back to this", which is exactly what one does
  // to a message already read.
  function flagMessage(id, alias, flagged) {
    if (!id) return
    actionError = ""
    actionNotice = ""
    setOverride("flagged", id, alias, flagged === true)
    var queued = flagQueue.slice()
    queued.push({ id: String(id), alias: String(alias), flagged: flagged === true })
    flagQueue = queued
    pumpFlags()
  }

  function pumpFlags() {
    if (flagProc.running || flagQueue.length === 0 || pluginDir === "") return
    var next = flagQueue[0]
    flagProc.command = ["python3", helper(), "flag",
                        "--account", next.alias,
                        "--id", next.id,
                        next.flagged ? "--flag" : "--unflag"]
    flagProc.running = true
  }

  function deleteMessage(alias, id) {
    if (!id || deleteProc.running || pluginDir === "") return
    actionError = ""
    actionNotice = ""
    deleteProc.mailbox = String(alias)
    deleteProc.command = ["python3", helper(), "delete", "--account", String(alias), "--id", String(id)]
    deleteProc.running = true
  }

  Process {
    id: markProc
    running: false
    stdout: StdioCollector { id: markOut; waitForEnd: true }
    onExited: function(exitCode) {
      var done = root.markQueue.length > 0 ? root.markQueue[0] : null
      root.markQueue = root.markQueue.slice(1)
      var parsed = Model.parseJson(markOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.actionError = parsed && parsed.error ? String(parsed.error.message) : "Could not change this message"
        // Put the row back the way it was, for that message specifically.
        if (done) root.setOverride("read", done.id, done.alias, !done.read)
      }
      root.pumpMarks()
      if (root.markQueue.length === 0 && done) root.refresh([done.alias])
    }
  }

  Process {
    id: flagProc
    running: false
    stdout: StdioCollector { id: flagOut; waitForEnd: true }
    onExited: function(exitCode) {
      var done = root.flagQueue.length > 0 ? root.flagQueue[0] : null
      root.flagQueue = root.flagQueue.slice(1)
      var parsed = Model.parseJson(flagOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.actionError = parsed && parsed.error ? String(parsed.error.message) : "Could not flag this message"
        if (done) root.setOverride("flagged", done.id, done.alias, !done.flagged)
      }
      root.pumpFlags()
      if (root.flagQueue.length === 0 && done) root.refresh([done.alias])
    }
  }

  Process {
    id: deleteProc
    running: false
    property string mailbox: ""
    stdout: StdioCollector { id: deleteOut; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(deleteOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.actionError = parsed && parsed.error ? String(parsed.error.message) : "Could not delete this message"
        return
      }
      if (parsed.id) {
        // Announced first, while the row is still in every host's list, then
        // hidden. The next fetch simply stops returning it.
        root.messageDeleted(String(parsed.id), deleteProc.mailbox)
        root.setOverride("deleted", parsed.id, deleteProc.mailbox, true)
      }
      root.refresh([deleteProc.mailbox])
    }
  }

  // Filing a message somewhere else in the same mailbox. The destination's
  // name is carried along only to be said afterwards - Graph is told the id.
  function moveMessage(alias, id, folderId, folderName) {
    if (!id || !folderId || moveProc.running || pluginDir === "") return
    actionError = ""
    actionNotice = ""
    moveProc.mailbox = String(alias)
    moveProc.destination = String(folderName || "")
    moveProc.command = ["python3", helper(), "move",
                        "--account", String(alias),
                        "--id", String(id),
                        "--folder", String(folderId)]
    moveProc.running = true
  }

  Process {
    id: moveProc
    running: false
    property string mailbox: ""
    property string destination: ""
    stdout: StdioCollector { id: moveOut; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(moveOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.actionError = parsed && parsed.error ? String(parsed.error.message) : "Could not move this message"
        return
      }
      if (parsed.id) {
        // Announced while the row is still listed, then hidden - the same order
        // a delete goes in, because a host reading the message has the same
        // question to answer about what takes its place.
        //
        // The deleted overlay is what hides it. Not a lie about where it went:
        // the overlay means "gone from what is being read", and the move made
        // it so. The copy in the destination is a different message with a
        // different id, so this can never hide that one.
        root.messageMoved(String(parsed.id), moveProc.mailbox)
        root.setOverride("deleted", parsed.id, moveProc.mailbox, true)
      }
      root.actionNotice = moveProc.destination !== "" ? "Moved to " + moveProc.destination : "Moved"
      root.refresh([moveProc.mailbox])
    }
  }

  // ---- sign-in ------------------------------------------------------------
  //
  // One mailbox at a time for the whole shell. Two hosts offering the button
  // is fine; two device-code flows racing for the same mailbox is not.

  property string loginAlias: ""
  property bool loggingIn: false
  property string userCode: ""
  property string verificationUri: ""
  property string loginMessage: ""
  property string loginErrorCode: ""
  property string loginErrorMessage: ""
  // The mailbox's own configuration for the duration of its sign-in, so the
  // verification page opens in that mailbox's browser profile.
  property var loginConfig: null

  function startLogin(alias, wantWrite, config, calendar) {
    if (loginStartProc.running || pluginDir === "") return
    loginAlias = String(alias)
    loginConfig = config || null
    loggingIn = true
    userCode = ""
    verificationUri = ""
    loginErrorCode = ""
    loginErrorMessage = ""
    loginMessage = "Starting sign-in…"
    var command = ["python3", helper(), "login-start", "--account", loginAlias]
    if (wantWrite === true) command.push("--write")
    var clientId = String((config || {}).clientId || "").trim()
    var authority = String((config || {}).authority || "").trim()
    // An IMAP mailbox signs in as a desktop mail client instead of as this
    // plugin: a different client id and a different set of scopes, both of
    // which graph.py picks from the transport. Sending no client id is what
    // keeps that default, so only an explicit one is passed on.
    var transport = String((config || {}).transport || "").trim().toLowerCase()
    if (clientId !== "") command = command.concat(["--client-id", clientId])
    if (authority !== "") command = command.concat(["--authority", authority])
    if (transport === "imap") command = command.concat(["--transport", "imap"])
    // A calendar is added to a mailbox that already has mail, so this asks for
    // the EWS scope and merges the result rather than signing the mailbox in
    // again - which would throw the mail tokens away.
    if (calendar === true) command.push("--calendar")
    loginStartProc.command = command
    loginStartProc.running = true
  }

  function cancelLogin() {
    if (loginNotifyId > 0) {
      notify("Sign-in cancelled", "No changes were made", false)
      loginNotifyId = 0
    }
    loggingIn = false
    loginAlias = ""
    loginConfig = null
    userCode = ""
    verificationUri = ""
    loginMessage = ""
    loginPollTimer.running = false
  }

  // Opening the sign-in page with the mailbox's own browser profile is what
  // stops the browser handing back whichever account it was already signed
  // into - the page arrives already knowing who this should be.
  function openVerificationPage() {
    if (verificationUri === "") return
    Quickshell.execDetached(Model.openArgv(loginConfig ? loginConfig.openCommand : "", verificationUri))
  }

  function signOut(alias) {
    if (removeProc.running || pluginDir === "") return
    removeProc.mailbox = String(alias)
    removeProc.command = ["python3", helper(), "remove", "--account", String(alias)]
    removeProc.running = true
  }

  // Opening the browser takes focus, which dismisses the popup and takes the
  // device code with it. A notification outlives the panel; make it critical
  // so it stays put until dismissed, since the code expires in 15 minutes and
  // there is no way back to it once the panel is gone.
  function notify(summary, body, critical) {
    var command = ["notify-send", "-a", "Office 365"]
    if (critical === true) command = command.concat(["-u", "critical"])
    // Replace the code notification rather than stacking on it, so finishing
    // a sign-in clears the code that is no longer needed.
    if (loginNotifyId > 0) command = command.concat(["-r", String(loginNotifyId)])
    Quickshell.execDetached(command.concat([String(summary), String(body)]))
  }

  // Id of the standing device-code notification, so it can be replaced.
  property int loginNotifyId: 0

  function notifyCode(summary, body) {
    notifyProc.command = ["notify-send", "-a", "Office 365", "-u", "critical", "-p",
                          String(summary), String(body)]
    notifyProc.running = true
  }

  Timer {
    id: loginPollTimer
    interval: 5000
    repeat: true
    running: false
    onTriggered: {
      if (loginPollProc.running || root.loginAlias === "") return
      loginPollProc.command = ["python3", root.helper(), "login-poll", "--account", root.loginAlias]
      loginPollProc.running = true
    }
  }

  Process {
    id: notifyProc
    running: false
    stdout: StdioCollector { id: notifyOut; waitForEnd: true }
    onExited: {
      var id = parseInt(String(notifyOut.text || "").trim(), 10)
      root.loginNotifyId = isFinite(id) && id > 0 ? id : 0
    }
  }

  Process {
    id: loginStartProc
    running: false
    stdout: StdioCollector { id: loginStartOut; waitForEnd: true }
    stderr: StdioCollector { id: loginStartErr; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(loginStartOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.loggingIn = false
        root.loginAlias = ""
        root.loginConfig = null
        root.loginMessage = ""
        root.loginErrorCode = "login_failed"
        root.loginErrorMessage = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(loginStartErr.text || "Could not start sign-in", 160)
        return
      }
      root.userCode = String(parsed.userCode || "")
      root.verificationUri = String(parsed.verificationUri || "https://microsoft.com/devicelogin")
      root.loginMessage = "Waiting for you to finish signing in…"
      loginPollTimer.interval = Math.max(3, Number(parsed.interval || 5)) * 1000
      loginPollTimer.running = true
      // Clipboard first, so the code is already there to paste by the time the
      // browser has focus.
      Quickshell.clipboardText = root.userCode
      root.notifyCode("Sign in to " + root.loginAlias,
                      "Code " + root.userCode + " - copied, paste it in the browser")
      root.openVerificationPage()
    }
  }

  Process {
    id: loginPollProc
    running: false
    stdout: StdioCollector { id: loginPollOut; waitForEnd: true }
    onExited: function() {
      var parsed = Model.parseJson(loginPollOut.text, null)
      if (!parsed) return
      if (parsed.ok === false) {
        loginPollTimer.running = false
        root.loggingIn = false
        root.loginAlias = ""
        root.loginConfig = null
        root.loginMessage = ""
        root.loginErrorCode = String((parsed.error || {}).code || "login_failed")
        root.loginErrorMessage = String((parsed.error || {}).message || "Sign-in failed")
        return
      }
      if (parsed.status === "pending") {
        // The endpoint asks us to back off when we poll too eagerly.
        if (parsed.slowDown === true) loginPollTimer.interval += 5000
        return
      }
      loginPollTimer.running = false
      // The panel is usually closed by now, so say which account actually
      // arrived - that is the moment a wrong account is worth catching.
      var who = String(parsed.username || "")
      var alias = root.loginAlias
      root.notify("Signed in" + (alias !== "" ? " · " + alias : ""),
                  who !== "" ? who : "Mailbox is signed in", false)
      root.loginNotifyId = 0
      // Hold this mailbox in a "signed in, loading" state until its first
      // fetch returns, rather than letting it fall back to "sign in".
      if (alias !== "") root.markBusy(alias)
      root.loggingIn = false
      root.loginAlias = ""
      root.loginConfig = null
      root.userCode = ""
      root.loginMessage = ""
      root.loginErrorCode = ""
      root.loginErrorMessage = ""
      if (alias !== "") root.refresh([alias])
    }
  }

  Process {
    id: removeProc
    running: false
    property string mailbox: ""
    onExited: {
      root.clearBusy(removeProc.mailbox)
      root.refresh([removeProc.mailbox])
    }
  }
}
