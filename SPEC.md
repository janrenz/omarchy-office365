# SPEC.md — Office 365 Mail & Calendar

**Status: descriptive.** This records what the plugin does as of version
**1.10.0** (2026-09-04). It is the contract; `AGENTS.md` is how to change it;
`README.md` is for somebody deciding whether to install it. The contract all
three communication plugins share lives in [`PLATFORM.md`](PLATFORM.md) and is
not restated here.

---

## 1. Scope

Unread Outlook mail and the agenda, in the bar as a dropdown and in a window of
its own. Works against Microsoft 365 (work/school) and Outlook.com (personal).

**One widget can carry several mailboxes.** With several, mail and calendars
merge into one overview and a coloured rail on each row says which mailbox a row
came from. The widget is also `allowMultiple: true`, so a mailbox can be given
an icon of its own instead. The two styles mix freely.

| | |
|---|---|
| Plugin id | `caseonline.omarchy.office365` |
| Kinds | `bar-widget`, `panel`, **`service`** |
| Entry points | `src/BarWidget.qml`, `src/MailWindow.qml`, `src/Store.qml` |
| `allowMultiple` | **true** |
| Helper | `src/graph.py` (dispatches to `imapmail.py` / `ewscal.py`) |
| State | `~/.local/state/omarchy/office365/` |

**This is the only one of the three with a `service` kind**, and therefore the
only one with a true singleton. See §5.

---

## 2. Transports

Three, chosen **per mailbox** by `"transport"` on the widget entry.

| Transport | Mail | Calendar | Sending |
|---|---|---|---|
| `""` (default) | Microsoft Graph | Graph | Graph `/me/sendMail` |
| `"imap"` | IMAP (`outlook.office365.com`) | **EWS** | SMTP (`smtp.office365.com:587`) |

IMAP exists for tenants that will not consent to Graph's `Mail.Read`. EWS exists
because **IMAP carries no calendar**, and Entra issues one token per resource.

Three rules govern this split:

1. **A transport must be invisible downstream.** `ewscal.py` shapes its events
   exactly like the Graph path's and converts EWS's UTC answers to local time,
   *because* `Model.parseDate` reads a zone-less timestamp as local wall clock.
   Anything new returning mail or events shapes it the same way.
2. **`GRAPH_CAPABILITIES` gates `calendar`, `focused` and `webLinks`.** A
   feature added on the Graph path needs a decision about the IMAP one.
3. **`account["write"]` on the IMAP path is local policy, not a boundary.** IMAP
   has no read-only scope. On the Graph path the token enforces it; over IMAP it
   does not, and comments must say so rather than implying otherwise.

**Entra will not mint a token for one resource from another's refresh token.**
Mail (IMAP), sending (SMTP) and calendar (EWS) each need their own interactive
consent and their own token set; the calendar's lives under
`account["calendar"]`. Asking for a scope the account did not consent to fails
with `AADSTS65001`, not with a prompt.

### 2.1 Scopes

| Constant | Value |
|---|---|
| `SCOPES_READ` | `openid profile offline_access User.Read Mail.Read Calendars.Read` |
| `SCOPES_WRITE` | the above plus `Mail.ReadWrite`, `Calendars.ReadWrite` |
| `SCOPES_IMAP_READ` | `offline_access https://outlook.office365.com/IMAP.AccessAsUser.All` |
| `SCOPES_IMAP_WRITE` | the above plus `SMTP.Send` |
| `SCOPES_EWS` | `offline_access https://outlook.office365.com/EWS.AccessAsUser.All` |

Sign-in is OAuth 2.0 **device code**. No password, no client secret.
`DEFAULT_CLIENT_ID` is `1cebbbf2-…`; the IMAP path uses Thunderbird's public
client id `9e5f94bc-…`. A Graph mailbox can borrow that or another well-known
client: `CLIENT_ID_ALIASES` maps the names `office` (Microsoft's first-party
`d3590ed6-…`), `thunderbird`, and `apple` (`f8d98a96-…`), typed in the client id
field or passed to `--client-id`, onto their GUIDs, and `resolve_client_id`
spells one out before the device code is asked for - so what is stored, and what
a token belongs to, is always the GUID. Default authority is `common`.

Write scope is **per mailbox and opt-in**: "Allow changes…" signs that one
mailbox in again with the wider scope. Every other mailbox stays read-only, and
a widget never granted anything can never change mail.

---

## 3. Helper command surface

`python3 src/graph.py <command> --account <alias> [...]`. Every command obeys
the helper contract in `PLATFORM.md` §2.

### 3.1 Sign-in

| Command | Arguments | Returns |
|---|---|---|
| `login-start` | `--client-id` *(GUID or `thunderbird`)*, `--authority`, `--transport {"",imap}`, `--write`, `--calendar` | device code, verification URI |
| `login-poll` | — | pending, or the stored sign-in |
| `list` | *(no account)* | configured aliases |
| `remove` | — | forgets the account |
| `palette` | *(no account)* | the theme's named colours |

### 3.2 Reading

| Command | Arguments | Notes |
|---|---|---|
| `fetch` | `--account` (repeatable), `--mails`, `--days`, `--folder ALIAS=ID` (repeatable), `--from-now`, `--demo` | The poll. Mail **and** agenda in one answer. |
| `search` | `--account` (repeatable), `--query` \| `--stdin`, `--scope {all,folder}`, `--folder`, `--limit`, `--demo` | Query goes over **stdin** |
| `message` | `--id`, `--body {auto,html,text}`, `--html`, `--load-images`, `--demo` | One message's body |
| `folders` | — | One mailbox's folder tree |
| `event` | `--id`, `--demo` | One meeting, with attendees |
| `attachment` | `--id`, `--key`, `--into`, `--demo` | **Writes the file and answers with its path** |

### 3.3 Writing

| Command | Arguments | Requires |
|---|---|---|
| `mark` | `--id`, `--read` \| `--unread` | write |
| `flag` | `--id`, `--flag` \| `--unflag` | write |
| `delete` | `--id` | write |
| `move` | `--id`, `--folder` | write |
| `compose` | `--id`, `--mode`, `--comment` \| `--stdin`, `--to`, `--cc`, `--subject`, `--attach` (repeatable), `--draft`, `--demo` | send |
| `respond` | `--id`, `--reply {accept,tentative,decline}`, `--comment` | respond |
| `folder-new` | `--name`, `--parent` | write |
| `folder-rename` | `--id`, `--name` | write |
| `folder-move` | `--id`, `--parent` | write |
| `folder-delete` | `--id` | write |

**`compose --mode` is one of `reply`, `reply-all`, `forward`, `new`**
(`COMPOSE_CHOICES`, sorted). Only the first three name Graph endpoints hanging
off a message — `COMPOSE_MODES` maps them to
`reply`/`createReply`, `replyAll`/`createReplyAll`, `forward`/`createForward` —
which is why `new` is not in it: there is no `createReply` to ask for it, and the
subject and every recipient have to come from the person writing rather than from
a message being quoted. So the whole message
is assembled and handed to `/me/sendMail` (or POSTed to `/me/messages` for a
draft) in **one** request, attachments inside it. `--id` is therefore optional and
guarded per mode. Over IMAP the difference is what is *left out*: nothing is
fetched, nothing is quoted, and there is no `In-Reply-To`.

**An attachment cannot ride on `/reply`.** Those endpoints take a comment and
recipients and nothing else, so `compose --attach` builds the same draft the
`--draft` path builds, POSTs each file to `/attachments`, and sends the draft —
three requests where there was one, and only when something is attached.

---

## 4. Behavioural contracts worth stating as spec

These are not implementation notes. Each is a rule a change has to honour.

### 4.1 `out()` does not exit in this helper

In `slack.py` and `teams.py` it does, so a command ends at its `out(...)`. **In
`graph.py` only `fail()` exits: every `out(...)` needs the `return` after it.**

This is not hypothetical. `cmd_compose` was missing two of them, so **Save as
draft created the draft and then sent the message**, and a reply with a file went
out twice. The test stubs make `out()` raise, which hides exactly this —
`ComposeStopsWhenItIsDone` in `dev/test-python.py` lets it print instead and
counts the requests. **Any new command with more than one `out()` wants the same
treatment.**

### 4.2 `compose` reaches the mailbox unless `--demo` says otherwise

The window passes `--demo` when the widget has `demo` on. That line was added
after a dev harness whose fixture alias was `work` — a real signed-in mailbox —
pressed Send and made a real Graph request. The fixture's message id was refused
as malformed, which is the only reason nothing was sent.

Give a scratch harness an alias no mailbox uses, and check the demo line is there
before pressing anything that writes. **The demo fixtures are read-only**
(`"write": False`, `"send": False`), so no compose path can be exercised against
them without editing the fixture in the staged copy outside the repo.

### 4.3 Two things are called searching

They answer different questions, and both stay:

- **Typing narrows the rows already merged.** `Model.filterMail` over
  `Service.mailUnfiltered`. No request, instant.
- **Enter runs the helper's `search` across the mailbox.** Its hits go through
  `Model.searchViews` so that `mergeMailAll` and everything after it — the
  optimistic overlay, the unread and Focused filters, the threading, the cap, the
  colours — is the pipeline that already exists rather than a second one.

A row's `folder` is set **only on a hit**; a fetched row has none, because the
header names its folder already. `searchedQuery` is what the rows in hand answer
and is the one flag saying the list is not a folder.

Two server-side constraints shape it:

- **`$search` and `$orderby` are a 400 together.** Graph answers a search by
  relevance and will not sort it, so `graph_search` sorts by date itself. A
  tenant with search turned off answers 400 or 501, and the fallback is
  `contains(subject,…)` **with a warning saying only subjects were read** — a
  poorer search is worth more than none, but not if it claims to be the same one.
- **imaplib carries exactly one literal per command.** A non-ASCII term has to
  travel as a literal for `CHARSET UTF-8` to mean anything, so a non-ASCII query
  goes as one phrase under a single `TEXT` key; an ASCII one is split into a
  `TEXT` key per word, which is IMAP's "all of these". **IMAP has no cross-folder
  search at all** — everywhere is a SELECT and a SEARCH per folder, capped at
  `SEARCH_FOLDER_CAP` with `complete: false` rather than opening two hundred.

### 4.4 "Every mailbox on the same folder" is a state, not a folder

The window's list has always been merged — `snapshot` walks every alias — but
`selectedFolders` is per mailbox, so clicking one folder in the tree broke the
merge with no way back, and the title said one mailbox's address about a list
holding three.

`Model.unifiedFolder` derives the state, `folderRows` draws the merged group
above the per-mailbox trees with `alias: "*"`, and `selectFolderEverywhere` sets
them all. **It sends the well-known *name* (`archive`, `sentitems`), never an
id**: no id means the same folder in two mailboxes. `unifiedFolder` is
deliberately `""` for a single mailbox, or the tree would stop lighting the
folder that is open.

### 4.5 A mailbox with no data for the folder being opened stands in

Switching folder makes a new fetch key, and `Service.snapshot` used to skip a
mailbox with nothing under it: the mailbox vanished and its folder tree collapsed
to one row until the server answered.

`Store.staleDataFor` hands back the newest answer for that alias whatever folder
it was for, marked `stale: true`, and **`Model.accountViews` decides what may be
taken from it** — the tree, the identity, the agenda, the unread count — **and
what may not**: the mail rows and the folder they came from. Adding a field to a
view means asking which of the two it is.

### 4.6 Attachments are names and sizes until somebody clicks one

The list rides along with the body (`attachments` on the `message` reply), which
is free over IMAP — the source is already parsed — and one extra request on the
Graph path, made only when `hasAttachments` says so.

The bytes are the separate `attachment` command, which **writes the file and
answers with its path**: a megabyte of PDF has no business being turned into
JSON, parsed into a QML value and written back out. The key is a Graph attachment
id on one transport and a walk-order position on the other, so **it is opaque to
QML by design**.

**A part with a Content-ID is markup, not a document** — tested *before* the
disposition, because senders mark inline logos `Content-Disposition: attachment`
all the same. Only images: a non-image part with a Content-ID is rare enough that
treating it as a file is the safer guess. Get this wrong and every forward carries
somebody's letterhead as an attachment.

### 4.7 A forward fetches the original whole

`MAX_MESSAGE_BYTES` (2 MB) is a display decision; `FORWARD_FETCH_BYTES` (30 MB)
is not. Cutting the source at 2 MB drops the files being forwarded.
`fetch_parsed` reports whether the cap cut the source, and **a forward refuses
rather than going out short**.

The 3 MB `ATTACH_TOTAL_CAP` deliberately does **not** apply to what a forward
carries: that number is what one Graph request can hold, and Graph's own forward
carries attachments already on the server with no such limit, so matching it here
would refuse forwards that work on the other transport. `FORWARD_TOTAL_CAP` is
25 MB, roughly where a server stops.

### 4.8 Anything typed into a To field arrives with a name on it

`recipient_list` used to split the whole field on whitespace as well as on
commas, so `Jan Renz <jan@example.com>` became three entries and two of them had
no `@` — and forwarding to anybody whose address had not been typed out by hand
answered `bad_recipient: Not an email address: Jan, Renz`.

Every entry is now parsed the way a mail client parses one, and
`split_address_list` **scans rather than splits**, because a display name may
hold a comma inside its quotes and an angle-bracketed address may not be cut
apart. `Model.lastAddressFragment` keeps the same rule in QML for the entry being
completed. **Three places, one rule; change one and change all three.**

### 4.9 `make_msgid()` costs five seconds and leaks the hostname

With no `domain=` it calls `socket.getfqdn()`, which blocks until the resolver
gives up on a machine whose hostname does not resolve — five seconds on every
IMAP reply, measured here — and then writes that hostname into a header the
recipient reads. `imapmail.compose` passes the mailbox's own domain. **Any new
header built from the local machine deserves the same suspicion.**

### 4.10 The address book is harvested, not fetched

`Store.qml` builds it from rows that have arrived and messages that have been
opened, capped at `addressCap` (400). Graph's `/me/people` and `/me/contacts`
need consent this plugin does not ask for, and an IMAP mailbox has no contacts
endpoint at all — so a book from either would be empty on the transport the FWU
mailbox uses. **It lives for the shell's lifetime and is never written down.**

### 4.11 The opened message and the list row carry different fields

`messageId` was on the row and not on the opened message, and `compose` read it
from the opened one — so replies over IMAP went out with **no `In-Reply-To`**
while the suite stayed green, because the tests stubbed `message()` with a dict
that had the key.

The fixtures build a real source and let `shaped` shape it now (`imap_message` in
`dev/test-python.py`). A hand-written dict is how that hid.

---

## 5. State model — Store vs Service

**This is the thing to understand first.**

The bar widget and the window are separate hosts, and a bar surface exists *per
monitor*, so there are several `Service`s. They used to each own a fetch loop,
which polled one mailbox two or three times over and left the bar showing a
message unread after the window had marked it read.

So the data moved into **`Store.qml`** — one per plugin, built by the shell
because the manifest declares `kinds: ["service"]`.

| Lives in `Store.qml` (shared) | Lives in `Service.qml` (per host) |
|---|---|
| Fetched mail and agenda, keyed by **alias + folder** | Filters: `filterAlias`, `unreadOnly`, `focusedOnly` |
| The optimistic read / flagged / deleted overlay | The open folder (`selectedFolders`, `pickedAlias`) |
| Message bodies (`bodies`, cap 40) | The message being read (`previewMail`, `previewDetail`) |
| Meeting details (`meetings`, cap 20) | A half-written reply (`composeMode`, `composeText`, …) |
| The theme palette | Search state (`searchQuery`, `searchedQuery`, `searchResults`) |
| The sign-in state machine | Paging (`paged`, `wantedMails`) |
| The harvested address book | The cursor, the panes, the drawers |

Rules:

- **Do not add a poll outside the store.**
- **Fetching is keyed by mailbox *and* folder**, and requests for one mailbox run
  **one at a time** — a fetch is also a token refresh and Entra rotates refresh
  tokens, so two at once risks an avoidable sign-in.
- Concurrency is managed by `claim()` / `put()` / `release()` over a `requests`
  map and a `tokenSerial`.
- The optimistic overlay records an **owner** per override
  (`overrideOwner`), so `pruneOwnedOverrides` can drop only what a given host put
  there.

---

## 6. Settings

Read through `setting()` / `intSetting()`; declared in
`manifest.json` → `barWidget.schema`.

| Key | Type | Default | Range / options |
|---|---|---|---|
| `label` | string | `""` | |
| `icon` | string | `󰇮` | |
| `mails` | integer | 5 | 1–25 |
| `calendar` | string | `3day` | `1day`, `3day`, `week` |
| `agendaView` | string | `list` | `list`, `timeline` |
| `dayStart` | string | `07:00` | HH:MM |
| `dayEnd` | string | `22:00` | HH:MM |
| `showWeekends` | boolean | true | |
| `dedupeEvents` | boolean | true | Show a meeting from two mailboxes once |
| `refreshIntervalSec` | integer | 180 | 60–3600 |
| `pausePolling` | boolean | true | |
| `tintOnUnread` | boolean | true | |
| `notify` | boolean | true | |
| `htmlBody` | boolean | false | Always keep the message's own formatting |
| `htmlSenders` | string | `""` | Comma-separated; written by the reading pane |
| `previewLine` | boolean | true | |
| `focusedByDefault` | boolean | false | |
| `unreadByDefault` | boolean | false | |
| `markReadOnOpen` | boolean | false | Needs write permission |
| `agentHandover` | boolean | true | |
| `ipcTarget` | string | `""` | **Must stay empty by default** |

**Per-mailbox settings** live in an `accounts` array on the widget entry, each
entry taking `account` (the alias), and optionally `color`, `authority`,
`transport`, `calendar`. There is also a single-mailbox `account` form.

No `density` setting — see `PLATFORM.md` §3.1.

### 6.1 Live configuration on this machine

```json
{
  "id": "caseonline.omarchy.office365",
  "accounts": [
    { "account": "uds" },
    { "account": "FWU", "color": "blue",
      "authority": "c15c774e-…", "transport": "imap" }
  ],
  "instance": "cd3a559d2c53",
  "mails": 10, "calendar": "3day", "agendaView": "list",
  "dayStart": "07:00", "dayEnd": "22:00", "showWeekends": true,
  "refreshIntervalSec": 180, "pausePolling": true,
  "htmlBody": false, "previewLine": true, "markReadOnOpen": true,
  "tintOnUnread": true, "notify": true, "agentHandover": true,
  "focusedByDefault": false, "icon": "󰇰"
}
```

`FWU` is the mailbox on the IMAP/EWS path, which is why that transport is not
theoretical here.

---

## 7. Data shapes

### 7.1 Mail row

Produced by `graph.message_row` and, identically, by `imapmail.row_from`.

```
id, subject, from, fromAddress, received, preview, webLink,
important, hasAttachments, read, flagged, focused,
thread, messageId, references[]
```

- `flagged` is true only for Graph's `flagged` state. `complete` is a flag ticked
  off, not one still standing.
- `focused` is Outlook's Focused Inbox split, applied **in the panel** over what
  was fetched — Graph will filter on it or sort by date, not both.
- `thread` / `messageId` / `references` are the threading relation. Graph keeps
  the thread itself and says so with blanks rather than omitting the keys; the
  IMAP path rebuilds the same relation from `Message-ID` headers. **Both arrive
  as these three fields so the grouping never asks which transport answered.**

### 7.2 Message body

`bodyFormat`, `body`, `hasHtml`, `htmlAuto`, `attachments[]`,
`imagesBlocked`, plus sender / recipient fields. Rendered through
`Model.bodyMarkup`, which is `legibleBody` then `withLinkColor` **in that one
order** — the link colour is a default a sender's own anchor colour would beat,
so the unreadable one has to be gone first.

### 7.3 Event

Shaped identically by the Graph path and by `ewscal.py`: local ISO timestamps,
`joinUrl`, `response`, attendees. See `PLATFORM.md` on why the shaping is the
transport's job.

---

## 8. UI surfaces

### 8.1 Bar widget (`BarWidget.qml`, 140 lines)

Icon or label; tint on unread; elects `notifies`.

- **Left click** — the dropdown
- **Right click** — focus the mailbox's app window, or open Outlook on the web
- **Middle click** — refresh now

### 8.2 Dropdown (`Panel.qml`, 920 lines)

Merged mail beside the merged agenda. Offers every action the window does and
performs none of the hard ones — `actsHere: false` puts "opens the window on it"
in the tooltips, and the buttons `handOff` to the window with an `action` it runs
once its fetch lands.

### 8.3 Window (`MailWindow.qml`, 2056 lines)

Folders, list, reading pane, agenda.

- **`MailList.qml` is a `ListView` on purpose** — hand-diffed `ListModel`. See
  `PLATFORM.md` §9.2.
- **`SearchBar.qml` is its own row**, not a header control, because the header
  collapses when its pills outgrow the width.
- **The header collapses if the pills outgrow the width beside the title.**
  `header` is anchored to `headerActions.left`; once the pills no longer fit that
  right edge is left of the row's own left one, `implicitHeight` goes to zero,
  and an `Item` sized `height: header.implicitHeight` takes the title, every pill
  and the whole header off the window. **Nothing is printed** — no binding loop,
  no TypeError — so it reads as "my new pill broke the header". It is
  `Math.max` of the two rows now, and a control added at the widths where the
  header is fullest wants a **glyph rather than a word**: the Calendar pill is
  `\u{F00ED}` for that reason, not for decoration.
- **The agenda scroller holds two children**, the grid and the list, and a
  `ScrollView` derives its content size from a single one. With two it measured
  nothing, so an agenda taller than the pane could not be scrolled by anything —
  keys or wheel. `contentHeight` is stated, from whichever child `agendaView` is
  showing.

### 8.4 Keymap

Beyond the shared set in `PLATFORM.md` §9.1:

| Key | |
|---|---|
| `C` | The calendar, from anywhere — `Esc` brings the mail back |
| `Tab` | Between the folders and the list |
| `c` | Write a new message from this mailbox |
| `s` | Save every file this message carries, to downloads |
| `x` | Delete the message under the cursor |
| `m` | Move it to another folder |
| `F` | Flag for follow-up, or clear the flag |
| `f` | Show only Focused mail |
| `t` | Group the list by conversation |
| `/` | Search — typing narrows, Enter asks the mailbox |
| **Folders** | `n` / `N` new folder inside / at top level; `R` rename; `m` reparent; `x` delete |

---

## 9. Window IPC

`MailWindow.open(payloadJson)` is a **contract, not a stub**. Beside the old
`{"instance": "…"}` it takes:

| Key | Meaning |
|---|---|
| `account` | mailbox alias |
| `folderId` | folder to open |
| `messageId` | message to reveal |
| `action` | run once the fetch lands (`pendingAction`) |
| `draft` | put a coding agent's reply in the reply box, **unsent** |

`omarchy-shell shell call <id> agentDraft '<json>'` is the same draft route and
returns what it made of it.

**`open()` re-reads `shell.json` every time it is called.** A dev harness that
calls it after putting fixture settings in place has them replaced by the real
widget's — which points the harness at a real mailbox. **Drive `applyPayload`
directly instead.**

---

## 10. Limits and caps

| Constant | Value | Governs |
|---|---|---|
| `MAIL_CAP` | 100 | rows per fetch |
| `MAIL_FILTER_CAP` | 25 | |
| `SEARCH_CAP` | 50 | search hits |
| `FOLDER_CAP` / `FOLDER_MAX_DEPTH` | 200 / 3 | folder tree |
| `MAX_PAGES` | 10 | Graph pagination |
| `MAX_RESPONSE_BYTES` | 16 MB | any one response |
| `HTML_BODY_CAP` / `TEXT_BODY_CAP` | 40 000 | body shown in the reading pane |
| `IMAGE_MAX_BYTES` / `IMAGE_TOTAL_BYTES` / `IMAGE_MAX_COUNT` | 512 KB / 4 MB / 40 | inline images |
| `IMAGE_MAX_WIDTH` | 560 | |
| `ATTACHMENT_LIST_CAP` | 40 | attachment rows |
| `ATTACH_CAP` / `ATTACH_TOTAL_CAP` | 3 MB / 3 MB | what one Graph request can carry |
| `MAX_MESSAGE_BYTES` | 2 MB | IMAP source read for display |
| `FORWARD_FETCH_BYTES` | 30 MB | IMAP source read for a forward |
| `FORWARD_TOTAL_CAP` | 25 MB | what a forward may carry |
| `SEARCH_FOLDER_CAP` | 25 | folders searched over IMAP |
| `MAX_EVENTS` (EWS) | 250 | |
| Store `bodyCap` / `meetingCap` / `addressCap` | 40 / 20 / 400 | in-memory caches |

`TEXT_BODY_CAP` governs how much of a body the reading pane shows. **When
weighing a display limit against a preview or bandwidth cost, display wins.**

---

## 11. Error codes

`graph.py`: `attach_failed`, `attachment_failed`, `attachment_is_a_link`,
`attachment_is_a_message`, `auth_required`, `bad_alias`, `bad_mode`, `bad_name`,
`bad_recipient`, `bad_reply`, `calendar_auth_required`, `create_failed`,
`declined`, `delete_failed`, `demo`, `draft_failed`, `empty_file`,
`event_failed`, `expired`, `flag_failed`, `graph_error`, `login_failed`,
`mark_failed`, `message_failed`, `move_failed`, `no_calendar`, `no_file`,
`no_folder`, `no_id`, `no_palette`, `no_pending_login`, `no_query`,
`no_recipient`, `no_transport`, `no_username`, `rename_failed`,
`respond_failed`, `respond_permission`, `save_failed`, `search_failed`,
`send_failed`, `send_permission_required`, `too_large`, `unreadable`,
`write_required`

`imapmail.py` adds: `attachment_gone`, `bad_folder`, `bad_id`, `fetch_failed`,
`imap_error`, `list_failed`, `network`, `select_failed`, `stale_id`

`ewscal.py` raises `CalendarError`.

---

## 12. Security invariants

Verbatim from `AGENTS.md`, because breaking one is a security bug and not a
regression. `PLATFORM.md` §2 covers 1, 3, 4, 5, 8 and 9 in their shared form.

1. Tokens never reach QML — mode 600 under `~/.local/state/omarchy/`, passed on
   stdin.
2. **The window never fetches anything remote.** Wherever a message's own markup
   is rendered — Show formatting, a standing sender rule, `htmlBody`, or a
   message with no plain-text part at all — images and everything else remote are
   stripped *before* rendering.
3. A message never chooses its own markup beyond what the sanitiser allows.
   Links `http`/`https`/`mailto` only, checked in Python, in `Model.js`, and in
   `openUrl`.
4. Stdlib only.
5. Every helper command prints one JSON object and exits 0 even on failure.
6. A transport must be invisible downstream.
7. `account["write"]` on the IMAP path is local policy, not a boundary.
8. No symlinks anywhere in the repo.
9. Colours and spacing come from `qs.Commons`.
10. **`ipcTarget` is empty by default and must stay that way.**

**Known divergence:** this helper has no `GuardedRedirects` opener and no test
asserting `urllib.request.urlopen` is uncalled, both of which Slack and Teams
have. Recorded here rather than in the gaps document because it is a factual
description of the current code.

---

## 13. Development

Per `PLATFORM.md` §10, plus:

```bash
node    dev/test-model.js
python3 dev/test-python.py                        # 2964 lines
python3 src/graph.py fetch --account work --demo
python3 src/graph.py palette
dev/run.sh ; dev/shot.sh /tmp/mail.png ; dev/showcase.sh
```

- `dev/link.sh` stages into `$XDG_RUNTIME_DIR/omarchy-office365-dev` and
  symlinks the sources **plus `dev/shell.qml` and `dev/Fixtures.js`**. Writing a
  throwaway harness to `$STAGE/shell.qml` therefore writes it *into the repo*
  through the symlink. Give a scratch harness any other name.
- **Photographing the window needs a child of its content item, and a remap to
  resize it.** `dev/shell.qml` grabs an `Item` it owns; `MailWindow` has only
  `floatingWindow`, whose `contentItem` is a proxy and answers
  `grabToImage: item has no QML engine`. Its **first child** — the `FocusScope`
  filling the window — grabs fine. And a mapped toplevel keeps the size the
  compositor gave it, so setting `implicitWidth` does nothing: set `visible`
  false, resize, set it true. Both matter, because the header collapsing under
  one pill too many is only visible in a picture at ~720px.
