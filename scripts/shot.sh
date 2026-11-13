#!/usr/bin/env bash
# Launches the Debug Histq app in an isolated state dir and captures its window only. The launch stays in the
# background: `open -g` (no activation) and `-HistqBackground YES` (the app never activates, its window is ordered
# behind the others and never made key, on the "ARZOPA" display when connected), so a run never takes the user's
# focus. `screencapture -l` captures the window even when other windows cover it; inactive-window rendering (grey
# traffic lights) is expected.
#
# Usage: scripts/shot.sh <out.png> [--keep-state] [--wait <s>] [repo paths…] [-- app args…]
#
#   --keep-state  keep build/qa/state and the QA preferences suite (com.math2it.histq.qa)
#   --wait <s>    seconds to wait after the window appears, before the capture (default 1.5)
#
# Relative paths (out.png, repo paths) are resolved against the caller's cwd. Only the instance
# this script starts is killed (matched by pid); never the real com.math2it.histq domain or app.
set -euo pipefail

die() { echo "shot.sh: $*" >&2; exit 1; }
usage() { echo "usage: shot.sh <out.png> [--keep-state] [--wait <s>] [repo paths…] [-- app args…]" >&2; exit 2; }
abspath() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$CALLER_CWD/$1" ;; esac; }

CALLER_CWD="$PWD"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
STATE_DIR="$ROOT/build/qa/state"
QA_SUITE="com.math2it.histq.qa"

[ $# -ge 1 ] || usage
case "$1" in -*) usage ;; esac
OUT="$(abspath "$1")"
shift

keep_state=0 wait_s=1.5
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-state) keep_state=1; shift ;;
    --wait) [ $# -ge 2 ] || usage; wait_s="$2"; shift 2 ;;
    *) break ;;
  esac
done
[[ "$wait_s" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--wait needs a number of seconds, got '$wait_s'"

# Remaining arguments: repo paths, then `--` and app args. open_args is never empty (bash 3.2 + set -u).
open_args=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do
  open_args+=("$(abspath "$1")")
  shift
done
[ $# -gt 0 ] && shift  # drop `--`
open_args+=(--args -HistqStateDir "$STATE_DIR" -HistqBackground YES)
[ $# -gt 0 ] && open_args+=("$@")

APP="$(cd "$ROOT" && xcodebuild -project Histq.xcodeproj -scheme Histq -configuration Debug -showBuildSettings 2>/dev/null \
  | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1 || true)"
[ -n "$APP" ] || die "BUILT_PRODUCTS_DIR not found (xcodebuild -showBuildSettings failed in $ROOT)"
APP="$APP/Histq.app"
BIN="$APP/Contents/MacOS/Histq"
[ -x "$BIN" ] || die "Debug app not built: $BIN missing (run the APP chain first)"

if [ $keep_state -eq 0 ]; then
  rm -rf "$STATE_DIR"
  defaults delete "$QA_SUITE" 2>/dev/null || true
fi
mkdir -p "$STATE_DIR" "$(dirname "$OUT")"
rm -f "$OUT"

# Only processes whose executable is this Debug binary count; never an installed release.
bin_pids() { ps -axo pid=,comm= | awk -v b="$BIN" '{ p = $1; sub(/^ *[0-9]+ /, ""); if ($0 == b) print p }'; }
is_ours() { [[ "$(ps -o comm= -p "$1" 2>/dev/null)" == "$BIN" ]]; }

pid=""
tmpdir="$(mktemp -d)"
cleanup() {
  if [ -n "$pid" ] && is_ours "$pid"; then
    kill "$pid" 2>/dev/null || true
    local i
    for i in $(seq 25); do is_ours "$pid" || break; sleep 0.2; done
    if is_ours "$pid"; then kill -9 "$pid" 2>/dev/null || true; fi
    for i in $(seq 25); do is_ours "$pid" || break; sleep 0.2; done
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

# Compiled before launch so the build time does not eat the 10 s window budget.
cat > "$tmpdir/winid.swift" <<'SWIFT'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
if let w = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
   let id = w[kCGWindowNumber as String] as? Int { print(id) }
SWIFT
xcrun swiftc -O -o "$tmpdir/winid" "$tmpdir/winid.swift" 2>"$tmpdir/swiftc.log" \
  || die "could not compile the window-id helper: $(cat "$tmpdir/swiftc.log")"

before="$(bin_pids | sort)"
open -n -g -a "$APP" "${open_args[@]}" || die "open failed for $APP"

# Up to 10 s for the new instance and its window.
winid=""
deadline=$((SECONDS + 10))
while [ $SECONDS -lt $deadline ]; do
  if [ -z "$pid" ]; then
    new="$(comm -13 <(printf '%s\n' "$before") <(bin_pids | sort) | sed '/^$/d')"
    if [ -n "$new" ]; then
      [ "$(printf '%s\n' "$new" | wc -l | tr -d ' ')" -eq 1 ] || die "several new Histq instances appeared: $(echo $new)"
      pid="$new"
    fi
  fi
  if [ -n "$pid" ]; then
    is_ours "$pid" || die "the new Histq instance (pid $pid) exited before showing a window"
    winid="$("$tmpdir/winid" "$pid" 2>/dev/null || true)"
    [ -n "$winid" ] && break
  fi
  sleep 0.2
done
[ -n "$pid" ] || die "no new Histq instance started within 10 s"
[ -n "$winid" ] || die "no window for Histq (pid $pid) within 10 s"

sleep "$wait_s"
is_ours "$pid" || die "Histq (pid $pid) exited before the capture"
# Window-only capture: never fall back to a full-screen shot.
screencapture -x -o -l"$winid" "$OUT" || die "screencapture failed for window $winid: screen locked, Screen Recording permission missing, or this shell's sandbox blocks capture"
[ -s "$OUT" ] || die "screencapture wrote no image to $OUT (Screen Recording permission?)"
echo "$OUT ($(stat -f%z "$OUT") bytes, pid $pid, window $winid)"
