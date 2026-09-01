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
src/Model.js          Pure JS: shaping, grouping, dates, link building. No Qt
                      types, so `node dev/test-model.js` can run it.
src/Store.qml         *** The one service, per plugin, for the whole shell. ***
src/Service.qml       One host's *view* of the store: filters, open folder,
                      message being read, a half-written reply.
src/BarWidget.qml     The bar icon.
src/Panel.qml         The bar dropdown: merged mail beside the merged agenda.
src/MailWindow.qml    The window: folders, list, reading pane. ~1.2k lines.
src/MailList.qml      A ListView, deliberately — read the comment at the top.
src/AgendaList.qml    The day-grouped agenda. AgendaTimeline.qml is the grid.
src/Notifier.qml      omarchy-notification-send, the prime-then-announce rule,
                      and the click that opens the message.
src/PollGate.qml      Whether it is worth polling at all: idle, network, battery.
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
2. **The window never fetches anything remote.** With `htmlBody` on, images and
   anything else remote are stripped *before* rendering, so nothing in a message
   can phone home or report a read receipt.
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

- **Three transports, chosen per mailbox** by `"transport"` on the widget entry.
  Graph is the default; `"imap"` moves mail to IMAP/SMTP and the calendar to
  EWS. `GRAPH_CAPABILITIES` gates calendar, Focused and webLinks behaviour, so a
  feature added on the Graph path needs a decision about the IMAP one.
- **Entra will not mint a token for one resource from another's refresh token.**
  Mail (IMAP), sending (SMTP) and calendar (EWS) each need their own interactive
  consent and their own token set; the calendar's lives under
  `account["calendar"]`. Asking for a scope the account did not consent to fails
  with AADSTS65001, not with a prompt.
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
- **`compose` only replies, replies-all and forwards.** There is no "new
  message" — writing a fresh mail means leaving for Outlook, and the
  `--draft` path opens Outlook by design. That is the plugin's biggest hole, and
  it is the kind of hole worth closing rather than documenting.
- **`MailList.qml` is a `ListView` on purpose**, and the comment at the top says
  why a `Repeater` over a plain array was worse. The Slack and Teams plugins have
  not made that change yet; if you are porting UI between them, port this too.
- **`TEXT_BODY_CAP` governs how much of a body the reading pane shows.** When
  weighing a display limit against a preview/bandwidth cost, display wins.
- **The window has no settings of its own.** It is one per plugin while the
  widget is multi-instance, so it reads a widget's configuration out of
  `shell.json`.

## House style

Comments and prose explain **why**, never what — the headers of `Store.qml`,
`imapmail.py` and `ewscal.py` are the register to match: state plainly what
would otherwise only live in the git log, including the uncomfortable parts.
Full sentences. A comment that restates the line below it does not survive
review. The README is written for a person deciding whether to install this, and
says plainly what the plugin does not do.

Keep the work inside the app. When something cannot be finished here, that is
the bug — not a reason to hand the user off to Outlook or a browser.
