#!/usr/bin/env bash
# Ask the harness to draw itself into a PNG.
#
# It grabs its own contents rather than being photographed off the screen: a
# tiling compositor will happily put the window behind another one, and a
# region screenshot then captures whatever is in front of it. This works even
# when the harness is on a workspace nobody is looking at.
#
#   dev/shot.sh out.png [days] [from] [to] [select]
set -euo pipefail
cd "$(dirname "$0")"

STAGE="${OFFICE365_DEV_STAGE:-${XDG_RUNTIME_DIR:-/tmp}/omarchy-office365-dev}"
qs() { command qs -p "$STAGE/shell.qml" "$@"; }

out="${1:-/tmp/office365-dev.png}"
[ "${2:-}" != "" ] && qs ipc call dev range "$2"
[ "${3:-}" != "" ] && qs ipc call dev hours "$3" "${4:-22:00}"
[ "${5:-}" != "" ] && qs ipc call dev select "$5"

rm -f "$out"
qs ipc call dev shot "$out"

# grabToImage finishes on the render thread, after the call returns - and the
# file appears before it is finished being written, so a size check alone hands
# back a truncated PNG.
# A truncated PNG still identifies (with a warning), so wait for the size to
# settle instead.
previous=-1
for _ in $(seq 1 60); do
  sleep 0.1
  size=$(stat -c %s "$out" 2>/dev/null || echo 0)
  if [ "$size" -gt 1000 ] && [ "$size" = "$previous" ]; then
    echo "$out"
    exit 0
  fi
  previous=$size
done
echo "no image at $out - is the harness running? try dev/run.sh" >&2
exit 1
