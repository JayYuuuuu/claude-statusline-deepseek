#!/usr/bin/env bash
# DeepSeek-aware Claude Code statusline.
# Replaces claude-hud and shows DeepSeek balance / session spend when
# routed through cc-switch (ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic).
# Falls back to native cost + rate_limits on real Anthropic.

set -uo pipefail

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

jq_s() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null; }
jq_n() { printf '%s' "$INPUT" | jq -r "$1 // 0"     2>/dev/null; }
# Round half-up to int. Empty/non-numeric becomes 0.
round_int() { awk -v v="${1:-0}" 'BEGIN { v=v+0; if (v<0) printf "%d", v-0.5; else printf "%d", v+0.5 }'; }

# ---------- stdin fields ----------
SESSION_ID=$(jq_s '.session_id')
MODEL_ID=$(jq_s '.model.id')
MODEL_NAME=$(jq_s '.model.display_name'); [ -z "$MODEL_NAME" ] && MODEL_NAME="$MODEL_ID"
[ -z "$MODEL_NAME" ] && MODEL_NAME="?"
CWD=$(jq_s '.workspace.current_dir'); [ -z "$CWD" ] && CWD=$(jq_s '.cwd'); [ -z "$CWD" ] && CWD="$PWD"
TRANSCRIPT=$(jq_s '.transcript_path')
PCT=$(round_int "$(jq_n '.context_window.used_percentage')")
CTX_SIZE=$(jq_n '.context_window.context_window_size')
CTX_IN=$(jq_n '.context_window.total_input_tokens')
CTX_OUT=$(jq_n '.context_window.total_output_tokens')
DUR_MS=$(jq_n '.cost.total_duration_ms')
COST_NATIVE=$(jq_n '.cost.total_cost_usd')
RL5_PCT=$(jq_s '.rate_limits.five_hour.used_percentage')
RL5_RESET=$(jq_s '.rate_limits.five_hour.resets_at')
RL7_PCT=$(jq_s '.rate_limits.seven_day.used_percentage')
RL7_RESET=$(jq_s '.rate_limits.seven_day.resets_at')
EFFORT=$(jq_s '.effort.level')
THINKING=$(jq_s '.thinking.enabled')

# ---------- ANSI ----------
RST=$'\033[0m'; DIM=$'\033[2m'; BOLD=$'\033[1m'
CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
RED=$'\033[31m'; MAG=$'\033[35m'; BLUE=$'\033[34m'
# Dim background colors for the progress-bar "track" so partial-fill cells
# don't leak terminal-black through the unfilled half-cell. 256-color codes:
# 22=dark green, 58=olive, 52=maroon. Reset to default BG with \033[49m.
BG_GREEN=$'\033[48;5;22m'; BG_YELLOW=$'\033[48;5;58m'; BG_RED=$'\033[48;5;52m'
BG_RST=$'\033[49m'

BASE_URL="${ANTHROPIC_BASE_URL:-}"
IS_DEEPSEEK=0
[[ "$BASE_URL" == *deepseek.com* ]] && IS_DEEPSEEK=1

# ---------- DeepSeek pricing (USD per 1M tokens) ----------
# Source: https://api-docs.deepseek.com/quick_start/pricing
# v4-pro is in a 75%-off promo until 2026-05-31; full list price afterward.
ds_price_for() {
  # Args: model name. Sets DS_PRICE_INPUT_MISS / _HIT / _OUTPUT and DS_MODEL_LABEL.
  local m=$1
  case "$m" in
    deepseek-v4-pro)
      DS_PRICE_INPUT_MISS=0.435; DS_PRICE_INPUT_HIT=0.003625; DS_PRICE_OUTPUT=0.87
      DS_MODEL_LABEL="v4-pro" ;;
    deepseek-v4-flash|deepseek-chat|deepseek-reasoner|"")
      DS_PRICE_INPUT_MISS=0.14;  DS_PRICE_INPUT_HIT=0.0028;   DS_PRICE_OUTPUT=0.28
      DS_MODEL_LABEL="v4-flash" ;;
    *)
      # Unknown model — use v4-flash as conservative default and label as ?
      DS_PRICE_INPUT_MISS=0.14;  DS_PRICE_INPUT_HIT=0.0028;   DS_PRICE_OUTPUT=0.28
      DS_MODEL_LABEL="${m}?" ;;
  esac
}

# Default to v4-flash; auto-detection happens later (after MODEL_ID is parsed).
ds_price_for ""

# Map a Claude model id (e.g. claude-opus-4-7) to the DeepSeek model that
# cc-switch routes to via ANTHROPIC_DEFAULT_*_MODEL env vars.
ds_resolve_model() {
  local mid=$1
  case "$mid" in
    *opus*)   printf '%s' "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}" ;;
    *sonnet*) printf '%s' "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" ;;
    *haiku*)  printf '%s' "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}" ;;
    deepseek-*) printf '%s' "$mid" ;;
    *) ;;
  esac
}

if [ "$IS_DEEPSEEK" = "1" ]; then
  RESOLVED=$(ds_resolve_model "$MODEL_ID")
  [ -n "$RESOLVED" ] && ds_price_for "$RESOLVED"
fi

# User env file always wins.
[ -f "$HOME/.claude/statusline-deepseek.env" ] && . "$HOME/.claude/statusline-deepseek.env"

CDIR="${TMPDIR:-/tmp}"
SID="${SESSION_ID:-_}"
BAL_CACHE="${CDIR}/dsbal-${SID}.json"
BASE_FILE="${CDIR}/dsbase-${SID}.txt"
TX_CACHE="${CDIR}/dstx-${SID}.json"
BAL_TTL=60
TX_TTL=3

cache_age() {
  [ -f "$1" ] || { echo 99999; return; }
  local m; m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)
  echo $(( $(date +%s) - m ))
}

# ---------- DeepSeek balance fetch (60s cache) ----------
fetch_balance() {
  local key="${ANTHROPIC_AUTH_TOKEN:-${DEEPSEEK_API_KEY:-}}"
  [ -z "$key" ] && return
  if [ -f "$BAL_CACHE" ] && [ "$(cache_age "$BAL_CACHE")" -lt "$BAL_TTL" ]; then
    cat "$BAL_CACHE"; return
  fi
  local resp
  resp=$(curl -fsS --max-time 2 \
    -H "Authorization: Bearer $key" -H "Accept: application/json" \
    "https://api.deepseek.com/user/balance" 2>/dev/null)
  if [ -n "$resp" ] && printf '%s' "$resp" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$resp" > "$BAL_CACHE"
    printf '%s' "$resp"
  elif [ -f "$BAL_CACHE" ]; then
    cat "$BAL_CACHE"
  fi
}

# ---------- Single transcript scan (cached 3s) ----------
# Output JSON: {tokens, pending_tools, last_tool, todos}
parse_transcript() {
  if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    echo '{"tokens":{"in":0,"out":0,"cr":0,"cc":0},"pending":[],"last_tool":null,"todos":{"total":0,"completed":0,"in_progress":0,"active":null}}'
    return
  fi
  if [ -f "$TX_CACHE" ] && [ "$(cache_age "$TX_CACHE")" -lt "$TX_TTL" ]; then
    cat "$TX_CACHE"; return
  fi
  jq -s '
    def is_assistant: .type=="assistant";
    def is_user:      .type=="user";
    def tool_uses:    [.[] | select(is_assistant) | .message.content[]? | select(.type=="tool_use")];
    def tool_results: [.[] | select(is_user)      | .message.content[]? | select(.type=="tool_result")];

    . as $E |
    (tool_uses) as $U |
    (tool_results) as $R |
    ($R | map(.tool_use_id)) as $done |
    ($U | map(select(.id as $i | $done | index($i) | not))) as $pending |

    # Token sums across whole transcript (real cumulative session cost)
    ([.[] | select(is_assistant) | .message.usage // empty]) as $usage |

    # TaskCreate map: tool_use_id -> subject (from outer toolUseResult)
    ([$E[] | select(is_user)
      | (.toolUseResult? | objects | .task? // empty) as $t
      | select($t)
      | {id: ($t.id|tostring), subject: $t.subject}
    ]) as $created |
    # TaskUpdate calls
    ([$U[] | select(.name=="TaskUpdate") | .input]) as $updates |

    # Build initial state from creates
    (reduce $created[] as $c ({}; .[$c.id] = {subject: $c.subject, status: "pending"})) as $init |
    (reduce $updates[] as $u ($init;
       ($u.taskId|tostring) as $k |
       if .[$k] then
         .[$k].status = ($u.status // .[$k].status)
       else . end
    )) as $tasks_new |

    # Legacy TodoWrite snapshot fallback (older sessions)
    ([$U[] | select(.name=="TodoWrite") | .input.todos] | last) as $todos_legacy |

    (if $todos_legacy then
        {
          total: ($todos_legacy | map(select(.status != "deleted")) | length),
          completed: ($todos_legacy | map(select(.status == "completed")) | length),
          in_progress: ($todos_legacy | map(select(.status == "in_progress")) | length),
          active: ($todos_legacy | map(select(.status == "in_progress")) | first | .activeForm // .content // null)
        }
     else
        ($tasks_new | [to_entries[] | .value]) as $tlist |
        {
          total:       ($tlist | map(select(.status != "deleted")) | length),
          completed:   ($tlist | map(select(.status == "completed")) | length),
          in_progress: ($tlist | map(select(.status == "in_progress")) | length),
          active:      ($tlist | map(select(.status == "in_progress")) | first | .subject // null)
        }
     end) as $todos |

    {
      tokens: {
        in: ([$usage[].input_tokens // 0]              | add // 0),
        out: ([$usage[].output_tokens // 0]            | add // 0),
        cr: ([$usage[].cache_read_input_tokens // 0]   | add // 0),
        cc: ([$usage[].cache_creation_input_tokens // 0] | add // 0)
      },
      pending: ($pending | map({name, sub: (.input.subagent_type // null)})),
      last_tool: ($U | last | .name // null),
      todos: $todos
    }
  ' "$TRANSCRIPT" 2>/dev/null > "$TX_CACHE.tmp" \
    && mv "$TX_CACHE.tmp" "$TX_CACHE"
  cat "$TX_CACHE"
}

# ---------- Git ----------
git_info() {
  cd "$CWD" 2>/dev/null || return
  git rev-parse --git-dir >/dev/null 2>&1 || return
  local b s m out
  b=$(git branch --show-current 2>/dev/null)
  [ -z "$b" ] && b=$(git rev-parse --short HEAD 2>/dev/null)
  s=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
  m=$(git diff --numstat 2>/dev/null | wc -l | tr -d ' ')
  out="🌿 ${b}"
  [ "${s:-0}" -gt 0 ] 2>/dev/null && out="${out} ${GREEN}+${s}${RST}"
  [ "${m:-0}" -gt 0 ] 2>/dev/null && out="${out} ${YELLOW}~${m}${RST}"
  printf '%s' "$out"
}

# ---------- Helpers ----------
# Sub-character resolution bar: 10 cells × 8 eighths = 80 steps,
# so any pct >= 1.25 shows at least one visible eighth (▏).
build_bar() {
  local p=$1 width=10 eighths full part empty bar c
  [ "$p" -gt 100 ] && p=100
  eighths=$(( p * width * 8 / 100 ))
  # Any non-zero pct shows at least the thinnest mark (▏)
  [ "$eighths" -lt 1 ] && [ "$p" -gt 0 ] && eighths=1
  full=$(( eighths / 8 ))
  part=$(( eighths % 8 ))
  empty=$(( width - full - (part > 0 ? 1 : 0) ))
  local sub=( "" "▏" "▎" "▍" "▌" "▋" "▊" "▉" )
  bar=""
  [ "$full"  -gt 0 ] && printf -v F "%${full}s"  && bar="${F// /█}"
  [ "$part"  -gt 0 ] && bar="${bar}${sub[$part]}"
  # Empty cells are spaces so the dim BG renders without any FG glyph.
  [ "$empty" -gt 0 ] && printf -v E "%${empty}s" && bar="${bar}${E}"
  local bg
  if   [ "$p" -ge 90 ]; then c="$RED";    bg="$BG_RED"
  elif [ "$p" -ge 70 ]; then c="$YELLOW"; bg="$BG_YELLOW"
  else                       c="$GREEN";  bg="$BG_GREEN"
  fi
  # FG paints filled glyphs; BG fills the entire 10-cell track including
  # the right-half of partial cells and the all-empty trailing cells.
  printf '%s%s%s%s%s' "$bg" "$c" "$bar" "$BG_RST" "$RST"
}

# format token count: 12345 -> 12.3k, 1234567 -> 1.23M
fmt_tokens() {
  awk -v n="$1" 'BEGIN {
    if (n>=1000000) printf "%.2fM", n/1000000;
    else if (n>=1000) printf "%.1fk", n/1000;
    else printf "%d", n;
  }'
}

# Truncate string to N display chars (best-effort, byte-based)
trunc() {
  local s="$1" n="$2"
  if [ "${#s}" -gt "$n" ]; then printf '%s…' "${s:0:$((n-1))}"
  else printf '%s' "$s"; fi
}

rl_color() {
  local p=$1
  if   [ "$p" -ge 90 ]; then printf '%s' "$RED"
  elif [ "$p" -ge 70 ]; then printf '%s' "$YELLOW"
  else                       printf '%s' "$GREEN"; fi
}

# Unix epoch seconds remaining → "5d2h" / "2h13m" / "47m" / "<1m"
fmt_until() {
  local target=$1 now diff d h m
  [ -z "$target" ] || [ "$target" = "0" ] && return
  now=$(date +%s); diff=$(( target - now ))
  [ "$diff" -le 0 ] && { printf '0m'; return; }
  d=$(( diff / 86400 )); h=$(( (diff % 86400) / 3600 )); m=$(( (diff % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm' "$m"
  else printf '<1m'; fi
}

# ---------- Compose ----------
TX=$(parse_transcript)
# Extract everything we need from the cached TX json in ONE jq call.
# Fields are tab-separated; "-" sentinel = empty (so `read` won't drop trailing empties).
{
  IFS=$'\t' read -r IN_T OUT_T CR_T CC_T \
                   TODO_TOTAL TODO_DONE TODO_INPR TODO_ACTIVE \
                   LAST_TOOL ANY_PENDING PENDING_TOOL_NAME \
                   PENDING_AGENTS PENDING_AGENTS_LIST <<EOF
$(printf '%s' "$TX" | jq -r '[
    .tokens.in // 0, .tokens.out // 0, .tokens.cr // 0, .tokens.cc // 0,
    .todos.total // 0, .todos.completed // 0, .todos.in_progress // 0,
    (.todos.active // "-"),
    (.last_tool // "-"),
    (.pending | length),
    (.pending | last | .name // "-"),
    ([.pending[] | select(.name=="Agent")] | length),
    (([.pending[] | select(.name=="Agent") | .sub // "agent"] | join(", ")) | if . == "" then "-" else . end)
  ] | @tsv' 2>/dev/null)
EOF
}
# unsentinelize
[ "$TODO_ACTIVE" = "-" ] && TODO_ACTIVE=""
[ "$LAST_TOOL" = "-" ] && LAST_TOOL=""
[ "$PENDING_TOOL_NAME" = "-" ] && PENDING_TOOL_NAME=""
[ "$PENDING_AGENTS_LIST" = "-" ] && PENDING_AGENTS_LIST=""

DIR_BASE="${CWD##*/}"; [ -z "$DIR_BASE" ] && DIR_BASE="/"
GIT=$(git_info)
BAR=$(build_bar "$PCT")
MIN=$(( DUR_MS / 60000 ))
SEC=$(( (DUR_MS % 60000) / 1000 ))

# ===== Line 1: identity =====
L1="${CYAN}[${MODEL_NAME}]${RST}"
# Effort + thinking indicator: "🧠 xhigh 💭" — only when fields exist
if [ -n "$EFFORT" ]; then L1="${L1} ${DIM}🧠 ${EFFORT}${RST}"; fi
if [ "$THINKING" = "true" ]; then L1="${L1} ${DIM}💭${RST}"; fi
L1="${L1}  ${BOLD}📁 ${DIR_BASE}${RST}"
[ -n "$GIT" ] && L1="${L1}  ${GIT}"

# ===== Line 2: context + rate limits + cost + duration =====
L2="${BAR} ${PCT}%"

# Context token count: (85k/200k)
if [ "${CTX_SIZE:-0}" -gt 0 ] && [ "${CTX_IN:-0}" -gt 0 ]; then
  USED=$(fmt_tokens "$(( CTX_IN + CTX_OUT ))")
  TOTAL=$(fmt_tokens "$CTX_SIZE")
  L2="${L2} ${DIM}(${USED}/${TOTAL})${RST}"
fi

# Rate limit bars inline (real Anthropic Pro/Max only)
build_rl_segment() {
  local label=$1 raw=$2 reset=$3 p bar rt
  [ -z "$raw" ] && return
  p=$(round_int "$raw")
  bar=$(build_bar "$p")
  rt=$(fmt_until "$reset")
  local seg="${DIM}${label}${RST} ${bar} ${p}%"
  [ -n "$rt" ] && seg="${seg} ${DIM}↻${rt}${RST}"
  printf '%s' "$seg"
}
SEG5=$(build_rl_segment "5h" "$RL5_PCT" "$RL5_RESET")
SEG7=$(build_rl_segment "7d" "$RL7_PCT" "$RL7_RESET")
[ -n "$SEG5" ] && L2="${L2}  ${SEG5}"
[ -n "$SEG7" ] && L2="${L2}  ${SEG7}"

# Cost block
if [ "$IS_DEEPSEEK" = "1" ]; then
  EST=$(awk -v in_t="$IN_T" -v out_t="$OUT_T" -v cr_t="$CR_T" -v cc_t="$CC_T" \
            -v p_in="$DS_PRICE_INPUT_MISS" -v p_hit="$DS_PRICE_INPUT_HIT" -v p_out="$DS_PRICE_OUTPUT" \
            'BEGIN {
              cost = (in_t * p_in + cc_t * p_in + cr_t * p_hit + out_t * p_out) / 1000000
              printf "%.4f", cost
            }')
  L2="${L2}  ${MAG}≈\$${EST}${RST} ${DIM}${DS_MODEL_LABEL}${RST}"

  BAL_RESP=$(fetch_balance)
  if [ -n "$BAL_RESP" ]; then
    BAL_TOTAL=$(printf '%s' "$BAL_RESP" | jq -r '.balance_infos[0].total_balance // empty' 2>/dev/null)
    BAL_CCY=$(printf   '%s' "$BAL_RESP" | jq -r '.balance_infos[0].currency // empty'      2>/dev/null)
    if [ -n "$BAL_TOTAL" ]; then
      [ ! -f "$BASE_FILE" ] && printf '%s' "$BAL_TOTAL" > "$BASE_FILE"
      BASE=$(cat "$BASE_FILE" 2>/dev/null)
      if [ -n "$BASE" ]; then
        DELTA=$(awk -v a="$BASE" -v b="$BAL_TOTAL" \
                'BEGIN { d=a-b; if (d<0) d=0; if (d>=0.01) printf "▼%.2f", d; else printf "▼%.4f", d }')
      fi
      L2="${L2}  ${BLUE}💳 ${BAL_TOTAL} ${BAL_CCY}${RST}"
      [ -n "${DELTA:-}" ] && L2="${L2} ${DIM}(${DELTA})${RST}"
    fi
  else
    L2="${L2}  ${DIM}💳 —${RST}"
  fi
else
  COST_FMT=$(awk -v c="$COST_NATIVE" 'BEGIN { printf "%.2f", c }')
  L2="${L2}  ${YELLOW}\$${COST_FMT}${RST}"
fi

L2="${L2}  ${DIM}⏱ ${MIN}m${SEC}s${RST}"

# ===== Line 3: activity (todos + agents + last tool) — only if anything =====
L3=""
if [ "${TODO_TOTAL:-0}" -gt 0 ]; then
  TD="${GREEN}✓${TODO_DONE}${RST}/${TODO_TOTAL}"
  [ "${TODO_INPR:-0}" -gt 0 ] && TD="${TD} ${YELLOW}⏳${TODO_INPR}${RST}"
  if [ -n "$TODO_ACTIVE" ]; then
    ACTIVE_TRUNC=$(trunc "$TODO_ACTIVE" 30)
    TD="${TD} ${DIM}${ACTIVE_TRUNC}${RST}"
  fi
  L3="$TD"
fi
if [ "${PENDING_AGENTS:-0}" -gt 0 ]; then
  if [ "$PENDING_AGENTS" -eq 1 ]; then
    AG="${MAG}🤖 ${PENDING_AGENTS_LIST}${RST}"
  else
    AG="${MAG}🤖 ${PENDING_AGENTS} agents: $(trunc "$PENDING_AGENTS_LIST" 35)${RST}"
  fi
  [ -n "$L3" ] && L3="${L3}  ${DIM}|${RST}  ${AG}" || L3="$AG"
fi
if [ "${ANY_PENDING:-0}" -gt 0 ] && [ -n "$PENDING_TOOL_NAME" ] && [ "$PENDING_TOOL_NAME" != "Agent" ]; then
  TL="${DIM}⚒ ${PENDING_TOOL_NAME}${RST}"
  [ -n "$L3" ] && L3="${L3}  ${DIM}|${RST}  ${TL}" || L3="$TL"
elif [ -z "$L3" ] && [ -n "$LAST_TOOL" ]; then
  L3="${DIM}⚒ ${LAST_TOOL}${RST}"
fi

printf '%s\n%s\n' "$L1" "$L2"
if [ -n "$L3" ]; then printf '%s\n' "$L3"; fi
exit 0
