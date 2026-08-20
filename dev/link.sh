#!/usr/bin/env bash
# Assemble the harness's Quickshell config folder, outside the repo.
#
# Two constraints pull in opposite directions. Quickshell will only import
# modules from inside its own config folder, so the plugin's sources and the
# shell's Commons/Ui have to sit beside shell.qml. But Omarchy refuses to load a
# plugin folder containing any symlink — a symlink could point a plugin that has
# landed in the trusted plugins directory at anything on disk — so building that
# folder inside the repo makes `omarchy plugin validate` fail for anyone working
# on this.
#
# So the config folder is assembled somewhere else and links back in. Editing a
# link still edits the real file, which is the point, and the repo stays a plugin
# folder Omarchy will load.
set -euo pipefail
cd "$(dirname "$0")"
repo="$(cd .. && pwd)"

STAGE="${OFFICE365_DEV_STAGE:-${XDG_RUNTIME_DIR:-/tmp}/omarchy-office365-dev}"
rm -rf "$STAGE"
mkdir -p "$STAGE"

ln -sfn /usr/share/omarchy/shell/Commons "$STAGE/Commons"
ln -sfn /usr/share/omarchy/shell/Ui "$STAGE/Ui"
for f in "$repo"/src/*.qml "$repo"/src/Model.js; do
  ln -sfn "$f" "$STAGE/$(basename "$f")"
done
for f in shell.qml Fixtures.js; do
  ln -sfn "$repo/dev/$f" "$STAGE/$f"
done

echo "$STAGE"
