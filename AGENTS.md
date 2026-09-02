# AGENTS.md

An Omarchy shell plugin: unread Outlook mail and your agenda, in the bar as a
popup and in a window of its own. One widget can carry several mailboxes, and
the widget is multi-instance. Quickshell/QML on top of Python helpers. Read
`README.md` for what it does and how it is installed — this file is about
changing it.

## Orientation, in one pass

```
manifest.json         schemaVersion 1. kinds: bar-widget + panel + service, and
                      the settings schema the shell's settings panel renders.
                      Adding a setting means adding it here AND reading it
                      through `setting()`.
src/graph.py          The helper. Microsoft Graph, the device-code sign-in, and
                      the token store. Prints one JSON object per invocation.
src/imapmail.py       IMAP/SMTP transport, for tenants that will not consent to
                      Graph's Mail.Read. Same device-code sign-in.
src/ewscal.py         EWS calendar, for a mailbox read over IMAP — IMAP carries
                      no calendar, and Entra issues one token per resource.
src/config.py         Shared config/paths for the three.
src/Model.js          Pure JS: shaping, grouping, dates, link building, and
                      the recipient completion. No Qt types, so
                      `node dev/test-model.js` can run it.
src/Store.qml         *** The one service, per plugin, for the whole shell. ***
src/Service.qml       One host's *view* of the store: filters, open folder,
                      message being read, a half-written reply.
src/BarWidget.qml     The bar icon.
src/Panel.qml         The bar dropdown: merged mail beside the merged agenda.
src/MailWindow.qml    The window: folders, list, reading pane. ~1.7k lines.
src/RecipientField.qml
                      A To/Cc field that completes from the address book.
src/MailList.qml      A ListView, deliberately — read the comment at the top.
src/MeetingPane.qml   One meeting: who is coming, what they said, and the
                      Accept/Maybe/Decline that used to mean opening Outlook.
                      Shown where the agenda is, in both the popup and window.
src/AgendaList.qml    The day-grouped agenda. AgendaTimeline.qml is the grid.
src/Notifier.qml      omarchy-notification-send, the prime-then-announce rule,
                      and the click that opens the message.
src/PollGate.qml      Whether it is worth polling at all: idle, network, battery.
src/handover.sh       Builds the prompt that hands a message to the user's
                      coding agent and execs omarchy-agent. Runnable by hand;
                      --print shows the prompt and launches nothing.
skills/omarchy-office365/
                      What that agent is pointed at: the helper's commands, and
                      how to put a draft reply in the window's reply box
                      instead of sending it.
```

**Store vs Service is the thing to understand first.** The bar widget and the
window are separate hosts, and a bar surface exists *per monitor*, so there are
several `Service`s. They used to each own a fetch loop, which polled one mailbox
two or three times over and left the bar showing a message unread after the
window marked it read. So the data moved into `Store.qml` — one per plugin,
built by the shell because the manifest declares `kinds: ["service"]`. What two
readers must agree on lives in the store: fetched mail, the optimistic
read/deleted overlay, message bodies, the palette, the sign-in state machine.
What belongs to one host stays in `Service.qml`. Fetching is keyed by mailbox
*and* folder, and requests for one mailbox run one at a time — a fetch is also a
token refresh and Entra rotates refresh tokens, so two at once risks an
avoidable sign-in. Do not add a poll outside the store.

## Invariants. Breaking one of these is a security bug, not a regression

1. **Tokens never reach QML.** They live under `~/.local/state/omarchy/` mode
   600, and reach the helpers on **stdin** — never in argv (anyone on the machine
   can read another process's command line) and never in `shell.json`
   (world-readable).
2. **The window never fetches anything remote.** Wherever a message's own
   markup is rendered - the reader pressed **Show formatting**, the sender has
   a standing rule, `htmlBody` is on, or the message carried no plain-text part
   at all - images and anything else remote are stripped *before* rendering, so
   nothing in a message can phone home or report a read receipt.
3. **A message never chooses its own markup** beyond what the sanitiser allows.
   Links are `http`, `https`, `mailto` only, checked in Python, again in
   `Model.js` where the anchor is written, and once more in `openUrl` before the
   browser sees it. Keep all three.
4. **Stdlib only.** No pip, nothing vendored — `imaplib`, `smtplib`, `email`,
   `urllib` are the whole toolkit.
5. **Every helper command prints one JSON object** and exits 0 even on failure —
   `{"ok": false, "error": {...}}` — so the widget always has something to
   render. Exit non-zero only when the arguments themselves were unusable.
6. **A transport must be invisible downstream.** `ewscal.py` shapes its events
   exactly like the Graph path's, and converts EWS's UTC answers to local time,
   *because* `parseDate` in `Model.js` reads a zone-less timestamp as local wall
   clock. Anything new that returns mail or events shapes it the same way.
7. **`account["write"]` on the IMAP path is local policy, not a boundary.** IMAP
   has no read-only scope. Say so in comments rather than implying the token
   enforces it; on the Graph path it does.
8. **No symlinks anywhere in this repo.** `omarchy plugin validate` refuses a
   plugin folder that contains one. That is why the dev harness is assembled
   outside the repo — see below.
9. **Colors and spacing come from `qs.Commons`** (`Color`, `Style`, `Border`).
   No hardcoded hex, no hardcoded pixel gaps.
10. **`ipcTarget` is empty by default and must stay that way.** The widget is
    multi-instance; several instances registering one IPC target would collide.
    A user opts one instance in by setting `"ipcTarget": "mail"`.

## The dev loop

```bash
node    dev/test-model.js                            # the shaping the UI binds to
python3 dev/test-python.py                           # the helpers: parsing, transports, hosts
python3 src/graph.py fetch --account work --demo     # synthetic data, no sign-in
python3 src/graph.py palette                         # the theme's named colours

dev/run.sh                                           # the real UI, offscreen
dev/shot.sh /tmp/mail.png                            # photograph what it is drawing
dev/showcase.sh                                      # regenerate the README images
```

A syntax check across the whole repo, which is worth having before a commit and
is not on `$PATH`:

```bash
/usr/lib/qt6/bin/qmlformat src/*.qml >/dev/null   # silence means they all parse
```

A bare `qmlformat` is "command not found", and inside a loop with `|| echo FAIL`
that reads as every file being broken - which is a confusing way to learn that
nothing is wrong. It catches what a running shell does not: a file that parses
but is never imported by the harness.

`dev/link.sh` assembles a Quickshell config folder in
`$XDG_RUNTIME_DIR/omarchy-office365-dev` and symlinks the sources plus
`dev/shell.qml` and `dev/Fixtures.js` into it. It has to: Quickshell only
imports modules from inside its own config folder, so `Commons/` and `Ui/` from
`/usr/share/omarchy/shell/` must sit beside a `shell.qml` — and the repo itself
may not contain symlinks (invariant 8). Editing a link edits the real file.

**Installed-copy edits need a real restart.** `omarchy-shell shell reloadConfig`
and `rescanPlugins` both return ok without re-reading plugin QML or a widget's
entry in `shell.json`. Run `omarchy-restart-shell` and confirm the PID moved
(`pgrep -af 'quickshell -n'`). A surviving PID also proves the QML parsed — a
fatal QML error makes it exit instead. Symptom of forgetting: a sign-in that
keeps using the old client id or authority.

## Things that will surprise you

- **A toast is a route back in, and it survives a shell restart.** Notifications
  go out through `omarchy-notification-send`, whose `--exec` becomes the
  `omarchy-exec-argv` hint: the click action rides as *data*, so omarchy can
  still run it after the shell that sent it has been restarted, which a live
  libnotify action cannot. Clicking runs `omarchy-shell shell summon <id>
  '<json>'` and the payload lands in the window's `open()`. Two traps: that
  sender has no `--` to end its options, so a headline that is exactly one of
  its flags is guarded with a leading space in `asText()`; and `-r` needs the id
  a previous send printed with `-p`, which is what makes several messages in one
  conversation update one toast instead of stacking.
- **The poll gate's signals arrive late.** For the first second or two of a
  shell's life UPower has no devices, NetworkManager reports `Unknown`
  connectivity and `canCheckConnectivity` is false - measured, on this machine.
  Every default in `PollGate.qml` therefore means "go ahead": a gate that failed
  closed would swallow the first fetch after every shell start, which is the one
  that fills an empty panel.
- **A formatted message brings its own colours, and they are for white paper.**
  Outlook and Word put `color: black` (or `rgb(0, 0, 0)`, or `windowtext`) on
  almost every span they emit; Qt's rich text obeys it, so on a dark theme the
  body came out black on near-black and could only be read by selecting it.
  `Model.legibleBody` measures each declaration against the pane's background
  and drops the ones that fail, which lets that text inherit the pane's
  foreground. It lives in `Model.js` beside `withLinkColor` for that function's
  two reasons: the helper does not know the theme, and bodies are cached in the
  store - so a decision made in Python would have to survive the user changing
  theme. Backgrounds are dropped unconditionally, and that is what makes the
  test correct rather than approximate: with none surviving there is one
  background to judge against and no cascade to reconstruct from a regex.
  `MailPreview` and `MeetingPane` call `bodyMarkup`, which is both passes in
  the one order that works - the link colour is a default that a sender's own
  anchor colour would beat, so the unreadable one has to be gone first.
- **`out()` does not exit here.** In `slack.py` and `teams.py` it does, so a
  command ends at its `out(...)`. In `graph.py` only `fail()` exits: every
  `out(...)` needs the `return` after it, and code copied across from the chat
  plugins will happily print an answer and then carry on and make the request.
  This is not hypothetical: `cmd_compose` was missing two of them, so **Save as
  draft** created the draft and then sent the message, and a reply with a file
  went out twice. The test stubs make `out()` raise, which hides exactly this —
  `ComposeStopsWhenItIsDone` in `dev/test-python.py` lets it print instead and
  counts the requests, and any new command with more than one `out()` wants the
  same treatment.
- **`compose` reaches the mailbox unless `--demo` says otherwise**, and the
  window passes `--demo` when the widget has `demo` on. That line was added
  after a dev harness whose fixture alias was `work` - a real signed-in mailbox
  here - pressed Send and made a real Graph request; the fixture's message id
  was refused as malformed, which is the only reason nothing was sent. Give a
  scratch harness an alias no mailbox uses, and check the demo line is there
  before you press anything that writes.
- **Three transports, chosen per mailbox** by `"transport"` on the widget entry.
  Graph is the default; `"imap"` moves mail to IMAP/SMTP and the calendar to
  EWS. `GRAPH_CAPABILITIES` gates calendar, Focused and webLinks behaviour, so a
  feature added on the Graph path needs a decision about the IMAP one.
- **Entra will not mint a token for one resource from another's refresh token.**
  Mail (IMAP), sending (SMTP) and calendar (EWS) each need their own interactive
  consent and their own token set; the calendar's lives under
  `account["calendar"]`. Asking for a scope the account did not consent to fails
  with AADSTS65001, not with a prompt.
- **An attachment cannot ride on `/reply`.** Those endpoints take a comment and
  recipients and nothing else, so `compose --attach` builds the same draft the
  `--draft` path builds, POSTs each file to `/attachments`, and sends the draft.
  Three requests where there was one, and only when something is attached. The
  cap - 3 MB in total, shared with the IMAP path - is what one request can
  carry: base64 costs a third on top of a 4 MB request limit, and the route past
  it is an upload session on an Outlook host this helper does not talk to.
- **`make_msgid()` costs five seconds and leaks the hostname.** With no
  `domain=` it calls `socket.getfqdn()`, which blocks until the resolver gives
  up on a machine whose hostname does not resolve - five seconds on every IMAP
  reply, measured here - and then writes that hostname into a header the
  recipient reads. `imapmail.compose` passes the mailbox's own domain. Any new
  header built from the local machine deserves the same suspicion.
- **`compose --mode new` is the one mode with no original.** The other three
  name Graph endpoints that hang off a message, which is why `new` is not in
  `COMPOSE_MODES`: there is no `createReply` to ask for it, so the whole message
  is assembled and handed to `/me/sendMail` (or POSTed to `/me/messages` for a
  draft) in one request — attachments inside it, so none of the
  draft-attach-send dance a reply needs. `--id` is therefore optional and
  guarded per mode instead. Over IMAP the difference is what is *left out*:
  nothing is fetched, nothing is quoted, and there is no `In-Reply-To`.
- **Anything typed into a To field arrives with a name on it.** `recipient_list`
  used to split the whole field on whitespace as well as on commas, so `Jan Renz
  <jan@example.com>` became three entries and two of them had no `@` - and
  forwarding to anybody whose address had not been typed out by hand answered
  `bad_recipient: Not an email address: Jan, Renz`. Every entry is now parsed
  the way a mail client parses one, and `split_address_list` scans rather than
  splits, because a display name may hold a comma inside its quotes and an
  angle-bracketed address may not be cut apart. `Model.lastAddressFragment`
  keeps the same rule in QML, for the entry being completed. Three places, one
  rule; change one and change all three.
- **The address book is harvested, not fetched.** `Store.qml` builds it from
  rows that have arrived and messages that have been opened. Graph's
  `/me/people` and `/me/contacts` need consent this plugin does not ask for and
  an IMAP mailbox has no contacts endpoint at all, so a book from either would
  be empty on the transport the FWU mailbox uses. It lives for the shell's
  lifetime and is never written down.
- **`MailList.qml` is a `ListView` on purpose**, and the comment at the top says
  why a `Repeater` over a plain array was worse. The Slack and Teams plugins have
  not made that change yet; if you are porting UI between them, port this too.
- **`TEXT_BODY_CAP` governs how much of a body the reading pane shows.** When
  weighing a display limit against a preview/bandwidth cost, display wins.
- **The window's header collapses if the pills outgrow the width beside the
  title.** `header` is anchored to `headerActions.left`; once the pills no
  longer fit, that right edge is left of the row's own left one, its
  `implicitHeight` goes to zero, and an `Item` sized `height:
  header.implicitHeight` takes the title, every pill and the whole header off
  the window. Nothing is printed - no binding loop, no TypeError - so it reads
  as "my new pill broke the header" rather than "the header has no slack
  left". It is `Math.max` of the two rows now, and a control added at the
  widths where the header is fullest wants a glyph rather than a word: the
  Calendar pill is `\u{F00ED}` for that reason, not for decoration.
- **The agenda scroller holds two children**, the grid and the list, and a
  `ScrollView` derives its content size from a single one. With two it measured
  nothing, so an agenda taller than the pane could not be scrolled by anything
  - keys or wheel. `contentHeight` is stated, from whichever child the
  `agendaView` setting is showing.
- **The window has no settings of its own.** It is one per plugin while the
  widget is multi-instance, so it reads a widget's configuration out of
  `shell.json`.
- **`MailWindow.open(payloadJson)` is a contract now, not a stub.** Beside the
  old `{"instance": "..."}` it takes `account`, `folderId` and `messageId` -
  what a clicked notification passes - and a `draft` object, which puts a
  coding agent's reply in the reply box unsent. The shell drains its payload
  queue in a loop and delivers to a window that is already open, so anything
  added there has to survive arriving twice. A message in a folder that has not
  been read yet cannot be revealed at once, which is why `pendingMessageId` and
  the `Connections` on `mailView.mail` exist: the folder is fetched and the
  request answered when the list lands. `omarchy-shell shell call <id>
  agentDraft '<json>'` is the same draft route and returns what it made of it.
- **The dropdown offers every action the window does and performs none of the
  hard ones.** A pane that silently has five fewer buttons than the same pane
  elsewhere is a difference nobody can explain, so `Panel.qml` sets
  `canCompose`, `canMove` and `canAgent` like the window — and `actsHere:
  false`, which puts "opens the window on it" in those tooltips. The buttons
  call `handOff`, which summons the window with `{account, folderId, messageId,
  action}`; `MailWindow.applyPayload` reveals the message and then runs the
  action once the fetch has landed, which is why `pendingAction` rides with
  `pendingMessageId` rather than being acted on at once. Adding an action to
  the reading pane means deciding which surface performs it.
- **"Every mailbox on the same folder" is a state, not a folder.** The window's
  list has always been merged - `snapshot` walks every alias - but
  `selectedFolders` is per mailbox, so clicking one folder in the tree broke the
  merge with no way back, and the title said one mailbox's address about a list
  holding three. `Model.unifiedFolder` derives the state, `folderRows` draws the
  merged group above the per-mailbox trees with `alias: "*"`, and
  `selectFolderEverywhere` sets them all. It sends the well-known *name*
  ("archive", "sentitems"), never an id: no id means the same folder in two
  mailboxes. `unifiedFolder` is deliberately "" for a single mailbox, or the
  tree would stop lighting the folder that is open.
- **The coding-agent handover is one setting away from not existing.**
  `agentHandover` gates the `a` key, the reading pane's button, the help entry
  and the inbound draft. A feature that reaches somebody's mail has to be
  refusable, so check the gate rather than assuming it.
- **`dev/link.sh` symlinks `dev/shell.qml` into the stage.** Writing a
  throwaway harness to `$STAGE/shell.qml` therefore writes it *into the repo*,
  through the symlink. Give a scratch harness any other name.
- **`open()` re-reads `shell.json` every time it is called.** A dev harness
  that calls it after putting fixture settings in place has them replaced by
  the real widget's - which points the harness at a real mailbox. Drive
  `applyPayload` directly instead.
- **The demo fixtures are read-only** (`"write": False`, `"send": False` in
  `graph.py`), so no compose path can be exercised against them without
  changing the fixture in the staged copy outside the repo.

## House style

Comments and prose explain **why**, never what — the headers of `Store.qml`,
`imapmail.py` and `ewscal.py` are the register to match: state plainly what
would otherwise only live in the git log, including the uncomfortable parts.
Full sentences. A comment that restates the line below it does not survive
review. The README is written for a person deciding whether to install this, and
says plainly what the plugin does not do.

Keep the work inside the app. When something cannot be finished here, that is
the bug — not a reason to hand the user off to Outlook or a browser.
