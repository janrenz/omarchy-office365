#!/usr/bin/env bash
# Generate the showcase images: the real panel on the real desktop, with demo
# data, framed by the bar above it and the wallpaper around it.
#
#   dev/showcase.sh [outdir]        # default: ./
#
# Repeatable on purpose. The panel is a layer surface drawn inside a
# full-screen layer, so there is no window geometry to ask for and no way to
# render it offscreen the way dev/run.sh does for the pieces. What there is
# instead: the panel dims everything behind it, so photographing the screen
# with the panel shut and again with it open and taking the bounding box of the
# difference finds it exactly, whatever size the current settings make it.
#
# Nothing of yours ends up in an image. The margins are taken from the
# wallpaper file rather than from the photograph, so whatever you had open at
# the time is never in frame - only the bar strip, which is opaque, and the
# panel itself, which is showing invented mailboxes.
#
# Your shell.json is saved first and put back on the way out, including on
# failure or Ctrl-C.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-$PWD}"
SHELL_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"
WALLPAPER="$(readlink -f "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/current/background")"
PLUGIN_ID="caseonline.omarchy.office365"
WORK="$(mktemp -d)"
BACKUP="$WORK/shell.json.yours"

# Fraction of the panel's own size left as margin on the open sides.
MARGIN=0.10
# Which output to photograph.
MONITOR="${SHOWCASE_MONITOR:-$(hyprctl monitors -j | jq -r '.[0].name')}"

for tool in grim magick jq wtype python3 hyprctl; do
  command -v "$tool" >/dev/null || { echo "showcase: $tool is required" >&2; exit 1; }
done
[ -f "$WALLPAPER" ] || { echo "showcase: no wallpaper at $WALLPAPER" >&2; exit 1; }

# One at a time. Two runs at once means the second saves a shell.json that the
# first has already replaced with a demo widget, and whichever restores last
# writes that back as if it were yours - which is exactly how a real
# configuration got lost once.
LOCK="${XDG_RUNTIME_DIR:-/tmp}/omarchy-office365-showcase.lock"
exec 9>"$LOCK"
flock -n 9 || { echo "showcase: another run is in progress" >&2; exit 1; }

# Refuse to start from a config this script left behind, so a backup is never a
# backup of the demo.
if grep -q '"demo": true' "$SHELL_JSON" 2>/dev/null; then
  echo "showcase: $SHELL_JSON still has a demo widget in it - restore it first" >&2
  exit 1
fi

cp "$SHELL_JSON" "$BACKUP"
restore() {
  cp "$BACKUP" "$SHELL_JSON"
  omarchy restart shell >/dev/null 2>&1 || true
  rm -rf "$WORK"
  echo "showcase: your shell.json is back"
}
trap restore EXIT

shell_ipc() { qs -p /usr/share/omarchy/shell/shell.qml ipc "$@" >/dev/null 2>&1 || true; }

# Replace every instance of this plugin with one demo widget carrying the
# settings a scenario wants, then wait until its IPC answers again.
install_widget() {
  python3 - "$SHELL_JSON" "$PLUGIN_ID" "$1" <<'PY'
import json, sys
path, plugin_id, overrides = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
config = json.load(open(path))
widget = {
    "id": plugin_id, "ipcTarget": "mail", "demo": True,
    "mails": 10, "refreshIntervalSec": 3600, "previewLine": True,
    "accounts": [
        {"account": "work", "short": "WRK", "color": "blue"},
        {"account": "personal", "short": "PRS", "color": "magenta"},
    ],
}
widget.update(overrides)
for section, entries in config["bar"]["layout"].items():
    config["bar"]["layout"][section] = [
        e for e in entries if not (isinstance(e, dict) and e.get("id") == plugin_id)
    ]
config["bar"]["layout"]["right"].append(widget)
json.dump(config, open(path, "w"), indent=2)
PY
  omarchy restart shell >/dev/null 2>&1
  for _ in $(seq 1 60); do
    qs -p /usr/share/omarchy/shell/shell.qml ipc show 2>/dev/null | grep -q "target mail" && return 0
    sleep 0.5
  done
  echo "showcase: the bar did not come back" >&2
  return 1
}

# One scenario: name, widget settings, keys to press once the panel is open.
capture_once() {
  local name="$1" overrides="$2" keys="${3:-}"
  echo "showcase: $name"
  install_widget "$overrides"

  shell_ipc call mail close
  sleep 1.5
  grim -o "$MONITOR" "$WORK/$name.shut.png"

  shell_ipc call mail open
  sleep 3
  grim -o "$MONITOR" "$WORK/$name.open.png"

  if [ -n "$keys" ]; then
    # Keys go to whatever holds keyboard focus, so the panel has to be known
    # to be up before any are sent - otherwise they land in whatever you are
    # working in. Finding the panel in this frame is that proof; if it is not
    # there, nothing is typed and the attempt is abandoned.
    if ! find_panel "$name" >/dev/null; then
      shell_ipc call mail close
      return 1
    fi
    # The panel's own keys: arrows move the cursor, Enter opens the message.
    for key in $keys; do wtype -k "$key" 2>/dev/null || true; sleep 0.6; done
    sleep 1.5
    grim -o "$MONITOR" "$WORK/$name.open.png"
  fi
  shell_ipc call mail close

  frame "$name"
}

# Photograph until the panel is found. A miss is almost always something of
# yours moving between the two frames, which the next attempt will not repeat.
capture() {
  local attempt
  for attempt in 1 2 3; do
    if capture_once "$@"; then return 0; fi
    echo "showcase: retrying $1 ($attempt)" >&2
    sleep 2
  done
  echo "showcase: gave up on $1" >&2
  return 1
}

# Where the panel is in $name.open.png, as WxH+X+Y. Fails if it is not there.
find_panel() {
  local name="$1"
  local shut="$WORK/$name.shut.png" open="$WORK/$name.open.png"

  local sw sh
  sw=$(magick identify -format "%w" "$open")
  sh=$(magick identify -format "%h" "$open")

  # Where the panel is. The difference between shut and open is mostly the
  # panel, but not only: anything of yours that moved between the two
  # photographs is in there too, and a chat window updating in the corner of
  # the screen is enough to stretch a plain bounding box across the desktop.
  #
  # So the mask is dilated until the panel's fragments - its rows, its borders,
  # the gaps where its background happens to match the dimmed desktop - merge
  # into one blob, and the blob that covers a point just under the bar at the
  # right-hand edge is taken. The panel is anchored there; a window of yours
  # that also changed is a different blob and is left behind. The precise edges
  # then come from measuring the undilated mask inside that blob.
  local mask blob
  mask="$WORK/$name.mask.png"
  magick "$shut" "$open" -compose difference -composite \
    -colorspace Gray -threshold 30% "$mask"
  blob=$(magick "$mask" -morphology Dilate Octagon:10 \
          -define connected-components:verbose=true -connected-components 8 null: 2>/dev/null \
        | awk -v sw="$sw" '$NF=="gray(255)" {
            split($2, g, /[x+]/); w=g[1]; h=g[2]; x=g[3]; y=g[4]
            seedx = sw - 25; seedy = 60
            if (seedx >= x && seedx <= x+w && seedy >= y && seedy <= y+h && w*h > best) {
              best = w*h; found = $2
            }
          } END { print found }')
  [ -n "$blob" ] || { echo "showcase: could not find the panel in $name" >&2; return 1; }

  local parts bw bh bx by pw ph px py
  parts=${blob//[x+]/ }; set -- $parts; bw=$1 bh=$2 bx=$3 by=$4
  parts=$(magick "$mask" -crop "${bw}x${bh}+${bx}+${by}" +repage -format "%@" info:)
  parts=${parts//[x+]/ }; set -- $parts
  pw=$1; ph=$2; px=$((bx + $3)); py=$((by + $4))

  # Sanity, because the dilation can still bridge the panel to something of
  # yours that moved right beside it. The panel is anchored under the bar at
  # the right-hand edge and never fills the screen, so a box that does is a
  # miss, and the caller photographs again rather than shipping the desktop.
  if [ "$pw" -gt $((sw * 7 / 10)) ] || [ "$ph" -gt $((sh * 19 / 20)) ] \
     || [ $((px + pw)) -lt $((sw - 150)) ] || [ "$py" -gt 200 ]; then
    echo "showcase: $name looked like ${pw}x${ph}+${px}+${py}, which is not the panel" >&2
    return 1
  fi
  echo "${pw}x${ph}+${px}+${py}"
}

# Cut the panel out and paste it back onto a clean plate.
frame() {
  local name="$1" found
  found=$(find_panel "$name") || return 1
  local parts pw ph px py sw sh
  parts=${found//[x+]/ }; set -- $parts; pw=$1 ph=$2 px=$3 py=$4
  local open="$WORK/$name.open.png" shut="$WORK/$name.shut.png"
  sw=$(magick identify -format "%w" "$open")
  sh=$(magick identify -format "%h" "$open")

  # Open sides get a margin of the panel's own size; the right keeps whatever
  # gap the bar really leaves, and the top keeps the bar.
  local mx my gap cx cy cw ch
  mx=$(python3 -c "print(round($pw * $MARGIN))")
  my=$(python3 -c "print(round($ph * $MARGIN))")
  gap=$((sw - px - pw))
  cx=$((px - mx)); cy=0
  cw=$((mx + pw + gap)); ch=$((py + ph + my))
  [ "$cx" -lt 0 ] && { cw=$((cw + cx)); cx=0; }
  [ "$ch" -gt "$sh" ] && ch=$sh

  # The plate: the wallpaper as the compositor lays it out, cropped to the same
  # region. Taking it from the file rather than the photograph is what keeps
  # whatever was on screen out of the picture.
  # +gravity before the crop: the centre gravity used for the extent would
  # otherwise be read as the crop's origin too, and the crop silently collapses.
  magick "$WALLPAPER" -resize "${sw}x${sh}^" -gravity center -extent "${sw}x${sh}" \
    +gravity -crop "${cw}x${ch}+${cx}+${cy}" +repage "$WORK/$name.plate.png"

  # The bar is opaque, so it can come straight off the photograph.
  magick "$WORK/$name.shut.png" -crop "${cw}x${py}+${cx}+0" +repage "$WORK/$name.bar.png"
  magick "$open" -crop "${pw}x${ph}+${px}+${py}" +repage "$WORK/$name.panel.png"

  magick "$WORK/$name.plate.png" \
    "$WORK/$name.bar.png" -geometry "+0+0" -composite \
    "$WORK/$name.panel.png" -geometry "+$((px - cx))+${py}" -composite \
    "$OUT/$name.png"
  echo "  -> $OUT/$name.png  ($(magick identify -format '%wx%h' "$OUT/$name.png"))"
}

# The three settings pages, side by side.
#
# These come from the offscreen harness rather than the panel, because reaching
# a settings page means clicking a row and there is no click to send: the panel
# answers to keys, and the gear is not one of them. The harness renders the same
# SettingsForm with the same Style and Color, so what is drawn is the real
# thing; it simply has no bar over it, which suits a figure about settings.
settings_trio() {
  echo "showcase: showcase-settings"
  local stage gap page shot n
  stage="$(dev/link.sh)"
  dev/run.sh >/dev/null 2>&1

  gap=48
  n=0

  # The stage paints nothing of its own, so a grab of it is transparent
  # wherever the form does not draw. Sample the harness window's background
  # once and flatten every card onto it, or the wallpaper shows through the
  # text.
  local bg
  dev/shot.sh "$WORK/settings-bg.png" >/dev/null 2>&1
  bg=$(magick "$WORK/settings-bg.png" -format "%[pixel:p{2,2}]" info:)
  for page in -1 0 -2; do
    qs -p "$stage/shell.qml" ipc call dev settingsPage "$page" >/dev/null 2>&1
    sleep 1
    shot="$WORK/settings-$n.raw.png"
    rm -f "$shot"
    qs -p "$stage/shell.qml" ipc call dev stageShot "$shot" >/dev/null 2>&1
    # grabToImage finishes on the render thread; wait for the size to settle.
    local previous=-1 size
    for _ in $(seq 1 60); do
      sleep 0.1
      size=$(stat -c %s "$shot" 2>/dev/null || echo 0)
      [ "$size" -gt 1000 ] && [ "$size" = "$previous" ] && break
      previous=$size
    done
    # The form is shorter than the stage on most pages; trim the empty
    # background off and give every card the same margin back.
    magick "$shot" -fuzz 2% -trim +repage \
      -background "$bg" -alpha remove -alpha off \
      -bordercolor "$bg" -border 28 "$WORK/settings-$n.png"
    n=$((n + 1))
  done

  # Each page is a different height; the canvas takes the tallest.
  local w h maxh total i
  maxh=0; total=$gap
  for i in 0 1 2; do
    w=$(magick identify -format "%w" "$WORK/settings-$i.png")
    h=$(magick identify -format "%h" "$WORK/settings-$i.png")
    [ "$h" -gt "$maxh" ] && maxh=$h
    total=$((total + w + gap))
  done
  local ch=$((maxh + gap * 2))

  magick "$WALLPAPER" -resize "${total}x${ch}^" -gravity center \
    +gravity -extent "${total}x${ch}" "$WORK/settings-plate.png"

  local args="" x=$gap
  for i in 0 1 2; do
    w=$(magick identify -format "%w" "$WORK/settings-$i.png")
    args="$args $WORK/settings-$i.png -geometry +${x}+${gap} -composite"
    x=$((x + w + gap))
  done
  # shellcheck disable=SC2086
  magick "$WORK/settings-plate.png" $args "$OUT/showcase-settings.png"
  echo "  -> $OUT/showcase-settings.png  ($(magick identify -format '%wx%h' "$OUT/showcase-settings.png"))"
}

mkdir -p "$OUT"

capture "showcase-agenda" '{"agendaView":"timeline","calendar":"3day"}'
capture "showcase-reading" '{"agendaView":"list","unreadByDefault":true}' "Down Return"
settings_trio

echo "showcase: done"
