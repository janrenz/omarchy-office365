#!/usr/bin/env bash
# Hand the message being read to whichever coding agent Omarchy is set up with
# (`omarchy default agent`), the same way omarchy-agent-crash hands over a core
# dump.
#
# What crosses over is a pointer, never the mail: the mailbox alias, the folder
# and the message id, plus the path to the skill that says how to read one. Not
# even the subject - a mail subject is content, and an agent window's command
# line is readable by anyone on this machine for as long as it lives. The agent
# asks graph.py itself, which also means it reads the message as it is now.
#
# Usable by hand and from a Hyprland binding:
#   src/handover.sh --account work --message AAMkAD… --print

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

account=""
message=""
folder=""
task=""
print=false

while (($#)); do
  case "$1" in
    --account) account=${2:?--account needs a value}; shift 2 ;;
    --message) message=${2:?--message needs a value}; shift 2 ;;
    --folder)  folder=${2-}; shift 2 ;;
    --task)    task=${2-}; shift 2 ;;
    --print)   print=true; shift ;;
    *) echo "Unexpected argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z $account || -z $message ]]; then
  echo "Usage: handover.sh --account <alias> --message <id> [--folder id] [--task t] [--print]" >&2
  exit 1
fi

# The window launches this detached, so stderr goes nowhere and a plain `echo`
# would make a keypress that does nothing look like a plugin that is broken.
complain() {
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a "Office 365" -u critical "Office 365" "$1"
  fi
  echo "$1" >&2
}

# The skill is named by absolute path rather than by name. Only some harnesses
# have a skill mechanism at all, and none of them look inside a plugin folder,
# so a path is the one form every agent can follow.
skill="$(cd "$here/.." && pwd)/skills/omarchy-office365/SKILL.md"

: "${task:=Read this message and tell me what it needs from me. If it wants an answer, draft one into the reply box with the draft recipe in the skill. Send nothing.}"

prompt=$(
  cat <<PROMPT
I am reading a message in the Omarchy Office 365 plugin and want your help with
it.

Which message:
  mailbox alias: $account
  message id:    $message${folder:+
  folder:        $folder}

Read it with the plugin's own helper. It holds the tokens, prints one JSON object
per call, and is the only thing here that talks to the mailbox - over Graph, or
over IMAP for a tenant that would not consent to Graph, which it decides for
itself:

  python3 $here/graph.py message --account $account --id '$message'

Before you do anything else, read this skill: it lists the rest of the helper's
commands, what may and may not be done with them, and how to put a draft reply
into the window's reply box instead of sending it yourself.

  $skill

What I want: $task
PROMPT
)

if [[ $print == "true" ]]; then
  printf '%s\n' "$prompt"
  exit 0
fi

if ! command -v omarchy-agent >/dev/null 2>&1; then
  complain "This Omarchy has no omarchy-agent, so there is nothing to hand this message to."
  exit 1
fi

# Omarchy ships without a default agent. Erroring into a void would be a
# keypress that opens nothing and explains nothing, so send them to the picker
# the menu uses - and say why, since the prompt is dropped on that path.
if [[ -z $(omarchy-default-agent) ]]; then
  complain "Choose a coding agent first — then press a again."
  exec omarchy-agent --pick
fi

exec omarchy-agent --prompt "$prompt"
