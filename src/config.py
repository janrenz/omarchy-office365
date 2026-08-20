#!/usr/bin/env python3
"""Update one widget instance's settings in ~/.config/omarchy/shell.json.

The shell's own updateEntryInline() matches bar entries by plugin id, which
would rewrite every instance of a multi-instance widget with the same values.
This helper targets a single entry instead.

Identity is an "instance" key this helper writes into the entry the first time
it saves one. Everything else is a guess: aliases are shared the moment someone
runs a merged widget beside a per-mailbox one, and two widgets showing the same
mailbox with the same settings are indistinguishable by their contents. So an
instance id wins outright, and the guesses that stand in for it before one
exists must each identify exactly one entry:

  1. the entry carrying the caller's instance id, else
  2. the entry whose keys deep-equal the caller's current settings, else
  3. the entry holding one of the caller's mailbox aliases, else
  4. the entry that has no mailbox yet - a freshly added widget.

Anything matching more than one entry is refused rather than resolved by
position: rewriting the wrong widget's settings is worse than saying no.

Values are applied as given; an empty string removes the key so the plugin's
default takes over again.
"""

import argparse
import json
import os
import stat
import sys
import uuid

DEFAULT_SHELL_JSON = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
    "omarchy",
    "shell.json",
)
SECTIONS = ("left", "center", "right")


def out(payload):
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")
    sys.exit(0)


def fail(code, message):
    out({"ok": False, "error": {"code": code, "message": message}})


def body(entry):
    return {k: v for k, v in entry.items() if k != "id"}


def entry_aliases(entry):
    """Every mailbox alias an entry holds, v1 single or v2 list."""
    aliases = []
    single = str(entry.get("account", "") or "").strip()
    if single:
        aliases.append(single)
    for account in entry.get("accounts") or []:
        if isinstance(account, dict):
            alias = str(account.get("account", "") or "").strip()
            if alias:
                aliases.append(alias)
    return aliases


def entry_instance(entry):
    return str(entry.get("instance", "") or "").strip()


def only(hits):
    """(section, index) when exactly one entry matched, "ambiguous", or None."""
    if len(hits) == 1:
        return hits[0][:2]
    return "ambiguous" if hits else None


def find_entry(config, plugin_id, match, instance=""):
    """Return (section, index) of the entry to update, "ambiguous", or None."""
    layout = (config.get("bar") or {}).get("layout") or {}
    candidates = []
    for section in SECTIONS:
        for index, entry in enumerate(layout.get(section) or []):
            if isinstance(entry, dict) and entry.get("id") == plugin_id:
                candidates.append((section, index, entry))

    if not candidates:
        return None

    # An id the caller was given by an earlier save. Nothing else is consulted:
    # a widget that knows which entry it is cannot be talked out of it by
    # another widget that happens to hold the same mailbox.
    if instance:
        return only([c for c in candidates if entry_instance(c[2]) == instance])

    # No id yet, so identify by contents - most specific first, and each step
    # has to land on exactly one entry to count.
    found = only([c for c in candidates if body(c[2]) == match])
    if found:
        return found

    for alias in entry_aliases(match):
        found = only([c for c in candidates if alias in entry_aliases(c[2])])
        if found:
            return found

    return only([c for c in candidates if not entry_aliases(c[2])])


def write_config(path, config):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")
    os.replace(tmp, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin-id", default="caseonline.omarchy.office365")
    parser.add_argument("--match", required=True, help="the widget's current settings, as JSON")
    parser.add_argument("--set", dest="updates", required=True, help="keys to write, as JSON")
    parser.add_argument("--instance", default="", help="this widget's instance id, if it has one yet")
    parser.add_argument("--shell-json", default=DEFAULT_SHELL_JSON)
    args = parser.parse_args()

    try:
        match = json.loads(args.match)
        updates = json.loads(args.updates)
    except ValueError as error:
        fail("bad_json", "Could not parse arguments: %s" % error)
    if not isinstance(match, dict) or not isinstance(updates, dict):
        fail("bad_json", "Both --match and --set must be JSON objects")

    try:
        with open(args.shell_json, "r", encoding="utf-8") as handle:
            config = json.load(handle)
    except OSError as error:
        fail("no_config", "Could not read %s: %s" % (args.shell_json, error))
    except ValueError as error:
        fail("bad_config", "%s is not valid JSON: %s" % (args.shell_json, error))

    instance = str(args.instance or "").strip()
    target = find_entry(config, args.plugin_id, match, instance)
    if target == "ambiguous":
        fail(
            "ambiguous",
            "More than one Office 365 widget looks like this one, so saving "
            "could rewrite the wrong one. Give them different mailboxes or "
            "settings, save each once, and they will keep themselves apart "
            "from then on.",
        )
    if target is None:
        fail("not_found", "Could not find this widget in the bar layout")

    section, index = target
    entry = config["bar"]["layout"][section][index]
    for key, value in updates.items():
        if key in ("id", "instance"):
            continue
        if value == "":
            entry.pop(key, None)
        else:
            entry[key] = value

    # Stamp identity on the way past, so the next save does not have to guess
    # again. Short because a person may well read it in shell.json.
    if not entry_instance(entry):
        entry["instance"] = instance or uuid.uuid4().hex[:12]

    write_config(args.shell_json, config)
    out({"ok": True, "section": section, "index": index, "entry": entry})


if __name__ == "__main__":
    main()
