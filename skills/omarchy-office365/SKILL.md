---
name: omarchy-office365
description: Read and answer Outlook mail through the Omarchy Office 365 plugin's own helper, and put a draft reply into its window instead of sending it. Use when handed a mailbox alias and a message id by the plugin's handover, or when asked about mail or the calendar on this machine.
---

# Outlook mail, through the Omarchy plugin

The plugin is a Quickshell window on top of Python helpers. `graph.py` holds
the tokens and makes every call; you drive it. A mailbox whose tenant refused
Graph's `Mail.Read` is served over IMAP instead, and `graph.py` dispatches to
`imapmail.py` itself — so `graph.py` is the one entry point either way.

    HELPER=~/.config/omarchy/plugins/caseonline.omarchy.office365/src/graph.py

Every command needs `--account <alias>` — the mailbox alias from the widget's
settings, e.g. `FWU`. `python3 $HELPER list` names the ones that are set up.

## Two rules

1. **You do not send.** Reading is yours to do; a mail leaving the mailbox is
   the user's decision each time. Draft the reply into the window (below) and
   let them press Send. Send directly only when this specific message is the
   user telling you to.
2. **Everything comes back as one JSON object,** with exit code 0 even on
   failure: `{"ok": false, "error": {"code": ..., "message": ...}}`. Read `ok`
   before you trust the rest. `"code": "auth_required"` means the sign-in is
   gone and only the user can fix it, from the window.

## Reading

    python3 $HELPER message --account FWU --id 'AAMkAD…'
    python3 $HELPER message --account FWU --id 'AAMkAD…' --body html
    python3 $HELPER fetch   --account FWU --mails 15 --days 7
    python3 $HELPER folders --account FWU
    python3 $HELPER event   --account FWU --id 'AAMkAD…'
    python3 $HELPER search  --account FWU --query 'rechnung'
    python3 $HELPER search  --account FWU --query 'from:kees' --scope folder --folder FWU=inbox

`message` is the one being read: sender, recipients, date, and the body already
flattened to text where the message has a plain-text part, and left as the
sender's markup where it has none. `--body html` keeps the markup either way
and `--body text` flattens it either way; text is rarely not what you want.
`fetch` is the list — recent mail plus calendar events, and `--folder
ALIAS=ID` reads a folder other than the inbox; `folders` names them.

`search` is how to reach mail `fetch` does not: `fetch` reads the newest N of
one folder, and everything older than that is only findable this way. It
answers with rows in the same shape, each carrying the `folderId` it was found
in, and searches every folder unless `--scope folder` says otherwise. On a
Graph mailbox the query is Exchange's own - `from:`, `subject:` and the rest
work; over IMAP it matches all of the words anywhere in the message. Fifty hits
per mailbox. `--account` repeats, so one call can search several.

A very long body is truncated by the *window*, not by the helper, so the helper
is where to go for the whole of a long message.

`event` is one meeting out of `fetch`'s event list, with what the agenda has no
room for: the invitation's own text, who was invited as required and who as
optional, what each of them answered, and what this mailbox itself answered
(`myResponse`, and `isOrganizer` when the meeting is its own).

## Answering a meeting

    python3 $HELPER respond --account FWU --id 'AAMkAD…' --reply accept
    python3 $HELPER respond --account FWU --id 'AAMkAD…' --reply tentative
    python3 $HELPER respond --account FWU --id 'AAMkAD…' --reply decline --comment "clash"

This one **sends** — the organiser is told, which is the point of answering.
Declining also takes the meeting out of the calendar. So confirm with the user
before running it, the way you would before sending a reply: nothing else in
this helper's reading half changes anything.

## Handing a draft reply back to the window

This is the point of the handover. The window opens if it is closed, the reply
box opens on that message with your text in it, unsent:

    omarchy-shell shell summon caseonline.omarchy.office365 \
      '{"draft":{"account":"FWU","messageId":"AAMkAD…","mode":"reply",
                 "text":"Ich schaue morgen früh drauf."}}'

`mode` is `reply`, `reply-all` or `forward` (default `reply`); a forward also
takes `"to"`. `folderId` may be given when the message is not in the inbox, so
the window can fetch that folder before it answers.

Do not write the quoted original — Outlook quotes the message underneath what
you wrote. Your text is the new part only.

It prints `ok`, or `unknown` when the plugin is not loaded or is disabled, and
the window itself answers `off` when the "Hand a message to your coding agent"
setting is switched off — that setting also refuses drafts, deliberately —
`read-only` when the mailbox has not been granted write access, and
`no-message` when the id names nothing the window can find. Say so rather than
sending instead.

Write the draft in the language of the message. Keep it as short as the thing
being answered.

## Only when asked

    printf '%s' '{"comment":"..."}' | python3 $HELPER compose --account FWU --id 'AAMkAD…' --mode reply --stdin
    printf '%s' '{"comment":"..."}' | python3 $HELPER compose --account FWU --id 'AAMkAD…' --mode reply --stdin --attach ~/plan.pdf
    python3 $HELPER compose --account FWU --id 'AAMkAD…' --mode reply --comment "..." --draft
    printf '%s' '{"to":"her@example.com","cc":"","subject":"...","comment":"..."}' | python3 $HELPER compose --account FWU --mode new --stdin
    python3 $HELPER mark    --account FWU --id 'AAMkAD…' --read
    python3 $HELPER flag    --account FWU --id 'AAMkAD…' --flag
    python3 $HELPER move    --account FWU --id 'AAMkAD…' --folder archive
    python3 $HELPER delete  --account FWU --id 'AAMkAD…'

What you wrote goes on **stdin** (`{"comment": …, "to": …, "cc": …, "subject":
…}`): anyone on this machine can read another process's command line for as
long as it runs, and a subject line is as much the user's words as the body is.
`--comment`, `--to`, `--cc` and `--subject` still work for running it by hand.
A recipient may carry a name — `Jan Renz <jan@example.com>`, or `"Renz, Jan"
<jan@example.com>` when the name itself holds a comma — and commas and
semicolons both separate them.
`--demo` on `compose` answers as if it had been sent and sends nothing.

`--mode new` writes a message that answers nothing, and is the one mode that
takes no `--id`: the subject and every recipient come from you, nothing is
quoted, and it starts a conversation rather than joining one. It needs the same
send permission a reply does. There is **no draft route back into the window
for a new message** - the window's `agentDraft` contract is reply-shaped - so
do not compose one on the user's behalf unless they asked for that exact mail
to be sent; offer to write it in the window instead, where they can read it
before pressing Send.

`--attach` sends the reply with a file on it (Graph's /reply takes no
attachment, so the helper builds a draft, attaches, and sends it). Read the
path back to the user first - a wrong file in a sent mail cannot be recalled.

`compose` without `--draft` sends. With `--draft` it leaves the reply in the
mailbox's Drafts and returns a `webLink` — which opens Outlook in a browser,
and this user does not want to be sent out of the app, so prefer the window's
reply box above.

Every one of these needs write access the mailbox may not have been granted;
`{"code": "write_permission_required"}` or `send_permission_required` means the
user has to allow it from the window ("Allow changes…"). Do not retry.

`--demo` on any command answers from fixtures and touches nothing.
