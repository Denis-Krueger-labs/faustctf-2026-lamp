#!/usr/bin/env bash
set -u -o pipefail

# FAUST CTF 2026 - LAMP continuous probe/harvest loop
# Reconstructed from the competition notes/chat.
#
# A/D rule: if you looked at a target five minutes ago, congratulations,
# your information is now historical fiction.

OWN_TEAM="${OWN_TEAM:-}"
TARGET_FILE="${TARGET_FILE:-lamp-teamids.txt}"
PROBE_SCRIPT="${PROBE_SCRIPT:-./lamp-probe.sh}"
HARVEST_SCRIPT="${HARVEST_SCRIPT:-./lamp-brrr.sh}"
SLEEP_SECONDS="${SLEEP_SECONDS:-180}"
REPROBE_EVERY="${REPROBE_EVERY:-5}"
PROBE_WORKERS="${PROBE_WORKERS:-12}"
HARVEST_WORKERS="${HARVEST_WORKERS:-4}"
MOTH_URL="${MOTH_URL:-http://127.0.0.1:8001}"
MOTH_ENDPOINT="${MOTH_ENDPOINT:-/api/flags/batch}"
STATE_DIR="${STATE_DIR:-$HOME/.lamp-brrr}"

if [[ -z "$OWN_TEAM" ]]; then
  echo "[-] Set OWN_TEAM first, e.g. OWN_TEAM=123 $0" >&2
  exit 2
fi

SEEN_FILE="$STATE_DIR/seen.flags"
VULN_FILE="$STATE_DIR/vulnerable.txt"
NEW_FILE="$STATE_DIR/new.flags"
LOG_DIR="$STATE_DIR/logs"
CHUNK_DIR="$STATE_DIR/chunks"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$CHUNK_DIR"
touch "$SEEN_FILE" "$VULN_FILE"
sort -u "$SEEN_FILE" -o "$SEEN_FILE"

for cmd in curl jq grep sort comm split awk tee date flock; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "[-] missing dependency: $cmd" >&2
    exit 2
  }
done

[[ -x "$PROBE_SCRIPT" ]] || { echo "[-] not executable: $PROBE_SCRIPT" >&2; exit 2; }
[[ -x "$HARVEST_SCRIPT" ]] || { echo "[-] not executable: $HARVEST_SCRIPT" >&2; exit 2; }

# One loop is enough. Two loops become interpretive concurrency theatre.
exec 200>"$STATE_DIR/loop.lock"
if ! flock -n 200; then
  echo "[-] another lamp-loop instance already owns $STATE_DIR/loop.lock" >&2
  exit 1
fi

if [[ -z "${MOTH_API_TOKEN:-}" && -r /etc/moth/moth.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source /etc/moth/moth.env
  set +a
fi

if [[ -z "${MOTH_API_TOKEN:-}" ]]; then
  read -rsp 'MOTH API token: ' MOTH_API_TOKEN
  echo
  export MOTH_API_TOKEN
fi

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

banner() {
  printf '\n================================================================\n'
  printf '[%s] %s\n' "$(timestamp)" "$*"
  printf '================================================================\n'
}

run_probe() {
  local log probe_dir
  log="$LOG_DIR/probe-$(date '+%Y%m%d-%H%M%S').log"

  banner "FULL FIELD PROBE"

  OWN_TEAM="$OWN_TEAM" \
  TARGET_FILE="$TARGET_FILE" \
  WORKERS="$PROBE_WORKERS" \
    "$PROBE_SCRIPT" 2>&1 | tee "$log"

  probe_dir="$(sed -n 's/^\[\*\] probe data kept in //p' "$log" | tail -1)"
  if [[ -z "$probe_dir" || ! -r "$probe_dir/vulnerable.txt" ]]; then
    probe_dir="$(ls -1dt /tmp/lamp-probe.* 2>/dev/null | head -1 || true)"
  fi

  if [[ -n "$probe_dir" && -r "$probe_dir/vulnerable.txt" ]]; then
    sort -nu "$probe_dir/vulnerable.txt" > "$VULN_FILE"
  else
    echo "[-] could not recover probe vulnerable list" >&2
    return 1
  fi

  echo "[*] Current vulnerable teams:"
  cat "$VULN_FILE" || true
}

run_harvest() {
  local log teams harvest_dir harvested

  banner "HARVEST"

  if [[ ! -s "$VULN_FILE" ]]; then
    echo "[*] no currently vulnerable teams"
    : > "$NEW_FILE"
    return 0
  fi

  teams="$(paste -sd, "$VULN_FILE")"
  log="$LOG_DIR/harvest-$(date '+%Y%m%d-%H%M%S').log"

  # Harvest first, submit once. Otherwise every worker tries to become MOTH's
  # favourite child at the same time.
  OWN_TEAM="$OWN_TEAM" \
  WORKERS="$HARVEST_WORKERS" \
  ONLY_TEAMS="$teams" \
  SUBMIT=0 \
    "$HARVEST_SCRIPT" 2>&1 | tee "$log"

  harvest_dir="$(sed -n 's/^\[\*\] run data kept in //p' "$log" | tail -1)"
  if [[ -z "$harvest_dir" || ! -r "$harvest_dir/all.flags" ]]; then
    harvest_dir="$(ls -1dt /tmp/lamp-brrr.* 2>/dev/null | head -1 || true)"
  fi

  harvested="$STATE_DIR/harvested.flags"
  if [[ -n "$harvest_dir" && -r "$harvest_dir/all.flags" ]]; then
    sort -u "$harvest_dir/all.flags" > "$harvested"
  else
    : > "$harvested"
  fi

  sort -u "$SEEN_FILE" -o "$SEEN_FILE"
  comm -23 "$harvested" "$SEEN_FILE" > "$NEW_FILE"

  echo "[*] harvested this cycle: $(wc -l < "$harvested" | tr -d ' ')"
  echo "[*] never submitted:      $(wc -l < "$NEW_FILE" | tr -d ' ')"
}

submit_new() {
  local chunk payload response http body

  [[ -s "$NEW_FILE" ]] || {
    echo "[*] nothing new for MOTH"
    return 0
  }

  banner "FEEDING MOTH"

  rm -f "$CHUNK_DIR"/flags-* "$CHUNK_DIR"/*.json 2>/dev/null || true
  split -l 100 -d -a 3 "$NEW_FILE" "$CHUNK_DIR/flags-"

  for chunk in "$CHUNK_DIR"/flags-*; do
    [[ -s "$chunk" ]] || continue

    payload="${chunk}.json"
    jq -Rs '
      {flags:(split("\n")|map(select(length>0))), service:"LAMP", source:"lamp-loop"}
    ' "$chunk" > "$payload"

    response="$(curl -sS --connect-timeout 2 --max-time 10 \
      -X POST "${MOTH_URL}${MOTH_ENDPOINT}" \
      -H "Authorization: Bearer $MOTH_API_TOKEN" \
      -H 'Content-Type: application/json' \
      --data-binary "@$payload" \
      -w $'\n%{http_code}' 2>/dev/null || true)"

    http="${response##*$'\n'}"
    body="${response%$'\n'*}"

    printf '[*] MOTH HTTP %s ' "$http"
    if jq -e . >/dev/null 2>&1 <<<"$body"; then
      jq -c '.summary // .' <<<"$body"
    else
      printf '%s\n' "${body:0:240}"
    fi

    if [[ "$http" =~ ^2[0-9][0-9]$ ]]; then
      # MOTH has seen these snacks. Do not offer them again.
      cat "$chunk" >> "$SEEN_FILE"
      sort -u "$SEEN_FILE" -o "$SEEN_FILE"
    fi
  done

  echo "[*] persistent seen flags: $(wc -l < "$SEEN_FILE" | tr -d ' ')"
}

cycle=0
run_probe || true

while true; do
  cycle=$((cycle + 1))
  banner "CYCLE $cycle"

  # Re-probe because defenders have a deeply inconvenient habit of defending.
  if (( cycle > 1 && (cycle - 1) % REPROBE_EVERY == 0 )); then
    run_probe || true
  fi

  run_harvest || true
  submit_new || true

  echo "[*] cycle complete"
  echo "[*] sleeping ${SLEEP_SECONDS}s"
  sleep "$SLEEP_SECONDS"
done
