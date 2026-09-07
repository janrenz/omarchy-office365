# GAPS.md — Office 365 Mail & Calendar

**Companion to [`SPEC.md`](SPEC.md).** That file says what the plugin does; this
one says what it does not do *that it arguably should*, and where the spec has no
answer at all.

Written 2026-09-04 against version 1.10.0. Every finding carries the evidence it
was drawn from, so it can be re-checked rather than believed.

## How to read this

| | |
|---|---|
| **Gap** | Behaviour or a contract that is missing, and whose absence is not a stated decision |
| **Divergence** | Something two of the three plugins do and this one does not |
| **Unspecified** | Code decides it; no document says what the decision should be |

**Severity is about consequence, not effort.** `high` means it can lose data,
leak a credential, or break a stated invariant. `medium` means a user meets it.
`low` means a maintainer meets it.

## What is *not* in here

The items in `README.md` are **deliberate non-goals**, not gaps: the read-only
default, the per-mailbox write opt-in, no live updates, the harvested address
book. `SPEC.md` §4 records the rules behind them. Do not re-raise them as
findings.

---

## MAIL-1 — No redirect guard, and no test behind the invariant · `high` · Divergence

**`SPEC.md` §12 invariant 2 says the window never fetches anything remote and
that the helper checks hosts. The helper has no host check and no redirect
guard.**

Evidence:

```
graph.py    GuardedRedirects: 0   raw urlopen(: 2   build_opener: 0
slack.py    GuardedRedirects: 2   raw urlopen(: 0   build_opener: 1
teams.py    GuardedRedirects: 2   raw urlopen(: 0   build_opener: 1

dev/test-python.py   mentions of urlopen: 0
dev/test-slack.py    mentions of urlopen: 11   (classes Hosts, Redirects, LocalFiles)
dev/test-teams.py    mentions of urlopen: 3    (classes ImageHostGuard, Redirects, LocalFiles)
```

Slack and Teams both state this as a security invariant in their own
`AGENTS.md`, in the same words: *"urllib follows a redirect by copying the
request's headers onto the new request — `Authorization` among them — and
compares no hosts while doing it, so a host check that only looks at the URL it
was handed is a check a `302` walks straight through."* Both assert in their test
suite that `urllib.request.urlopen` is called nowhere. This helper calls it
twice.

**The two call sites are not equally exposed, and the difference matters:**

| Site | Token attached? | URL comes from | Exposure |
|---|---|---|---|
| `http()` → `graph_get_url` (`graph.py:356`) | **Yes** — `Authorization: Bearer` | `GRAPH + path`, or Graph's own `@odata.nextLink` | A redirect off `graph.microsoft.com` would carry the bearer token to the new host. Requires Graph to redirect off-host, so this is a posture gap rather than a live hole. |
| `ImagePolicy.fetch()` (`graph.py:2191`) | **No** — deliberately no cookie, no referrer, a bland User-Agent | **A URL out of a message body**, on the `--load-images` opt-in | No credential to lose. But there is no scheme check and no host check, so a message can redirect the fetch to `http://` or at an address inside the user's network. |

The second is the one an attacker can steer, and it is the one that leaks
nothing. The first is the one that carries the token, and its URLs come from
Graph. **Neither is a token-exfiltration path today.** Both are the pattern the
other two plugins call an invariant, and Slack's own rationale applies verbatim
to the `nextLink` case: *"an API response is a better source than a message, but
it is still somebody else naming where our data goes."*

**What the spec should say:** every request goes through a `GuardedRedirects`
opener; the token comes off the moment the host changes; a redirect off `https`
is refused; a redirect off the allowed hosts is refused; `ImagePolicy.fetch`
refuses a redirect that changes scheme or leaves the host it was given; and a
test asserts `urllib.request.urlopen` is called nowhere.

---

## MAIL-2 — The dev stage falls back to shared temp · `medium` · Divergence

`dev/link.sh:19`:

```sh
STAGE="${OFFICE365_DEV_STAGE:-${XDG_RUNTIME_DIR:-/tmp}/omarchy-office365-dev}"
rm -rf "$STAGE"
```

With `XDG_RUNTIME_DIR` unset, the stage is the predictable path
`/tmp/omarchy-office365-dev` — **and line 20 `rm -rf`s it.**

Both other plugins have a `dev/stage.sh` that refuses exactly this, and Teams'
copy says why in full:

> Every script here `rm -rf`s this folder and kills the harness by matching a
> command line that contains this path, so it has to be a place nobody else can
> write to or get to first: `$XDG_RUNTIME_DIR` is per-user and mode 0700, `/tmp`
> is neither. With no runtime dir there is no safe default, so refuse rather than
> fall back to a predictable path in shared temp.

This plugin has no `dev/stage.sh` at all (`dev/` holds `Fixtures.js link.sh
run.sh shell.qml shot.sh showcase.sh test-model.js test-python.py`).

**What the spec should say:** there is no safe default stage; with no
`XDG_RUNTIME_DIR`, refuse and tell the user to set `OFFICE365_DEV_STAGE` to a
directory only they can write.

---

## MAIL-3 — `demo` is load-bearing and unspecified · `medium` · Unspecified · shared: `PLAT-3`

`Service.qml:191` reads `setting("demo", false)`, and that setting decides
whether `compose` passes `--demo` — that is, **whether pressing Send reaches a
real mailbox.** It appears in **no** manifest schema in any of the three plugins:

```
caseonline.omarchy.office365/manifest.json   occurrences of "demo": 0
janrenz.omarchy.slack/manifest.json          occurrences of "demo": 0
janrenz.omarchy.teams/manifest.json          occurrences of "demo": 0
```

So it cannot be set from the settings panel, is not documented as a setting, and
is not covered by the rule in `PLATFORM.md` §3 that adding a setting means adding
it to the manifest *and* reading it through `setting()`.

This is not hypothetical. `SPEC.md` §4.2 records that a harness whose fixture
alias was `work` — a real signed-in mailbox — pressed Send and made a real Graph
request, and that the fixture's message id being refused as malformed *is the
only reason nothing was sent.*

**What the spec should say:** either `demo` is a real setting with a schema entry
and a description saying plainly what it disables, or it is a
harness-only override read from somewhere that is not the widget's settings —
and the choice is stated. A load-bearing flag that gates whether writes reach a
real mailbox should not be the one thing nobody wrote down.

---

## MAIL-4 — Nothing enforces `out()`-then-`return` · `medium` · Unspecified

`SPEC.md` §4.1 states the rule and the reason: **in this helper only `fail()`
exits**, so every `out(...)` needs the `return` after it, and code copied from
`slack.py` or `teams.py` — where `out()` does exit — will print an answer and
then carry on and make the request. `cmd_compose` was missing two of them, so
**Save as draft created the draft and then sent the message**, and a reply with a
file went out twice.

The rule ends: *"any new command with more than one `out()` wants the same
treatment"* as `ComposeStopsWhenItIsDone`. **Nothing checks that it got it.** The
test stubs make `out()` raise, which hides the class; exactly one command has the
counting test.

Commands in `graph.py` with more than one `out()` are the population at risk, and
the suite covers one of them.

**What the spec should say:** either a test that walks the command table and
asserts each command stops at its first `out()`, or a lint over `graph.py`
asserting every `out(` is followed by `return`. The rule is written down and
unenforced, which is the state a copied-in command will break silently.

---

## MAIL-5 — No `density`, so the window ignores the theme's font size · `medium` · Divergence

`grep -c density src/Service.qml` → **0**.

Slack and Teams both carry a `density` setting (`compact` / `cosy` / `roomy` /
`spacious`, scaling `0.6 / 1.0 / 1.7 / 2.4`), read it through `densityScale`,
and route every gap through `pad()` so the window follows the theme's font size.
`PLATFORM.md` §9 makes that a UI convention; §3.1 records mail as the exception.

Teams' `Model.js` even explains why the range is as wide as it is: *"the tokens
it multiplies are small. The shell's spacing steps are 2, 4, 6, 8px; 1.4 times
4px is one pixel of difference, which is what the first attempt at this shipped
and what nobody could see."* That reasoning is not mail-specific.

**What the spec should say:** either mail adopts `density` and the convention
becomes platform-wide, or `PLATFORM.md` §9 records that spacing is per-plugin and
mail's fixed scale is deliberate. As it stands the convention has one silent
exception.

---

## MAIL-6 — An attached image can only be seen by leaving the app · `medium` · Divergence

Slack and Teams each ship `src/ImageViewer.qml` (208 lines, a 4-line diff between
them) — a picture from the transcript with save-as, `s` to save and `o` to open
elsewhere. Mail has no such file:

```
ls src/ | grep -i 'image\|viewer'   →  (nothing)
```

Inline images that came *with* a message are embedded as data URIs and render in
the reading pane, so those are fine. But an **attachment** — the ordinary case of
somebody sending a photo or a screenshot — has only the `attachment` command,
which writes the file to disk and answers with its path. Seeing it means opening
something else.

That runs against this repo's own house rule, stated in `AGENTS.md` and
`PLATFORM.md` §11: *"Keep the work inside the app. When something cannot be
finished here, that is the bug — not a reason to hand the user off."*

**What the spec should say:** an image attachment opens in a viewer in the
window, with the same `s` / `o` keys the other two use — or the README says
plainly that viewing an attachment is the one thing that leaves the window, the
way Teams says it about joining a meeting.

---

## MAIL-7 — The IMAP capability matrix is decided per feature, not specified · `low` · Unspecified

`GRAPH_CAPABILITIES = {"calendar": True, "focused": True, "webLinks": True}`
gates three behaviours, and `AGENTS.md` says *"a feature added on the Graph path
needs a decision about the IMAP one."* **There is no record of what those
decisions were, or of what the IMAP path is expected to do for anything not in
that dict.**

Present state, reconstructed from the code rather than from any document:

| Capability | Graph | IMAP/EWS |
|---|---|---|
| Calendar | Graph | EWS, separate consent, `account["calendar"]` |
| Focused Inbox | yes | absent |
| `webLink` | yes | absent |
| Cross-folder search | `$search`, one request | SELECT+SEARCH per folder, `SEARCH_FOLDER_CAP` 25, `complete: false` |
| Threading | `conversationId` | rebuilt from `Message-ID` / `References` |
| Read-only enforcement | the token | **local policy only** (invariant 7) |
| Attachment key | Graph attachment id | walk-order position |
| Forward | server-side, no size cap | fetch whole, `FORWARD_TOTAL_CAP` 25 MB |

**What the spec should say:** this table, maintained, with a column for "what
happens when the IMAP path cannot do it" — degrade, hide, or refuse. Seven
features have each answered that question separately and the eighth will have to
guess.

---

## PLAT-1 — Shared components are copies, and they have drifted · `medium` · Divergence

Line-counts of `diff` output between the three repos' copies of the same file:

| File | slack↔teams | mail↔slack | mail↔teams |
|---|---|---|---|
| `src/config.py` | **2** | 219 | 219 |
| `src/SelectableText.qml` | **2** | 14 | 14 |
| `src/ImageViewer.qml` | **4** | n/a | n/a |
| `src/Notifier.qml` | 12 | 20 | 10 |
| `src/PollGate.qml` | 14 | 4 | 10 |
| `src/LabeledField.qml` | 7 | 28 | 21 |
| `src/handover.sh` | 54 | — | — |
| `src/Model.js` (first 190 lines) | 48 | — | — |

`config.py` between Slack and Teams differs by **one line** — the default
`--plugin-id` — across 151 lines. `Model.js`'s first ~190 lines are the same
helpers (`parseJson`, `oneLine`, `plainText`, `escapeHtml`, `safeHref`, `anchor`,
`linkify`, `usableSpans`, `autoLinked`, `densityScale`) with 48 lines of drift,
most of it comment wording, some of it real (`reactionIsMine` keys on `name` in
Slack and `emoji` in Teams).

Mail's `PollGate.qml` is **4 lines** from Slack's.

**No mechanism and no document says which copy is canonical.** A fix to the
redirect guard, the poll gate, or the link builder has to be made three times by
someone who knows all three repos have it.

**What the spec should say:** either a stated canonical source and a sync step in
the release ritual, or an explicit decision that these are forks and drift is
accepted. `PLATFORM.md` currently describes the shared contract without saying
who owns the shared code.

---

## PLAT-2 — Three answers to the several-Services problem, and no platform decision · `medium` · Unspecified

`PLATFORM.md` §6 records the state: mail uses a `kinds: ["service"]` singleton
(`Store.qml`), Slack uses an `flock` in the helper (`FetchSlot`), and Teams uses
neither and polls three times an interval.

All three are defensible. **What is missing is a statement of which one a fourth
plugin should adopt, and why mail's answer was not enough for Slack.** Slack's
`AGENTS.md` gives half of it — the lock *"holds for the window and for a manual
refresh too, which a QML singleton would not have covered"* — and that is a real
argument that mail's approach is the weaker one. It has never been written down as
a platform choice.

The two approaches are also not equivalent in what they protect: the singleton
shares **UI state** (mail's optimistic read/flagged/deleted overlay, keyed by
owner) as well as fetches, and the lock shares **only the fetch**. See `SLACK-1`
in the Slack repo's `GAPS.md`.

**What the spec should say:** which of the two is the platform's answer, what the
other is for, and — if the answer is the singleton — that Slack's lock stays
because it covers manual refresh, which the singleton does not.

---

## Summary

| ID | Severity | Class | One line |
|---|---|---|---|
| MAIL-1 | high | Divergence | No redirect guard, 2 raw `urlopen`, no test — an invariant the other two enforce |
| MAIL-2 | medium | Divergence | Dev stage falls back to `/tmp` and is `rm -rf`'d; the other two refuse |
| MAIL-3 | medium | Unspecified | `demo` gates whether Send reaches a real mailbox and is in no manifest |
| MAIL-4 | medium | Unspecified | The `out()`-then-`return` rule is written down and unenforced |
| MAIL-5 | medium | Divergence | No `density`; the window ignores the theme's font size |
| MAIL-6 | medium | Divergence | An image attachment can only be seen by leaving the app |
| MAIL-7 | low | Unspecified | The IMAP capability matrix exists only in the code |
| PLAT-1 | medium | Divergence | Shared components are copies with silent drift; no canonical source |
| PLAT-2 | medium | Unspecified | Three answers to the several-Services problem, no platform decision |
