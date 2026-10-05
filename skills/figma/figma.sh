#!/usr/bin/env bash
# Figma helper — рендер нод в PNG + выгрузка node JSON (стили/паддинги/тексты/эффекты)
# из макетов Figma через REST API. WebFetch по figma-ссылке даёт 403 — только API.
#
# Auth: Figma personal access token со scope file_content:read.
#   Токен берётся из env FIGMA_TOKEN, иначе из файла рядом: .figma_token
#
# Зависимости: curl, jq.
#
# Команды:
#   figma.sh get   <target> [outdir]          — PNG (scale 2) + node JSON + сводка токенов (осн. режим)
#   figma.sh img   <target> [outdir] [scale]  — только PNG
#   figma.sh node  <target> [outfile]         — только JSON нода (+ сводка на stderr)
#   figma.sh sum   <target>                   — только сводка токенов (без сохранения файлов)
#   figma.sh me                               — проверить токен (кто я)
#
# <target> — либо полная ссылка Figma (…/design/<KEY>/…?node-id=<A>-<B>),
#            либо два аргумента: <fileKey> <nodeId>.
#   node-id из URL идёт с "-" (18937-24686), в API нужен ":" (18937:24686) — конвертируется сам.
#
# ВАЖНО (для Claude): запускать через Bash с dangerouslyDisableSandbox: true —
# sandbox режет сеть к api.figma.com. JSON-токен — источник правды по значениям
# (radius/padding/fontSize/цвета/тени), а не глаз по PNG.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="https://api.figma.com/v1"

# --- token ---
TOKEN="${FIGMA_TOKEN:-}"
if [[ -z "$TOKEN" && -f "$SELF_DIR/.figma_token" ]]; then
  TOKEN="$(tr -d '[:space:]' < "$SELF_DIR/.figma_token")"
fi
if [[ -z "$TOKEN" ]]; then
  echo "ERROR: нет токена. Задай env FIGMA_TOKEN или положи его в $SELF_DIR/.figma_token" >&2
  exit 1
fi

# Sandbox-прокси рвёт TLS к figma — сбрасываем, если подсунут.
unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy 2>/dev/null || true

die() { echo "ERROR: $*" >&2; exit 1; }

fig() { curl -fsS -m 60 -H "X-Figma-Token: ${TOKEN}" "$@"; }

# parse target → FILE_KEY, NODE (API-форма с ':'), TARGET_ARGS (сколько арг. съедено)
FILE_KEY=""; NODE=""; TARGET_ARGS=0
parse_target() {
  local a="${1:-}"
  [[ -n "$a" ]] || die "не задан target (ссылка Figma или '<fileKey> <nodeId>')"
  if [[ "$a" == http* || "$a" == *figma.com/* ]]; then
    FILE_KEY="$(sed -nE 's#.*figma\.com/(design|file|proto)/([A-Za-z0-9]+).*#\2#p' <<<"$a")"
    NODE="$(sed -nE 's#.*[?&]node-id=([^&]+).*#\1#p' <<<"$a")"
    TARGET_ARGS=1
  else
    FILE_KEY="$a"; NODE="${2:-}"; TARGET_ARGS=2
  fi
  [[ -n "$FILE_KEY" ]] || die "не удалось определить file key из target"
  [[ -n "$NODE" ]] || die "не удалось определить node-id из target"
  NODE="${NODE//\%3A/:}"   # %3A → :
  NODE="${NODE//-/:}"      # 18937-24686 → 18937:24686
}

# сводка ключевых токенов дизайна по node JSON (stdin = JSON /nodes, $1 = node id)
JQ_SUMMARY='
  def hb: (.*255|round) as $v | ($v/16|floor) as $h | ($v - $h*16) as $l
          | ("0123456789abcdef"|explode) as $x
          | ([$x[$h]]|implode) + ([$x[$l]]|implode);
  def hex: if . == null then "-" else "#" + (.r|hb) + (.g|hb) + (.b|hb)
           + (if (.a//1) < 1 then " a=" + ((.a*100|round|tostring)+"%") else "" end) end;
  .nodes[$n].document as $d
  | "── \($d.name)  [\($d.type)]",
    "  size:    \($d.absoluteBoundingBox.width|floor) x \($d.absoluteBoundingBox.height|floor)   radius: \($d.cornerRadius // "-")",
    "  layout:  \($d.layoutMode // "-")   gap: \($d.itemSpacing // 0)   pad: L\($d.paddingLeft//0) R\($d.paddingRight//0) T\($d.paddingTop//0) B\($d.paddingBottom//0)",
    "  fills:   \([$d.fills[]? | select(.visible != false) | (.color|hex)] | join(", "))",
    "  effects: \([$d.effects[]? | select(.visible != false) | "\(.type) off(\(.offset.x//0),\(.offset.y//0)) blur \(.radius//0) \(.color|hex)"] | join(" | "))",
    ( [.. | objects | select(.type=="TEXT" and (.visible != false))]
      | if length==0 then empty else "  text:" end ),
    ( [.. | objects | select(.type=="TEXT" and (.visible != false))][]
      | "    \"\(.characters)\"  \(.style.fontSize)/\(.style.fontWeight) lh\(.style.lineHeightPx // "-") \([.fills[]?.color|hex][0] // "-")" )
'

emit_summary() { jq -r --arg n "$NODE" "$JQ_SUMMARY" ; }

cmd_img() {
  parse_target "$@"; shift "$TARGET_ARGS"
  local outdir="${1:-./figma-out}" scale="${2:-2}"
  mkdir -p "$outdir"
  local safe="${NODE//[:\/]/_}"
  local meta url out="$outdir/figma_${safe}.png"
  meta="$(fig "$API/images/$FILE_KEY?ids=$NODE&scale=$scale&format=png")"
  url="$(jq -r --arg n "$NODE" '.images[$n] // empty' <<<"$meta")"
  [[ -n "$url" && "$url" != "null" ]] || die "рендер не получен: $(jq -c '{status,err}' <<<"$meta" 2>/dev/null || echo "$meta")"
  curl -fsS -m 60 "$url" -o "$out"
  echo "$out"
}

cmd_node() {
  parse_target "$@"; shift "$TARGET_ARGS"
  local safe="${NODE//[:\/]/_}"
  local out="${1:-./figma-out/node_${safe}.json}"
  mkdir -p "$(dirname "$out")"
  fig "$API/files/$FILE_KEY/nodes?ids=$NODE" -o "$out"
  jq -e --arg n "$NODE" '.nodes[$n]' "$out" >/dev/null 2>&1 || die "нод не найден в ответе (проверь node-id/доступ): $(jq -c '{status,err}' "$out" 2>/dev/null)"
  echo "$out"
  emit_summary <"$out" >&2
}

cmd_get() {
  parse_target "$@"; shift "$TARGET_ARGS"
  local outdir="${1:-./figma-out}"
  local png json
  png="$(cmd_img "$FILE_KEY" "$NODE" "$outdir")"
  json="$(cmd_node "$FILE_KEY" "$NODE" "$outdir/node_${NODE//[:\/]/_}.json" 2>/dev/null)"
  echo "PNG:  $png"
  echo "JSON: $json"
  echo "--- tokens ---"
  emit_summary <"$json"
}

cmd_sum() {
  parse_target "$@"
  fig "$API/files/$FILE_KEY/nodes?ids=$NODE" | emit_summary
}

cmd_me() { fig "$API/me" | jq -c '{email, handle, id}' 2>/dev/null || fig "$API/me"; }

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    get)  cmd_get  "$@" ;;
    img)  cmd_img  "$@" ;;
    node) cmd_node "$@" ;;
    sum)  cmd_sum  "$@" ;;
    me)   cmd_me ;;
    ""|-h|--help|help) sed -nE 's/^# ?//p' "${BASH_SOURCE[0]}" | sed -n '1,30p' ;;
    *) die "неизвестная команда: $cmd (см. figma.sh help)" ;;
  esac
}

main "$@"
