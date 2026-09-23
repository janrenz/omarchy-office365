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

  // Where `fetch` leaves its last answer. The same path graph.py builds, and
  // the reason it is one file per mailbox rather than one per folder: an alias
  // is already checked to be a filename and a folder id is a Graph blob or an
  // IMAP path, which both sides would then have to hash into one the same way.
  readonly property string cacheDir: {
    var base = Quickshell.env("XDG_CACHE_HOME")
    if (!base) base = Quickshell.env("HOME") + "/.cache"
    return base + "/omarchy/office365"
  }

  // The last answer a mailbox gave, drawn before anything has been asked of
  // the network. A shell start - and a QML edit is a shell restart - used to
  // put the panel on a skeleton for as long as the first fetch took, measured
  // at 4 to 8 seconds against real mailboxes, for data that had been on this
  // machine the whole time.
  //
  // Three things it deliberately does not do. It does not touch `loading`: the
  // fetch is still running and the spinner belongs over these rows, because
  // they are the last answer rather than a fresh one. It never draws over an
  // answer already in hand, whatever order things arrive in. And it does not
  // go near the notifier - priming it from the cache would leave the first
  // real fetch announcing everything that arrived while the shell was off,
  // which is a toast storm at login rather than a feature.
  function applyCached(key, held) {
    if (!held || !held.account) return false
    var entry = entries[key]
    if (entry && entry.data) return false
    var at = Date.parse(String(held.fetchedAt || ""))
    patchEntry(key, { data: held.account, at: isNaN(at) ? 0 : at })
    harvestFromMail(held.account)
    return true
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
            notify: false, pausePolling: true, wantFolders: false, wantFocused: false
          }
        }
        // The most anyone asked for, so a widget showing five messages and a
        // window showing twenty-five are answered by one fetch of twenty-five.
        spec.mails = Math.max(spec.mails, Number(request.mails) || 5)
        spec.days = Math.max(spec.days, Number(request.days) || 3)
        spec.demo = spec.demo || request.demo === true
        // One host drawing the tree is enough to pay for it, and the bar on
        // its own does not draw one - see Service.wantsFolders.
        spec.wantFolders = spec.wantFolders || request.wantFolders === true
        // The same bargain for Outlook's Focused views, except that this one
        // follows a filter rather than a host: one pill switched on anywhere
        // buys the two queries for everybody watching that mailbox.
        spec.wantFocused = spec.wantFocused || request.wantFocused === true
        spec.intervalSec = Math.min(spec.intervalSec, Number(request.intervalSec) || 180)
        // One host wanting to be told is enough. The fetch is shared, so the
        // announcement has to be made once for all of them or not at all.
        spec.notify = spec.notify || request.notify === true
        // The other way round: one host that wants to keep polling keeps the
        // fetch alive for everybody, because the answer it gets is shared too.
        spec.pausePolling = spec.pausePolling && request.pausePolling !== false
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

  // The newest answer this mailbox gave for any folder.
  //
  // Switching folder makes a new fetch key, and a new key has no data until
  // the server answers. The mailbox therefore vanished from the snapshot
  // altogether for those seconds - taking its folder tree with it, which is
  // the thing the click was aimed at and the last thing that should move.
  // The tree, the address, what the mailbox may do and its agenda are the
  // same whatever folder is open, so the last answer stands in for them while
  // the new one is on its way. What is genuinely about the folder - the mail
  // itself - is left out by Model.accountViews, which is handed this marked
  // as stale.
  function staleDataFor(alias) {
    var wanted = String(alias || "")
    var best = null
    var newest = -1
    for (var key in entries) {
      var entry = entries[key]
      if (!entry || !entry.data) continue
      if (String(entry.data.alias || "") !== wanted) continue
      var when = Number(entry.at || 0)
      if (when >= newest) {
        newest = when
        best = entry.data
      }
    }
    return best
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

  // ---- who you write to ---------------------------------------------------
  //
  // An address book, built out of the mail already in hand rather than fetched
  // from anywhere. Graph has /me/people and /me/contacts, and both need consent
  // this plugin does not ask for; an IMAP mailbox has no contacts endpoint at
  // all, so a book that came from either would be empty on the transport at
  // least one mailbox here is read over. Harvesting what has already arrived
  // costs no request and no scope, and gives the better answer anyway: the
  // people actually corresponded with, rather than a directory of everyone.
  //
  // In the store because it is worth agreeing on - the window's reply box
  // should know about the mail the bar fetched - and per shell rather than
  // written down, so nothing about who is written to is persisted.
  //
  // **Kept per mailbox, and that is the point.** One widget carries several,
  // and a book pooled across them completes a reply from the work address with
  // colleagues from the private one - which is a mistake that leaves the
  // machine before anybody notices it. So the mailbox a draft is written
  // *from* decides what is offered, and nothing merges the books: two
  // mailboxes that share a correspondent each remember them separately, which
  // costs a duplicate entry and buys never suggesting the wrong side of a
  // divide the user drew themselves.
  //
  // {alias: {lowercased address: {address, name, count, at}}}.
  property var addressBook: ({})

  // Every address ever seen would grow without bound over a shell's life, and
  // nobody reads past six suggestions. Least recently seen goes first, per
  // mailbox - a busy account must not evict a quiet one's contacts.
  readonly property int addressCap: 400

  // Both of these live in Model.js, where `node dev/test-model.js` can reach
  // them: which mailbox an address is filed under is the part of this worth a
  // test, and a property assignment in QML is not testable at all.
  function bookFor(alias) {
    return Model.bookFor(addressBook, alias)
  }

  function rememberAddresses(alias, people) {
    addressBook = Model.rememberedAddresses(addressBook, alias, people, addressCap)
  }

  // Everyone a fetched page of mail mentions. Only the sender: a row carries no
  // recipients, which is why a message opened for reading contributes more.
  function harvestFromMail(account) {
    if (!account || !account.mail) return
    var people = []
    for (var i = 0; i < account.mail.length; i++) {
      var row = account.mail[i] || {}
      people.push({ address: row.fromAddress, name: row.from })
    }
    // The fetch answers with the mailbox it was about, which is what files
    // these under the right book.
    rememberAddresses(account.alias, people)
  }

  // ...and everyone a message that was opened mentions, which is where the
  // people you were written to *alongside* come from - the ones a reply-all
  // would reach and a reply would not.
  //
  // The alias comes from the job that asked for the body rather than from the
  // message: a detail is one message's headers and says nothing about which
  // mailbox it was read out of.
  function harvestFromDetail(alias, detail) {
    if (!detail) return
    var people = [{ address: detail.fromAddress, name: detail.from }]
    var lists = [detail.to, detail.cc]
    for (var l = 0; l < lists.length; l++)
      for (var i = 0; i < (lists[l] || []).length; i++) people.push(lists[l][i])
    rememberAddresses(alias, people)
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

  // Images are part of the key, not a flag beside it: a body fetched without
  // them and the same body with them are two different documents, and caching
  // them under one name is how pressing the button would appear to do nothing.
  // `mode` is graph.py's --body: "auto", "html" or "text". Part of the key
  // because the same message read three ways is three different bodies, and
  // switching between them must not hand back the one that was cached first.
  function bodyKey(id, mode, withImages) {
    return String(id) + "|" + String(mode || "auto")
           + (withImages === true ? "|img" : "")
  }

  function cachedBody(id, mode, withImages) {
    return bodies[bodyKey(id, mode, withImages)] || null
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

  function requestBody(alias, id, mode, demo, withImages) {
    var key = bodyKey(id, mode, withImages)
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
    queued.push({ key: key, alias: String(alias), id: String(id),
                  body: String(mode || "auto"),
                  demo: demo === true, images: withImages === true })
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
    command.push("--body", next.body)
    // Only ever set by the reader pressing the button on this one message.
    if (next.images) command.push("--load-images")
    messageProc.command = command
    messageProc.running = true
  }

  function finishBody(key, alias, detail, message) {
    var next = {}
    for (var k in bodyPending) if (k !== key) next[k] = bodyPending[k]
    bodyPending = next
    if (detail) {
      rememberBody(key, detail)
      harvestFromDetail(alias, detail)
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
          root.finishBody(job.key, job.alias, null, parsed && parsed.error
            ? String(parsed.error.message)
            : Model.oneLine(messageErr.text || "Could not open this message", 160))
        } else {
          root.finishBody(job.key, job.alias, parsed, "")
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
    // `at` is what makes staleDataFor able to pick the newest answer this
    // mailbox gave, whichever folder it was for.
    patchEntry(key, { loading: false, error: null, data: account, at: Date.now() })
    harvestFromMail(account)
    announceNewMail(key, spec, account)
    if (spec) clearBusy(spec.alias)
    if (account) pruneOverrides(account)
    return true
  }

  // ---- when it is worth asking at all -------------------------------------
  //
  // See PollGate.qml. Nothing here decides *what* to fetch, only whether the
  // timers should be running, so a refresh anybody asked for by hand still
  // goes out - a failure the user can see beats a silence they cannot. The
  // same holds for the one fetch that confirms an action (a move, a delete, a
  // send, a sign-in): it is the tail of something the user did, not a poll.
  readonly property bool pausePolling: {
    for (var key in wants) if (wants[key].pausePolling === false) return false
    return true
  }

  // ---- the user's own pause -----------------------------------------------
  //
  // Pause fetching is one switch for the whole plugin, not one per widget,
  // and it merges the opposite way to `pausePolling`. That one is a host
  // saying it can *tolerate* a pause, so the most demanding host keeps the
  // poll alive. This one is the user saying stop, and there is only one fetch
  // loop behind every widget and the window: a pause that one widget asked
  // for and another quietly overruled would be a switch that does nothing.
  // So any host carrying `paused` holds the store.
  //
  // It is still written into each widget's entry in shell.json, because that
  // is the only settings path there is and it survives a restart - but into
  // *every* entry of this plugin at once (config.py --every), so that no
  // widget is left holding a pause nobody can see a switch for. The window
  // reads its settings once, when it opens, which is why `heldOverride`
  // exists: the switch takes effect the moment it is pressed, whatever any
  // host's copy of shell.json still says, and stands down when the hosts'
  // own settings agree with it.
  readonly property bool pausedByHosts: {
    for (var token in requests) {
      var request = requests[token]
      if (request && request.paused === true) return true
    }
    return false
  }

  property var heldOverride: null
  readonly property bool held: heldOverride !== null ? heldOverride === true : pausedByHosts

  onPausedByHostsChanged: if (heldOverride !== null && pausedByHosts === heldOverride) heldOverride = null

  function setPaused(value) {
    var next = value === true
    heldOverride = next === pausedByHosts ? null : next
    pauseWrite = next
    writePause()
  }

  function togglePause() {
    setPaused(!held)
  }

  // The value still to be written, or null. A second press while the first
  // write is running is kept rather than dropped, and only the last one
  // matters.
  property var pauseWrite: null

  function writePause() {
    if (pauseProc.running || pauseWrite === null || pluginDir === "") return
    pauseProc.command = ["python3", pluginDir + "/config.py",
                         "--plugin-id", "caseonline.omarchy.office365",
                         "--every", "--set", JSON.stringify({ paused: pauseWrite === true })]
    pauseWrite = null
    pauseProc.running = true
  }

  // Why the last write did not land, for a host that wants to say so. The
  // pause itself is in force either way; only surviving a restart is at risk.
  property string pauseError: ""

  Process {
    id: pauseProc
    running: false
    stdout: StdioCollector { id: pauseOut; waitForEnd: true }
    stderr: StdioCollector { id: pauseErr; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(pauseOut.text, null)
      root.pauseError = exitCode === 0 && parsed && parsed.ok !== false ? ""
        : (parsed && parsed.error ? String(parsed.error.message)
                                  : Model.oneLine(pauseErr.text || "Could not save the pause", 160))
      root.writePause()
    }
  }

  property PollGate poll: PollGate {
    pauseWhenAway: root.pausePolling
    pauseWhenOffline: root.pausePolling
    slowOnBattery: root.pausePolling
    held: root.held
  }

  // For a host that wants to explain a panel that is not moving.
  readonly property string pollReason: poll.reason

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

      // What the last fetch for each key actually asked for, as
      // {key: {mails, folders}}. Nothing binds to it, so it is written in
      // place.
      property var served: ({})

      // A host arriving wants more than the one before it: the window wants
      // twenty-five rows and the folder tree where the bar wanted five and no
      // tree at all. The key is the same, so `keySignature` does not move and
      // the answer already in the store stands - which left the window opening
      // on five messages beside an empty sidebar until the interval came
      // round, up to three minutes later. Wanting *less* is not worth a fetch:
      // what is in hand already covers it.
      readonly property string demand: {
        var keys = root.keysForAlias(mailbox)
        var parts = []
        for (var i = 0; i < keys.length; i++) {
          var spec = root.wants[keys[i]]
          if (spec) parts.push(keys[i] + "=" + spec.mails
                               + "," + (spec.wantFolders ? "t" : "f")
                               + "," + (spec.wantFocused ? "t" : "f"))
        }
        return parts.join(" ")
      }

      onDemandChanged: Qt.callLater(unit.catchUp)

      function catchUp() {
        // Held, a host wanting more waits: what it wants is automatic, and the
        // fetch the resume makes asks for everything anybody wants by then.
        if (root.held) return
        var keys = root.keysForAlias(mailbox)
        var behind = []
        for (var i = 0; i < keys.length; i++) {
          var spec = root.wants[keys[i]]
          if (!spec) continue
          var last = served[keys[i]]
          if (!last || spec.mails > last.mails
              || (spec.wantFolders && !last.folders)
              || (spec.wantFocused && !last.focused))
            behind.push(keys[i])
        }
        if (behind.length > 0) enqueue(behind)
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
        // Left off entirely when the tree is wanted, so the command line is
        // what it always was for anyone reading it over somebody's shoulder.
        if (!spec.wantFolders) command.push("--no-folders")
        if (!spec.wantFocused) command.push("--no-focused")
        // Only a folder that was actually picked: leaving the default off
        // keeps the command line what it was for anyone reading their inbox.
        if (spec.folder !== "" && spec.folder !== "inbox")
          command = command.concat(["--folder", spec.alias + "=" + spec.folder])
        // "demo": true in shell.json fills the panel with synthetic data, for
        // working on the layout without every mailbox being signed in.
        if (spec.demo) command.push("--demo")
        // Recorded as it goes out rather than when it lands: this is what was
        // asked for, and a fetch that failed is the retry timer's business.
        unit.served[key] = { mails: spec.mails, folders: spec.wantFolders === true,
                             focused: spec.wantFocused === true }
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
            // laptop coming back from suspend refills the panel quickly. Not
            // while the gate is closed, though: twenty seconds apart forever
            // is what a locked laptop with no network would do to the API
            // budget, and the gate opening starts a fetch on its own.
            if (!root.applyFetch(key, exitCode, fetchOut.text, fetchErr.text)
                && !root.poll.paused) retry.restart()
          }
          unit.pump()
        }
      }

      property Timer retry: Timer {
        interval: 20000
        repeat: false
        // Armed before the gate closed, it would still fire into a pause.
        onTriggered: if (!root.poll.paused) unit.refreshNow()
      }

      // triggeredOnStart is what makes waking up, coming back online and
      // switching Pause fetching off immediate: the gate opening restarts this
      // timer, and a restarted timer fires at once rather than an interval
      // later.
      property Timer timer: Timer {
        interval: unit.intervalSec * 1000 * root.poll.intervalScale
        repeat: true
        running: root.pluginDir !== "" && !root.poll.paused
        triggeredOnStart: true
        onTriggered: unit.refreshNow()
      }

      // A folder picked for the first time has nothing cached, so fetch it as
      // soon as somebody asks for it rather than at the next tick. Not held
      // back by the pause: a key only appears because somebody clicked a
      // folder, and an empty list for a folder you just opened is not what
      // pausing asked for.
      readonly property string keySignature: root.keysForAlias(mailbox).join(",")
      onKeySignatureChanged: {
        unit.drawFromCache()
        Qt.callLater(unit.refreshNow)
      }

      // This mailbox's last answer, per folder. Loaded blockingly and once:
      // the file is tens of kilobytes on local disk, and the whole point is to
      // have it before the first frame rather than after it. Not watched -
      // every fetch rewrites it, and re-reading our own answer would be work
      // for nothing.
      property FileView cache: FileView {
        path: root.cacheDir + "/" + unit.mailbox + ".json"
        blockLoading: true
        printErrors: false
      }

      Component.onCompleted: unit.drawFromCache()

      function drawFromCache() {
        var text = ""
        // No file at all is the ordinary case on a first run, and FileView
        // says so by throwing rather than by answering with nothing.
        try { text = cache.text() } catch (error) { return }
        if (!text) return
        var held = Model.parseJson(text, null)
        var folders = held && held.folders ? held.folders : null
        if (!folders) return
        var keys = root.keysForAlias(mailbox)
        for (var i = 0; i < keys.length; i++) {
          var spec = root.wants[keys[i]]
          if (spec) root.applyCached(keys[i], folders[spec.folder])
        }
      }
    }
  }

  // ---- telling you something arrived --------------------------------------

  property Notifier notifier: Notifier {
    appName: "Mail"
    plural: "new emails"
    // The same glyph the bar widget defaults to, so the toast is recognisably
    // this plugin's at a glance.
    glyph: "󰇮"
    // Clicking a digest opens the window on whatever it was showing: a digest
    // is about several messages, so there is no one message to open.
    defaultExec: root.summonArgv("{}")
  }

  // The fold each fetch left behind, as {key: millis}: how old a message may
  // be and still be one that has just arrived.
  //
  // A fetch carries the newest `mails` messages of the folder and stops, so a
  // message older than every one of them was below the fold rather than
  // absent. It did not arrive; something above it left, and the list refilled
  // down to it. Deleting a row is the ordinary way that happens, and opening a
  // window on a mailbox the bar was reading five messages of is another - the
  // notifier has never seen what the extra twenty carried, and unseen is all
  // "new" means to it.
  //
  // Zero when the page did not fill: nothing can hide below a list with room
  // to spare, so an old message turning up in one was really put there - moved
  // in by a rule, say - and is worth announcing after all.
  //
  // **It is the folder page's own fold, and the helper is the only thing that
  // can say where that is.** The `mail` in an answer is the union of every
  // query the fetch made, and the unread and flagged ones exist precisely to
  // reach messages from far below the page - so measuring the fold against the
  // union put it weeks in the past on any mailbox with old unread mail in it,
  // which let through exactly what this guard is for: delete four rows, the
  // list refills from below the fold, and four toasts go off about mail from
  // last month. So the fold is `mailPage` now - see graph.py's fetch_account
  // and imapmail.snapshot - and this only remembers what they reported.
  property var notifyFloor: ({})

  // What the helper will read however much is asked of it - MAIL_CAP in
  // graph.py, Service.qml's mailCeiling. A setting past it means every answer
  // stops short of the cap, which is not the same as a mailbox that ran out.
  readonly property int mailCeiling: 100

  // The argv omarchy's notification service runs when a toast is clicked. It
  // goes through the shell rather than a window of our own, because the click
  // may arrive when nothing is loaded - summon() mounts the window and hands
  // the payload to open(), and delivers it straight away when the window is
  // already up.
  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "caseonline.omarchy.office365"

  function summonArgv(payloadJson) {
    return ["omarchy-shell", "shell", "summon", pluginId, String(payloadJson || "{}")]
  }

  // Which message a toast should open. The key is `messageId` and not `message`
  // because that is what MailWindow.applyPayload reads; the chat plugins call
  // the same thing `message`, since a row there has no other id.
  // JSON.stringify rather than a hand-built string: a subject never goes in
  // here, but an id from the server still is not ours to trust with quoting.
  function openMessageArgv(alias, folderId, id) {
    return summonArgv(JSON.stringify({
      account: String(alias || ""),
      folderId: String(folderId || ""),
      messageId: String(id || "")
    }))
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

    // Read against the overlay and not the fetch alone, the same way every
    // list on screen reads it. A message marked read here is read whatever
    // this answer still says: marking is optimistic, and the round that
    // follows a delete goes out long before the server agrees. Without this a
    // row the list refilled to its cap with - one already read, sitting just
    // below the fold until the delete pulled it up - is a message the notifier
    // has never seen, carrying the server's stale unread, and it gets
    // announced as new mail the moment it becomes visible.
    var readHere = overrides.read || ({})
    var deletedHere = overrides.deleted || ({})

    // See notifyFloor: how old a message may be and still be one that arrived.
    var floor = Number(notifyFloor[key]) || 0

    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var id = String(row.id || "")
      if (id === "") continue
      // Present, and so remembered, even when it is not worth announcing -
      // that is what keeps it from being announced later.
      present.push(id)
      var when = Model.parseDate(row.received)
      var at = when ? when.getTime() : 0
      // Deleted here and not yet gone from the server's answer. Nothing on
      // screen still shows it, so nothing should announce it either.
      if (deletedHere[id] === true) continue
      var read = readHere[id] === undefined ? row.read === true : readHere[id] === true
      if (read) continue
      // Older than anything this fetch has ever carried, so it surfaced rather
      // than landed. Still unread mail, and the list draws it in bold like any
      // other - but a toast says something just happened, and what happened
      // here was a delete. A message with no readable date is announced as
      // before: guessing it is old would silence real mail.
      if (floor > 0 && at > 0 && at < floor) continue
      var from = String(row["from"] || "")
      fresh.push({
        id: id,
        summary: (place !== "" ? place + " · " : "") + (from !== "" ? from : "New mail"),
        body: String(row.subject || ""),
        // Clicking it opens that message, in that mailbox and folder.
        exec: openMessageArgv(account.alias, account.folderId, id),
        // Two replies to the same conversation in one round are one thing
        // happening, so the second updates the first toast rather than
        // stacking under it. Keyed by conversation, not by message, and
        // scoped so two mailboxes cannot collide.
        replaceKey: String(row.thread || "") !== ""
          ? key + "/" + String(row.thread) : ""
      })
    }

    // What the helper said about the page it read: `full` if there is more
    // behind it, and the oldest row it carried. A helper that said nothing at
    // all leaves the fold where it was rather than guessing from the union of
    // the queries, which is the mistake this used to make.
    var page = account.mailPage || null
    if (page) {
      var nextFloor = {}
      for (var f in notifyFloor) nextFloor[f] = notifyFloor[f]
      var edge = Model.parseDate(page.oldest)
      nextFloor[key] = page.full === true && edge ? edge.getTime() : 0
      notifyFloor = nextFloor
    }

    // Demo data is invented, and a screenshot run should not push six
    // notifications about people who do not exist onto a real desktop.
    notifier.observe(key, fresh, present,
                     !spec || spec.notify !== true || spec.demo === true)
  }

  // ---- one meeting, and answering it --------------------------------------
  //
  // The agenda carries what a grid draws. Who else was invited, what they
  // said, and what the organiser wrote are one request more, made when
  // somebody opens a meeting - and kept, so closing a meeting and opening it
  // again costs nothing.

  property var meetings: ({})
  property var meetingOrder: []
  readonly property int meetingCap: 20

  signal meetingReady(string id, var detail)
  signal meetingFailed(string id, string message)
  // The answer went through. Hosts refresh on this rather than on the button
  // press: what the calendar now says is what the next fetch brings back.
  signal meetingAnswered(string id, string response)

  function rememberMeeting(id, detail) {
    var next = {}
    for (var k in meetings) next[k] = meetings[k]
    next[id] = detail
    var order = meetingOrder.slice()
    var at = order.indexOf(id)
    if (at >= 0) order.splice(at, 1)
    order.push(id)
    while (order.length > meetingCap) delete next[order.shift()]
    meetings = next
    meetingOrder = order
  }

  function forgetMeeting(id) {
    var next = {}
    for (var k in meetings) if (k !== String(id)) next[k] = meetings[k]
    meetings = next
    meetingOrder = meetingOrder.filter(function(k) { return k !== String(id) })
  }

  property var meetingQueue: []
  property var meetingPending: ({})

  function requestMeeting(alias, id, demo) {
    var key = String(id)
    if (!key) return ""
    var cached = meetings[key]
    if (cached) {
      // Asynchronous even when it is already here, so a caller that sets its
      // loading flag after this returns is not left with it stuck on.
      Qt.callLater(function() { root.meetingReady(key, cached) })
      return key
    }
    if (meetingPending[key] === true) return key
    var pending = {}
    for (var k in meetingPending) pending[k] = meetingPending[k]
    pending[key] = true
    meetingPending = pending
    var queued = meetingQueue.slice()
    queued.push({ id: key, alias: String(alias), demo: demo === true })
    meetingQueue = queued
    pumpMeetings()
    return key
  }

  function pumpMeetings() {
    if (meetingProc.running || meetingQueue.length === 0 || pluginDir === "") return
    var next = meetingQueue[0]
    var command = ["python3", helper(), "event", "--account", next.alias, "--id", next.id]
    if (next.demo) command.push("--demo")
    meetingProc.command = command
    meetingProc.running = true
  }

  Process {
    id: meetingProc
    running: false
    stdout: StdioCollector { id: meetingOut; waitForEnd: true }
    stderr: StdioCollector { id: meetingErr; waitForEnd: true }
    onExited: function(exitCode) {
      var job = root.meetingQueue.length > 0 ? root.meetingQueue[0] : null
      root.meetingQueue = root.meetingQueue.slice(1)
      if (job) {
        var pending = {}
        for (var k in root.meetingPending) if (k !== job.id) pending[k] = root.meetingPending[k]
        root.meetingPending = pending
        var parsed = Model.parseJson(meetingOut.text, null)
        if (exitCode !== 0 || !parsed || parsed.ok === false) {
          root.meetingFailed(job.id, parsed && parsed.error
            ? String(parsed.error.message)
            : Model.oneLine(meetingErr.text || "Could not open this meeting", 160))
        } else {
          root.rememberMeeting(job.id, parsed)
          root.meetingReady(job.id, parsed)
        }
      }
      root.pumpMeetings()
    }
  }

  property string answerError: ""
  readonly property bool answering: answerProc.running

  // Accept, tentatively accept or decline. One at a time: there is one meeting
  // open at a time to answer, and a second press while the first is in flight
  // is a double click rather than a second answer.
  function answerMeeting(alias, id, reply, comment, demo) {
    if (!id || answerProc.running || pluginDir === "") return
    answerError = ""
    answerProc.meeting = String(id)
    answerProc.mailbox = String(alias)
    var command = ["python3", helper(), "respond", "--account", String(alias),
                   "--id", String(id), "--reply", String(reply)]
    if (String(comment || "") !== "") command = command.concat(["--comment", String(comment)])
    if (demo === true) command.push("--demo")
    answerProc.command = command
    answerProc.running = true
  }

  Process {
    id: answerProc
    running: false
    property string meeting: ""
    property string mailbox: ""
    stdout: StdioCollector { id: answerOut; waitForEnd: true }
    stderr: StdioCollector { id: answerErr; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(answerOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.answerError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(answerErr.text || "Could not answer this meeting", 160)
        return
      }
      root.answerError = ""
      // What was cached says the old answer, and the answer is the one thing
      // the pane is about to redraw.
      root.forgetMeeting(answerProc.meeting)
      root.meetingAnswered(answerProc.meeting, String(parsed.response || ""))
      // The calendar itself has changed - a declined meeting leaves it - so
      // the agenda is worth asking about again.
      root.refresh([answerProc.mailbox])
    }
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

  // ---- the outbox ---------------------------------------------------------
  //
  // Mail on its way out, and the one queue for the whole shell.
  //
  // Sending used to happen in the host that pressed the button: Service.qml
  // ran the helper, and every control in the compose box was disabled until it
  // came back. That is a token refresh, a message with its attachments going
  // up somebody's uplink, and on the IMAP path an SMTP conversation as well -
  // twenty seconds is ordinary and a minute is not unusual. For all of it the
  // window said "Sending..." and took no keys, so the thing to do with a mail
  // client while a mail was leaving it was wait.
  //
  // Now Send hands the message over and the box closes at once. The queue is
  // here rather than in the host for two reasons: the window is one of several
  // hosts and it can be closed, and a send that dies because somebody shut the
  // window they wrote it in is a message silently lost. Here it outlives the
  // window, the bar can say how many are waiting, and a failure has somewhere
  // to sit until the person who wrote it decides what to do about it.
  //
  // What is *not* here: "Save as draft". It ends by opening the draft in
  // Outlook, so its answer has to arrive back in the host that asked for it,
  // and there is nothing to wait for in the background - see Service.qml.
  //
  // One job:
  //   { id, alias, mode, messageId, to, cc, subject, text, attachments,
  //     demo, title, recipient,
  //     state: "queued" | "sending" | "failed",
  //     what, done, total, error, code, at }
  // `title` and `recipient` are for drawing the row and are never read here -
  // a reply's subject belongs to the message it answers, which the host has
  // and the store does not.
  property var outbox: []
  property int outboxSerial: 0

  // Sent, and gone from the queue. Hosts refresh on this rather than on the
  // press: what is in Sent Items is what the next fetch brings back. `notice`
  // says what rode along with it, because a forward carrying files is worth
  // more than "Sent".
  signal sendFinished(string jobId, string notice)
  // Still in the queue, with its error, waiting to be retried or discarded.
  signal sendFailed(string jobId, string message)

  readonly property int outboxFailed: {
    var n = 0
    for (var i = 0; i < outbox.length; i++)
      if (outbox[i].state === "failed") n++
    return n
  }

  function outboxJob(jobId) {
    var wanted = String(jobId)
    for (var i = 0; i < outbox.length; i++)
      if (String(outbox[i].id) === wanted) return outbox[i]
    return null
  }

  // Replace one job, by id. The list is copied rather than mutated in place
  // because QML notices an assignment and does not notice a write into an
  // array it already has - a progress line that changed a row without
  // replacing the list left the bar sitting where it was.
  function patchJob(jobId, patch) {
    var wanted = String(jobId)
    var next = []
    for (var i = 0; i < outbox.length; i++) {
      var job = outbox[i]
      if (String(job.id) !== wanted) { next.push(job); continue }
      var merged = {}
      for (var k in job) merged[k] = job[k]
      for (var j in patch) merged[j] = patch[j]
      next.push(merged)
    }
    outbox = next
  }

  function dropJob(jobId) {
    var wanted = String(jobId)
    var next = []
    for (var i = 0; i < outbox.length; i++)
      if (String(outbox[i].id) !== wanted) next.push(outbox[i])
    outbox = next
  }

  // Put a message in the queue. Answers the job's id, which is what a host
  // holds on to if it wants to follow this one.
  function queueSend(job) {
    outboxSerial = outboxSerial + 1
    var id = String(outboxSerial)
    var queued = {
      id: id,
      alias: String(job.alias || ""),
      mode: String(job.mode || "reply"),
      messageId: String(job.messageId || ""),
      to: String(job.to || ""),
      cc: String(job.cc || ""),
      subject: String(job.subject || ""),
      text: String(job.text || ""),
      attachments: (job.attachments || []).slice(),
      demo: job.demo === true,
      // The message being answered, carried untouched and never read here.
      // Edit on a failed row has to put the reply back together as it was, and
      // a mode that answers an original cannot be rebuilt from an id alone.
      mail: job.mail || null,
      title: String(job.title || ""),
      recipient: String(job.recipient || ""),
      state: "queued",
      what: "",
      done: 0,
      total: 0,
      error: "",
      code: "",
      at: Date.now()
    }
    var next = outbox.slice()
    next.push(queued)
    outbox = next
    pumpOutbox()
    return id
  }

  // A failed job, sent again from the top. Its error goes now rather than when
  // the helper answers: a row still showing last time's failure while a bar
  // moves under it says two things at once.
  function retrySend(jobId) {
    var job = outboxJob(jobId)
    if (!job || job.state !== "failed") return
    patchJob(jobId, { state: "queued", error: "", code: "", what: "", done: 0, total: 0 })
    pumpOutbox()
  }

  // Give it back to whoever wants to edit it, and take it out of the queue.
  // The words are the person's, so they are handed over rather than copied and
  // left here to be sent by a later pump as well.
  function takeBackSend(jobId) {
    var job = outboxJob(jobId)
    if (!job || job.state === "sending") return null
    dropJob(jobId)
    return job
  }

  function discardSend(jobId) {
    var job = outboxJob(jobId)
    // A send already on the wire cannot be called back - the message may
    // already be in the recipient's mailbox - so this refuses rather than
    // pretending. It becomes discardable again the moment it fails.
    if (!job || job.state === "sending") return
    dropJob(jobId)
  }

  // One at a time, and in the order they were written. A send is a token
  // refresh as well, and Entra rotates refresh tokens - two at once for one
  // mailbox risks an avoidable sign-in, which is the same reason fetches for a
  // mailbox are serialised. The order matters on its own account, too: two
  // replies to the same thread should leave in the order somebody wrote them.
  function pumpOutbox() {
    if (sendProc.running || pluginDir === "") return
    var next = null
    for (var i = 0; i < outbox.length && !next; i++)
      if (outbox[i].state === "queued") next = outbox[i]
    if (!next) return

    var command = ["python3", helper(), "compose",
                   "--account", next.alias,
                   "--mode", next.mode,
                   "--stdin", "--progress"]
    if (next.mode !== "new") command = command.concat(["--id", next.messageId])
    // A harness runs with this on. Without it, pressing Send there reaches the
    // mailbox with a real token - see graph.py's demo line in cmd_compose.
    if (next.demo) command.push("--demo")
    for (var a = 0; a < next.attachments.length; a++)
      command = command.concat(["--attach", String(next.attachments[a])])

    sendProc.jobId = next.id
    sendProc.problem = ""
    patchJob(next.id, { state: "sending", what: "", done: 0, total: 0 })
    sendProc.command = command
    sendProc.running = true
  }

  Process {
    id: sendProc
    running: false
    stdinEnabled: true
    // Which job is on the wire. Read in onExited, so it has to survive the
    // list being rewritten under it - an id rather than an index or the object.
    property string jobId: ""
    // Whatever the helper said on stderr that was not a phase. It is the error
    // message of last resort, for a helper that died before printing its own.
    property string problem: ""

    onStarted: {
      var job = root.outboxJob(sendProc.jobId)
      if (!job) return
      // The words go over stdin, never in argv: anyone on this machine can
      // read /proc/<pid>/cmdline while a process runs, and this is somebody's
      // letter. The subject travels the same way for the same reason.
      sendProc.write(JSON.stringify({ comment: job.text, to: job.to,
                                      cc: job.cc, subject: job.subject }) + "\n")
    }

    stdout: StdioCollector { id: sendOut; waitForEnd: true }

    // The phases, one JSON object per line - see graph.py's Progress. Not
    // stdout: that is exactly one JSON object and every caller parses it as
    // one, which is invariant 5. A line that is not a phase is kept as the
    // error of last resort instead of being thrown away.
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        var text = String(line || "")
        if (text.trim() === "") return
        var parsed = Model.parseJson(text, null)
        if (parsed && parsed.progress) {
          var step = parsed.progress
          root.patchJob(sendProc.jobId, {
            what: String(step.what || ""),
            done: Number(step.done) || 0,
            total: Number(step.total) || 0
          })
          return
        }
        sendProc.problem = sendProc.problem === "" ? text : sendProc.problem + " " + text
      }
    }

    onExited: function(exitCode) {
      var jobId = sendProc.jobId
      var job = root.outboxJob(jobId)
      sendProc.jobId = ""
      var parsed = Model.parseJson(sendOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        var error = parsed && parsed.error ? parsed.error : null
        var message = error ? String(error.message || "Could not send this message")
                            : Model.oneLine(sendProc.problem || "Could not send this message", 200)
        // It stays in the queue with what went wrong on it. Nobody's words are
        // thrown away by a failure: Retry, Edit and Discard are all still
        // there, and Edit hands the whole draft back to the compose box.
        root.patchJob(jobId, { state: "failed", what: "",
                               error: message,
                               code: error ? String(error.code || "") : "" })
        // The window it was written in may well be closed by now - that is
        // half of why the queue is here - so a failure nobody would otherwise
        // see gets a toast. Critical, because a mail that did not go out is
        // not something to notice tomorrow.
        if (job && job.demo !== true)
          root.notify("Mail not sent", (job && job.title !== "" ? job.title + ": " : "") + message, true)
        root.sendFailed(jobId, message)
        root.pumpOutbox()
        return
      }
      // Say what rode along with it. A forward on the IMAP path used to drop
      // the original's attachments without a word, and "Sent" was the last
      // thing said before it did - so the count is worth the two lines.
      var carried = parsed.carried && parsed.carried.length ? parsed.carried.length : 0
      var notice = carried > 0
        ? ("Sent, with " + carried + (carried === 1 ? " file" : " files"))
        : "Sent"
      root.dropJob(jobId)
      root.sendFinished(jobId, notice)
      // A reply usually means the message is dealt with, and a new message
      // lands in Sent - which is a folder a window may be looking at.
      if (job) root.refresh([job.alias])
      root.pumpOutbox()
    }
  }

  // ---- folders as things that can be made and unmade ----------------------
  //
  // One process for all four actions. They are all somebody's deliberate act
  // on one folder, one at a time, and a second while the first is in flight is
  // refused rather than queued - a rename racing a move on the same folder is
  // two answers about where it now is.

  readonly property bool folderBusy: folderProc.running

  // Told to every host, because a folder that has just been renamed or deleted
  // is one that somebody else's sidebar is pointing at. `was` is the id it had
  // - on IMAP a folder id is its path, so renaming or moving one changes it.
  signal folderChanged(string alias, string action, string folderId, string was)

  function folderAction(alias, action, folderId, name, parent) {
    if (!alias || folderProc.running || pluginDir === "") return
    var verbs = { "new": "folder-new", "rename": "folder-rename",
                  "move": "folder-move", "delete": "folder-delete" }
    var verb = verbs[String(action)]
    if (!verb) return
    actionError = ""
    actionNotice = ""

    var command = ["python3", helper(), verb, "--account", String(alias)]
    if (action !== "new") command = command.concat(["--id", String(folderId || "")])
    if (action === "new" || action === "rename") command = command.concat(["--name", String(name || "")])
    if (action === "new" || action === "move") command = command.concat(["--parent", String(parent || "")])

    folderProc.mailbox = String(alias)
    folderProc.what = String(action)
    folderProc.was = String(folderId || "")
    folderProc.label = String(name || "")
    folderProc.command = command
    folderProc.running = true
  }

  Process {
    id: folderProc
    running: false
    property string mailbox: ""
    property string what: ""
    property string was: ""
    property string label: ""
    stdout: StdioCollector { id: folderOut; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(folderOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.actionError = parsed && parsed.error
          ? String(parsed.error.message) : "Could not change that folder"
        return
      }
      var name = String(parsed.name || folderProc.label)
      var notices = {
        "new": name !== "" ? "Made " + name : "Folder made",
        "rename": name !== "" ? "Renamed to " + name : "Folder renamed",
        "move": name !== "" ? "Moved " + name : "Folder moved",
        "delete": name !== "" ? "Deleted " + name : "Folder deleted"
      }
      root.actionNotice = notices[folderProc.what] || "Done"
      root.folderChanged(folderProc.mailbox, folderProc.what,
                         String(parsed.id || ""), folderProc.was)
      // The tree comes back with the fetch, so the sidebar redraws itself the
      // moment this lands rather than at the next poll.
      root.refresh([folderProc.mailbox])
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
