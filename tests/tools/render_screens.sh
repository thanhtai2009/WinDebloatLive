#!/bin/sh
# Renders the GUI windows to PNG under Mono + Xvfb (Linux): tests/tools/render_screens.sh <outDir>
# Needs mono (mcs), Xvfb, pwsh. Mono's Windows Forms only approximates native Windows controls (combo boxes,
# scroll bars, title bar); the custom-drawn Material controls are rendered by the same code as on Windows.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$ROOT/screens}
WORK=$(mktemp -d)
mkdir -p "$OUT"
pwsh -NoProfile -File "$ROOT/tests/tools/New-ScreenData.ps1" -OutDir "$WORK/data" >/dev/null
mcs -langversion:5 -target:library -r:System.Windows.Forms.dll -r:System.Drawing.dll -out:"$WORK/WdlUi.dll" "$ROOT/lib/WdlUi.cs"
mcs -langversion:5 -r:System.Windows.Forms.dll -r:System.Drawing.dll -r:"$WORK/WdlUi.dll" -out:"$WORK/Shots.exe" "$ROOT/tests/tools/Shots.cs"
Xvfb :77 -screen 0 1600x1100x24 -dpi ${DPI:-96} >/dev/null 2>&1 &
XPID=$!
sleep 1
for s in "mode en light" "modehover en light" "mode en dark" "modehover en dark" "mode vi light" "modehover vi light" "modehover vi dark" "simple en light" "simple vi dark" "advanced vi light" "advanced en dark" "preview vi light" "undo en dark" "message vi light" "mode vi dark"; do
  set -- $s
  DISPLAY=:77 MONO_ENV_OPTIONS= mono "$WORK/Shots.exe" "$ROOT" "$OUT" "$1" "$2" "$3" "$WORK/data" || echo "failed: $s"
done
kill $XPID 2>/dev/null || true
rm -rf "$WORK"
ls -1 "$OUT"
