#!/usr/bin/env bash
set -euo pipefail

# ── COLORS ─────────────────────────────────────────────
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
GRAY="\e[90m"
BOLD="\e[1m"
RESET="\e[0m"

command -v jq >/dev/null || exit 1
command -v curl >/dev/null || exit 1

SPEC_INPUT="$1"

# ── LOAD SPEC ─────────────────────────────────────────────
if [[ "$SPEC_INPUT" =~ ^https?:// ]]; then
  SPEC_JSON=$(curl -fsSL "$SPEC_INPUT")
else
  SPEC_JSON=$(cat "$SPEC_INPUT")
fi

echo "$SPEC_JSON" | jq empty || exit 1

IS_V3=$(echo "$SPEC_JSON" | jq -r 'if .openapi then "yes" else "no" end')

# ── BASE URL ─────────────────────────────────────────────
if [[ "$IS_V3" == "yes" ]]; then
  BASE_URL=$(echo "$SPEC_JSON" | jq -r '.servers[0].url // ""')
  [[ -z "$BASE_URL" ]] && BASE_URL=$(echo "$SPEC_INPUT" | awk -F/ '{print $1"//"$3}')
else
  HOST=$(echo "$SPEC_JSON" | jq -r '.host // ""')
  SCHEME=$(echo "$SPEC_JSON" | jq -r '.schemes[0] // "https"')
  BASE_URL="${SCHEME}://${HOST}"
fi

BASE_URL="${BASE_URL%/}"

# ── BASE URL VALIDATION ─────────────────────────────
echo -e "${YELLOW}[*] Checking Base URL... $BASE_URL ${RESET}"

BASE_CHECK=$(curl -k -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 5 --max-time 5 "$BASE_URL")

# normalize (keep only last 3 digits)
BASE_CHECK="${BASE_CHECK: -3}"

if [[ "$BASE_CHECK" == "000" ]]; then
  echo -e "${RED}[ERROR] Base URL not reachable: $BASE_URL${RESET}"
  exit 1
fi

OUTPUT_FILE="results.txt"
>> "$OUTPUT_FILE"   # clear file


echo -e "${GREEN}[OK] Base URL reachable (HTTP $BASE_CHECK)${RESET}"

echo ""
echo "Swagger cURL Extractor"
echo "Base: $BASE_URL"
echo "──────────────────────────────────────────────"

# ── REF RESOLVER ─────────────────────────────────────────
resolve_ref(){
  local s="$1"
  local r
  r=$(echo "$s" | jq -r '."$ref" // empty')
  [[ -z "$r" ]] && { echo "$s"; return; }

  local n="${r##*/}"
  echo "$SPEC_JSON" | jq -c --arg n "$n" \
    '.components.schemas[$n] // .definitions[$n] // {}'
}

# ── OBJECT BUILDER ───────────────────────────────────────
build_object(){
  local s="$1"
  s=$(resolve_ref "$s")

  local props out first=1
  props=$(echo "$s" | jq -c '.properties // {}')

  [[ "$props" == "{}" ]] && { echo "{}"; return; }

  out="{"
  while IFS= read -r k; do
    v=$(sample_value "$(echo "$props" | jq -c --arg k "$k" '.[$k]')")
    [[ $first -eq 0 ]] && out+=","
    out+="\"$k\":$v"
    first=0
  done < <(echo "$props" | jq -r 'keys[]')

  out+="}"
  echo "$out"
}

# ── VALUE GENERATOR ──────────────────────────────────────
sample_value(){
  local s="$1"
  s=$(resolve_ref "$s")

  local t
  t=$(echo "$s" | jq -r '.type // "object"')

  case "$t" in
    string) echo '"string"' ;;
    integer|number) echo 0 ;;
    boolean) echo true ;;
    array)
      local i v
      i=$(echo "$s" | jq -c '.items // {}')
      i=$(resolve_ref "$i")
      v=$(sample_value "$i")
      echo "[${v}]"
      ;;
    *) build_object "$s" ;;
  esac
}

# ── BODY BUILDER (UNCHANGED LOGIC) ──────────────────────
build_body(){
  local s="$1"
  s=$(resolve_ref "$s")

  local ex
  ex=$(echo "$s" | jq -c '.example // empty' 2>/dev/null || true)
  [[ -n "$ex" ]] && { echo "$ex"; return; }

  local t
  t=$(echo "$s" | jq -r '.type // "object"')

  case "$t" in
    array)
      local i v
      i=$(echo "$s" | jq -c '.items // {}')
      i=$(resolve_ref "$i")
      v=$(sample_value "$i")
      echo "[${v}]"
      ;;
    object|*)
      build_object "$s"
      ;;
  esac
}

# ── SANITIZERS ──────────────────────────────────────────
sanitize_url() {
  sed -E 's/\{[^}]+\}/1/g; s/\[[^]]+\]/1/g'
}

sanitize_header() {
  sed -E 's/[{}]//g; s/\[//g; s/\]//g'
}

# ── CURL EXECUTION REPORT ───────────────────────────────
run_and_report() {
  local cmd="$1"

  (
    response=$(eval "$cmd -s -o /dev/null -w 'STATUS:%{http_code}|TYPE:%{content_type}|SIZE:%{size_download}|URL:%{url_effective}'" 2>/dev/null || true)

    status=$(echo "$response" | cut -d'|' -f1 | cut -d':' -f2)
    type=$(echo "$response" | cut -d'|' -f2 | cut -d':' -f2)
    size=$(echo "$response" | cut -d'|' -f3 | cut -d':' -f2)
    url=$(echo "$response" | cut -d'|' -f4 | cut -d':' -f2-)

    # SAFE PATH EXTRACT
    path="/${url#*://*/}"

    # 401/403/301/302 skip requests
    if [[ "$status" =~ ^(401|403|307|302|301|503|504|000)$ ]]; then
      exit 0
    fi
    # COLOR SELECTION
    if [[ "$status" =~ ^2 ]]; then
      S_COLOR=$GREEN
    elif [[ "$status" =~ ^3 ]]; then
      S_COLOR=$CYAN
    elif [[ "$status" =~ ^4 ]]; then
      S_COLOR=$YELLOW
    else
      S_COLOR=$RED
    fi

    # OUTPUT (PRINT + SAVE WITHOUT COLORS)
    {
      echo "──────────────────────────────────────────────"
      echo "[$status] [$METHOD] $url"
      [[ -n "$type" ]] && echo "TYPE: $type"
      [[ -n "$size" ]] && echo "SIZE: $size bytes"
      [[ -n "$CMD" ]] && echo "COMMAND: $CMD"
      echo "──────────────────────────────────────────────"
      echo ""
    } | tee -a "$OUTPUT_FILE" -a "/root/hackerone/temp/result_swagger.txt" >/dev/null

    # TERMINAL (COLORED)
    echo -e "${GRAY}──────────────────────────────────────────────${RESET}"
    echo -e "${S_COLOR}[$status]${RESET} ${BLUE}$url${RESET}"

    [[ -n "$type" ]] && echo -e "${CYAN}TYPE:${RESET} $type"
    [[ -n "$size" ]] && echo -e "${CYAN}SIZE:${RESET} $size bytes"
    [[ -n "$CMD" ]] && echo -e "${CYAN}COMMAND:${RESET} $CMD"

    echo -e "${GRAY}──────────────────────────────────────────────${RESET}"
    echo ""

  ) &

  # LIMIT TO 10 PARALLEL REQUESTS
  while [[ $(jobs -rp | wc -l) -ge 10 ]]; do
    wait -n 2>/dev/null || true
  done
}

# ── MAIN LOOP ────────────────────────────────────────────
while read -r path; do
  for m in get post put patch delete; do

    OP=$(echo "$SPEC_JSON" | jq -c --arg p "$path" --arg m "$m" '.paths[$p][$m] // empty')
    [[ -z "$OP" ]] && continue

    METHOD=${m^^}

    URL="${BASE_URL}${path}"

    PARAMS=$(echo "$OP" | jq -c '.parameters // []')

    # QUERY
    QUERY=""
    while IFS= read -r q; do
      QUERY+="${q}=[${q}]&"
    done < <(echo "$PARAMS" | jq -r '.[] | select(.in=="query") | .name')

    QUERY="${QUERY%&}"
    [[ -n "$QUERY" ]] && URL="${URL}?${QUERY}"

    URL=$(echo "$URL" | sanitize_url)

    # CURL START
    CMD="curl -X $METHOD '$URL'"

    # HEADERS
    declare -A SEEN_HEADERS 2>/dev/null || true

    if [[ "$IS_V3" == "yes" ]]; then
      CT=$(echo "$OP" | jq -r '.requestBody.content // {} | keys[0] // empty')
      [[ -n "$CT" ]] && CMD+=" -H 'Content-Type: $CT'"
      SEEN_HEADERS["Content-Type"]=1
    fi

    while IFS= read -r h; do
      [[ -z "$h" ]] && continue

      CLEAN=$(echo "$h" | sanitize_header)

      [[ -n "${SEEN_HEADERS[$CLEAN]:-}" ]] && continue
      SEEN_HEADERS["$CLEAN"]=1

      CMD+=" -H '$CLEAN: $CLEAN'"

    done < <(echo "$PARAMS" | jq -r '.[] | select(.in=="header") | .name')

    # BODY (UNCHANGED)
    BODY=""
    if [[ "$IS_V3" == "yes" ]]; then
      CT=$(echo "$OP" | jq -r '.requestBody.content // {} | keys[0] // empty')
      if [[ -n "$CT" ]]; then
        SCHEMA=$(echo "$OP" | jq -c --arg ct "$CT" '.requestBody.content[$ct].schema // {}')
        BODY=$(build_body "$SCHEMA")
      fi
    else
      SCHEMA=$(echo "$OP" | jq -c '.parameters[]? | select(.in=="body") | .schema // empty' | head -n1)
      [[ -n "$SCHEMA" ]] && BODY=$(build_body "$SCHEMA")
    fi

    [[ -n "$BODY" ]] && CMD+=" -H 'Content-Type: application/json' -d '$BODY'"

    # EXECUTE + REPORT
    run_and_report "$CMD"

  done
done < <(echo "$SPEC_JSON" | jq -r '.paths | keys[]')
wait
