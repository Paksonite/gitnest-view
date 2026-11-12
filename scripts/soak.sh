#!/usr/bin/env bash
# Soak test of the debug build against a test server: starts and quits it
# many times, lets it sit idle, and walks through the repositories with a
# time budget. Never point it at a server you care about with a token that
# can write: the app only reads here, but a test server is the place for it.
#
#   GNV_SOAK_HOST=forge.example.com GNV_SOAK_TOKEN=… GNV_SOAK_WORKDIR=/path/to/clones \
#   GNV_SOAK_WORKSPACE=Org scripts/soak.sh [launches] [idle seconds] [repositories to walk]
#
# Budgets (override with the variables): no crash report, idle CPU below
# IDLE_CPU percent on average, the main thread never held longer than
# STALL_MS while walking.
set -euo pipefail
cd "$(dirname "$0")/.."

launches="${1:-10}"
idle="${2:-60}"
walk="${3:-12}"
: "${GNV_SOAK_HOST:?set GNV_SOAK_HOST}" "${GNV_SOAK_TOKEN:?set GNV_SOAK_TOKEN}" "${GNV_SOAK_WORKDIR:?set GNV_SOAK_WORKDIR}"
idle_cpu="${IDLE_CPU:-3}"
stall_ms="${STALL_MS:-150}"
app="build.noindex/DerivedData/Build/Products/Debug/GitNest View.app/Contents/MacOS/GitNest View"
reports=~/Library/Logs/DiagnosticReports
out="$(mktemp -d)"
failed=0

xcodegen generate --quiet
xcodebuild -project GitNestView.xcodeproj -scheme GitNestView -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build.noindex/DerivedData -quiet build

start() { # start <stderr file> [env…] → pid in $pid
  local log="$1"; shift
  env "$@" GNV_DEV_HOST="$GNV_SOAK_HOST" GNV_DEV_LOGIN="${GNV_SOAK_LOGIN:-}" GNV_DEV_TOKEN="$GNV_SOAK_TOKEN" \
    GNV_DEV_WORKDIR="$GNV_SOAK_WORKDIR" GNV_DEV_WORKSPACE="${GNV_SOAK_WORKSPACE:-}" \
    "$app" -ApplePersistenceIgnoreState YES >/dev/null 2>"$log" &
  pid=$!
}

crashes() { ls "$reports" 2>/dev/null | grep -c "GitNest View" || true; }
before=$(crashes)

echo "== $launches launches"
for i in $(seq 1 "$launches"); do
  start "$out/launch-$i.log"
  sleep 6
  # A polite quit, the way ⌘Q does it; a kill only if that is not possible.
  # The debug build's own identity: the installed app is left alone.
  osascript -e 'tell application id "pl.paksonite.gitnest-view.debug" to quit' >/dev/null 2>&1 || kill -TERM "$pid"
  for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
  if kill -0 "$pid" 2>/dev/null; then echo "  launch $i did not quit"; kill -KILL "$pid"; failed=1; fi
  wait "$pid" 2>/dev/null || true
done

echo "== idle for ${idle}s"
start "$out/idle.log"
sleep 20 # the first reads are over
samples=0; total=0; peak_rss=0
for _ in $(seq 1 $((idle / 5))); do
  sleep 5
  read -r cpu rss < <(ps -o %cpu=,rss= -p "$pid") || break
  total=$(echo "$total + $cpu" | bc); samples=$((samples + 1))
  [[ "$rss" -gt "$peak_rss" ]] && peak_rss="$rss"
done
kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
if [[ "$samples" -gt 0 ]]; then
  average=$(echo "scale=2; $total / $samples" | bc)
  echo "  CPU ${average}% on average, memory at most $((peak_rss / 1024)) MB"
  if (( $(echo "$average > $idle_cpu" | bc) )); then echo "  over the budget of ${idle_cpu}%"; failed=1; fi
fi

echo "== walking through $walk repositories"
start "$out/walk.log" GNV_TRACE=1 GNV_DEV_CYCLE="$walk"
sleep $((8 + walk * 4 + 4 * 3 + 10))
kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
grep -E "cycle:" "$out/walk.log" | sed 's/^TRACE *[0-9]* ms  /  /' || true
switches=$(grep -c "main thread free again" "$out/walk.log" || true)
worst=$(grep -oE "main thread was busy for [0-9]+ ms" "$out/walk.log" | grep -oE "[0-9]+" | sort -n | tail -1 || true)
echo "  $switches switches, the main thread held for at most ${worst:-less than 25} ms"
if [[ -n "${worst:-}" && "$worst" -gt "$stall_ms" ]]; then echo "  over the budget of ${stall_ms} ms"; failed=1; fi
if [[ "$switches" -eq 0 ]]; then echo "  nothing was walked: is the workspace right?"; failed=1; fi

sleep 4
new=$(( $(crashes) - before ))
echo "== crash reports: $new"
[[ "$new" -gt 0 ]] && failed=1
echo "logs: $out"
exit "$failed"
