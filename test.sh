#!/usr/bin/env bash
# Test suite for scripts/statusline.sh — synthetic transcripts, no live session needed.
set -u

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/scripts/statusline.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HEADROOM_STATE_DIR="$TMP/state"
# The Windows fixtures below fake the OS (DOCTOR_OS=windows) while their fake
# engine stays a POSIX `#!` script, because the host actually running this
# suite has to be able to execute it. On a genuine Windows host is_windows() is
# really true, so doctor's PE guard rightly refuses those fixtures — which is
# why the windows CI job used to drown in failures that no product bug caused.
# Declaring the simulation here makes the suite behave identically on both
# hosts; the one fixture that tests the PE refusal unsets it explicitly.
export DOCTOR_FAKE_PE=1
# The Windows bash-preference fixtures put a FAKE `bash` first on PATH so the
# doctor's own `command -v bash` finds it. That must not also hijack the bash
# used to RUN the doctor, so resolve a real one now, before any such games.
BASHBIN=$(command -v bash)

# `ln -s` is NOT dependable under MSYS: Git for Windows creates a .lnk or a
# plain text link file (depending on the winsymlinks setting) instead of a real
# symlink, so a "linked" binary ends up EXISTING — doctor's `jq found` check
# passed — while being unrunnable. Every jq call in every doctor fixture then
# failed silently and every JSON check reported invalid: 60 doctor runs on the
# windows job produced ZERO successful JSON parses, which is most of that job's
# failures. Fall back to a copy whenever the link does not come out runnable.
link_tool() {  # link_tool <real binary> <dest> — make <dest> run <real binary>
  # `ln -s` is NOT dependable under MSYS: Git for Windows writes a .lnk or a
  # plain text link file instead of a real symlink, so the result EXISTS (and
  # doctor's `jq found` check passes) while refusing to execute. A COPY is no
  # better: /usr/bin/jq.exe is an MSYS binary that loads msys-2.0.dll from its
  # OWN directory, so a copy parked in a stub dir cannot start either. Both
  # failure modes are silent — every jq call returns nonzero, so every JSON
  # check in every doctor fixture reported invalid. Fall back to an exec
  # wrapper, which leaves the real binary where its DLLs are.
  # An absent source is the quiet killer: `link_tool "$(command -v foo)" ...`
  # with foo missing from the host writes `exec "" "$@"`, which EXISTS and fails
  # every call -- the same invalid-everything outcome the wrapper exists to
  # prevent, across all 8 call sites at once. Refuse loudly instead.
  if [ -z "${1:-}" ] || [ ! -x "$1" ]; then
    echo "FAIL - link_tool: no runnable source for $(basename "${2:-?}") (got '${1:-}')"
    FAIL=$((FAIL+1)); return 1
  fi
  rm -f "$2" 2>/dev/null
  ln -sf "$1" "$2" 2>/dev/null || true
  if ! "$2" --version >/dev/null 2>&1; then
    rm -f "$2" 2>/dev/null
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$1" > "$2" && chmod +x "$2"
  fi
  # ...and verify what we just staged actually RUNS. 126/127 are the only codes
  # that mean "cannot execute"/"not found"; a tool with no --version answers 1
  # or 2, so this cannot false-alarm on the coreutils that lack the flag.
  "$2" --version >/dev/null 2>&1
  case $? in
    126|127) echo "FAIL - link_tool: staged $2 does not run (exit $?)"; FAIL=$((FAIL+1)); return 1 ;;
  esac
  return 0
}

PASS=0; FAIL=0; SKIP=0

check() {  # check <name> <expected-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "ok - $1"; PASS=$((PASS+1))
  else
    echo "FAIL - $1"
    echo "    expected substring: $2"
    echo "    got: $3"
    FAIL=$((FAIL+1))
  fi
}

check_absent() {  # check_absent <name> <forbidden-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "FAIL - $1"
    echo "    forbidden substring present: $2"
    echo "    got: $3"
    FAIL=$((FAIL+1))
  else
    echo "ok - $1"; PASS=$((PASS+1))
  fi
}

real_python() {  # a real SYSTEM interpreter — not a suite stub, not the engine venv
  # The two callers build a FAKE headroom package and inject it on PYTHONPATH, so
  # they need an interpreter that runs but does NOT already import headroom.
  # That is what the old `PATH=/usr/bin:/bin:/usr/local/bin command -v python3`
  # was really protecting, and it bought that protection with a pinned PATH that
  # no Windows interpreter can ever satisfy: Git Bash on windows-latest has
  # `python` but no `python3`, so both blocks fell to the literal
  # /usr/bin/python3, failed `[ -x ]`, and skipped SILENTLY on every Windows run.
  # One of them is w12 -- the POSIX regression guard for the no-fcntl stats
  # write -- so that behaviour's coverage was absent on Windows by this route and
  # wrong by the other (windows-check looked for the stub's filename). Assert the
  # two properties directly instead of approximating them with a path pin, and
  # take doctor.sh's interpreter order while we are here.
  local c q
  for c in python3 python; do
    q=$(command -v "$c" 2>/dev/null) || continue
    [ -n "$q" ] && [ -x "$q" ] || continue
    case $q in "${TMP:-/nonexistent}"/*|"${W:-/nonexistent}"/*) continue ;; esac  # a fixture stub
    "$q" -c 'import sys' >/dev/null 2>&1 || continue          # Windows Store alias only nags
    "$q" -c 'import headroom' >/dev/null 2>&1 && continue     # an engine python would shadow the fake
    printf '%s\n' "$q"; return 0
  done
  return 1
}
skip_note() {  # skip_note <reason> — a COUNTED skip
  # An uncounted bare `echo` of a skip is invisible to the Windows gate, which
  # builds its whole view of reality from FAIL lines: a fixture that stops
  # running emits neither "ok -" nor "FAIL -", so it reads as fixed (if it was
  # on the known-failure list) or vanishes silently (if it was not).
  printf 'skip - %s\n' "$1"; SKIP=$((SKIP+1))
}
check_eq() {  # check_eq <name> <expected> <actual> — exact match (exit codes, counts)
  if [ "$2" = "$3" ]; then
    echo "ok - $1"; PASS=$((PASS+1))
  else
    echo "FAIL - $1"
    echo "    expected exactly: $2"
    echo "    got: $3"
    FAIL=$((FAIL+1))
  fi
}

badge() {  # badge <transcript> <model-id> <session-id> — run the script as Claude Code would
  printf '{"transcript_path":"%s","model":{"id":"%s"},"session_id":"%s"}' "$1" "$2" "$3" \
    | bash "$SCRIPT"
}

badge_at() {  # badge_at <script-path> <transcript> <model-id> <session-id> — render a specific
  # installed copy (its SELF_DIR is its own dir), so dep resolution (lib/ vs flat) is exercised
  printf '{"transcript_path":"%s","model":{"id":"%s"},"session_id":"%s"}' "$2" "$3" "$4" \
    | HEADROOM_STATE_DIR="${5:-$TMP/state-badge-at}" bash "$1"
}

mkuniform() {  # mkuniform <path> [rows] — a uniform JSON array (gate-eligible by size)
  jq -n --argjson n "${2:-900}" '[range(0; $n) | {id:., v:"xxxxxxxxxxxxxxxx"}]' > "$1"
}

NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

compress_event() {  # compress_event <tool-use-id> <tokens-saved> — one compress + linked result
  printf '%s\n%s\n' \
    "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"mcp__headroom__headroom_compress\"}]}}" \
    "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"content\":[{\"type\":\"text\",\"text\":\"{\\\"tokens_saved\\\": $2}\"}]}]}}"
}

# --- 1. compress + linked result → green active badge with tokens and count
compress_event t1 500 > "$TMP/t_active.jsonl"
out=$(badge "$TMP/t_active.jsonl" claude-opus-4-8 sess-active)
check "active: green dot"  "●"        "$out"
check "active: tokens"     "~500 tok" "$out"
check "active: count"      "1×"       "$out"

# --- 2. stats-only transcript → red idle (no false positive)
printf '%s\n' '{"message":{"content":[{"type":"tool_use","id":"s1","name":"mcp__headroom__headroom_stats"}]}}' > "$TMP/t_stats.jsonl"
out=$(badge "$TMP/t_stats.jsonl" claude-opus-4-8 sess-stats)
check "stats-only: idle"   "not compressing yet" "$out"

# --- 3. money: 500 tok on opus-4-8 = $0.0025 → shown as cents
out=$(badge "$TMP/t_active.jsonl" claude-opus-4-8 sess-money)
check "money: cents"        "0.25¢"      "$out"

# 10,000 tok on fable-5 = $0.10 → dollars + k-abbreviated tokens
compress_event big 10000 > "$TMP/t_big.jsonl"
out=$(badge "$TMP/t_big.jsonl" claude-fable-5 sess-big)
check "money: dollars"      "\$0.10"     "$out"
check "tokens: k-abbrev"    "~10.0k tok" "$out"

# --- 4. unknown model → tokens-only, never a wrong dollar figure
# Fresh state dir: once lifetime totals exist (Task 4), earlier sessions' "$X all-time"
# segment would otherwise leak into this badge and false-fail the absence checks.
export HEADROOM_STATE_DIR="$TMP/state-2"
out=$(badge "$TMP/t_active.jsonl" some-future-model sess-unknown)
check "unknown model: tokens"      "~500 tok" "$out"
check_absent "unknown model: no ¢" "¢"        "$out"
check_absent "unknown model: no \$" "\$"      "$out"

# --- 5. cache: same-size transcript rewrite is served from cache (proves no re-parse)
compress_event c1 500 > "$TMP/t_cache.jsonl"
out=$(badge "$TMP/t_cache.jsonl" claude-opus-4-8 sess-cache)
check "cache: first render"  "~500 tok" "$out"
# mangle the tool name in place, keeping byte length identical — a re-parse would find 0 events
sed 's/headroom_compress/headroom_compresX/' "$TMP/t_cache.jsonl" > "$TMP/t_cache.mangled" \
  && mv "$TMP/t_cache.mangled" "$TMP/t_cache.jsonl"
out=$(badge "$TMP/t_cache.jsonl" claude-opus-4-8 sess-cache)
check "cache: same-size rewrite still served from cache" "~500 tok" "$out"

# --- 6. cache invalidation: transcript growth triggers re-parse
compress_event g1 500 > "$TMP/t_grow.jsonl"
out=$(badge "$TMP/t_grow.jsonl" claude-opus-4-8 sess-grow)
check "growth: first render" "1×" "$out"
compress_event g2 250 >> "$TMP/t_grow.jsonl"
out=$(badge "$TMP/t_grow.jsonl" claude-opus-4-8 sess-grow)
check "growth: recount"      "2×"       "$out"
check "growth: retotal"      "~750 tok" "$out"

# --- 7. lifetime totals across sessions
rm -rf "$HEADROOM_STATE_DIR"   # reset state accumulated by earlier tests
compress_event a1 500 > "$TMP/t_life_a.jsonl"
compress_event b1 500 > "$TMP/t_life_b.jsonl"
out=$(badge "$TMP/t_life_a.jsonl" claude-opus-4-8 sess-life-a)
check_absent "lifetime: hidden on first-ever session" "all-time" "$out"
out=$(badge "$TMP/t_life_b.jsonl" claude-opus-4-8 sess-life-b)
check "lifetime: shown from 2nd session" "all-time"       "$out"
check "lifetime: summed usd"             "0.50¢ all-time" "$out"

# --- 8. decay badge: a compress event with an old timestamp renders dim idle, never green/red
rm -rf "$HEADROOM_STATE_DIR"
printf '%s\n%s\n' \
  '{"timestamp":"2020-01-01T00:00:00.000Z","message":{"content":[{"type":"tool_use","id":"d1","name":"mcp__headroom__headroom_compress"}]}}' \
  '{"message":{"content":[{"type":"tool_result","tool_use_id":"d1","content":[{"type":"text","text":"{\"tokens_saved\": 500}"}]}]}}' \
  > "$TMP/t_decay.jsonl"
out=$(badge "$TMP/t_decay.jsonl" claude-opus-4-8 sess-decay)
check "decay: dim idle badge"  "○ headroom idle · ~500 tok"  "$out"
check_absent "decay: not active" "●"                          "$out"

# --- 9. fix 1: sessions that saved nothing must not get a totals file
rm -rf "$HEADROOM_STATE_DIR"
printf '%s\n' '{"message":{"content":[{"type":"tool_use","id":"s1","name":"mcp__headroom__headroom_stats"}]}}' > "$TMP/t_zero.jsonl"
badge "$TMP/t_zero.jsonl" claude-opus-4-8 sess-zero > /dev/null
if [ -e "$HEADROOM_STATE_DIR/session-sess-zero.totals" ]; then
  echo "FAIL - fix1: no totals file for zero-saved session"
  echo "    found: $HEADROOM_STATE_DIR/session-sess-zero.totals"
  FAIL=$((FAIL+1))
else
  echo "ok - fix1: no totals file for zero-saved session"; PASS=$((PASS+1))
fi

# --- 10. fix 2: a model switch mid-session must never shrink the session's recorded usd
rm -rf "$HEADROOM_STATE_DIR"
compress_event sw1 500 > "$TMP/t_switch.jsonl"
badge "$TMP/t_switch.jsonl" claude-opus-4-8 sess-switch > /dev/null
check "fix2: initial totals usd" "0.002500" "$(cat "$HEADROOM_STATE_DIR/session-sess-switch.totals")"
compress_event sw2 100 >> "$TMP/t_switch.jsonl"
badge "$TMP/t_switch.jsonl" claude-haiku-4-5 sess-switch > /dev/null
check "fix2: totals usd never shrinks on model switch" "0.002500" "$(cat "$HEADROOM_STATE_DIR/session-sess-switch.totals")"

# --- 11-15. missed-opportunity nudge
export HEADROOM_STATE_DIR="$TMP/state-nudge"
OLD_TS="2020-01-01T00:00:00.000Z"

old_compress_event() {  # old_compress_event <id> <tokens> — compress stamped in the past (grey badge)
  printf '%s\n%s\n' \
    "{\"timestamp\":\"$OLD_TS\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"mcp__headroom__headroom_compress\"}]}}" \
    "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"content\":[{\"type\":\"text\",\"text\":\"{\\\"tokens_saved\\\": $2}\"}]}]}}"
}

big_result_event() {  # big_result_event <tool-use-id> <tool-name> <byte-count> — a large non-compress tool result
  pad=$(printf 'x%.0s' $(seq 1 "$3"))
  printf '%s\n%s\n' \
    "{\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"$2\"}]}}" \
    "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"content\":[{\"type\":\"text\",\"text\":\"$pad\"}]}]}}"
}

# 11. big blobs with no compress → red nudge, singular/plural
big_result_event b1 Bash 4096 > "$TMP/t_nudge1.jsonl"
out=$(badge "$TMP/t_nudge1.jsonl" claude-opus-4-8 sess-n1)
check "nudge: singular" "1 big blob uncompressed" "$out"
{ big_result_event b1 Bash 4096; big_result_event b2 Read 4096; } > "$TMP/t_nudge2.jsonl"
out=$(badge "$TMP/t_nudge2.jsonl" claude-opus-4-8 sess-n2)
check "nudge: plural" "2 big blobs uncompressed" "$out"

# 12. just under the threshold → no nudge
big_result_event u1 Bash 4095 > "$TMP/t_under.jsonl"
out=$(badge "$TMP/t_under.jsonl" claude-opus-4-8 sess-n3)
check "nudge: under threshold" "not compressing yet" "$out"

# 13. headroom's own oversized results are excluded
big_result_event r1 mcp__headroom__headroom_retrieve 5000 > "$TMP/t_retr.jsonl"
out=$(badge "$TMP/t_retr.jsonl" claude-opus-4-8 sess-n4)
check "nudge: headroom results excluded" "not compressing yet" "$out"

# 14. forgiveness: each compression forgives one big blob
{ old_compress_event c1 500; big_result_event b1 Bash 4096; big_result_event b2 Bash 4096; } > "$TMP/t_forgive.jsonl"
out=$(badge "$TMP/t_forgive.jsonl" claude-opus-4-8 sess-n5)
check "forgive: grey shows missed"      "· 1 missed"                "$out"
check "forgive: grey idle with totals"  "○ headroom idle · ~500 tok" "$out"
{ old_compress_event c1 500; big_result_event b1 Bash 4096; } > "$TMP/t_even.jsonl"
out=$(badge "$TMP/t_even.jsonl" claude-opus-4-8 sess-n6)
check_absent "forgive: even count hides missed" " missed" "$out"

# 15. v2.0 4-field cache line forces recompute and upgrades to 5 fields
big_result_event b1 Bash 4096 > "$TMP/t_upg.jsonl"
sz=$(stat -c%s "$TMP/t_upg.jsonl" 2>/dev/null || stat -f%z "$TMP/t_upg.jsonl")
mkdir -p "$HEADROOM_STATE_DIR"
printf '%s|9|9999|2020-01-01T00:00:00.000Z\n' "$sz" > "$HEADROOM_STATE_DIR/session-sess-n7.cache"
out=$(badge "$TMP/t_upg.jsonl" claude-opus-4-8 sess-n7)
check "cache upgrade: stale 4-field line recomputed" "1 big blob uncompressed" "$out"
fields=$(awk -F'|' '{print NF; exit}' "$HEADROOM_STATE_DIR/session-sess-n7.cache")
check_eq "cache upgrade: rewritten with 5 fields" "5" "$fields"

# 16. string-form tool_result content is measured too (the dominant shape in real transcripts)
strpad=$(printf 'x%.0s' $(seq 1 4096))
printf '%s\n%s\n' \
  '{"message":{"content":[{"type":"tool_use","id":"s1","name":"Bash"}]}}' \
  "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"s1\",\"content\":\"$strpad\"}]}}" > "$TMP/t_str.jsonl"
out=$(badge "$TMP/t_str.jsonl" claude-opus-4-8 sess-n8)
check "nudge: string-form content" "1 big blob uncompressed" "$out"

# --- 17-19. dangi hook (real-time detector)
DANGI="$ROOT/scripts/dangi-hook.sh"
export HEADROOM_STATE_DIR="$TMP/state-dangi"
export DANGI_NO_NOTIFY=1

hook_input() {  # hook_input <tool-name> <char-count> <session-id> — synthetic PostToolUse stdin
  jq -n --arg tool "$1" --arg sid "$3" --argjson n "$2" \
    '{hook_event_name:"PostToolUse", tool_name:$tool, session_id:$sid, tool_response:("x"*$n)}'
}

# 17. big output → one-line additionalContext JSON, exit 0
out=$(hook_input Bash 4096 dangi-s1 | bash "$DANGI"); rc=$?
check "dangi: nudges on big output"   "additionalContext" "$out"
check "dangi: message names itself"   "Dangi"             "$out"
check_eq "dangi: exit code"              "0"                  "$rc"
printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null \
  && check "dangi: valid hook JSON" "ok" "ok" \
  || check "dangi: valid hook JSON" "ok" "INVALID"

# 18. rate limiting — same session silent, other session nudges
out=$(hook_input Bash 8192 dangi-s1 | bash "$DANGI")
check_absent "dangi: cooldown silences same session" "additionalContext" "$out"
out=$(hook_input Bash 8192 dangi-s2 | bash "$DANGI")
check "dangi: cooldown is per-session" "additionalContext" "$out"

# 19. non-events stay silent (and exit 0)
out=$(hook_input Bash 4095 dangi-s3 | bash "$DANGI")
check_absent "dangi: under threshold" "additionalContext" "$out"
out=$(hook_input Edit 9000 dangi-s6 | bash "$DANGI")
check_absent "dangi: Edit excluded (echoes code being edited)" "additionalContext" "$out"
out=$(hook_input Write 9000 dangi-s6 | bash "$DANGI")
check_absent "dangi: Write excluded" "additionalContext" "$out"
out=$(hook_input Bash 9000 dangi-s7 | bash "$DANGI")
check "dangi: nudge points to hcat" "hcat" "$out"
check "dangi: nudge offers subagent fallback" "subagent" "$out"

# image tool_responses are base64 blobs — not text-compressible
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Read", session_id:"dangi-s8",
  tool_response:{type:"image", source:{data:("A"*9000)}}}' | bash "$DANGI")
check_absent "dangi: image response excluded" "additionalContext" "$out"
out=$(hook_input WebFetch 9000 dangi-s9 | bash "$DANGI")
check_absent "dangi: WebFetch excluded" "additionalContext" "$out"

# hcat invocations ARE compressions — their outputs are never nudge targets.
# (Real PostToolUse input carries the command in .tool_input.command; the hook
# attributes receipts structurally, so the fixtures carry it too.)
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"dangi-s13",
  tool_input:{command:"hcat \"/tmp/x.json\""},
  tool_response:("── hcat: /tmp/x.json · 10 lines · 5.0 KB · ~9000 tok → ~3000 tok (66.7% saved)\n" + ("y"*9000))}' | bash "$DANGI")
check_absent "dangi: hcat receipt excluded" "additionalContext" "$out"
# ...even buried mid-text after a persisted-output preview banner (legacy-path form)
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"dangi-s14",
  tool_input:{command:"/Users/abhi/.claude/hcat \"/tmp/x.json\""},
  tool_response:("Output too large. Preview:\n── hcat: /tmp/x.json · ~9000 tok → ~3000 tok (66.7% saved)\n" + ("y"*9000))}' | bash "$DANGI")
check_absent "dangi: buried hcat receipt excluded" "additionalContext" "$out"
# ...and in object-form tool_responses, where tostring JSON-escapes the newlines (chained form)
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"dangi-s15",
  tool_input:{command:"cd /tmp && hcat x.json"},
  tool_response:{stdout:("── hcat: /tmp/x.json · ~9000 tok → ~3000 tok (66.7% saved)\n" + ("y"*9000)), stderr:""}}' | bash "$DANGI")
check_absent "dangi: object-form receipt excluded" "additionalContext" "$out"
# a big blob that merely mentions hcat mid-line is still a missed opportunity
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"dangi-s16",
  tool_response:("run hcat <path> next time maybe " + ("y"*9000))}' | bash "$DANGI")
check "dangi: mid-line hcat mention still nudges" "additionalContext" "$out"

# size must be bytes, not codepoints: 3000 two-byte chars = 6000 bytes ≥ 4096
out=$(jq -n --arg sid dangi-s10 '{hook_event_name:"PostToolUse", tool_name:"Bash",
  session_id:$sid, tool_response:("é"*3000)}' | bash "$DANGI")
check "dangi: multibyte content counted in bytes" "additionalContext" "$out"

# notification branch: a fake osascript on PATH must get invoked
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho "$@" >> "%s/osascript.calls"\n' "$TMP" > "$FAKEBIN/osascript"
chmod +x "$FAKEBIN/osascript"
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"dangi-s11",
  tool_response:("x"*9000)}' | env -u DANGI_NO_NOTIFY PATH="$FAKEBIN:$PATH" bash "$DANGI")
for _ in 1 2 3 4 5 6 7 8 9 10; do   # osascript fires in the background — poll up to 2s
  [ -s "$TMP/osascript.calls" ] && break
  sleep 0.2
done
check "dangi: notification invoked" "display notification" "$(cat "$TMP/osascript.calls" 2>/dev/null)"
check "dangi: notification names the tool" "Bash" "$(cat "$TMP/osascript.calls" 2>/dev/null)"

# a stale lock must never wedge the hook
mkdir -p "$HEADROOM_STATE_DIR/.lock-dangi-s12" 2>/dev/null
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"dangi-s12",
  tool_response:("x"*9000)}' | bash "$DANGI"); rc=$?
check_eq "dangi: stale lock tolerated (exit 0)" "0" "$rc"
check "dangi: stale lock still nudges" "additionalContext" "$out"
out=$(hook_input mcp__headroom__headroom_compress 9000 dangi-s4 | bash "$DANGI")
check_absent "dangi: headroom tools excluded" "additionalContext" "$out"
out=$(printf 'not json at all' | bash "$DANGI"); rc=$?
check_absent "dangi: garbage stdin silent" "additionalContext" "$out"
check_eq "dangi: garbage stdin exit 0" "0" "$rc"

# 20. stderr purity: an unreadable state file must not leak bash diagnostics
hook_input Bash 5000 dangi-s5 | bash "$DANGI" >/dev/null 2>/dev/null   # first call creates the state file
chmod 000 "$HEADROOM_STATE_DIR/session-dangi-s5.dangi"
err=$(hook_input Bash 5000 dangi-s5 | bash "$DANGI" 2>&1 >/dev/null)
chmod 644 "$HEADROOM_STATE_DIR/session-dangi-s5.dangi"
if [ -z "$err" ]; then
  echo "ok - dangi: stderr silent on unreadable state"; PASS=$((PASS+1))
else
  echo "FAIL - dangi: stderr silent on unreadable state"
  echo "    got stderr: $err"
  FAIL=$((FAIL+1))
fi

# --- 21. status-line mascot
export HEADROOM_STATE_DIR="$TMP/state-mascot"
big_result_event m1 Bash 4096 > "$TMP/t_mascot.jsonl"
out=$(badge "$TMP/t_mascot.jsonl" claude-opus-4-8 sess-m1)
check "mascot: awake with count" "🤖 dangi: 1!" "$out"
compress_event m2 500 > "$TMP/t_asleep.jsonl"
out=$(badge "$TMP/t_asleep.jsonl" claude-opus-4-8 sess-m2)
check "mascot: asleep when clear" "😴 dangi" "$out"

# --- 22-25. hcat (compress-at-the-source shim)
HCAT="$ROOT/bin/hcat"
HEADROOM_PY=""
# Ask the PRODUCT's resolver first. This probe used to know only three POSIX
# candidates -- $HCAT_PYTHON, the `python` sibling of `headroom` on PATH, and
# $HOME/.headroom-venv/bin/python -- with no python.exe and no Scripts/ layout.
# On Windows that meant all 7 HEADROOM_PY-gated blocks below fell into their
# "headroom venv not found" skip branch ON THE ONE HOST THAT HAS A REAL ENGINE
# INSTALLED, while the gate still reported "no unlisted Windows failures": the
# Windows job installed an engine and then never exercised it through the suite.
# Sourced in a SUBSHELL on purpose -- the lib defines is_windows/win_path/etc.
# and must not land in this script's namespace next to the test helpers.
# HEADROOM_TEST_VENV lets CI point the probe at the venv it just built without
# setting DOCTOR_VENV_DIR, which individual fixtures own and override per run.
if [ -f "$ROOT/scripts/lib/engine-resolve.sh" ]; then
  HEADROOM_PY=$(DOCTOR_VENV_DIR="${HEADROOM_TEST_VENV:-${DOCTOR_VENV_DIR:-$HOME/.headroom-venv}}" \
    bash -c ". '$ROOT/scripts/lib/engine-resolve.sh'; resolve_engine_python" 2>/dev/null) || HEADROOM_PY=""
  [ -n "$HEADROOM_PY" ] && [ -x "$HEADROOM_PY" ] || HEADROOM_PY=""
fi
# legacy fallback: a partial/flat checkout with no lib beside it
if [ -z "$HEADROOM_PY" ]; then
  for cand in "${HCAT_PYTHON:-}" "$(command -v headroom 2>/dev/null | xargs -I{} dirname {} 2>/dev/null)/python" "$HOME/.headroom-venv/bin/python"; do
    [ -n "$cand" ] && [ -x "$cand" ] && HEADROOM_PY="$cand" && break
  done
fi

# 22. arg validation runs before python resolution — testable everywhere
out=$(bash "$HCAT" 2>&1); rc=$?
check "hcat: no args → usage" "usage" "$out"
check_eq "hcat: no args → exit 2" "2" "$rc"
out=$(bash "$HCAT" "$TMP/does-not-exist.json" 2>&1); rc=$?
check_eq "hcat: missing file → exit 2" "2" "$rc"

# 23. unusable python → distinct exit 3, nothing on stdout
printf '{"k":1}' > "$TMP/hc_small.json"
out=$(HCAT_PYTHON=/nonexistent/python bash "$HCAT" "$TMP/hc_small.json" 2>/dev/null); rc=$?
check_eq "hcat: no headroom → exit 3" "3" "$rc"
check_absent "hcat: no headroom → stdout empty" "{" "$out"

if [ -n "$HEADROOM_PY" ]; then
  # 24. real compression: big structured JSON shrinks, header cites source path
  "$HEADROOM_PY" - "$TMP/hc_big.json" <<'PYEOF'
import json, sys
rows = [{"id": i, "user": f"user_{i%50}", "event": "click", "ts": 1700000000+i, "ok": True} for i in range(500)]
open(sys.argv[1], "w").write(json.dumps(rows, indent=2))
PYEOF
  out=$(HEADROOM_WORKSPACE_DIR="$TMP/hc_ws" bash "$HCAT" "$TMP/hc_big.json"); rc=$?
  check_eq "hcat: exit 0 on success" "0" "$rc"
  check "hcat: header cites source path" "$TMP/hc_big.json" "$out"
  check "hcat: header shows savings" "% saved" "$out"
  raw_bytes=$(wc -c < "$TMP/hc_big.json")
  out_bytes=$(printf '%s' "$out" | wc -c)
  if [ "$out_bytes" -lt $(( raw_bytes / 2 )) ]; then
    echo "ok - hcat: output < half of raw"; PASS=$((PASS+1))
  else
    echo "FAIL - hcat: output < half of raw (raw=$raw_bytes out=$out_bytes)"; FAIL=$((FAIL+1))
  fi
  check "hcat: stats event written" '"strategy":"hcat"' "$(cat "$TMP"/hc_ws/*.jsonl 2>/dev/null)"

  # 25. incompressible content → raw passthrough, no schema noise
  printf 'short prose line\n' > "$TMP/hc_prose.txt"
  out=$(HEADROOM_WORKSPACE_DIR="$TMP/hc_ws" bash "$HCAT" "$TMP/hc_prose.txt")
  check "hcat: passthrough keeps raw" "short prose line" "$out"
else
  skip_note "hcat compression tests (headroom venv not found)"
fi

# --- 26-28. hcat-gate (PreToolUse Read gate)
GATE="$ROOT/scripts/hcat-gate.sh"
export HEADROOM_STATE_DIR="$TMP/state-gate"

gate_input() {  # gate_input <file-path> <session-id> — synthetic PreToolUse stdin
  jq -n --arg fp "$1" --arg sid "$2" \
    '{hook_event_name:"PreToolUse", tool_name:"Read", session_id:$sid, tool_input:{file_path:$fp}}'
}

# 26. small / non-structured / garbage → silent allow, exit 0
out=$(gate_input "$TMP/hc_small.json" gate-s1 | bash "$GATE"); rc=$?
check_absent "gate: small file allowed" "deny" "$out"
check_eq "gate: small file exit 0" "0" "$rc"
head -c 20000 /dev/zero | tr '\0' 'x' > "$TMP/hc_big.dart"
out=$(gate_input "$TMP/hc_big.dart" gate-s1 | bash "$GATE")
check_absent "gate: non-structured ext allowed" "deny" "$out"
out=$(printf 'not json' | bash "$GATE"); rc=$?
check_absent "gate: garbage stdin silent" "deny" "$out"
check_eq "gate: garbage stdin exit 0" "0" "$rc"

bash_gate_input() {  # bash_gate_input <command> <session-id>
  jq -n --arg cmd "$1" --arg sid "$2" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", session_id:$sid, tool_input:{command:$cmd}}'
}

if [ -n "$HEADROOM_PY" ]; then
  # 27. big structured file → deny once with hcat guidance...
  out=$(gate_input "$TMP/hc_big.json" gate-s2 | bash "$GATE")
  check "gate: big json denied" '"permissionDecision":"deny"' "$out"
  check "gate: reason names hcat" "hcat" "$out"
  # 28. ...second attempt on the same file passes (escape hatch)
  out=$(gate_input "$TMP/hc_big.json" gate-s2 | bash "$GATE")
  check_absent "gate: retry same file allowed" "deny" "$out"
  # other sessions unaffected
  out=$(gate_input "$TMP/hc_big.json" gate-s3 | bash "$GATE")
  check "gate: deny is per-session" '"permissionDecision":"deny"' "$out"
  # kill switch
  out=$(gate_input "$TMP/hc_big.json" gate-s4 | HCAT_GATE_OFF=1 bash "$GATE")
  check_absent "gate: HCAT_GATE_OFF disables" "deny" "$out"

  # --- 29. gate covers Bash raw dumps (tell, not nudge)
  out=$(bash_gate_input "cat $TMP/hc_big.json" gate-b1 | bash "$GATE")
  check "gate/bash: bare cat rewritten, not denied" '"permissionDecision":"allow"' "$out"
  check "gate/bash: updatedInput carries the hcat command" '"updatedInput"' "$out"
  check "gate/bash: rewritten command targets the file" "hc_big.json" "$out"
  check_absent "gate/bash: rewrite is not a deny" '"permissionDecision":"deny"' "$out"
  out=$(bash_gate_input "cat $TMP/hc_big.json" gate-b1 | bash "$GATE")
  check_absent "gate/bash: retry same file passes raw (no rewrite loop)" "updatedInput" "$out"
  out=$(bash_gate_input "cat $TMP/hc_big.json | jq '.[0]'" gate-b2 | bash "$GATE")
  check_absent "gate/bash: piped cat allowed (real processing)" "deny" "$out"
  out=$(bash_gate_input "head -c 200 $TMP/hc_big.json" gate-b2 | bash "$GATE")
  check_absent "gate/bash: bounded head allowed" "deny" "$out"
  out=$(bash_gate_input "cat $TMP/hc_small.json" gate-b2 | bash "$GATE")
  check_absent "gate/bash: small file allowed" "deny" "$out"
  out=$(bash_gate_input "cat $TMP/hc_big.dart" gate-b2 | bash "$GATE")
  check_absent "gate/bash: non-structured ext allowed" "deny" "$out"
  out=$(bash_gate_input "cat \"$TMP/hc_big.json\"" gate-b3 | bash "$GATE")
  check "gate/bash: quoted path still rewritten" '"updatedInput"' "$out"
else
  skip_note "gate deny tests (headroom venv not found)"
fi

# --- 30. badge counts hcat receipts from the transcript
export HEADROOM_STATE_DIR="$TMP/state-hcat-badge"

hcat_event() {  # hcat_event <tool-use-id> <before-tok> <after-tok> [pad-bytes]
  # Real transcripts carry the Bash command in tool_use .input.command — the
  # badge attributes receipts structurally, so the fixture must carry it too.
  local pad=""
  [ -n "${4:-}" ] && pad=$(head -c "$4" /dev/zero | tr '\0' 'y')
  printf '%s\n%s\n' \
    "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"Bash\",\"input\":{\"command\":\"hcat \\\"/tmp/x.json\\\"\"}}]}}" \
    "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"content\":[{\"type\":\"text\",\"text\":\"── hcat: /tmp/x.json · 10 lines · 5.0 KB · ~$2 tok → ~$3 tok (60.0% saved) · original on disk\\n$pad\"}]}]}}"
}

# hcat alone: green badge, savings counted, 1×
hcat_event h1 1000 400 > "$TMP/t_hcat.jsonl"
out=$(badge "$TMP/t_hcat.jsonl" claude-opus-4-8 sess-h1)
check "hcat badge: green dot"        "●"        "$out"
check "hcat badge: tokens counted"   "600"      "$out"
check "hcat badge: count"            "1×"       "$out"

# a big hcat receipt is NOT a missed opportunity (it IS compressed)
hcat_event h2 9000 3000 6000 > "$TMP/t_hcat_big.jsonl"
out=$(badge "$TMP/t_hcat_big.jsonl" claude-opus-4-8 sess-h2)
check_absent "hcat badge: receipt not counted as missed" "missed" "$out"
check "hcat badge: mascot asleep" "😴 dangi" "$out"

# mixed: MCP compress (500) + hcat (600) = 1.1k, 2×
{ compress_event m1 500; hcat_event h3 1000 400; } > "$TMP/t_mixed.jsonl"
out=$(badge "$TMP/t_mixed.jsonl" claude-opus-4-8 sess-hm)
check "hcat badge: mixed total" "1.1k" "$out"
check "hcat badge: mixed count" "2×"   "$out"

# a persisted big output buries the receipt mid-text after a preview banner
printf '%s\n%s\n' \
  "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"h5\",\"name\":\"Bash\",\"input\":{\"command\":\"hcat \\\"/tmp/z.json\\\"\"}}]}}" \
  '{"message":{"content":[{"type":"tool_result","tool_use_id":"h5","content":[{"type":"text","text":"Output too large (32.1KB). Full output saved.\nPreview (first 2KB):\n── hcat: /tmp/z.json · 9 lines · 8.0 KB · ~2000 tok → ~800 tok (60.0% saved) · original on disk\n..."}]}]}}' \
  > "$TMP/t_persist.jsonl"
out=$(badge "$TMP/t_persist.jsonl" claude-opus-4-8 sess-hpers)
check "hcat badge: persisted preview receipt counted" "1.2k" "$out"

# passthrough receipts (no "→") are not compressions
printf '%s\n%s\n' \
  "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"h4\",\"name\":\"Bash\",\"input\":{\"command\":\"hcat \\\"/tmp/y.txt\\\"\"}}]}}" \
  '{"message":{"content":[{"type":"tool_result","tool_use_id":"h4","content":[{"type":"text","text":"── hcat: /tmp/y.txt · 3 lines · 0.1 KB · passthrough (compression would save 0.0%)\nshort prose line"}]}]}}' \
  > "$TMP/t_pass.jsonl"
out=$(badge "$TMP/t_pass.jsonl" claude-opus-4-8 sess-hp)
check "hcat badge: passthrough not counted" "not compressing yet" "$out"

# --- 31. plugin-native hooks (hooks/hooks.json + bin/hcat)
HOOKS_JSON="$ROOT/hooks/hooks.json"
export HEADROOM_STATE_DIR="$TMP/state-plugnat"

if jq -e . "$HOOKS_JSON" >/dev/null 2>&1; then
  echo "ok - hooks.json: parses"; PASS=$((PASS+1))
else
  echo "FAIL - hooks.json: parses"; FAIL=$((FAIL+1))
fi
check_eq "hooks.json: exactly the five event arrays" "PostToolUse,PreToolUse,SessionEnd,SessionStart,Stop" \
  "$(jq -r '.hooks | keys | sort | join(",")' "$HOOKS_JSON" 2>/dev/null)"
check_eq "hooks.json: single PreToolUse entry"  "1" "$(jq -r '.hooks.PreToolUse  | length' "$HOOKS_JSON" 2>/dev/null)"
check_eq "hooks.json: single PostToolUse entry" "1" "$(jq -r '.hooks.PostToolUse | length' "$HOOKS_JSON" 2>/dev/null)"
check "hooks.json: PreToolUse matcher"  "Read|Bash" "$(jq -r '.hooks.PreToolUse[0].matcher'  "$HOOKS_JSON" 2>/dev/null)"
check "hooks.json: PostToolUse matcher" "*"         "$(jq -r '.hooks.PostToolUse[0].matcher' "$HOOKS_JSON" 2>/dev/null)"

gate_cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command'  "$HOOKS_JSON" 2>/dev/null)
dangi_cmd=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$HOOKS_JSON" 2>/dev/null)
check "hooks.json: gate command uses CLAUDE_PLUGIN_ROOT"  '${CLAUDE_PLUGIN_ROOT}' "$gate_cmd"
check "hooks.json: gate command targets hcat-gate.sh"     "hcat-gate.sh"          "$gate_cmd"
check "hooks.json: dangi command uses CLAUDE_PLUGIN_ROOT" '${CLAUDE_PLUGIN_ROOT}' "$dangi_cmd"
check "hooks.json: dangi command targets dangi-hook.sh"   "dangi-hook.sh"         "$dangi_cmd"

# hcat ships in bin/ (auto-added to Bash PATH while the plugin is enabled)
if [ -x "$ROOT/bin/hcat" ]; then
  echo "ok - bin/hcat: exists and is executable"; PASS=$((PASS+1))
else
  echo "FAIL - bin/hcat: exists and is executable"; FAIL=$((FAIL+1))
fi

# end-to-end through the EXACT command strings from hooks.json (not hardcoded
# paths): substitute CLAUDE_PLUGIN_ROOT=$ROOT and run via sh -c.
out=$(hook_input Bash 9000 plugnat-d1 | CLAUDE_PLUGIN_ROOT="$ROOT" sh -c "$dangi_cmd"); rc=$?
check "plugin-native dangi: nudges via hooks.json command" "additionalContext" "$out"
check_eq "plugin-native dangi: exit 0" "0" "$rc"
check "dangi nudge: plain hcat form (on PATH)" 'hcat \"<path>\"' "$out"
check "dangi nudge: says plugin installs have it on PATH" "plugin installs have it on PATH" "$out"
check "dangi nudge: names legacy fallback" "~/.claude/hcat" "$out"
check_absent "dangi nudge: no plugin-internal path" "bin/hcat" "$out"

if [ -n "$HEADROOM_PY" ]; then
  out=$(gate_input "$TMP/hc_big.json" plugnat-g1 | CLAUDE_PLUGIN_ROOT="$ROOT" sh -c "$gate_cmd"); rc=$?
  check "plugin-native gate: denies big json via hooks.json command" '"permissionDecision":"deny"' "$out"
  check_eq "plugin-native gate: exit 0" "0" "$rc"
  check "gate deny: plain single-quoted hcat form" "Run \`hcat '" "$out"
  check_absent "gate deny: no scripts/hcat path" "scripts/hcat" "$out"
  check_absent "gate deny: no bin/hcat path" "bin/hcat" "$out"
  check_absent "gate deny: no .claude/hcat" ".claude/hcat" "$out"
  check_absent "gate deny: no ~/.claude" "~/.claude" "$out"
else
  skip_note "plugin-native gate deny tests (headroom venv not found)"
fi

# --- 32. portability (v2.5 WS3): linux notify-send fallback, hcat SIGPIPE, GNU-stat env
export HEADROOM_STATE_DIR="$TMP/state-port"

# A minimal "Linux" PATH: coreutils + jq symlinked in, a GNU-style stat shim
# (accepts -c, rejects -f like GNU stat does), a fake notify-send that logs its
# args, and NO osascript anywhere on it.
LINBIN="$TMP/linbin"; mkdir -p "$LINBIN"
for t in jq tr wc date mkdir rmdir cat dirname basename grep sed tail head; do
  # same MSYS symlink caveat as link_tool, but these coreutils do not all
  # answer --version the same way, so probe with a plain existence+exec test
  link_tool "$(command -v "$t")" "$LINBIN/$t"
done
cat > "$LINBIN/stat" <<'EOF'
#!/bin/sh
case "$1" in
  -c) shift; /usr/bin/stat -c %Y "$2" 2>/dev/null || exec /usr/bin/stat -f %m "$2" ;;
  # Faithful to real GNU `stat -f %m FILE`: -f means --file-system there, so it
  # errors on the '%m' operand (stderr) but STILL prints an fs-info block for
  # FILE on stdout, and exits 1 — stdout garbage that poisons $(( now - ... ))
  # if a caller tries BSD-style -f first.
  -f) echo "stat: cannot read file system information for '%m': No such file or directory" >&2
      printf '  File: "%s"\n    ID: 100000ff Namelen: 255     Type: ext2/ext3\n' "${3:-}"
      exit 1 ;;
  *) echo "stat: invalid option" >&2; exit 1 ;;
esac
EOF
printf '#!/bin/sh\necho "$@" >> "%s/notifysend.calls"\n' "$TMP" > "$LINBIN/notify-send"
chmod +x "$LINBIN/stat" "$LINBIN/notify-send"

ns_count() { wc -l < "$TMP/notifysend.calls" 2>/dev/null | tr -d ' '; }

# no osascript on PATH → notify-send fallback fires; nudge and exit 0 intact
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"port-s1",
  tool_response:("x"*9000)}' | env -u DANGI_NO_NOTIFY PATH="$LINBIN" /bin/bash "$DANGI"); rc=$?
check "portability: linux env still nudges" "additionalContext" "$out"
check_eq "portability: linux env exit 0" "0" "$rc"
for _ in 1 2 3 4 5 6 7 8 9 10; do   # notify-send fires in the background — poll up to 2s
  [ -s "$TMP/notifysend.calls" ] && break
  sleep 0.2
done
check "portability: notify-send invoked without osascript" "Dangi" "$(cat "$TMP/notifysend.calls" 2>/dev/null)"
check "portability: notify-send carries the message" "KB Bash output" "$(cat "$TMP/notifysend.calls" 2>/dev/null)"

# NOTIFY_COOLDOWN applies to notify-send too — same session again stays quiet
jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"port-s1",
  tool_response:("x"*9000)}' | env -u DANGI_NO_NOTIFY PATH="$LINBIN" /bin/bash "$DANGI" > /dev/null
sleep 0.5
check_eq "portability: notify-send cooldown per session" "1" "$(ns_count)"

# DANGI_NO_NOTIFY kill switch silences notify-send as well
jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"port-s2",
  tool_response:("x"*9000)}' | env DANGI_NO_NOTIFY=1 PATH="$LINBIN" /bin/bash "$DANGI" > /dev/null
sleep 0.5
check_eq "portability: DANGI_NO_NOTIFY silences notify-send" "1" "$(ns_count)"

# when both notifiers are present, osascript is preferred (macOS look stays native)
osa_pre=$(wc -l < "$TMP/osascript.calls" | tr -d ' ')
jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"port-s3",
  tool_response:("x"*9000)}' | env -u DANGI_NO_NOTIFY PATH="$FAKEBIN:$LINBIN:$PATH" bash "$DANGI" > /dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(wc -l < "$TMP/osascript.calls" | tr -d ' ')" -gt "$osa_pre" ] && break
  sleep 0.2
done
check_eq "portability: osascript preferred when both exist" "$((osa_pre + 1))" "$(wc -l < "$TMP/osascript.calls" | tr -d ' ')"
check_eq "portability: notify-send not doubled" "1" "$(ns_count)"

# stale-lock steal must work where only GNU stat exists (stat -c, no -f)
mkdir -p "$HEADROOM_STATE_DIR/.lock-port-s4"
touch -t 202001010000 "$HEADROOM_STATE_DIR/.lock-port-s4"
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"port-s4",
  tool_response:("x"*9000)}' | env DANGI_NO_NOTIFY=1 PATH="$LINBIN" /bin/bash "$DANGI"); rc=$?
check "portability: stale lock stolen with GNU-only stat" "additionalContext" "$out"
check_eq "portability: GNU-only stat exit 0" "0" "$rc"

# hcat piped into head must not spew BrokenPipeError from python stdout teardown
if [ -n "$HEADROOM_PY" ]; then
  "$HEADROOM_PY" - "$TMP/hc_pipe.json" <<'PYEOF'
import json, sys
rows = [{"id": i, "user": f"user_{i%50}", "event": "click", "ts": 1700000000+i, "ok": True} for i in range(5000)]
open(sys.argv[1], "w").write(json.dumps(rows, indent=2))
PYEOF
  err=$( { HEADROOM_WORKSPACE_DIR="$TMP/hc_ws" bash "$HCAT" "$TMP/hc_pipe.json" | head -1 > "$TMP/hc_pipe.out"; } 2>&1 )
  check_absent "portability: no BrokenPipeError when piped to head" "BrokenPipeError" "$err"
  check_absent "portability: no traceback when piped to head" "Traceback" "$err"
  check "portability: receipt header survives the pipe" "── hcat:" "$(cat "$TMP/hc_pipe.out")"
else
  skip_note "hcat SIGPIPE test (headroom venv not found)"
fi

# --- 33. doctor + engine bootstrap + bundled MCP definition (v2.5 WS2)
DOCTOR="$ROOT/scripts/doctor.sh"
# hermetic: the doctor scans $PWD/.claude by default (v2.7) — point it at an
# empty dir so the developer's real project settings never leak into the suite
export DOCTOR_PROJECT_DIR="$TMP/no-proj"
# hermetic (v2.8 issue #9, check 2b): the default shim dir is the real
# ~/.local/bin — override it everywhere so a --fix run in this suite can never
# write a real symlink into the developer's actual home directory. Individual
# w6 fixtures below override this per-call to exercise the real default logic.
export DOCTOR_SHIM_DIR="$TMP/shim-default"
MCP_JSON="$ROOT/.mcp.json"
DOCD="$TMP/doc"; mkdir -p "$DOCD"

doc_settings_wired() {  # doc_settings_wired <claude-dir> — statusLine wired, no legacy hooks
  jq -n --arg cd "$1" '{statusLine:{type:"command",command:("bash \"" + $cd + "/headroom-statusline.sh\"")}}'
}
doc_settings_legacy() {  # doc_settings_legacy <claude-dir> — the real pre-plugin layout
  jq -n --arg cd "$1" '{hooks:{
    PostToolUse:[
      {matcher:"*",hooks:[{type:"command",command:("bash \"" + $cd + "/dangi-hook.sh\""),timeout:10}]},
      {matcher:"*",hooks:[{type:"command",command:"echo unrelated-hook"}]}],
    PreToolUse:[
      {matcher:"Read",hooks:[{type:"command",command:("bash \"" + $cd + "/hcat-gate.sh\""),timeout:10}]}]}}'
}

# stub toolchain for --fix tests: fake python3 whose `-m venv` materializes a fake
# venv (fake pip records its args; NEVER runs real pip), plus the real jq on PATH.
STUB="$DOCD/stub"; mkdir -p "$STUB"
link_tool "$(command -v jq)" "$STUB/jq"
cat > "$STUB/python3" <<'STUBEOF'
#!/bin/sh
d=$(dirname "$0")
echo "$@" >> "$d/python3.calls"
if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
  mkdir -p "$3/bin"
  cat > "$3/bin/pip" <<'PIPEOF'
#!/bin/sh
echo "$@" >> "$(dirname "$0")/../pip.calls"
PIPEOF
  cat > "$3/bin/python" <<'PYEOF2'
#!/bin/sh
exit 0
PYEOF2
  chmod +x "$3/bin/pip" "$3/bin/python"
fi
exit 0
STUBEOF
chmod +x "$STUB/python3"

# fake engine dir: python that always succeeds + headroom that reports its invocation
FENG="$DOCD/feng"; mkdir -p "$FENG"
printf '#!/bin/sh\nexit 0\n' > "$FENG/python"
cat > "$FENG/headroom" <<'FENGEOF'
#!/bin/sh
echo "launched: $* update=$HEADROOM_UPDATE_CHECK offline=$HF_HUB_OFFLINE"
FENGEOF
chmod +x "$FENG/python" "$FENG/headroom"

# headroom-only PATH entry (no sibling python) for fixtures whose engine-python
# resolution must actually exercise the --fix bootstrap path rather than
# short-circuit through 2b's PATH-sibling candidate ($FENG has a python sibling
# and would hijack that resolution order); putting this on PATH just makes
# check 2b's own `command -v headroom` succeed directly (issue #9)
AMBIENT_HR="$DOCD/ambient-hr"; mkdir -p "$AMBIENT_HR"
printf '#!/bin/sh\nexit 0\n' > "$AMBIENT_HR/headroom"; chmod +x "$AMBIENT_HR/headroom"

# 32a. healthy read-only run against the real engine
if [ -n "$HEADROOM_PY" ]; then
  CD1="$DOCD/cd1"; mkdir -p "$CD1/lib"
  S1="$DOCD/s1.json"; doc_settings_wired "$CD1" > "$S1"
  # a truly-healthy install has the wired script AND its lib deps on disk, not just
  # a settings.json pointer (see check 7's wired-but-missing guard + 7b/7c)
  cp "$ROOT/scripts/statusline.sh" "$CD1/headroom-statusline.sh"
  cp "$ROOT/scripts/lib/attribution.jq"    "$CD1/lib/"
  cp "$ROOT/scripts/lib/headroom-state.sh" "$CD1/lib/"
  cp "$ROOT/scripts/lib/engine-resolve.sh" "$CD1/lib/"   # v2.8: doctor provisions this one too
  # $FENG on PATH gives check 2b a real `headroom` to resolve (this Mac has none
  # ambient); HCAT_PYTHON is authoritative for check 2 so this can't hijack the
  # real-engine resolution being tested here (issue #9)
  out=$(HCAT_PYTHON="$HEADROOM_PY" PATH="$FENG:$PATH" DOCTOR_SETTINGS="$S1" DOCTOR_CLAUDE_DIR="$CD1" \
        DOCTOR_VENV_DIR="$DOCD/none" bash "$DOCTOR" 2>&1); rc=$?
  check "doctor: healthy engine"          "engine python"   "$out"
  check "doctor: healthy hcat smoke"      "hcat smoke"      "$out"
  check "doctor: healthy hooks.json"      "hooks.json"      "$out"
  check "doctor: healthy statusLine"      "statusLine"      "$out"
  check_absent "doctor: healthy has no FAIL"    "FAIL"    "$out"
  check_absent "doctor: healthy has no fixable" "fixable" "$out"
  check_eq "doctor: healthy exit 0" "0" "$rc"
else
  skip_note "doctor healthy-run tests (headroom venv not found)"
fi

# 32b. engine missing → fixable (not FAIL), smoke skipped, exit stays 0
CD2="$DOCD/cd2"; mkdir -p "$CD2"
S2="$DOCD/s2.json"; doc_settings_wired "$CD2" > "$S2"
out=$(HCAT_PYTHON=/nonexistent/python DOCTOR_SETTINGS="$S2" DOCTOR_CLAUDE_DIR="$CD2" \
      DOCTOR_VENV_DIR="$DOCD/none" bash "$DOCTOR" 2>&1); rc=$?
check "doctor: missing engine is fixable"    "fixable - engine"          "$out"
check "doctor: smoke skipped without engine" "hcat smoke (engine missing" "$out"
check_eq "doctor: fixable-only still exit 0"    "0"                          "$rc"

# 32c. broken engine (import ok, real runs fail) → FAIL + nonzero exit
BADPY="$DOCD/badpy"; mkdir -p "$BADPY"
printf '#!/bin/sh\ncase "$*" in *-c*) exit 0;; esac\nexit 1\n' > "$BADPY/python"
chmod +x "$BADPY/python"
out=$(HCAT_PYTHON="$BADPY/python" DOCTOR_SETTINGS="$S2" DOCTOR_CLAUDE_DIR="$CD2" \
      DOCTOR_VENV_DIR="$DOCD/none" bash "$DOCTOR" 2>&1); rc=$?
check "doctor: broken engine FAILs smoke" "FAIL" "$out"
if [ "$rc" -ne 0 ]; then
  echo "ok - doctor: FAIL exits nonzero"; PASS=$((PASS+1))
else
  echo "FAIL - doctor: FAIL exits nonzero (got rc=0)"; FAIL=$((FAIL+1))
fi

# 32d. resolution order branch 2: sibling python of `headroom` found on PATH
out=$(env -u HCAT_PYTHON PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S2" \
      DOCTOR_CLAUDE_DIR="$CD2" DOCTOR_VENV_DIR="$DOCD/none" bash "$DOCTOR" 2>&1)
check "doctor: engine via headroom on PATH" "engine python: $FENG/python" "$out"

# 32e. detectors: legacy hooks, unwired statusLine, stale copies, foreign statusLine
CD3="$DOCD/cd3"; mkdir -p "$CD3"
touch "$CD3/dangi-hook.sh" "$CD3/hcat-gate.sh" "$CD3/hcat"
S3="$DOCD/s3.json"; doc_settings_legacy "$CD3" > "$S3"
out=$(HCAT_PYTHON=/nonexistent/python DOCTOR_SETTINGS="$S3" DOCTOR_CLAUDE_DIR="$CD3" \
      DOCTOR_VENV_DIR="$DOCD/none" bash "$DOCTOR" 2>&1)
check "doctor: detects legacy hooks"        "fixable - legacy hooks" "$out"
check "doctor: detects unwired statusLine"  "fixable - statusLine"   "$out"
check "doctor: detects stale copies"        "fixable - stale"        "$out"
S3b="$DOCD/s3b.json"
jq -n '{statusLine:{type:"command",command:"bash ~/my-custom-line.sh"}}' > "$S3b"
out=$(HCAT_PYTHON=/nonexistent/python DOCTOR_SETTINGS="$S3b" DOCTOR_CLAUDE_DIR="$CD2" \
      DOCTOR_VENV_DIR="$DOCD/none" bash "$DOCTOR" --fix 2>&1)
check "doctor: foreign statusLine merged, not clobbered" "merged" "$out"
check "doctor: foreign statusLine preserved by --fix" "my-custom-line.sh" \
      "$(jq -r '.statusLine.command' "$S3b")"

# 32f. --fix end-to-end: venv bootstrap (stubbed), legacy removal, statusLine, stale cleanup
CD4="$DOCD/cd4"; mkdir -p "$CD4"
touch "$CD4/dangi-hook.sh" "$CD4/hcat-gate.sh" "$CD4/hcat"
S4="$DOCD/s4.json"; doc_settings_legacy "$CD4" > "$S4"
# $AMBIENT_HR (headroom, no python sibling) keeps check 2b clean ("ok") without
# hijacking the bootstrap-from-scratch resolution this fixture is testing (issue #9)
out=$(env -u HCAT_PYTHON PATH="$AMBIENT_HR:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S4" \
      DOCTOR_CLAUDE_DIR="$CD4" DOCTOR_VENV_DIR="$DOCD/venv-boot" bash "$DOCTOR" --fix 2>&1); rc=$?
check "fix: reports fixed"        "fixed"   "$out"
check_eq "fix: exit 0"               "0"       "$rc"
check "fix: venv created via python3 -m venv" "-m venv $DOCD/venv-boot" "$(cat "$STUB/python3.calls" 2>/dev/null)"
check "fix: pip install headroom-ai (stubbed)"   "install headroom-ai[all]" "$(cat "$DOCD/venv-boot/pip.calls" 2>/dev/null)"
check_eq "fix: legacy hooks removed" "0" \
  "$(jq '[.hooks // {} | to_entries[] | .value[]?.hooks[]? | select((.command // "") | test("dangi-hook|hcat-gate"))] | length' "$S4")"
check "fix: unrelated hook preserved" "unrelated-hook" "$(cat "$S4")"
check "fix: statusLine written" "headroom-statusline.sh" "$(jq -r '.statusLine.command // empty' "$S4")"
if cmp -s "$ROOT/scripts/statusline.sh" "$CD4/headroom-statusline.sh"; then
  echo "ok - fix: statusline script copied"; PASS=$((PASS+1))
else
  echo "FAIL - fix: statusline script copied"; FAIL=$((FAIL+1))
fi
# issue #2: statusline.sh needs its lib/ deps next to the copy, or compute()
# silently degrades to a permanent idle badge. --fix must provision them.
if cmp -s "$ROOT/scripts/lib/attribution.jq" "$CD4/lib/attribution.jq" \
   && cmp -s "$ROOT/scripts/lib/headroom-state.sh" "$CD4/lib/headroom-state.sh" \
   && cmp -s "$ROOT/scripts/lib/engine-resolve.sh" "$CD4/lib/engine-resolve.sh"; then
  echo "ok - fix: statusline lib deps provisioned (issue #2)"; PASS=$((PASS+1))
else
  echo "FAIL - fix: statusline lib deps provisioned (issue #2)"; FAIL=$((FAIL+1))
fi
check "fix: doctor reports lib deps current" "statusline lib deps current" "$out"
if [ -e "$CD4/dangi-hook.sh" ] || [ -e "$CD4/hcat-gate.sh" ] || [ -e "$CD4/hcat" ]; then
  echo "FAIL - fix: stale copies removed"; FAIL=$((FAIL+1))
else
  echo "ok - fix: stale copies removed"; PASS=$((PASS+1))
fi
check_eq "fix: one timestamped backup" "1" "$(ls "$S4".bak.* 2>/dev/null | wc -l | tr -d ' ')"
# idempotency: a second --fix run must change nothing and re-bootstrap nothing
cp "$S4" "$DOCD/s4.after1"
out2=$(env -u HCAT_PYTHON PATH="$AMBIENT_HR:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S4" \
       DOCTOR_CLAUDE_DIR="$CD4" DOCTOR_VENV_DIR="$DOCD/venv-boot" bash "$DOCTOR" --fix 2>&1)
if cmp -s "$S4" "$DOCD/s4.after1"; then
  echo "ok - fix: second run leaves settings unchanged"; PASS=$((PASS+1))
else
  echo "FAIL - fix: second run leaves settings unchanged"; FAIL=$((FAIL+1))
fi
check_eq "fix: second run adds no backup" "1" "$(ls "$S4".bak.* 2>/dev/null | wc -l | tr -d ' ')"
check_eq "fix: bootstrap not repeated"    "1" "$(wc -l < "$STUB/python3.calls" | tr -d ' ')"
check_absent "fix: nothing left fixable after fix" "fixable" "$out2"

# 32g. doctor CLI hygiene
out=$(bash "$DOCTOR" --bogus 2>&1); rc=$?
check "doctor: unknown flag errors" "unknown" "$out"
check_eq "doctor: unknown flag exit 2" "2"       "$rc"

# 32h. no launcher any more (v2.8): the MCP is spawned by name, so there must be
# nothing left that a shell-less Windows spawn would choke on
if [ ! -e "$ROOT/scripts/mcp-launcher.sh" ]; then
  echo "ok - launcher: removed (bare command since v2.8)"; PASS=$((PASS+1))
else
  echo "FAIL - launcher: scripts/mcp-launcher.sh still present"; FAIL=$((FAIL+1))
fi

# 32i. bundled .mcp.json — erases the manual "register headroom MCP" step
if jq -e . "$MCP_JSON" >/dev/null 2>&1; then
  echo "ok - mcp.json: parses"; PASS=$((PASS+1))
else
  echo "FAIL - mcp.json: parses"; FAIL=$((FAIL+1))
fi
check "mcp.json: stdio server" "stdio" "$(jq -r '.mcpServers.headroom.type // empty' "$MCP_JSON" 2>/dev/null)"
mcp_cmd=$(jq -r '.mcpServers.headroom.command // empty' "$MCP_JSON" 2>/dev/null)
check_eq "mcp.json: command is the bare name (spawned without a shell on every OS)" "headroom" "$mcp_cmd"
check_eq "mcp.json: args = mcp serve" "mcp serve" "$(jq -r '.mcpServers.headroom.args | join(" ")' "$MCP_JSON" 2>/dev/null)"
check "mcp.json: env update off" "off" "$(jq -r '.mcpServers.headroom.env.HEADROOM_UPDATE_CHECK // empty' "$MCP_JSON" 2>/dev/null)"
check_eq "mcp.json: env hf offline" "1"   "$(jq -r '.mcpServers.headroom.env.HF_HUB_OFFLINE // empty' "$MCP_JSON" 2>/dev/null)"
# end-to-end: the bare name resolves through PATH exactly as a shell-less spawn would
mcp_args=$(jq -r '.mcpServers.headroom.args | join(" ")' "$MCP_JSON")
# shellcheck disable=SC2086
out=$(PATH="$FENG:$PATH" HEADROOM_UPDATE_CHECK=off HF_HUB_OFFLINE=1 "$mcp_cmd" $mcp_args 2>&1)
check "mcp.json: end-to-end launch by name" "launched: mcp serve" "$out"

# 32j. /doctor skill
DSKILL="$ROOT/skills/doctor/SKILL.md"
if [ -f "$DSKILL" ]; then
  echo "ok - doctor skill: exists"; PASS=$((PASS+1))
else
  echo "FAIL - doctor skill: exists"; FAIL=$((FAIL+1))
fi
check "doctor skill: frontmatter name"     "name: doctor" "$(head -5 "$DSKILL" 2>/dev/null)"
check "doctor skill: triggers on breakage" "not working"  "$(cat "$DSKILL" 2>/dev/null)"
check "doctor skill: runs doctor.sh"       "doctor.sh"    "$(cat "$DSKILL" 2>/dev/null)"
check "doctor skill: consent before --fix" "consent"      "$(cat "$DSKILL" 2>/dev/null)"
# docs-parity: Step 3's consent list and the fixable lists must name every --fix
# mutation — an agent following the skill verbatim must not under-disclose
check "doctor skill: consent list names the headroom shim install"   "create or replace a \`headroom\` shim" "$(cat "$DSKILL" 2>/dev/null)"
check "doctor skill: consent list names the statusline re-copy"      "re-copy the statusline"       "$(cat "$DSKILL" 2>/dev/null)"
check "doctor skill: fixable list covers wired-but-missing re-copy"  "wired but script missing"     "$(cat "$DSKILL" 2>/dev/null)"
check "doctor header: fixable list covers wired-but-missing re-copy" "wired-missing copy"           "$(head -30 "$DOCTOR" 2>/dev/null)"
check "doctor skill: consent list names the statusLine.command rewrite" "rewrite \`statusLine.command\`" "$(cat "$DSKILL" 2>/dev/null)"
check "doctor header: header names the statusLine.command rewrite"      "rewrites statusLine.command"    "$(head -30 "$DOCTOR" 2>/dev/null)"
check "doctor skill: consent list names the headroom shim"        "shim"                    "$(cat "$DSKILL" 2>/dev/null)"
check "doctor skill: fixable list covers headroom not on PATH"    "headroom CLI not on PATH" "$(cat "$DSKILL" 2>/dev/null)"
check_absent "doctor skill: no launcher left in the doctor docs"  "mcp-launcher"            "$(cat "$DSKILL" 2>/dev/null)"
check "installer skill: legacy installer copies engine-resolve.sh" "engine-resolve.sh"       "$(cat "$ROOT/skills/headroom-usage-indicator/SKILL.md" 2>/dev/null)"

# --- 34. review fixes: badge + hooks
export HEADROOM_STATE_DIR="$TMP/state-review"

# 34a. receipt attribution is structural: a tool result that merely QUOTES a
# receipt line (grep/cat over docs or this very test file) must not count.
quote_event() {  # quote_event <id> <bash-command> [pad-bytes] — result quotes a receipt lookalike
  local pad=""
  [ -n "${3:-}" ] && pad=$(head -c "$3" /dev/zero | tr '\0' 'y')
  printf '%s\n%s\n' \
    "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"Bash\",\"input\":{\"command\":\"$2\"}}]}}" \
    "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"content\":[{\"type\":\"text\",\"text\":\"── hcat: /x.json · ~9999999 tok → ~1 tok (100.0% saved)\\n$pad\"}]}]}}"
}
quote_event q1 "grep -rn hcat-header notes" > "$TMP/t_rquote.jsonl"
out=$(badge "$TMP/t_rquote.jsonl" claude-opus-4-8 sess-rq1)
check "review: quoted receipt renders idle"      "not compressing yet" "$out"
check_absent "review: quoted receipt never green" "●"                  "$out"
if [ -e "$HEADROOM_STATE_DIR/session-sess-rq1.totals" ]; then
  echo "FAIL - review: quoted receipt writes no totals"
  echo "    found: $(cat "$HEADROOM_STATE_DIR/session-sess-rq1.totals")"
  FAIL=$((FAIL+1))
else
  echo "ok - review: quoted receipt writes no totals"; PASS=$((PASS+1))
fi

# a BIG quoted receipt is uncompressed raw text — a missed opportunity, not a save
quote_event q2 "cat README.md" 6000 > "$TMP/t_rquote_big.jsonl"
out=$(badge "$TMP/t_rquote_big.jsonl" claude-opus-4-8 sess-rq2)
check "review: big quoted receipt counts as missed" "1 big blob uncompressed" "$out"

# non-Bash receipts never count (Read of a file that starts with a receipt line)
printf '%s\n%s\n' \
  "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"q3\",\"name\":\"Read\",\"input\":{\"file_path\":\"/tmp/notes.txt\"}}]}}" \
  '{"message":{"content":[{"type":"tool_result","tool_use_id":"q3","content":[{"type":"text","text":"── hcat: /x.json · ~9999999 tok → ~1 tok (100.0% saved)"}]}]}}' \
  > "$TMP/t_rquote_read.jsonl"
out=$(badge "$TMP/t_rquote_read.jsonl" claude-opus-4-8 sess-rq3)
check "review: non-Bash receipt not counted" "not compressing yet" "$out"

# genuine invocations still count in every real spelling
genuine_event() {  # genuine_event <id> <bash-command> — real receipt, 1000→400
  printf '%s\n%s\n' \
    "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"Bash\",\"input\":{\"command\":\"$2\"}}]}}" \
    "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"content\":[{\"type\":\"text\",\"text\":\"── hcat: /tmp/x.json · 10 lines · 5.0 KB · ~1000 tok → ~400 tok (60.0% saved) · original on disk\"}]}]}}"
}
genuine_event ga "/Users/abhi/.claude/hcat \\\"/tmp/x.json\\\"" > "$TMP/t_rlegacy.jsonl"
out=$(badge "$TMP/t_rlegacy.jsonl" claude-opus-4-8 sess-rg1)
check "review: legacy-path hcat counts" "●"   "$out"
check "review: legacy-path savings"     "600" "$out"
genuine_event gb "jq -c . /tmp/x.json | hcat /dev/stdin" > "$TMP/t_rpipe.jsonl"
out=$(badge "$TMP/t_rpipe.jsonl" claude-opus-4-8 sess-rg2)
check "review: piped hcat counts" "●" "$out"

# --- gate-rewritten `cat` must be attributed (the rewrite is invisible in tool_use)
# The PreToolUse gate turns a raw `cat <big file>` into an hcat run via
# updatedInput. Claude Code RUNS the rewritten command but records the ORIGINAL
# `cat …` in the assistant's tool_use — so a transcript pass that only reads
# tool_use commands sees `cat`, fails the genuineness check, and scores a real
# compression as a MISS (badge blames the user for the savings it just made).
# The rewrite is recoverable from the hook_success attachment, keyed by
# toolUseID, that carries the gate's own stdout.
rewritten_event() {  # rewritten_event <tool-use-id> <recorded-command> <rewritten-command> [pad-bytes]
  # The pad matters: it pushes the receipt past NUDGE_BYTES so an unattributed
  # receipt is scored as a big MISSED blob. Without it the "not a miss"
  # assertion below would pass even unpatched and prove nothing.
  local pad=""
  [ -n "${4:-}" ] && pad=$(head -c "$4" /dev/zero | tr '\0' 'y')
  jq -cn --arg id "$1" --arg orig "$2" --arg now "$NOW" \
    '{timestamp:$now,message:{content:[{type:"tool_use",id:$id,name:"Bash",input:{command:$orig}}]}}'
  jq -cn --arg id "$1" --arg new "$3" \
    '{type:"attachment",attachment:{type:"hook_success",hookName:"PreToolUse:Bash",
      hookEvent:"PreToolUse",toolUseID:$id,stderr:"",exitCode:0,
      stdout:({hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",
        permissionDecisionReason:"🤖 hcat-gate: rewrote the raw `cat`",
        updatedInput:{command:$new}}}|tojson)}}'
  jq -cn --arg id "$1" --arg pad "$pad" \
    '{message:{content:[{type:"tool_result",tool_use_id:$id,content:[{type:"text",
      text:("── hcat: /tmp/x.json · 10 lines · 5.0 KB · ~1000 tok → ~400 tok (60.0% saved) · original on disk\n" + $pad)}]}]}}'
}
rewritten_event gw1 "cat /tmp/x.json" "hcat \"/tmp/x.json\"" 6000 > "$TMP/t_rewritten.jsonl"
out=$(badge "$TMP/t_rewritten.jsonl" claude-opus-4-8 sess-gw1)
check        "rewrite: gate-rewritten cat is attributed" "●"   "$out"
check        "rewrite: its savings are counted"          "600" "$out"
check        "rewrite: counted once"                     "1×"  "$out"
check_absent "rewrite: not scored as an uncompressed blob" "uncompressed" "$out"

# --- negatives: each poison is paired with a GENUINE compression in the same
# transcript, and we assert the genuine one still renders (1× / 600) while the
# poison adds nothing (never 2× / 1200). The pairing is the point: a bare
# check_absent on a poison-only transcript passes vacuously whenever the jq
# pass ABORTS and nothing renders at all — which is exactly how a non-string
# `updatedInput.command` (jq test() throws on non-strings, killing the whole
# program) slipped past the first version of these tests.
poison_event() {  # poison_event <id> <attachment-json-line>
  jq -cn --arg id "$1" --arg now "$NOW" \
    '{timestamp:$now,message:{content:[{type:"tool_use",id:$id,name:"Bash",input:{command:"cat /tmp/x.json"}}]}}'
  printf '%s\n' "$2"
  jq -cn --arg id "$1" \
    '{message:{content:[{type:"tool_result",tool_use_id:$id,content:[{type:"text",
      text:"── hcat: /tmp/x.json · 10 lines · 5.0 KB · ~1000 tok → ~400 tok (60.0% saved) · original on disk"}]}]}}'
}
gate_att() {  # gate_att <toolUseID> <attachment-type> <hookEvent> <command-json>
  jq -cn --arg id "$1" --arg at "$2" --arg ev "$3" --argjson cmd "$4" \
    '{type:"attachment",attachment:{type:$at,hookName:("PreToolUse:Bash"),hookEvent:$ev,
      toolUseID:$id,stderr:"",exitCode:0,
      stdout:({hookSpecificOutput:{hookEventName:$ev,permissionDecision:"allow",updatedInput:{command:$cmd}}}|tojson)}}'
}
neg_case() {  # neg_case <label> <session> <poison-id> <attachment-json>
  { hcat_event keep 1000 400; poison_event "$3" "$4"; } > "$TMP/t_neg_$3.jsonl"
  local o; o=$(badge "$TMP/t_neg_$3.jsonl" claude-opus-4-8 "$2")
  check        "rewrite/neg: $1 — genuine compression still counted" "600" "$o"
  check        "rewrite/neg: $1 — exactly one compression"           "1×"  "$o"
  check_absent "rewrite/neg: $1 — poison not counted"                "2×"  "$o"
}

# Negative 1: an attachment that did NOT rewrite to hcat.
neg_case "unrewritten cat" sess-gw2 gw2 "$(gate_att gw2 hook_success PreToolUse '"cat /tmp/x.json"')"

# Negative 2: hcat named only in hook PROSE, with no updatedInput at all.
neg_case "hcat only in hook prose" sess-gw3 gw3 "$(jq -cn '{type:"attachment",attachment:{type:"hook_success",hookName:"PreToolUse:Bash",hookEvent:"PreToolUse",toolUseID:"gw3",stderr:"",exitCode:0,
  stdout:({hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:"run hcat \"/tmp/x.json\" instead"}}|tojson)}}')"

# Negative 3: right shape, wrong hookEvent — pins the PreToolUse filter.
neg_case "PostToolUse attachment" sess-gw4 gw4 "$(gate_att gw4 hook_success PostToolUse '"hcat \"/tmp/x.json\""')"

# Negative 4: right shape, wrong attachment type — pins the hook_success filter.
neg_case "hook_error attachment" sess-gw5 gw5 "$(gate_att gw5 hook_error PreToolUse '"hcat \"/tmp/x.json\""')"

# Negative 5: a genuine-looking rewrite with NO toolUseID — pins the `// empty`
# guard, without which an id-less entry keys the set on "" and can launder any
# tool_result that also lacks a tool_use_id.
neg_case "attachment without toolUseID" sess-gw6 gw6 "$(jq -cn '{type:"attachment",attachment:{type:"hook_success",hookName:"PreToolUse:Bash",hookEvent:"PreToolUse",stderr:"",exitCode:0,
  stdout:({hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:{command:"hcat \"/tmp/x.json\""}}}|tojson)}}')"

# Negative 6: a NON-STRING updatedInput.command from any PreToolUse hook.
# jq's test() throws on non-strings and an uncaught throw aborts the whole
# program, so before the type guard this rendered NOTHING — the badge went
# blank and the ledger dropped the session. The genuine assertions below are
# what actually catch that; a bare check_absent would have passed.
neg_case "non-string command (number)" sess-gw7 gw7 "$(gate_att gw7 hook_success PreToolUse '42')"
neg_case "non-string command (array)"  sess-gw8 gw8 "$(gate_att gw8 hook_success PreToolUse '["ls","-la"]')"

# --- a receipt proves an hcat RUN, not that anything was compressed ---------
# hcat emits a "passthrough" receipt (no `~B tok → ~A tok` arrow) for
# incompressible content, and those raw bytes DO land in the context window.
# Savings accounting already required the arrow; the missed-opportunity counter
# did not, so a LARGE passthrough scored as neither a save nor a miss and the
# nudge went quiet on output that genuinely flooded the window.
pass_event() {  # pass_event <id> <command> [pad-bytes] — passthrough receipt, no arrow
  local pad=""
  [ -n "${3:-}" ] && pad=$(head -c "$3" /dev/zero | tr '\0' 'y')
  jq -cn --arg id "$1" --arg cmd "$2" --arg now "$NOW" \
    '{timestamp:$now,message:{content:[{type:"tool_use",id:$id,name:"Bash",input:{command:$cmd}}]}}'
  jq -cn --arg id "$1" --arg pad "$pad" \
    '{message:{content:[{type:"tool_result",tool_use_id:$id,content:[{type:"text",
      text:("── hcat: /tmp/y.txt · 3 lines · 200.0 KB · passthrough (compression would save 0.0%)\n" + $pad)}]}]}}'
}
# model-invoked hcat that passed through, LARGE: the bytes arrived raw -> a miss
pass_event pt1 'hcat "/tmp/y.txt"' 6000 > "$TMP/t_pass_big.jsonl"
out=$(badge "$TMP/t_pass_big.jsonl" claude-opus-4-8 sess-pt1)
check        "passthrough: a large passthrough is counted as a miss" "uncompressed" "$out"
check_absent "passthrough: it banks no savings"                      "●"            "$out"
# gate-rewritten cat whose hcat passed through: same rule, same answer
{ jq -cn --arg now "$NOW" '{timestamp:$now,message:{content:[{type:"tool_use",id:"pt2",name:"Bash",input:{command:"cat /tmp/y.txt"}}]}}'
  gate_att pt2 hook_success PreToolUse '"hcat \"/tmp/y.txt\""'
  jq -cn --arg pad "$(head -c 6000 /dev/zero | tr '\0' 'y')" \
    '{message:{content:[{type:"tool_result",tool_use_id:"pt2",content:[{type:"text",
      text:("── hcat: /tmp/y.txt · 3 lines · 200.0 KB · passthrough (compression would save 0.0%)\n" + $pad)}]}]}}'
} > "$TMP/t_pass_gate.jsonl"
out=$(badge "$TMP/t_pass_gate.jsonl" claude-opus-4-8 sess-pt2)
check "passthrough: a gate-rewritten passthrough is a miss too" "uncompressed" "$out"
# ...but a large REAL compression stays exempt (guards the over-correction)
hcat_event pt3 9000 3000 6000 > "$TMP/t_pass_real.jsonl"
out=$(badge "$TMP/t_pass_real.jsonl" claude-opus-4-8 sess-pt3)
check_absent "passthrough: a large real compression is still not a miss" "uncompressed" "$out"
check        "passthrough: and still banks its savings"                  "6.0k"         "$out"

# --- remaining branches of gate_rewritten_ids ------------------------------
# stdout that is not JSON at all must hit `try fromjson catch null` and be
# skipped cleanly, never abort the pass (the genuine event proves it rendered).
{ hcat_event keep2 1000 400
  jq -cn --arg now "$NOW" '{timestamp:$now,message:{content:[{type:"tool_use",id:"mf1",name:"Bash",input:{command:"cat /tmp/x.json"}}]}}'
  jq -cn '{type:"attachment",attachment:{type:"hook_success",hookName:"PreToolUse:Bash",hookEvent:"PreToolUse",toolUseID:"mf1",stderr:"",exitCode:0,stdout:"this is not json {{{"}}'
  jq -cn '{message:{content:[{type:"tool_result",tool_use_id:"mf1",content:[{type:"text",text:"── hcat: /tmp/x.json · 10 lines · 5.0 KB · ~1000 tok → ~400 tok (60.0% saved) · original on disk"}]}]}}'
} > "$TMP/t_malformed.jsonl"
out=$(badge "$TMP/t_malformed.jsonl" claude-opus-4-8 sess-mf1)
check        "rewrite: non-JSON hook stdout is skipped, pass still renders" "600" "$out"
check        "rewrite: non-JSON hook stdout attributes nothing extra"       "1×"  "$out"
check_absent "rewrite: non-JSON hook stdout not double-counted"             "2×"  "$out"

# an id in BOTH halves of the union (model ran hcat AND the gate logged a
# rewrite for the same tool_use) must count once — idset() dedupes, unpinned until now.
{ hcat_event dup 1000 400
  gate_att dup hook_success PreToolUse '"hcat \"/tmp/x.json\""'
} > "$TMP/t_dup.jsonl"
out=$(badge "$TMP/t_dup.jsonl" claude-opus-4-8 sess-dup)
check        "rewrite: id in both halves counts once"      "1×"  "$out"
check_absent "rewrite: id in both halves is not doubled"   "2×"  "$out"
check        "rewrite: id in both halves banks 600 once"   "600" "$out"

# a legacy absolute-path rewrite (`/abs/hcat "file"`) must still be recognised
{ jq -cn --arg now "$NOW" '{timestamp:$now,message:{content:[{type:"tool_use",id:"lg1",name:"Bash",input:{command:"cat /tmp/x.json"}}]}}'
  gate_att lg1 hook_success PreToolUse '"/Users/someone/.claude/hcat \"/tmp/x.json\""'
  jq -cn '{message:{content:[{type:"tool_result",tool_use_id:"lg1",content:[{type:"text",text:"── hcat: /tmp/x.json · 10 lines · 5.0 KB · ~1000 tok → ~400 tok (60.0% saved) · original on disk"}]}]}}'
} > "$TMP/t_legacy_rw.jsonl"
out=$(badge "$TMP/t_legacy_rw.jsonl" claude-opus-4-8 sess-lg1)
check "rewrite: legacy absolute-path hcat rewrite is attributed" "600" "$out"

# dangi, same attack: quoting a receipt in a grep is still a missed opportunity...
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"rev-d1",
  tool_input:{command:"grep -rn hcat-header notes"},
  tool_response:("── hcat: /x.json · ~9999999 tok → ~1 tok (100.0% saved)\n" + ("y"*9000))}' | bash "$DANGI")
check "review: dangi nudges on quoted receipt" "additionalContext" "$out"
# ...while a genuine hcat run stays exempt
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"rev-d2",
  tool_input:{command:"hcat \"/tmp/x.json\""},
  tool_response:("── hcat: /tmp/x.json · ~9000 tok → ~3000 tok (66.7% saved)\n" + ("y"*9000))}' | bash "$DANGI")
check_absent "review: dangi exempts genuine hcat run" "additionalContext" "$out"

# 34b. HOME unset (env -u HOME, set -u) must not kill any of the three scripts
NOHOME_TMP="$TMP/nohome"; mkdir -p "$NOHOME_TMP"
err=$(printf '{"transcript_path":"%s","model":{"id":"claude-opus-4-8"},"session_id":"rev-nh1"}' "$TMP/t_active.jsonl" \
  | env -u HOME -u HEADROOM_STATE_DIR TMPDIR="$NOHOME_TMP" bash "$SCRIPT" 2>&1 >"$TMP/nohome.badge"); rc=$?
check_eq "review: statusline survives unset HOME" "0" "$rc"
check "review: statusline still prints a badge" "headroom" "$(cat "$TMP/nohome.badge")"
if [ -z "$err" ]; then
  echo "ok - review: statusline stderr silent without HOME"; PASS=$((PASS+1))
else
  echo "FAIL - review: statusline stderr silent without HOME"
  echo "    got stderr: $err"; FAIL=$((FAIL+1))
fi
err=$(hook_input Bash 9000 rev-nh2 \
  | env -u HOME -u HEADROOM_STATE_DIR DANGI_NO_NOTIFY=1 TMPDIR="$NOHOME_TMP" bash "$DANGI" 2>&1 >/dev/null); rc=$?
check_eq "review: dangi survives unset HOME" "0" "$rc"
if [ -z "$err" ]; then
  echo "ok - review: dangi stderr silent without HOME"; PASS=$((PASS+1))
else
  echo "FAIL - review: dangi stderr silent without HOME"
  echo "    got stderr: $err"; FAIL=$((FAIL+1))
fi
out=$(gate_input "$TMP/hc_small.json" rev-nh3 | env -u HOME -u HEADROOM_STATE_DIR bash "$GATE" 2>&1); rc=$?
check_eq "review: gate survives unset HOME" "0" "$rc"
check_absent "review: gate quiet without HOME" "unbound" "$out"

# 34c. gate fails open when the resolved engine python cannot import headroom
BIGJSON="$TMP/rev_big.json"; head -c 20000 /dev/zero | tr '\0' 'x' > "$BIGJSON"
printf '#!/bin/sh\nexit 1\n' > "$TMP/rev_brokenpy"; chmod +x "$TMP/rev_brokenpy"
printf '#!/bin/sh\nexit 0\n' > "$TMP/rev_okpy";     chmod +x "$TMP/rev_okpy"
out=$(gate_input "$BIGJSON" rev-g1 | HCAT_PYTHON="$TMP/rev_brokenpy" bash "$GATE")
check_absent "review: gate fails open on import-broken engine" "deny" "$out"
out=$(gate_input "$BIGJSON" rev-g2 | HCAT_PYTHON="$TMP/rev_okpy" bash "$GATE")
check "review: gate still denies with importable engine" '"permissionDecision":"deny"' "$out"

# 34d. install-aware deny text: plugin layout claims PATH, legacy layout gives the abs path
check "review: plugin deny says on PATH" "on PATH" "$out"
LEGROOT="$TMP/legroot"; mkdir -p "$LEGROOT/legacy"
cp "$ROOT/scripts/hcat-gate.sh" "$LEGROOT/legacy/"
printf '#!/bin/sh\nexit 0\n' > "$LEGROOT/legacy/hcat"; chmod +x "$LEGROOT/legacy/hcat"
out=$(gate_input "$BIGJSON" rev-g3 | HCAT_PYTHON="$TMP/rev_okpy" bash "$LEGROOT/legacy/hcat-gate.sh")
check "review: legacy deny cites sibling hcat path" "$LEGROOT/legacy/hcat" "$out"
check_absent "review: legacy deny does not claim PATH" "on PATH" "$out"

# 34e. BSD awk honors LC_NUMERIC — money and totals must stay period-decimal
if locale -a 2>/dev/null | grep -qix 'de_DE.UTF-8'; then
  export HEADROOM_STATE_DIR="$TMP/state-locale"
  out=$(printf '{"transcript_path":"%s","model":{"id":"claude-opus-4-8"},"session_id":"rev-loc"}' "$TMP/t_active.jsonl" \
    | LC_ALL=de_DE.UTF-8 bash "$SCRIPT")
  check "review: de_DE money keeps period decimal" "0.25¢" "$out"
  check_absent "review: de_DE badge has no comma decimal" "0,25" "$out"
  tot=$(cat "$HEADROOM_STATE_DIR"/session-rev-loc.totals 2>/dev/null)
  check "review: de_DE totals keep period decimal" "0.002500" "$tot"
  check_absent "review: de_DE totals carry no comma" "," "$tot"
else
  skip_note "de_DE.UTF-8 locale tests (locale not installed)"
fi

# --- 35. review fixes: doctor + resolution (v2.5 F2)
REVD="$TMP/rev"; mkdir -p "$REVD"
NOVENV="$REVD/novenv"   # never created — engine must resolve without it

# F1: pip --user / pipx layout — a `headroom` console script with NO sibling
# python. Its shebang names a stub interpreter that passes `import headroom`
# (exit 0 on any argv, e.g. -c) and echoes its invocation. The stub must be a
# real binary — kernels reject a shebang interpreter that is itself a script —
# so symlink /bin/echo (argv comes out on stdout, exit 0 always; a copy would
# be SIGKILLed by macOS signature checks).
SPY="$REVD/interp"; mkdir -p "$SPY"
ln -s /bin/echo "$SPY/python3.14"
CLI="$REVD/clibin"; mkdir -p "$CLI"
printf '#!%s\n# console script only — no sibling python in this dir\n' "$SPY/python3.14" > "$CLI/headroom"
chmod +x "$CLI/headroom"
FAKEHOME="$REVD/home"; mkdir -p "$FAKEHOME"

# hcat needs an importing python: the console script's shebang interpreter
# (the echo-stub prints its argv, proving which interpreter hcat exec'd)
printf '{"k":1}' > "$REVD/tiny.json"
out=$(env -u HCAT_PYTHON HOME="$FAKEHOME" PATH="$CLI:/usr/bin:/bin" bash "$HCAT" "$REVD/tiny.json" 2>&1); rc=$?
check "f1 hcat: shebang interpreter resolved" "$REVD/tiny.json" "$out"
check_eq "f1 hcat: exit 0 (not 3)" "0" "$rc"

# ...including the `#!/usr/bin/env pythonX` shebang form, resolved via PATH
CLI2="$REVD/clibin2"; mkdir -p "$CLI2"
ln -s "$SPY/python3.14" "$CLI2/revpy"
printf '#!/usr/bin/env revpy\n' > "$CLI2/headroom"
chmod +x "$CLI2/headroom"
out=$(env -u HCAT_PYTHON HOME="$FAKEHOME" PATH="$CLI2:/usr/bin:/bin" bash "$HCAT" "$REVD/tiny.json" 2>&1)
check "f1 hcat: env-form shebang resolved" "$REVD/tiny.json" "$out"

# the doctor's engine check accepts the shebang interpreter too
CD35="$REVD/cd35"; mkdir -p "$CD35"
S35="$REVD/s35.json"; doc_settings_wired "$CD35" > "$S35"
out=$(env -u HCAT_PYTHON PATH="$CLI:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S35" \
      DOCTOR_CLAUDE_DIR="$CD35" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check "f1 doctor: engine via console-script shebang" "engine python: $SPY/python3.14" "$out"

# F2: a dotfile-manager symlinked settings.json must survive --fix as a symlink,
# with the fix landing in the target. (Also carries stale copies for the F5
# project-level caveat note.)
SYMD="$REVD/sym"; mkdir -p "$SYMD/cd"
touch "$SYMD/cd/dangi-hook.sh" "$SYMD/cd/hcat-gate.sh"
doc_settings_legacy "$SYMD/cd" > "$SYMD/target.json"
ln -s target.json "$SYMD/settings.json"
out=$(env -u HCAT_PYTHON PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$SYMD/settings.json" \
      DOCTOR_CLAUDE_DIR="$SYMD/cd" DOCTOR_VENV_DIR="$DOCD/venv-boot" bash "$DOCTOR" --fix 2>&1)
if [ -L "$SYMD/settings.json" ]; then
  echo "ok - f2: settings.json is still a symlink after --fix"; PASS=$((PASS+1))
else
  echo "FAIL - f2: settings.json is still a symlink after --fix"; FAIL=$((FAIL+1))
fi
check_eq "f2: legacy hooks removed through the link" "0" \
  "$(jq '[.hooks // {} | to_entries[] | .value[]?.hooks[]? | select((.command // "") | test("dangi-hook|hcat-gate"))] | length' "$SYMD/target.json")"
check "f2: statusLine fix landed in the target" "headroom-statusline.sh" \
  "$(jq -r '.statusLine.command // empty' "$SYMD/target.json")"
check_eq "f7b: doctor-written statusLine has refreshInterval 1" "1" \
  "$(jq -r '.statusLine.refreshInterval // empty' "$SYMD/target.json")"
check "f5: stale-copy deletion notes project-level settings caveat" "project-level" "$out"

# F3: broken exported HCAT_PYTHON — --fix must FAIL and refuse to bootstrap
BADIMP="$REVD/badimp"; mkdir -p "$BADIMP"
printf '#!/bin/sh\nexit 1\n' > "$BADIMP/python"; chmod +x "$BADIMP/python"
F3="$REVD/f3"; mkdir -p "$F3/cd"
doc_settings_wired "$F3/cd" > "$F3/settings.json"
pyc0=$(wc -l < "$STUB/python3.calls" | tr -d ' ')
out=$(HCAT_PYTHON="$BADIMP/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F3/settings.json" \
      DOCTOR_CLAUDE_DIR="$F3/cd" DOCTOR_VENV_DIR="$REVD/f3venv" bash "$DOCTOR" --fix 2>&1); rc=$?
check "f3: broken HCAT_PYTHON reported as FAIL" "HCAT_PYTHON is set but broken" "$out"
check_absent "f3: no bootstrap claim" "engine bootstrapped" "$out"
if [ "$rc" -ne 0 ]; then
  echo "ok - f3: --fix exits nonzero"; PASS=$((PASS+1))
else
  echo "FAIL - f3: --fix exits nonzero (got rc=0)"; FAIL=$((FAIL+1))
fi
if [ ! -e "$REVD/f3venv" ]; then
  echo "ok - f3: no venv created"; PASS=$((PASS+1))
else
  echo "FAIL - f3: no venv created ($REVD/f3venv exists)"; FAIL=$((FAIL+1))
fi
cp "$F3/settings.json" "$REVD/f3.settings.run1"
out2=$(HCAT_PYTHON="$BADIMP/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F3/settings.json" \
       DOCTOR_CLAUDE_DIR="$F3/cd" DOCTOR_VENV_DIR="$REVD/f3venv" bash "$DOCTOR" --fix 2>&1)
check "f3: second --fix FAILs identically" "HCAT_PYTHON is set but broken" "$out2"
if [ ! -e "$REVD/f3venv" ] && cmp -s "$F3/settings.json" "$REVD/f3.settings.run1"; then
  echo "ok - f3: state byte-identical after two --fix runs"; PASS=$((PASS+1))
else
  echo "FAIL - f3: state byte-identical after two --fix runs"; FAIL=$((FAIL+1))
fi
check_eq "f3: python3 never invoked" "$pyc0" "$(wc -l < "$STUB/python3.calls" | tr -d ' ')"

# F4: corrupt settings.json — FAIL, and all settings-mutating fixes refuse
for shape in trailing twodoc; do
  C4="$REVD/cor-$shape"; mkdir -p "$C4/cd"
  if [ "$shape" = trailing ]; then
    printf '{"statusLine":{"type":"command","command":"x"}} trailing-garbage\n' > "$C4/settings.json"
  else
    printf '{}\n{"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"bash ~/.claude/dangi-hook.sh"}]}]}}\n' > "$C4/settings.json"
  fi
  cp "$C4/settings.json" "$C4/settings.orig"
  out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$C4/settings.json" \
        DOCTOR_CLAUDE_DIR="$C4/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix 2>&1); rc=$?
  check "f4 ($shape): parse failure is a FAIL" "not a single valid JSON document" "$out"
  check_absent "f4 ($shape): no false legacy ok" "no legacy hook registrations" "$out"
  check_absent "f4 ($shape): nothing reported fixed" "fixed" "$out"
  if cmp -s "$C4/settings.json" "$C4/settings.orig"; then
    echo "ok - f4 ($shape): settings.json untouched by --fix"; PASS=$((PASS+1))
  else
    echo "FAIL - f4 ($shape): settings.json untouched by --fix"; FAIL=$((FAIL+1))
  fi
  if [ "$rc" -ne 0 ]; then
    echo "ok - f4 ($shape): exit nonzero"; PASS=$((PASS+1))
  else
    echo "FAIL - f4 ($shape): exit nonzero (got rc=0)"; FAIL=$((FAIL+1))
  fi
done

# F5 (v2.7 semantics): legacy hooks in settings.local.json are now FIXABLE —
# read-only reports them, --fix removes them (with backup) and may then also
# delete the stale copies they referenced.
F5="$REVD/f5"; mkdir -p "$F5/cd"
touch "$F5/cd/dangi-hook.sh" "$F5/cd/hcat"
doc_settings_wired "$F5/cd" > "$F5/settings.json"
doc_settings_legacy "$F5/cd" > "$F5/settings.local.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F5/settings.json" \
      DOCTOR_CLAUDE_DIR="$F5/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check "f5: read-only reports local legacy as fixable" "fixable - legacy hooks in settings.local.json" "$out"
check "f5: read-only keeps stale copies" "stale copies" "$out"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F5/settings.json" \
      DOCTOR_CLAUDE_DIR="$F5/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix 2>&1)
check "f5: --fix cleans settings.local.json" "removed 2 legacy hook entries from settings.local.json" "$out"
check_eq "f5: local legacy entries gone" "0" \
  "$(jq '[.hooks // {} | to_entries[] | .value[]?.hooks[]? | select((.command // "") | test("dangi-hook|hcat-gate"))] | length' "$F5/settings.local.json")"
check "f5: unrelated hook preserved" "unrelated-hook" "$(cat "$F5/settings.local.json")"
if ls "$F5"/settings.local.json.bak.* >/dev/null 2>&1; then
  echo "ok - f5: settings.local.json backup written"; PASS=$((PASS+1))
else
  echo "FAIL - f5: settings.local.json backup written"; FAIL=$((FAIL+1))
fi
check "f5: stale copies removed after local fix" "removed stale copies" "$out"
if [ ! -e "$F5/cd/dangi-hook.sh" ] && [ ! -e "$F5/cd/hcat" ]; then
  echo "ok - f5: stale scripts deleted once nothing references them"; PASS=$((PASS+1))
else
  echo "FAIL - f5: stale scripts deleted once nothing references them"; FAIL=$((FAIL+1))
fi

# F6: Debian venv dead-end — half-created venv removed, actionable message
DEB="$REVD/deb"; mkdir -p "$DEB"
link_tool "$(command -v jq)" "$DEB/jq"
cat > "$DEB/python3" <<'EOF'
#!/bin/sh
if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
  mkdir -p "$3/bin"
  ln -s /bin/sh "$3/bin/python"
  echo "Error: ensurepip is not available (python3-venv missing)" >&2
  exit 1
fi
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$DEB/apt-get"
# shadow the rest of the bootstrap fallback order (python, py) so a real
# /usr/bin/python on the runner can't silently succeed where python3 -m venv
# didn't — same hazard the w4none fixture guards against.
printf '#!/bin/sh\nexit 1\n' > "$DEB/python"
printf '#!/bin/sh\nexit 1\n' > "$DEB/py"
chmod +x "$DEB/python3" "$DEB/apt-get" "$DEB/python" "$DEB/py"
F6="$REVD/f6"; mkdir -p "$F6/cd"
doc_settings_wired "$F6/cd" > "$F6/settings.json"
out=$(env -u HCAT_PYTHON PATH="$DEB:/usr/bin:/bin" DOCTOR_SETTINGS="$F6/settings.json" \
      DOCTOR_CLAUDE_DIR="$F6/cd" DOCTOR_VENV_DIR="$REVD/f6venv" bash "$DOCTOR" --fix 2>&1)
check "f6: failure message suggests python3-venv" "python3-venv" "$out"
check "f6: bootstrap failure is a FAIL" "FAIL" "$out"
if [ ! -e "$REVD/f6venv" ]; then
  echo "ok - f6: half-created venv removed"; PASS=$((PASS+1))
else
  echo "FAIL - f6: half-created venv removed ($REVD/f6venv remains)"; FAIL=$((FAIL+1))
fi
# ...but a venv dir the doctor did NOT create must never be deleted
mkdir -p "$REVD/f6bvenv"; touch "$REVD/f6bvenv/keep-me"
env -u HCAT_PYTHON PATH="$DEB:/usr/bin:/bin" DOCTOR_SETTINGS="$F6/settings.json" \
    DOCTOR_CLAUDE_DIR="$F6/cd" DOCTOR_VENV_DIR="$REVD/f6bvenv" bash "$DOCTOR" --fix >/dev/null 2>&1
if [ -e "$REVD/f6bvenv/keep-me" ]; then
  echo "ok - f6: pre-existing venv dir preserved on failure"; PASS=$((PASS+1))
else
  echo "FAIL - f6: pre-existing venv dir preserved on failure"; FAIL=$((FAIL+1))
fi

# F7a: merge-aware statusLine fix — custom command preserved and chained
F7R="$REVD/f7r"; mkdir -p "$F7R/cd"
jq -n '{statusLine:{type:"command",command:"bash ~/my-line.sh"}}' > "$F7R/settings.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7R/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7R/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check "f7a: read-only reports custom statusLine as fixable" "fixable - statusLine" "$out"
F7="$REVD/f7"; mkdir -p "$F7/cd"
jq -n '{statusLine:{type:"command",command:"bash ~/my-line.sh"}}' > "$F7/settings.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix 2>&1)
check "f7a: fix reports a merge" "merged" "$out"
newcmd=$(jq -r '.statusLine.command' "$F7/settings.json")
check "f7a: custom command preserved in the chain" "my-line.sh" "$newcmd"
check "f7a: headroom badge appended" "headroom-statusline.sh" "$newcmd"
check "f7a: chained with the installer template" 'left=$(printf' "$newcmd"
check "f7a: original backed up" "bash ~/my-line.sh" \
      "$(jq -r '._headroomStatusLineBackup.command // empty' "$F7/settings.json")"
check_eq "f7a: merged entry has refreshInterval 1" "1" \
      "$(jq -r '.statusLine.refreshInterval // empty' "$F7/settings.json")"
cp "$F7/settings.json" "$REVD/f7.settings.run1"
out2=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7/settings.json" \
       DOCTOR_CLAUDE_DIR="$F7/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix 2>&1)
if cmp -s "$F7/settings.json" "$REVD/f7.settings.run1"; then
  echo "ok - f7a: second --fix run is idempotent"; PASS=$((PASS+1))
else
  echo "FAIL - f7a: second --fix run is idempotent"; FAIL=$((FAIL+1))
fi
check_absent "f7a: nothing fixable after the merge" "fixable" "$out2"

# F7c: stale ~/.claude statusline copy is detected and refreshed
F7C="$REVD/f7c"; mkdir -p "$F7C/cd"
doc_settings_wired "$F7C/cd" > "$F7C/settings.json"
printf '#!/bin/sh\n# stale old copy\n' > "$F7C/cd/headroom-statusline.sh"
chmod +x "$F7C/cd/headroom-statusline.sh"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7C/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7C/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check "f7c: stale statusline copy is fixable" "statusline copy" "$out"
check "f7c: reported as fixable" "fixable" "$out"
# F7d: the doctor validates the bundled .mcp.json
check "f7d: .mcp.json checked and healthy" ".mcp.json spawns \`headroom mcp serve\` by name" "$out"
HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7C/settings.json" \
  DOCTOR_CLAUDE_DIR="$F7C/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix >/dev/null 2>&1
if cmp -s "$F7C/cd/headroom-statusline.sh" "$ROOT/scripts/statusline.sh" && [ -x "$F7C/cd/headroom-statusline.sh" ]; then
  echo "ok - f7c: --fix refreshes the copy from the plugin"; PASS=$((PASS+1))
else
  echo "FAIL - f7c: --fix refreshes the copy from the plugin"; FAIL=$((FAIL+1))
fi

# F7e: the exact issue #2 shape — statusline copy is CURRENT but its lib/ deps
# are MISSING. The old doctor reported all-ok here while the badge was
# structurally stuck at "idle" showing zero. The dedicated check must flag it
# read-only, and --fix must provision attribution.jq + headroom-state.sh.
F7E="$REVD/f7e"; mkdir -p "$F7E/cd"
doc_settings_wired "$F7E/cd" > "$F7E/settings.json"
cp "$ROOT/scripts/statusline.sh" "$F7E/cd/headroom-statusline.sh"   # copy already current
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7E/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7E/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check "f7e: current copy, missing lib deps → fixable" "statusline lib deps missing/stale" "$out"
check "f7e: statusline copy itself still reported current" "statusline copy is current" "$out"
HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7E/settings.json" \
  DOCTOR_CLAUDE_DIR="$F7E/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix >/dev/null 2>&1
if cmp -s "$ROOT/scripts/lib/attribution.jq" "$F7E/cd/lib/attribution.jq" \
   && cmp -s "$ROOT/scripts/lib/headroom-state.sh" "$F7E/cd/lib/headroom-state.sh" \
   && cmp -s "$ROOT/scripts/lib/engine-resolve.sh" "$F7E/cd/lib/engine-resolve.sh"; then
  echo "ok - f7e: --fix provisions the missing lib deps (issue #2)"; PASS=$((PASS+1))
else
  echo "FAIL - f7e: --fix provisions the missing lib deps (issue #2)"; FAIL=$((FAIL+1))
fi

# F7f: dual-layout — statusline.sh resolves its deps from EITHER a lib/ subdir OR
# flat siblings next to the copy (see scripts/statusline.sh's resolution loop),
# and the v2.7 legacy full-manual installer provisions them FLAT. A healthy flat
# install must NOT be reported "missing/stale": that cry-wolf misleads the user
# and, via a spurious FIXABLE, blocks the ambient-health all-clear (block 9).
F7F="$REVD/f7f"; mkdir -p "$F7F/cd"
doc_settings_wired "$F7F/cd" > "$F7F/settings.json"
cp "$ROOT/scripts/statusline.sh" "$F7F/cd/headroom-statusline.sh"        # copy current
cp "$ROOT/scripts/lib/attribution.jq"    "$F7F/cd/attribution.jq"        # deps as FLAT siblings,
cp "$ROOT/scripts/lib/headroom-state.sh" "$F7F/cd/headroom-state.sh"     # not under lib/
cp "$ROOT/scripts/lib/engine-resolve.sh" "$F7F/cd/engine-resolve.sh"     # (v2.8 dep, same rule)
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7F/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7F/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check "f7f: flat-layout lib deps reported current" "statusline lib deps current" "$out"

# F7g: a stale lib/ dep must NOT be masked by a current flat sibling. statusline.sh
# loads lib/ by existence (content-blind) and never falls through, so a stale
# lib/attribution.jq shadows a current flat one — 7c must report it stale. An
# OR-of-matches check would wrongly green on the flat match; this is the red-green
# for the existence-first resolution fix.
F7G="$REVD/f7g"; mkdir -p "$F7G/cd/lib"
doc_settings_wired "$F7G/cd" > "$F7G/settings.json"
cp "$ROOT/scripts/statusline.sh" "$F7G/cd/headroom-statusline.sh"
printf '# stale\n' > "$F7G/cd/lib/attribution.jq"                 # lib/ attribution present but STALE
cp "$ROOT/scripts/lib/headroom-state.sh" "$F7G/cd/lib/"          # lib/ headroom-state current
cp "$ROOT/scripts/lib/attribution.jq"    "$F7G/cd/attribution.jq" # flat attribution current (would-be shadow)
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7G/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7G/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check        "f7g: the stale lib/ dep (attribution.jq) is the one flagged" "statusline lib deps missing/stale — attribution.jq" "$out"
check_absent "f7g: stale-shadowed install not greened"                     "statusline lib deps current"                        "$out"

# F7h: a current lib/ dep is authoritative even when a stale flat sibling exists —
# statusline.sh loads lib/ first, so 7c must stay "current" (guards against an
# over-correction that would AND-require every layout to match).
F7H="$REVD/f7h"; mkdir -p "$F7H/cd/lib"
doc_settings_wired "$F7H/cd" > "$F7H/settings.json"
cp "$ROOT/scripts/statusline.sh" "$F7H/cd/headroom-statusline.sh"
cp "$ROOT/scripts/lib/attribution.jq"    "$F7H/cd/lib/"          # lib/ deps current
cp "$ROOT/scripts/lib/headroom-state.sh" "$F7H/cd/lib/"
cp "$ROOT/scripts/lib/engine-resolve.sh" "$F7H/cd/lib/"
printf '# stale\n' > "$F7H/cd/attribution.jq"                    # stale flat sibling must be ignored
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7H/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7H/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check        "f7h: current lib/ deps stay current despite a stale flat sibling" "statusline lib deps current"       "$out"
check_absent "f7h: current lib/ not cried wolf over a stale flat sibling"        "statusline lib deps missing/stale" "$out"

# F7i: the flat-sibling branch must currency-check, not just test existence — a
# stale flat dep with no lib/ copy must still report "missing/stale" (guards a
# regression that accepts a flat sibling merely because it exists, silently
# reintroducing issue #2's zero-savings badge).
F7I="$REVD/f7i"; mkdir -p "$F7I/cd"
doc_settings_wired "$F7I/cd" > "$F7I/settings.json"
cp "$ROOT/scripts/statusline.sh" "$F7I/cd/headroom-statusline.sh"
printf '# stale\n' > "$F7I/cd/attribution.jq"                    # flat siblings present but STALE,
printf '# stale\n' > "$F7I/cd/headroom-state.sh"                 # and no lib/ copies at all
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7I/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7I/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check        "f7i: both stale flat deps named" "statusline lib deps missing/stale — attribution.jq headroom-state.sh" "$out"
check_absent "f7i: stale flat deps not greened" "statusline lib deps current"                                       "$out"

# F7j: wired-but-missing — settings.json points at headroom-statusline.sh but the
# script isn't on disk. check 7 must report this fixable (not a silent "wired" ok
# that lets block 9 clear the broken-badge flag); --fix must re-copy the script.
F7J="$REVD/f7j"; mkdir -p "$F7J/cd"
doc_settings_wired "$F7J/cd" > "$F7J/settings.json"              # wired, but NO script copied
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7J/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7J/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check        "f7j: wired-but-missing script reported fixable" "but the script is missing — --fix re-copies it" "$out"
check_absent "f7j: wired-but-missing not silently wired-ok"   "statusLine wired ("                              "$out"
HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7J/settings.json" \
  DOCTOR_CLAUDE_DIR="$F7J/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix >/dev/null 2>&1
if cmp -s "$ROOT/scripts/statusline.sh" "$F7J/cd/headroom-statusline.sh"; then
  echo "ok - f7j: --fix re-copies the missing statusline script"; PASS=$((PASS+1))
else
  echo "FAIL - f7j: --fix re-copies the missing statusline script"; FAIL=$((FAIL+1))
fi

# F7k: badge OUTCOME, not just the doctor's report string — pins statusline.sh's dep
# resolution against drift from doctor 7c (they are two implementations of the same
# lib/-then-flat rule). A copy WITHOUT its deps must degrade to idle (issue #2's
# symptom); a copy WITH them, under lib/ OR as flat siblings, must render real savings.
F7K="$REVD/f7k"; mkdir -p "$F7K/nolib" "$F7K/libdir/lib" "$F7K/flat"
cp "$ROOT/scripts/statusline.sh" "$F7K/nolib/headroom-statusline.sh"          # no deps at all
cp "$ROOT/scripts/statusline.sh" "$F7K/libdir/headroom-statusline.sh"
cp "$ROOT/scripts/lib/attribution.jq" "$ROOT/scripts/lib/headroom-state.sh" "$F7K/libdir/lib/"
cp "$ROOT/scripts/statusline.sh" "$F7K/flat/headroom-statusline.sh"
cp "$ROOT/scripts/lib/attribution.jq" "$ROOT/scripts/lib/headroom-state.sh" "$F7K/flat/"
out=$(badge_at "$F7K/nolib/headroom-statusline.sh" "$TMP/t_active.jsonl" claude-opus-4-8 sess-f7k-nolib "$F7K/st-nolib")
check        "f7k: lib-less copy degrades to idle (issue #2 symptom)" "not compressing yet" "$out"
check_absent "f7k: lib-less copy shows no savings"                    "~500 tok"            "$out"
out=$(badge_at "$F7K/libdir/headroom-statusline.sh" "$TMP/t_active.jsonl" claude-opus-4-8 sess-f7k-lib "$F7K/st-lib")
check "f7k: deps under lib/ render real savings"       "~500 tok" "$out"
out=$(badge_at "$F7K/flat/headroom-statusline.sh" "$TMP/t_active.jsonl" claude-opus-4-8 sess-f7k-flat "$F7K/st-flat")
check "f7k: deps as flat siblings render real savings" "~500 tok" "$out"

# F7l: block 9 must KEEP a recorded failure whenever the run is not clean — including
# when the ONLY issue is a FIXABLE (wired-but-missing script) and FAILED=0. Guards a
# regression that gates block 9 on FAILED alone: it would clear the broken-badge flag
# while the statusline script is still absent (the silent pass F7j's check-7 fix
# prevents). Needs a real engine so the smoke passes (FAILED=0), leaving the
# wired-but-missing FIXABLE as the sole non-ok.
if [ -n "$HEADROOM_PY" ]; then
  F7L="$REVD/f7l"; mkdir -p "$F7L/cd" "$F7L/state"
  doc_settings_wired "$F7L/cd" > "$F7L/settings.json"              # wired, script absent -> FIXABLE
  printf 'engine boom\n' > "$F7L/state/last-error"                # seed a recorded failure
  out=$(HCAT_PYTHON="$HEADROOM_PY" STATE_DIR="$F7L/state" HEADROOM_STATE_DIR="$F7L/state" \
        DOCTOR_SETTINGS="$F7L/settings.json" DOCTOR_CLAUDE_DIR="$F7L/cd" \
        DOCTOR_VENV_DIR="$DOCD/none" bash "$DOCTOR" 2>&1)
  check "f7l: block 9 keeps the failure state while a fixable remains" "recorded failure state kept" "$out"
  if [ -f "$F7L/state/last-error" ]; then
    echo "ok - f7l: last-error preserved (badge stays broken until a clean run)"; PASS=$((PASS+1))
  else
    echo "FAIL - f7l: last-error preserved (badge stays broken until a clean run)"; FAIL=$((FAIL+1))
  fi
else
  skip_note "f7l block-9 keep test (headroom venv not found)"
fi

# F7m: a headroom-statusline.sh wired at a NON-canonical (hand-edited) path is the
# user's to own — check 7 must trust it (ok), not cry wolf or drop an orphan copy at
# $CLAUDE_DIR. Guards the canonical-path guard; fails against a hardcoded
# $CLAUDE_DIR existence check that ignores where the command actually points.
# Deps are provisioned too so this is a genuinely fully-healthy custom install
# end to end — 7b/7c now also follow the custom path (finding #2's fix) and
# would otherwise FAIL here, which this fixture's own assertions never checked
# either way; asserting "current" pins that a healthy custom install is
# doctor-clean, not just that check 7 alone trusts it. (An UNhealthy custom
# install, deps missing/stale, is covered separately by F7p.)
F7M="$REVD/f7m"; mkdir -p "$F7M/cd/lib" "$F7M/custom/lib"
cp "$ROOT/scripts/statusline.sh" "$F7M/custom/headroom-statusline.sh"          # wired HERE, present
cp "$ROOT/scripts/lib/attribution.jq" "$ROOT/scripts/lib/headroom-state.sh" \
   "$ROOT/scripts/lib/engine-resolve.sh" "$F7M/custom/lib/"
# engine-resolve.sh is NOT a badge dep and is never demanded next to a custom
# copy (the doctor refuses to write there, so that FAIL could never be cleared —
# review #13): it is checked under $CLAUDE_DIR, so a fully-healthy custom install
# has it there too.
cp "$ROOT/scripts/lib/engine-resolve.sh" "$F7M/cd/lib/"
jq -n --arg c "$F7M/custom/headroom-statusline.sh" \
  '{statusLine:{type:"command",command:("bash \"" + $c + "\"")}}' > "$F7M/settings.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7M/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7M/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check        "f7m: custom-path statusLine trusted (ok, not cried wolf)" "statusLine wired ("        "$out"
check_absent "f7m: custom-path statusLine not flagged fixable"          "but the script is missing" "$out"
check        "f7m: 7b also reports the custom copy current, not just check 7" "statusline copy is current" "$out"
check_absent "f7m: 7b doesn't cry wolf over a current custom copy either"     "is stale"                    "$out"
check        "f7m: a fully-healthy custom install is doctor-clean end to end (7c too)" "statusline lib deps current" "$out"
check_absent "f7m: a fully-healthy custom install isn't cried wolf over by 7c"         "missing/stale"              "$out"
check        "f7m: the shared engine resolver is reported from \$CLAUDE_DIR, not the custom dir" \
             "shared engine resolver current ($F7M/cd/lib/engine-resolve.sh)" "$out"
HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7M/settings.json" \
  DOCTOR_CLAUDE_DIR="$F7M/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix >/dev/null 2>&1
if [ ! -f "$F7M/cd/headroom-statusline.sh" ]; then
  echo "ok - f7m: --fix drops no orphan copy at the canonical path"; PASS=$((PASS+1))
else
  echo "FAIL - f7m: --fix drops no orphan copy at the canonical path"; FAIL=$((FAIL+1))
fi

# F7n: the wired-but-missing guard must catch ANY spelling of a missing script,
# not just the literal $HOME-expanded canonical string. Two respellings that
# previously fell through to a trust-only "statusLine wired" ok with the script
# absent (letting block 9 clear a recorded failure — the same silent pass the
# canonical guard closes): (a) the quoted-tilde canonical form README shows for
# hand wiring — canonical once ~ is expanded, so it takes the fixable/re-copy
# branch; (b) a foreign-home absolute path synced from another machine's
# dotfiles — not ours to re-copy (no-orphan policy), so it is a FAIL, not ok.
F7N="$REVD/f7n"; mkdir -p "$F7N/home/.claude"
printf '%s\n' '{"statusLine":{"type":"command","command":"bash \"~/.claude/headroom-statusline.sh\"","refreshInterval":1}}' > "$F7N/settings.json"
out=$(HOME="$F7N/home" HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7N/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7N/home/.claude" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check        "f7n: tilde-spelled canonical wiring with missing script is fixable" "but the script is missing" "$out"
check_absent "f7n: tilde-spelled missing wiring not trusted as ok"                "statusLine wired ("        "$out"
HOME="$F7N/home" HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7N/settings.json" \
  DOCTOR_CLAUDE_DIR="$F7N/home/.claude" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix >/dev/null 2>&1
if cmp -s "$ROOT/scripts/statusline.sh" "$F7N/home/.claude/headroom-statusline.sh"; then
  echo "ok - f7n: --fix re-copies the script the tilde wiring points at"; PASS=$((PASS+1))
else
  echo "FAIL - f7n: --fix re-copies the script the tilde wiring points at"; FAIL=$((FAIL+1))
fi
F7NB="$REVD/f7n-b"; mkdir -p "$F7NB/cd"
printf '%s\n' '{"statusLine":{"type":"command","command":"bash \"/nonexistent-olduser/.claude/headroom-statusline.sh\"","refreshInterval":1}}' > "$F7NB/settings.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7NB/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7NB/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check        "f7n: foreign-home wiring with missing script is a FAIL" "no such file exists" "$out"
check_absent "f7n: foreign-home missing wiring not trusted as ok"     "statusLine wired ("  "$out"
HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7NB/settings.json" \
  DOCTOR_CLAUDE_DIR="$F7NB/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix >/dev/null 2>&1
if [ ! -f "$F7NB/cd/headroom-statusline.sh" ]; then
  echo "ok - f7n: --fix drops no orphan for a foreign-home wiring"; PASS=$((PASS+1))
else
  echo "FAIL - f7n: --fix drops no orphan for a foreign-home wiring"; FAIL=$((FAIL+1))
fi

# F7o: F7n proved --fix copies the file for a tilde-spelled canonical wiring,
# but never proved the badge would actually WORK afterward. Bash never
# tilde-expands a ~ inside double quotes, so `bash "~/.claude/headroom-statusline.sh"`
# (the exact form the pre-fix README showed for hand wiring) never resolves at
# render time — copying the file alone leaves the command permanently broken.
# --fix must also rewrite statusLine.command to the resolved absolute path.
F7O="$REVD/f7o"; mkdir -p "$F7O/home/.claude"
printf '%s\n' '{"statusLine":{"type":"command","command":"bash \"~/.claude/headroom-statusline.sh\"","refreshInterval":1}}' > "$F7O/settings.json"
HOME="$F7O/home" HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7O/settings.json" \
  DOCTOR_CLAUDE_DIR="$F7O/home/.claude" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix >/dev/null 2>&1
F7O_CMD=$(jq -r '.statusLine.command' "$F7O/settings.json")
check_absent "f7o: --fix rewrites away the unexpandable quoted tilde" '~' "$F7O_CMD"
check "f7o: --fix points the command at the resolved absolute path" "$F7O/home/.claude/headroom-statusline.sh" "$F7O_CMD"
if HOME="$F7O/home" sh -c "$F7O_CMD" < /dev/null >/dev/null 2>"$F7O/run.err"; then
  echo "ok - f7o: the rewired command actually runs (proves the badge would render, not just that the file exists)"; PASS=$((PASS+1))
else
  echo "FAIL - f7o: the rewired command actually runs (proves the badge would render, not just that the file exists)"; FAIL=$((FAIL+1))
  cat "$F7O/run.err" >&2
fi
F7O="$REVD/f7o-lit"; mkdir -p "$F7O/cd"
printf '%s\n' "{\"statusLine\":{\"type\":\"command\",\"command\":\"bash \\\"$F7O/cd/headroom-statusline.sh\\\"\",\"refreshInterval\":1}}" > "$F7O/settings.json"
HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7O/settings.json" \
  DOCTOR_CLAUDE_DIR="$F7O/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix >/dev/null 2>&1
check_eq "f7o: an already-literal canonical wiring is left untouched (no gratuitous settings.json backup)" "0" \
         "$(ls "$F7O"/settings.json.bak.* 2>/dev/null | wc -l | tr -d ' ')"

# F7p: check 7 was taught to trust a doctor-blessed custom-path statusLine
# install (F7m), but 7b/7c both hardcoded $CLAUDE_DIR for currency checks —
# a custom install's stale/missing script or deps went undetected forever
# (`skip`, not FAILED/FIXABLE), so a broken custom-path badge cleared any
# recorded failure just the same as a healthy one (issue #2's symptom, for
# the custom-path population). 7b/7c must now follow whatever path check 7
# actually validated, and must FAIL (not fixable — no-orphan policy) rather
# than silently skip.
F7P="$REVD/f7p"; mkdir -p "$F7P/cd" "$F7P/custom"
cp "$ROOT/scripts/statusline.sh" "$F7P/custom/headroom-statusline.sh"   # current script, deps never provisioned
jq -n --arg c "$F7P/custom/headroom-statusline.sh" \
  '{statusLine:{type:"command",command:("bash \"" + $c + "\"")}}' > "$F7P/settings.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7P/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7P/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check        "f7p: custom-path install with missing deps is a FAIL, not silently skipped" \
             "statusline lib deps at $F7P/custom missing/stale" "$out"
check_absent "f7p: custom-path missing deps not skipped"        "statusline lib deps (no"  "$out"
fix_out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7P/settings.json" \
  DOCTOR_CLAUDE_DIR="$F7P/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix 2>&1)
check_absent "f7p: --fix will not write into a custom-path install (no-orphan policy)" \
             "installed statusline lib deps" "$fix_out"
if [ ! -f "$F7P/custom/lib/attribution.jq" ] && [ ! -f "$F7P/cd/lib/attribution.jq" ]; then
  echo "ok - f7p: --fix drops no dep copies anywhere for a custom-path install"; PASS=$((PASS+1))
else
  echo "FAIL - f7p: --fix drops no dep copies anywhere for a custom-path install"; FAIL=$((FAIL+1))
fi
# healthy custom install (deps present and current) must report ok, not skip
F7P2="$REVD/f7p2"; mkdir -p "$F7P2/cd" "$F7P2/custom/lib"
cp "$ROOT/scripts/statusline.sh" "$F7P2/custom/headroom-statusline.sh"
cp "$ROOT/scripts/lib/attribution.jq" "$ROOT/scripts/lib/headroom-state.sh" \
   "$ROOT/scripts/lib/engine-resolve.sh" "$F7P2/custom/lib/"
jq -n --arg c "$F7P2/custom/headroom-statusline.sh" \
  '{statusLine:{type:"command",command:("bash \"" + $c + "\"")}}' > "$F7P2/settings.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7P2/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7P2/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check "f7p: a healthy, fully-provisioned custom-path install now reports current, not skip" \
      "statusline lib deps current" "$out"

# F7q: the path-token extraction must operate on whole quote/space-delimited
# tokens, structurally anchored at both ends, not a substring regex with no
# token boundary. Two prior failure directions from the unanchored version:
# (a) front misalignment — grep's leftmost-longest match on a variable-prefixed
# wiring like `bash "$HOME/.claude/headroom-statusline.sh"` starts at the '/'
# before .claude (the first '/' in the string), extracting the bogus
# `/.claude/headroom-statusline.sh` and false-FAILing a perfectly healthy
# install; (b) suffix truncation — a token like `...headroom-statusline.sh.bak`
# gets matched only up to the fixed `.sh` suffix, so if a canonical copy also
# happens to exist, check 7 verifies the WRONG file and never notices the real
# (suffixed) one is unparseable — it must fall through to the documented
# no-extractable-token trust rule instead of fabricating a fixable/FAIL verdict
# against a candidate nobody actually wired.
F7Q="$REVD/f7q"; mkdir -p "$F7Q/cd"
cp "$ROOT/scripts/statusline.sh" "$F7Q/cd/headroom-statusline.sh"   # healthy, current, real install
printf '%s\n' '{"statusLine":{"type":"command","command":"bash \"$HOME/.claude/headroom-statusline.sh\"","refreshInterval":1}}' > "$F7Q/settings.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7Q/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7Q/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check_absent "f7q: a \$HOME-variable-prefixed wiring is not false-FAILed by a misaligned extraction" \
             "no such file exists" "$out"

F7Q2="$REVD/f7q2"; mkdir -p "$F7Q2/cd"
# no canonical copy on disk at all — only the file the command actually names
printf '%s\n' '{"statusLine":{"type":"command","command":"bash \"~/.claude/headroom-statusline.sh.bak\"","refreshInterval":1}}' > "$F7Q2/settings.json"
# $FENG on PATH keeps check 2b "ok" (HCAT_PYTHON is authoritative here, so this
# can't change which statusLine-wiring candidate check 7 resolves) — this
# fixture asserts no "fixable" anywhere in the output (issue #9)
out=$(HOME="$F7Q2" HCAT_PYTHON="$FENG/python" PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7Q2/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7Q2/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check_absent "f7q: a suffixed filename is not truncated into a fabricated fixable claim about the canonical name" \
             "fixable" "$out"
check_absent "f7q: a suffixed filename is not truncated into a fabricated FAIL about the canonical name" \
             "but no such file exists" "$out"

# F7r: the present-file short-circuit must not trust a quoted-tilde wiring
# just because the canonical file happens to already exist on disk (e.g. from
# an earlier, separate install step) -- bash never expands a ~ inside double
# quotes, so the wired command can never resolve it regardless of whether the
# file is there. F7o proved the fix for the file-MISSING case; this proves it
# for the file-ALREADY-PRESENT case, which the present-file short-circuit
# (doctor.sh's `sl_present -eq 1` branch) previously trusted unconditionally.
F7R="$REVD/f7r"; mkdir -p "$F7R/home/.claude"
cp "$ROOT/scripts/statusline.sh" "$F7R/home/.claude/headroom-statusline.sh"   # already present, current
printf '%s\n' '{"statusLine":{"type":"command","command":"bash \"~/.claude/headroom-statusline.sh\"","refreshInterval":1}}' > "$F7R/settings.json"
out=$(HOME="$F7R/home" HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7R/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7R/home/.claude" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check_absent "f7r: an unexpandable quoted-tilde wiring is not trusted ok just because the file already exists" \
             "statusLine wired (" "$out"
check "f7r: it is reported fixable instead, naming why" "can never resolve" "$out"
HOME="$F7R/home" HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7R/settings.json" \
  DOCTOR_CLAUDE_DIR="$F7R/home/.claude" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix >/dev/null 2>&1
F7R_CMD=$(jq -r '.statusLine.command' "$F7R/settings.json")
check_absent "f7r: --fix rewrites away the tilde even though the script was already present" '~' "$F7R_CMD"
if HOME="$F7R/home" sh -c "$F7R_CMD" < /dev/null >/dev/null 2>"$F7R/run.err"; then
  echo "ok - f7r: the rewired command actually runs"; PASS=$((PASS+1))
else
  echo "FAIL - f7r: the rewired command actually runs"; FAIL=$((FAIL+1))
  cat "$F7R/run.err" >&2
fi
check_eq "f7r: exactly one settings.json backup written" "1" \
         "$(ls "$F7R"/settings.json.bak.* 2>/dev/null | wc -l | tr -d ' ')"

# F7s: settings.json's own backup must gate the destructive statusLine.command
# rewrite the same way .mcp.json's does (F8c) -- a swallowed backup failure
# followed by a rewrite would claim a backup that was never created.
if [ "$(id -u)" -ne 0 ]; then
  F7S="$REVD/f7s"; mkdir -p "$F7S/home/.claude" "$F7S/settingsdir"
  cp "$ROOT/scripts/statusline.sh" "$F7S/home/.claude/headroom-statusline.sh"   # already present, respelled wiring
  printf '%s\n' '{"statusLine":{"type":"command","command":"bash \"~/.claude/headroom-statusline.sh\"","refreshInterval":1}}' > "$F7S/settingsdir/settings.json"
  chmod 666 "$F7S/settingsdir/settings.json"   # the file itself stays writable in place
  chmod 555 "$F7S/settingsdir"                 # but the directory cannot gain new entries (no backup possible)
  out=$(HOME="$F7S/home" HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7S/settingsdir/settings.json" \
        DOCTOR_CLAUDE_DIR="$F7S/home/.claude" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix 2>&1)
  chmod 755 "$F7S/settingsdir"                 # restore before any cleanup/further use
  check "f7s: a settings.json backup failure refuses the statusLine.command rewrite" "could not back up settings.json" "$out"
  check_eq "f7s: the command is left untouched when the backup fails" \
           'bash "~/.claude/headroom-statusline.sh"' \
           "$(jq -r '.statusLine.command' "$F7S/settingsdir/settings.json")"
else
  skip_note "f7s: settings.json backup-failure guard (running as root, permission bits bypassed)"
fi

# F7t: a present token from one candidate must not mask a co-occurring
# missing signal from a DIFFERENT candidate token in the same statusLine
# command (e.g. a shell fallback chain: try a custom path, else canonical).
# The present-file short-circuit only ever needs to look at the FIRST
# resolvable token to wrongly declare victory; the second, missing, canonical
# token must still be surfaced.
F7T="$REVD/f7t"; mkdir -p "$F7T/cd" "$F7T/custom"
cp "$ROOT/scripts/statusline.sh" "$F7T/custom/headroom-statusline.sh"   # present, healthy, custom path
jq -n --arg cust "$F7T/custom/headroom-statusline.sh" --arg canon "$F7T/cd/headroom-statusline.sh" \
  '{statusLine:{type:"command",command:("bash \"" + $cust + "\" || bash \"" + $canon + "\"")}}' > "$F7T/settings.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7T/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7T/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check_absent "f7t: a present custom token doesn't mask a co-occurring missing canonical token" \
             "statusLine wired (" "$out"
check "f7t: the missing canonical token is still surfaced as fixable" \
      "but the script is missing — --fix re-copies it" "$out"

# F7u: settings.local.json's OWN legacy-hook removal must refuse to proceed
# when its OWN backup fails, mirroring the primary settings.json / .mcp.json
# guards (F7s/F8c) -- previously this call site swallowed the cp failure. The
# main settings.json is deliberately clean here so only the local-file path
# is exercised (that one was already fixed in an earlier round).
if [ "$(id -u)" -ne 0 ]; then
  F7U="$REVD/f7u"; mkdir -p "$F7U/cd" "$F7U/settingsdir"
  printf '{}\n' > "$F7U/settingsdir/settings.json"                          # main settings.json: clean
  doc_settings_legacy "$F7U/cd" > "$F7U/settingsdir/settings.local.json"    # settings.local.json: has the legacy hooks
  chmod 666 "$F7U/settingsdir/settings.local.json"
  chmod 555 "$F7U/settingsdir"
  out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7U/settingsdir/settings.json" \
        DOCTOR_CLAUDE_DIR="$F7U/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix 2>&1)
  chmod 755 "$F7U/settingsdir"
  check "f7u: settings.local.json legacy-hook removal backup failure refuses the rewrite" \
        "could not back up settings.local.json before rewriting it" "$out"
  check "f7u: settings.local.json's legacy hook entries survive when the backup fails" \
        "dangi-hook.sh" "$(cat "$F7U/settingsdir/settings.local.json")"
else
  skip_note "f7u: settings.local.json backup-failure guard (running as root, permission bits bypassed)"
fi

# F7v: wiring statusLine for the first time (no prior statusLine key at all)
# must also refuse to proceed -- including the lib-dep/price-table copies --
# when its own settings.json backup fails, not just the two respelled-wiring
# and legacy-hook paths already covered.
if [ "$(id -u)" -ne 0 ]; then
  F7V="$REVD/f7v"; mkdir -p "$F7V/cd" "$F7V/settingsdir"
  printf '{}\n' > "$F7V/settingsdir/settings.json"
  chmod 666 "$F7V/settingsdir/settings.json"
  chmod 555 "$F7V/settingsdir"
  out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7V/settingsdir/settings.json" \
        DOCTOR_CLAUDE_DIR="$F7V/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix 2>&1)
  chmod 755 "$F7V/settingsdir"
  check "f7v: fresh statusLine-wire backup failure refuses the rewrite" \
        "could not back up settings.json before wiring the statusLine" "$out"
  if [ ! -f "$F7V/cd/headroom-statusline.sh" ]; then
    echo "ok - f7v: no orphan statusline.sh copy is dropped when the backup fails"; PASS=$((PASS+1))
  else
    echo "FAIL - f7v: no orphan statusline.sh copy is dropped when the backup fails"; FAIL=$((FAIL+1))
  fi
else
  skip_note "f7v: fresh-wire backup-failure guard (running as root, permission bits bypassed)"
fi

# F7w: a custom-path install whose SCRIPT itself (not just its lib deps) is
# stale must be a FAIL (7b), not silently trusted -- and --fix must leave it
# untouched (no-orphan policy: a custom path is the user's own to update).
F7W="$REVD/f7w"; mkdir -p "$F7W/cd" "$F7W/custom"
printf '#!/usr/bin/env bash\necho stale\n' > "$F7W/custom/headroom-statusline.sh"
chmod +x "$F7W/custom/headroom-statusline.sh"
jq -n --arg c "$F7W/custom/headroom-statusline.sh" \
  '{statusLine:{type:"command",command:("bash \"" + $c + "\"")}}' > "$F7W/settings.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7W/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7W/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check        "f7w: a stale custom-path script is a FAIL (7b), not silently trusted" \
             "statusline copy at $F7W/custom/headroom-statusline.sh is stale" "$out"
check_absent "f7w: a stale custom script isn't cried-wolf as current" \
             "statusline copy is current" "$out"
HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7W/settings.json" \
  DOCTOR_CLAUDE_DIR="$F7W/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix >/dev/null 2>&1
if printf '#!/usr/bin/env bash\necho stale\n' | cmp -s - "$F7W/custom/headroom-statusline.sh"; then
  echo "ok - f7w: --fix leaves the stale custom script untouched (no-orphan policy)"; PASS=$((PASS+1))
else
  echo "FAIL - f7w: --fix leaves the stale custom script untouched (no-orphan policy)"; FAIL=$((FAIL+1))
fi

# F7x: the settings.json command rewrite for a respelled canonical wiring must
# not also mangle an unrelated SIBLING token that merely shares its prefix
# (e.g. a coexisting ...headroom-statusline.sh.bak reference elsewhere in the
# same command) -- an unbounded global substring replace would corrupt it too.
F7X="$REVD/f7x"; mkdir -p "$F7X/home/.claude"
printf '%s\n' '{"statusLine":{"type":"command","command":"bash \"~/.claude/headroom-statusline.sh\" ; bash \"~/.claude/headroom-statusline.sh.bak\"","refreshInterval":1}}' > "$F7X/settings.json"
HOME="$F7X/home" HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7X/settings.json" \
  DOCTOR_CLAUDE_DIR="$F7X/home/.claude" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix >/dev/null 2>&1
F7X_CMD=$(jq -r '.statusLine.command' "$F7X/settings.json")
check "f7x: the respelled token is rewritten to an absolute path" \
      "bash \"$F7X/home/.claude/headroom-statusline.sh\"" "$F7X_CMD"
check "f7x: an unrelated sibling token sharing the same prefix is left untouched" \
      'bash "~/.claude/headroom-statusline.sh.bak"' "$F7X_CMD"

# F7y: a SINGLE-quoted respelled wiring (bash '~/...') is just as unexpandable
# at spawn time as a double-quoted one (bash never expands a ~ inside EITHER
# quote style), but the extraction loop treats both quote characters as
# equally valid token delimiters -- so detection and the eventual rewrite
# must track which one actually wraps the token, not assume double quotes.
# Without this, the rewrite pattern silently fails to match, sl_new_cmd stays
# byte-identical to sl, and doctor would falsely report "fixed" while writing
# nothing -- violating the file's own "a second --fix run changes nothing"
# idempotency claim (it would in fact never converge).
F7Y="$REVD/f7y"; mkdir -p "$F7Y/home/.claude"
cp "$ROOT/scripts/statusline.sh" "$F7Y/home/.claude/headroom-statusline.sh"   # already present
printf "%s\n" '{"statusLine":{"type":"command","command":"bash '"'"'~/.claude/headroom-statusline.sh'"'"'","refreshInterval":1}}' > "$F7Y/settings.json"
out=$(HOME="$F7Y/home" HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7Y/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7Y/home/.claude" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check_absent "f7y: a single-quoted unexpandable wiring is not trusted ok just because the file exists" \
             "statusLine wired (" "$out"
HOME="$F7Y/home" HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7Y/settings.json" \
  DOCTOR_CLAUDE_DIR="$F7Y/home/.claude" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix >/dev/null 2>&1
F7Y_CMD=$(jq -r '.statusLine.command' "$F7Y/settings.json")
check_absent "f7y: --fix actually changes the single-quoted command (not a silent no-op)" \
             '~' "$F7Y_CMD"
check "f7y: the single-quote style is preserved in the rewritten command" \
      "bash '$F7Y/home/.claude/headroom-statusline.sh'" "$F7Y_CMD"
if HOME="$F7Y/home" sh -c "$F7Y_CMD" < /dev/null >/dev/null 2>"$F7Y/run.err"; then
  echo "ok - f7y: the rewired single-quoted command actually runs"; PASS=$((PASS+1))
else
  echo "FAIL - f7y: the rewired single-quoted command actually runs"; FAIL=$((FAIL+1))
  cat "$F7Y/run.err" >&2
fi

# F7z: an UNQUOTED bare tilde (bash ~/...) DOES tilde-expand correctly at
# spawn time (quoting, not the tilde itself, is what blocks expansion) -- it
# must not be misclassified as an unexpandable respelling and rewritten (or
# flagged fixable) when it already works.
F7Z="$REVD/f7z"; mkdir -p "$F7Z/home/.claude"
cp "$ROOT/scripts/statusline.sh" "$F7Z/home/.claude/headroom-statusline.sh"
printf '%s\n' '{"statusLine":{"type":"command","command":"bash ~/.claude/headroom-statusline.sh","refreshInterval":1}}' > "$F7Z/settings.json"
out=$(HOME="$F7Z/home" HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7Z/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7Z/home/.claude" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check "f7z: a genuinely-working unquoted tilde wiring is trusted ok, not misdiagnosed" \
      "statusLine wired (" "$out"
check_absent "f7z: an unquoted tilde wiring is not flagged as unexpandable" \
             "can never resolve" "$out"
F7Z2="$REVD/f7z2"; mkdir -p "$F7Z2/home/.claude"
printf '%s\n' '{"statusLine":{"type":"command","command":"bash ~/.claude/headroom-statusline.sh","refreshInterval":1}}' > "$F7Z2/settings.json"
HOME="$F7Z2/home" HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7Z2/settings.json" \
  DOCTOR_CLAUDE_DIR="$F7Z2/home/.claude" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix >/dev/null 2>&1
check_eq "f7z: a missing unquoted-tilde wiring's file is copied without rewriting the (already-fine) command" \
         "bash ~/.claude/headroom-statusline.sh" \
         "$(jq -r '.statusLine.command' "$F7Z2/settings.json")"
if cmp -s "$ROOT/scripts/statusline.sh" "$F7Z2/home/.claude/headroom-statusline.sh"; then
  echo "ok - f7z: --fix still re-copies the missing script for an unquoted wiring"; PASS=$((PASS+1))
else
  echo "FAIL - f7z: --fix still re-copies the missing script for an unquoted wiring"; FAIL=$((FAIL+1))
fi

# F7aa: the PRIMARY settings.json's own legacy-hook removal must refuse to
# proceed when its own backup fails -- the code path was fixed several
# rounds ago (via backup_settings()) but never had a dedicated fixture; every
# sibling call site (F7s, F7u, .mcp.json's F8c) has one, this one didn't.
if [ "$(id -u)" -ne 0 ]; then
  F7AA="$REVD/f7aa"; mkdir -p "$F7AA/cd" "$F7AA/settingsdir"
  doc_settings_legacy "$F7AA/cd" > "$F7AA/settingsdir/settings.json"
  chmod 666 "$F7AA/settingsdir/settings.json"
  chmod 555 "$F7AA/settingsdir"
  out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7AA/settingsdir/settings.json" \
        DOCTOR_CLAUDE_DIR="$F7AA/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix 2>&1)
  chmod 755 "$F7AA/settingsdir"
  check "f7aa: primary settings.json legacy-hook removal backup failure refuses the rewrite" \
        "could not back up settings.json before rewriting it" "$out"
  check "f7aa: legacy hook entries survive when the backup fails" \
        "dangi-hook.sh" "$(cat "$F7AA/settingsdir/settings.json")"
else
  skip_note "f7aa: primary settings.json backup-failure guard (running as root, permission bits bypassed)"
fi

# F7bb: the project-level settings scan's own backup (a THIRD, independent
# call site from F7u's settings.local.json) must also refuse to proceed when
# its backup fails.
if [ "$(id -u)" -ne 0 ]; then
  F7BB="$REVD/f7bb"; mkdir -p "$F7BB/cd" "$F7BB/settingsdir" "$F7BB/proj/.claude"
  printf '{}\n' > "$F7BB/settingsdir/settings.json"
  doc_settings_legacy "$F7BB/cd" > "$F7BB/proj/.claude/settings.json"
  chmod 666 "$F7BB/proj/.claude/settings.json"
  chmod 555 "$F7BB/proj/.claude"
  out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7BB/settingsdir/settings.json" \
        DOCTOR_CLAUDE_DIR="$F7BB/cd" DOCTOR_PROJECT_DIR="$F7BB/proj" DOCTOR_VENV_DIR="$NOVENV" \
        bash "$DOCTOR" --fix 2>&1)
  chmod 755 "$F7BB/proj/.claude"
  check "f7bb: project-level settings legacy-hook removal backup failure refuses the rewrite" \
        "could not back up $F7BB/proj/.claude/settings.json before rewriting it" "$out"
  check "f7bb: project-level legacy hook entries survive when the backup fails" \
        "dangi-hook.sh" "$(cat "$F7BB/proj/.claude/settings.json")"
else
  skip_note "f7bb: project-level settings backup-failure guard (running as root, permission bits bypassed)"
fi

# F8: execution semantics — Claude Code spawns an MCP stdio command DIRECTLY
# (no shell) on every OS, so the bundled command must be the bare name
# `headroom`, resolved via PATH, with no path segment and no quotes for a
# shell-less spawn to mis-resolve (a path or quoted command broke this on
# every OS pre-v2.8, and a `.sh` would be unspawnable on Windows regardless).
# Hook commands are the opposite — they DO run through a shell — so
# hooks.json keeps its quoting. Pin the asymmetry in both directions.
check_absent "f8: mcp command carries no path (nothing for a shell-less spawn to mis-resolve)" "/" "$mcp_cmd"
check_absent "f8: mcp command carries no quotes" '"' "$mcp_cmd"
check "f8: hooks.json gate command KEEPS its shell quoting (hooks run via shell)" \
      '"${CLAUDE_PLUGIN_ROOT}"/scripts/hcat-gate.sh' \
      "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$ROOT/hooks/hooks.json")"

# F8b: doctor 4b judges the .mcp.json SHAPE — a path-style command is what a
# pre-v2.8 cache copy looks like, and it can never spawn on Windows: FAIL, not
# fixable (there is no launcher left to repair; the fix is a plugin update).
F8B="$REVD/f8b"; mkdir -p "$F8B/root/scripts" "$F8B/root/bin" "$F8B/cd"
cp "$DOCTOR" "$F8B/root/scripts/doctor.sh"; cp -R "$ROOT/scripts/lib" "$F8B/root/scripts/lib"
cp "$HCAT" "$F8B/root/bin/hcat"; cp -R "$ROOT/hooks" "$F8B/root/hooks"
jq -n '{mcpServers:{headroom:{type:"stdio",command:"${CLAUDE_PLUGIN_ROOT}/scripts/mcp-launcher.sh",args:[],env:{}}}}' \
  > "$F8B/root/.mcp.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F8B/settings.json" \
      DOCTOR_CLAUDE_DIR="$F8B/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$F8B/root/scripts/doctor.sh" 2>&1)
check        "f8b: path-style mcp command is FAIL (stale copy)" "stale plugin copy" "$out"
check_absent "f8b: path-style mcp command not greened" ".mcp.json spawns" "$out"

# --- 36. data-driven price table (data/model-prices.json)
PRICES_JSON="$ROOT/data/model-prices.json"
if jq -e '(.prices|type)=="array" and (.prices|length)>0' "$PRICES_JSON" >/dev/null 2>&1; then
  echo "ok - prices: bundled model-prices.json parses"; PASS=$((PASS+1))
else
  echo "FAIL - prices: bundled model-prices.json parses"; FAIL=$((FAIL+1))
fi
check "prices: opus-4-8 present in table" "opus-4-8" "$(cat "$PRICES_JSON")"
check "prices: fable-5 present in table"  "fable-5"  "$(cat "$PRICES_JSON")"

export HEADROOM_STATE_DIR="$TMP/state-prices"
# a NEW model present only in the JSON is priced — proving pricing is data, not code
PF="$TMP/prices-custom.json"
jq -n '{version:1, prices:[{match:"zeta-9", usd_per_mtok:8}]}' > "$PF"
out=$(HEADROOM_PRICES_FILE="$PF" badge "$TMP/t_active.jsonl" claude-zeta-9 sess-px1)  # 500 tok @ $8 = 0.40¢
check "prices: model from JSON is priced (data-driven)" "0.40¢" "$out"
# a model absent from an authoritative JSON is unknown → tokens-only, never a guess.
# Fresh state dir so an earlier session's all-time totals can't leak a ¢ in.
export HEADROOM_STATE_DIR="$TMP/state-prices-px2"
out=$(HEADROOM_PRICES_FILE="$PF" badge "$TMP/t_active.jsonl" some-absent-model sess-px2)
check "prices: unlisted model is tokens-only" "~500 tok" "$out"
check_absent "prices: unlisted model shows no cents" "¢" "$out"
# invalid or missing price file → built-in table still prices (zero-regression fallback)
printf 'not json{' > "$TMP/prices-bad.json"
out=$(HEADROOM_PRICES_FILE="$TMP/prices-bad.json" badge "$TMP/t_active.jsonl" claude-opus-4-8 sess-px3)
check "prices: invalid file falls back to built-in table" "0.25¢" "$out"
out=$(HEADROOM_PRICES_FILE="$TMP/does-not-exist.json" badge "$TMP/t_active.jsonl" claude-opus-4-8 sess-px4)
check "prices: missing file falls back to built-in table" "0.25¢" "$out"

# --- 37. dangi: file-aware nudge + batched suppression count
export HEADROOM_STATE_DIR="$TMP/state-dangi2"

# names the exact structured file drawn from the Bash command
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"faware-1",
  tool_input:{command:"cat /var/data/events.json"}, tool_response:("x"*9000)}' | bash "$DANGI")
check "dangi file-aware: nudge names the file" 'hcat \"/var/data/events.json\"' "$out"
# no command → generic <path> placeholder preserved (unchanged behavior)
out=$(hook_input Bash 9000 faware-2 | bash "$DANGI")
check "dangi file-aware: generic path when no command" 'hcat \"<path>\"' "$out"
# a command with no structured-file token → generic placeholder, no bad guess
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"faware-3",
  tool_input:{command:"echo hello world"}, tool_response:("x"*9000)}' | bash "$DANGI")
check "dangi file-aware: generic when no file token" 'hcat \"<path>\"' "$out"

# batching: big blobs suppressed during the cooldown are counted and surfaced on
# the next nudge. DANGI_NOW drives the cooldown clock deterministically.
padB=$(head -c 9000 /dev/zero | tr '\0' x)
fire() {  # fire <simulated-now> — one big Bash blob at that clock time
  jq -n --arg pad "$padB" \
    '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"batch-1", tool_response:$pad}' \
    | DANGI_NOW="$1" bash "$DANGI"
}
o1=$(fire 100000)   # first: nudges, pending resets
check "dangi batch: first output nudges"        "additionalContext" "$o1"
check_absent "dangi batch: first has no count"  "slipped by"        "$o1"
o2=$(fire 100010); check_absent "dangi batch: second suppressed" "additionalContext" "$o2"
o3=$(fire 100020); check_absent "dangi batch: third suppressed"  "additionalContext" "$o3"
o4=$(fire 100100)   # >cooldown since last nudge: nudges again, names the 2 missed
check "dangi batch: nudges again after cooldown"    "additionalContext"     "$o4"
check "dangi batch: surfaces the suppressed count"  "2 more large outputs"  "$o4"

# --- 38. ambient health: last-error state, broken badge, session probe (v2.7)
PROBE="$ROOT/scripts/session-probe.sh"
export HEADROOM_STATE_DIR="$TMP/state-health"
mkdir -p "$HEADROOM_STATE_DIR"

# Hermetic status-line state for the probe's setup-nudge check: a wired
# settings.json whose script copy + lib deps are present, so a healthy run stays
# silent regardless of the real ~/.claude on this machine. Individual tests below
# override HEADROOM_SETTINGS to exercise the unwired / missing-dep nudges.
PROBE_CD="$TMP/probe-claude"; mkdir -p "$PROBE_CD/lib"
printf '{"statusLine":{"type":"command","command":"bash \\"%s/headroom-statusline.sh\\""}}' "$PROBE_CD" > "$PROBE_CD/settings.json"
: > "$PROBE_CD/headroom-statusline.sh"; : > "$PROBE_CD/lib/attribution.jq"
export HEADROOM_SETTINGS="$PROBE_CD/settings.json"

# hcat with a dead HCAT_PYTHON records an engine error (and still exits 3)
printf '{"a":1}\n' > "$TMP/health.json"
HCAT_PYTHON=/nonexistent/python bash "$ROOT/bin/hcat" "$TMP/health.json" >/dev/null 2>&1; rc=$?
check_eq "health: hcat missing engine exits 3" "3" "$rc"
check "health: hcat wrote last-error" "engine" "$(cat "$HEADROOM_STATE_DIR/last-error" 2>/dev/null)"

# a fresh last-error takes over the badge and points at the doctor
tr_h="$TMP/t_health.jsonl"; compress_event th1 500 > "$tr_h"
out=$(badge "$tr_h" claude-opus-4-8 health-s1)
check "health: badge shows broken"     "broken"  "$out"
check "health: badge points at doctor" "/doctor" "$out"

# a stale entry (>24h by its own timestamp) no longer takes over
printf '%s engine old failure\n' "$(( $(date -u +%s) - 90000 ))" > "$HEADROOM_STATE_DIR/last-error"
out=$(badge "$tr_h" claude-opus-4-8 health-s2)
check_absent "health: stale error ignored" "broken" "$out"

# gate with a resolved-but-broken engine fails open AND records the breakage
rm -f "$HEADROOM_STATE_DIR/last-error"
big_h="$TMP/big-health.json"; head -c 20000 /dev/zero | tr '\0' x > "$big_h"
out=$(gate_input "$big_h" health-g1 | HCAT_PYTHON=/usr/bin/false bash "$ROOT/scripts/hcat-gate.sh"); rc=$?
check_eq "health: gate broken engine exit 0"       "0"    "$rc"
check_absent "health: gate broken engine fails open" "deny" "$out"
check "health: gate recorded the breakage" "import failed" \
      "$(cat "$HEADROOM_STATE_DIR/last-error" 2>/dev/null)"

# hooks.json registers the SessionStart probe
jq -e '.hooks.SessionStart[0].hooks[0].command | contains("session-probe.sh")' \
   "$ROOT/hooks/hooks.json" >/dev/null 2>&1 \
  && check "health: hooks.json registers the probe" "ok" "ok" \
  || check "health: hooks.json registers the probe" "ok" "MISSING"

# probe: healthy env is silent (existence-level checks only). $AMBIENT_HR
# (a PATH dir holding nothing but an executable `headroom`) is what makes
# these fixtures healthy under the v2.8 contract: the bundled .mcp.json spawns
# the bare name, so an engine that resolves while `headroom` is off PATH now
# earns its own probe nudge (see the w11 block) -- this box has no ambient
# headroom, so without it every "silent" assertion below would be asserting
# the absence of a line the probe is now right to print.
rm -f "$HEADROOM_STATE_DIR/last-error"
out=$(HCAT_PYTHON=/usr/bin/true PATH="$AMBIENT_HR:$PATH" bash "$PROBE"); rc=$?
check_eq "health: probe healthy silent" "" "$out"
check_eq "health: probe healthy exit 0" "0" "$rc"

# probe: an HCAT_PYTHON pointing nowhere is a breakage → context line + last-error
out=$(HCAT_PYTHON=/nonexistent/python bash "$PROBE"); rc=$?
check "health: probe flags broken override" "additionalContext" "$out"
check "health: probe wrote last-error" "engine" "$(cat "$HEADROOM_STATE_DIR/last-error" 2>/dev/null)"
check_eq "health: probe exit 0" "0" "$rc"

# probe: never-installed engine gets a pointer but does NOT flip the badge
rm -f "$HEADROOM_STATE_DIR/last-error"
out=$(env -u HCAT_PYTHON HOME="$TMP/nohome" PATH="$STUB:/usr/bin:/bin" bash "$PROBE")
check "health: probe notes missing engine" "not installed" "$out"
if [ -f "$HEADROOM_STATE_DIR/last-error" ]; then
  echo "FAIL - health: missing engine must not write last-error"; FAIL=$((FAIL+1))
else
  echo "ok - health: missing engine must not write last-error"; PASS=$((PASS+1))
fi

# probe: surfaces a fresh recorded failure even when its own checks pass
printf '%s runtime hcat: compression failed: boom\n' "$(date +%s)" > "$HEADROOM_STATE_DIR/last-error"
out=$(HCAT_PYTHON=/usr/bin/true PATH="$AMBIENT_HR:$PATH" bash "$PROBE")
check "health: probe surfaces recorded failure" "recent failure" "$out"

# probe: status line not wired yet → one-line setup nudge (the "I installed it,
# why is there no badge?" case). Must be a setup line, not a breakage, and must
# NOT write last-error (an unfinished setup step is not an engine failure).
rm -f "$HEADROOM_STATE_DIR/last-error"
uwd="$TMP/probe-unwired"; mkdir -p "$uwd"; printf '{}' > "$uwd/settings.json"
out=$(HCAT_PYTHON=/usr/bin/true PATH="$AMBIENT_HR:$PATH" HEADROOM_SETTINGS="$uwd/settings.json" bash "$PROBE")
check "health: probe nudges an unwired status line" "status line" "$out"
check "health: setup nudge points at doctor --fix"  "doctor --fix"  "$out"
check "health: setup nudge is a setup line"          "headroom setup" "$out"
if [ -f "$HEADROOM_STATE_DIR/last-error" ]; then
  echo "FAIL - health: unwired status line must not write last-error"; FAIL=$((FAIL+1))
else
  echo "ok - health: unwired status line must not write last-error"; PASS=$((PASS+1))
fi

# probe: status line wired but the copy's lib deps are missing → surfaces the
# exact issue-#2 shape (badge would read a permanent zero) with the same nudge.
wmd="$TMP/probe-wiredmiss"; mkdir -p "$wmd"
printf '{"statusLine":{"type":"command","command":"bash \\"%s/headroom-statusline.sh\\""}}' "$wmd" > "$wmd/settings.json"
: > "$wmd/headroom-statusline.sh"   # copy present, but no lib/ next to it
out=$(HCAT_PYTHON=/usr/bin/true PATH="$AMBIENT_HR:$PATH" HEADROOM_SETTINGS="$wmd/settings.json" bash "$PROBE")
check "health: probe nudges wired-but-missing-deps" "missing its deps" "$out"

# probe: fully wired + deps present (the exported fixture) → silent, no false nudge
rm -f "$HEADROOM_STATE_DIR/last-error"
out=$(HCAT_PYTHON=/usr/bin/true PATH="$AMBIENT_HR:$PATH" bash "$PROBE")
check_eq "health: wired status line + deps stays silent" "" "$out"

# a working compression clears engine/runtime errors (real engine required)
if [ -n "$HEADROOM_PY" ]; then
  printf '%s engine stale\n' "$(date +%s)" > "$HEADROOM_STATE_DIR/last-error"
  HCAT_PYTHON="$HEADROOM_PY" HEADROOM_WORKSPACE_DIR="$TMP/ws-health" \
    bash "$ROOT/bin/hcat" "$TMP/hc_big.json" >/dev/null 2>&1
  if [ -f "$HEADROOM_STATE_DIR/last-error" ]; then
    echo "FAIL - health: successful hcat clears engine error"; FAIL=$((FAIL+1))
  else
    echo "ok - health: successful hcat clears engine error"; PASS=$((PASS+1))
  fi

  # doctor: fully-clean run clears the state; fixable/failed runs keep it
  printf '%s engine stale2\n' "$(date +%s)" > "$HEADROOM_STATE_DIR/last-error"
  CDH="$TMP/doc-health"; mkdir -p "$CDH"
  SH="$TMP/doc-health-s.json"; doc_settings_wired "$CDH" > "$SH"
  # $FENG on PATH keeps check 2b "ok" (real headroom isn't on this Mac's ambient
  # PATH) so the run stays fully clean and block 9 actually clears (issue #9)
  out=$(HCAT_PYTHON="$HEADROOM_PY" PATH="$FENG:$PATH" DOCTOR_SETTINGS="$SH" DOCTOR_CLAUDE_DIR="$CDH" \
        DOCTOR_VENV_DIR="$TMP/doc-none" bash "$DOCTOR" 2>&1)
  check "health: doctor reports clearing" "cleared recorded failure" "$out"
  if [ -f "$HEADROOM_STATE_DIR/last-error" ]; then
    echo "FAIL - health: doctor clean run removes last-error"; FAIL=$((FAIL+1))
  else
    echo "ok - health: doctor clean run removes last-error"; PASS=$((PASS+1))
  fi
else
  skip_note "health engine-clear tests (headroom venv not found)"
fi
printf '%s engine stale3\n' "$(date +%s)" > "$HEADROOM_STATE_DIR/last-error"
out=$(HCAT_PYTHON=/nonexistent/python DOCTOR_SETTINGS="$S2" DOCTOR_CLAUDE_DIR="$CD2" \
      DOCTOR_VENV_DIR="$DOCD/none" bash "$DOCTOR" 2>&1)
check "health: doctor keeps state while fixable" "failure state kept" "$out"
rm -f "$HEADROOM_STATE_DIR/last-error"

# --- 39. dangi router: true-size detection + tiered compress/delegate advice (v2.7)
export HEADROOM_STATE_DIR="$TMP/state-router"

# a 200 KB file read via Bash cat with a truncated (9 KB) payload → the nudge
# reports the TRUE size and advises delegation, not in-place compression
huge_f="$TMP/router-huge.json"; head -c 200000 /dev/zero | tr '\0' x > "$huge_f"
out=$(jq -n --arg cmd "cat $huge_f" '{hook_event_name:"PostToolUse", tool_name:"Bash",
  session_id:"router-1", tool_input:{command:$cmd}, tool_response:("x"*9000)}' | bash "$DANGI")
check "router: huge file → delegation advice" "disposable subagent" "$out"
check "router: huge file → true size reported" "195 KB" "$out"
check "router: huge file names the file" "router-huge.json" "$out"
check_absent "router: huge file → no in-place hcat advice" "run hcat" "$out"

# a 20 KB file stays in the compress-in-place tier and names the file for hcat
med_f="$TMP/router-med.json"; head -c 20000 /dev/zero | tr '\0' x > "$med_f"
out=$(jq -n --arg cmd "cat $med_f" '{hook_event_name:"PostToolUse", tool_name:"Bash",
  session_id:"router-2", tool_input:{command:$cmd}, tool_response:("x"*9000)}' | bash "$DANGI")
check "router: medium file → hcat advice" "run hcat" "$out"
check "router: medium file → true size reported" "19 KB" "$out"

# a huge raw (non-file-backed) payload also routes to delegation
out=$(hook_input Bash 140000 router-3 | bash "$DANGI")
check "router: huge raw payload → delegation" "disposable subagent" "$out"
check_absent "router: huge raw payload → no hcat advice" "run hcat" "$out"

# Read is now file-aware too: a big structured file read via Read names itself
out=$(jq -n --arg fp "$med_f" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"router-4", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | bash "$DANGI")
check "router: Read names the file" "router-med.json" "$out"

# a written-but-never-read big file must NOT trigger on a small payload
out=$(jq -n --arg cmd "curl -o $huge_f https://x.test" '{hook_event_name:"PostToolUse",
  tool_name:"Bash", session_id:"router-5", tool_input:{command:$cmd},
  tool_response:"ok"}' | bash "$DANGI")
check_absent "router: small payload never triggers on file size" "additionalContext" "$out"

# a spacey/unsafe file path falls back to the generic placeholder (JSON safety)
sp_dir="$TMP/router sp"; mkdir -p "$sp_dir"
sp_f="$sp_dir/data.json"; head -c 20000 /dev/zero | tr '\0' x > "$sp_f"
out=$(jq -n --arg fp "$sp_f" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"router-6", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | bash "$DANGI")
check "router: unsafe path → generic placeholder" 'hcat \"<path>\"' "$out"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 \
  && check "router: unsafe path output is valid JSON" "ok" "ok" \
  || check "router: unsafe path output is valid JSON" "ok" "INVALID"

# --- 40. gate rewrite extras + hcat TOON-lite lossless tier (v2.7)
export HEADROOM_STATE_DIR="$TMP/state-toon"

# The fake engine ($FENG/python exits 0 for everything, `import headroom`
# included) satisfies the gate's engine checks — these run venv or not.
big40="$TMP/hc_big40.json"
mkuniform "$big40"
# rewrite preserves sibling tool_input fields (full-object updatedInput)
out=$(jq -n --arg cmd "cat $big40" '{hook_event_name:"PreToolUse", tool_name:"Bash",
  session_id:"toon-g1", tool_input:{command:$cmd, description:"dump the file"}}' \
  | HCAT_PYTHON="$FENG/python" bash "$GATE")
check "rewrite: preserves other tool_input fields" '"description":"dump the file"' "$out"
# kill switch: HCAT_GATE_NO_REWRITE falls back to the deny redirect
out=$(bash_gate_input "cat $big40" toon-g2 | HCAT_PYTHON="$FENG/python" HCAT_GATE_NO_REWRITE=1 bash "$GATE")
check "rewrite: NO_REWRITE falls back to deny" '"permissionDecision":"deny"' "$out"

# TOON-lite: uniform JSON array compresses with no engine installed at all
uni="$TMP/toon-uniform.json"
jq -n '[range(0; 80) | {id:., user:("user_" + (.%7|tostring)), event:"click", ok:true}]' > "$uni"
out=$(env -u HCAT_PYTHON HOME="$TMP/nohome" PATH="$STUB:/usr/bin:/bin" bash "$ROOT/bin/hcat" "$uni"); rc=$?
check_eq "toon: no-engine uniform json exit 0" "0" "$rc"
check "toon: emits a receipt"          "── hcat:"          "$out"
check "toon: names the strategy"       "toon-lite"         "$out"
check "toon: receipt has token arrow"  " tok → ~"          "$out"
check "toon: header row present"       "id,user,event,ok"  "$out"

# non-uniform JSON without an engine still errors (exit 3)
nonu="$TMP/toon-nonuniform.json"
printf '{"a": {"nested": [1,2,3]}, "b": "x"}\n' > "$nonu"
env -u HCAT_PYTHON HOME="$TMP/nohome" PATH="$STUB:/usr/bin:/bin" bash "$ROOT/bin/hcat" "$nonu" >/dev/null 2>&1; rc=$?
check_eq "toon: no-engine non-uniform exit 3" "3" "$rc"

# CSV-special values get JSON-quoted so rows stay parseable
spec="$TMP/toon-special.json"
jq -n '[range(0; 40) | {id:., note:"a,b \"q\" line", n:(.*2)}]' > "$spec"
out=$(env -u HCAT_PYTHON HOME="$TMP/nohome" PATH="$STUB:/usr/bin:/bin" bash "$ROOT/bin/hcat" "$spec")
check "toon: special chars json-quoted" '\"q\"' "$out"

# --- 41. session ledger + next-session invoice (v2.7)
LEDGERH="$ROOT/scripts/ledger-hook.sh"
export HEADROOM_STATE_DIR="$TMP/state-ledger"
mkdir -p "$HEADROOM_STATE_DIR"

trL="$TMP/t_ledger.jsonl"
# One MCP save + two misses: the MCP-compress discount drops the SMALLEST miss
# (fillerA), leaving events.json as the surviving, named biggest miss.
{
  compress_event lg1 500
  printf '{"timestamp":"%s","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"hi"}]}}\n' "$NOW"
  jq -n '{message:{content:[{type:"tool_use",id:"lgf1",name:"Read",input:{file_path:"/var/data/fillerA.log"}}]}}'
  jq -n '{message:{content:[{type:"tool_result",tool_use_id:"lgf1",content:[{type:"text",text:("z"*5000)}]}]}}'
  jq -n '{message:{content:[{type:"tool_use",id:"lgm1",name:"Read",input:{file_path:"/var/data/events.json"}}]}}'
  jq -n '{message:{content:[{type:"tool_result",tool_use_id:"lgm1",content:[{type:"text",text:("z"*9000)}]}]}}'
} > "$trL"

printf '{"session_id":"ledger-s1","transcript_path":"%s"}' "$trL" | bash "$LEDGERH" >"$TMP/lh.out" 2>&1; rc=$?
lg="$HEADROOM_STATE_DIR/ledger.jsonl"
check_eq "ledger: exit 0" "0" "$rc"
check_eq "ledger: hook prints nothing" "" "$(cat "$TMP/lh.out")"
check "ledger: entry written"       "ledger-s1"                 "$(cat "$lg" 2>/dev/null)"
check "ledger: saves recorded"      '"save_tokens":500'         "$(cat "$lg" 2>/dev/null)"
check "ledger: miss recorded"       '"miss_count":1'            "$(cat "$lg" 2>/dev/null)"
check "ledger: miss path captured"  "/var/data/events.json"     "$(cat "$lg" 2>/dev/null)"
check "ledger: model captured"      "claude-opus-4-8"           "$(cat "$lg" 2>/dev/null)"
check "ledger: saves priced"        '"save_usd":"0.002500"'     "$(cat "$lg" 2>/dev/null)"
check "ledger: misses priced"       '"miss_usd"'                "$(cat "$lg" 2>/dev/null)"

# idempotent: an unchanged transcript must not append a second line
printf '{"session_id":"ledger-s1","transcript_path":"%s"}' "$trL" | bash "$LEDGERH"
check_eq "ledger: unchanged transcript not re-appended" "1" "$(wc -l < "$lg" | tr -d ' ')"

# growth → a new cumulative snapshot line (2nd compress + a 3rd smaller miss,
# so with the discount events.json still survives as the biggest miss)
{
  compress_event lg2 700
  jq -n '{message:{content:[{type:"tool_use",id:"lgf2",name:"Read",input:{file_path:"/var/data/fillerC.log"}}]}}'
  jq -n '{message:{content:[{type:"tool_result",tool_use_id:"lgf2",content:[{type:"text",text:("z"*6000)}]}]}}'
} >> "$trL"
printf '{"session_id":"ledger-s1","transcript_path":"%s"}' "$trL" | bash "$LEDGERH"
check_eq "ledger: grown transcript appends" "2" "$(wc -l < "$lg" | tr -d ' ')"
check "ledger: snapshot is cumulative" '"save_tokens":1200' "$(tail -1 "$lg")"

# an empty session leaves no trace
trE="$TMP/t_ledger_empty.jsonl"; printf '{"message":{"content":[{"type":"text","text":"hi"}]}}\n' > "$trE"
printf '{"session_id":"ledger-empty","transcript_path":"%s"}' "$trE" | bash "$LEDGERH"
check_absent "ledger: empty session not recorded" "ledger-empty" "$(cat "$lg")"

# the probe surfaces the invoice exactly once
out=$(HCAT_PYTHON=/usr/bin/true PATH="$AMBIENT_HR:$PATH" bash "$PROBE")
check "invoice: probe surfaces last session" "headroom invoice" "$out"
check "invoice: reports savings"             "saved ~1.2k tok"  "$out"
check "invoice: loss-frames the misses"      "left on the table" "$out"
check "invoice: names the biggest miss"      "/var/data/events.json" "$out"
out=$(HCAT_PYTHON=/usr/bin/true PATH="$AMBIENT_HR:$PATH" bash "$PROBE")
check_absent "invoice: surfaced only once" "invoice" "$out"

# hooks.json registers the ledger hook on Stop and SessionEnd
jq -e '.hooks.Stop[0].hooks[0].command | contains("ledger-hook.sh")' \
   "$ROOT/hooks/hooks.json" >/dev/null 2>&1 \
  && check "ledger: hooks.json Stop registered" "ok" "ok" \
  || check "ledger: hooks.json Stop registered" "ok" "MISSING"
jq -e '.hooks.SessionEnd[0].hooks[0].command | contains("ledger-hook.sh")' \
   "$ROOT/hooks/hooks.json" >/dev/null 2>&1 \
  && check "ledger: hooks.json SessionEnd registered" "ok" "ok" \
  || check "ledger: hooks.json SessionEnd registered" "ok" "MISSING"

# --- 42. detection that learns: offender memory + content sniff (v2.7)
export HEADROOM_STATE_DIR="$TMP/state-learn"
mkdir -p "$HEADROOM_STATE_DIR"

# dangi records a file-backed offender when the nudge fires
learn_f="$TMP/learn-offender.json"; head -c 20000 /dev/zero | tr '\0' x > "$learn_f"
jq -n --arg fp "$learn_f" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"learn-1", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | bash "$DANGI" >/dev/null
check "learn: offender recorded" "$learn_f" "$(cat "$HEADROOM_STATE_DIR/offenders" 2>/dev/null)"

# re-offense updates in place — no duplicate lines
jq -n --arg fp "$learn_f" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"learn-2", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | bash "$DANGI" >/dev/null
check_eq "learn: offender deduped" "1" "$(wc -l < "$HEADROOM_STATE_DIR/offenders" | tr -d ' ')"

# Gate checks run against the fake engine — no real venv needed (see 40).
# a learned offender with no structured extension is now gated
noext="$TMP/learn-noext"; head -c 20000 /dev/zero | tr '\0' x > "$noext"
printf '%s %s\n' "$(date +%s)" "$noext" > "$HEADROOM_STATE_DIR/offenders"
out=$(gate_input "$noext" learn-g1 | HCAT_PYTHON="$FENG/python" bash "$GATE")
check "learn: offender gated without extension" '"permissionDecision":"deny"' "$out"
# stale entries decay (default TTL 14 days)
printf '%s %s\n' "$(( $(date +%s) - 1300000 ))" "$noext" > "$HEADROOM_STATE_DIR/offenders"
out=$(gate_input "$noext" learn-g2 | HCAT_PYTHON="$FENG/python" bash "$GATE")
check_absent "learn: stale offender ignored" "deny" "$out"
rm -f "$HEADROOM_STATE_DIR/offenders"

# sniff: a big extensionless JSON array is gated on structure alone
sniff_f="$TMP/learn-sniff"
mkuniform "$sniff_f"
out=$(gate_input "$sniff_f" learn-g3 | HCAT_PYTHON="$FENG/python" bash "$GATE")
check "learn: sniff gates JSON-shaped file" '"permissionDecision":"deny"' "$out"
out=$(gate_input "$sniff_f" learn-g4 | HCAT_PYTHON="$FENG/python" HCAT_GATE_NO_SNIFF=1 bash "$GATE")
check_absent "learn: NO_SNIFF disables the sniff" "deny" "$out"

# CSV vitals: matching 3+ delimiter counts across the first two rows
csv_f="$TMP/learn-csv"
{ printf 'a,b,c,d,e\n'; i=0; while [ "$i" -lt 1600 ]; do printf '1,2,3,4,five\n'; i=$((i+1)); done; } > "$csv_f"
out=$(gate_input "$csv_f" learn-g5 | HCAT_PYTHON="$FENG/python" bash "$GATE")
check "learn: sniff gates CSV-shaped file" '"permissionDecision":"deny"' "$out"

# plain prose stays un-gated
prose_f="$TMP/learn-prose"; head -c 20000 /dev/zero | tr '\0' x > "$prose_f"
out=$(gate_input "$prose_f" learn-g6 | HCAT_PYTHON="$FENG/python" bash "$GATE")
check_absent "learn: prose not gated" "deny" "$out"

# --- 43. doctor: project-level settings scan + fix (v2.7)
PROJ43="$TMP/proj43"; mkdir -p "$PROJ43/.claude"
CD43="$TMP/proj43-cd"; mkdir -p "$CD43"
S43="$TMP/proj43-s.json"; doc_settings_wired "$CD43" > "$S43"
doc_settings_legacy "$CD43" > "$PROJ43/.claude/settings.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S43" \
      DOCTOR_CLAUDE_DIR="$CD43" DOCTOR_VENV_DIR="$NOVENV" DOCTOR_PROJECT_DIR="$PROJ43" \
      bash "$DOCTOR" 2>&1)
check "proj: legacy hooks detected as fixable" "legacy hooks in project settings" "$out"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S43" \
      DOCTOR_CLAUDE_DIR="$CD43" DOCTOR_VENV_DIR="$NOVENV" DOCTOR_PROJECT_DIR="$PROJ43" \
      bash "$DOCTOR" --fix 2>&1)
check "proj: --fix cleans project settings" \
      "removed 2 legacy hook entries from $PROJ43/.claude/settings.json" "$out"
check_eq "proj: entries gone" "0" \
  "$(jq '[.hooks // {} | to_entries[] | .value[]?.hooks[]? | select((.command // "") | test("dangi-hook|hcat-gate"))] | length' "$PROJ43/.claude/settings.json")"
check "proj: unrelated hook preserved" "unrelated-hook" "$(cat "$PROJ43/.claude/settings.json")"
if ls "$PROJ43"/.claude/settings.json.bak.* >/dev/null 2>&1; then
  echo "ok - proj: backup written"; PASS=$((PASS+1))
else
  echo "FAIL - proj: backup written"; FAIL=$((FAIL+1))
fi
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S43" \
      DOCTOR_CLAUDE_DIR="$CD43" DOCTOR_VENV_DIR="$NOVENV" DOCTOR_PROJECT_DIR="$PROJ43" \
      bash "$DOCTOR" 2>&1)
check "proj: clean project settings reported ok" \
      "no legacy hook registrations in $PROJ43/.claude/settings.json" "$out"

# unparseable project settings → FAIL, stale-copy gate stays shut
printf '{ broken\n' > "$PROJ43/.claude/settings.local.json"
touch "$CD43/dangi-hook.sh"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S43" \
      DOCTOR_CLAUDE_DIR="$CD43" DOCTOR_VENV_DIR="$NOVENV" DOCTOR_PROJECT_DIR="$PROJ43" \
      bash "$DOCTOR" --fix 2>&1)
check "proj: unparseable project settings FAIL" "project settings did not parse" "$out"
check "proj: stale copies kept while project scan inconclusive" "stale copies kept" "$out"

# --- 44. v2.7 F1 review fixes: rewrite fidelity, learning precision, honest sizing
export HEADROOM_STATE_DIR="$TMP/state-v271"
mkdir -p "$HEADROOM_STATE_DIR"

big44="$TMP/v271-big.json"
mkuniform "$big44"

# the rewrite emits an UNQUOTED command word — the shape every attribution
# surface (dangi/statusline/ledger) recognises as an hcat invocation
out=$(bash_gate_input "cat $big44" v271-g1 | HCAT_PYTHON="$FENG/python" bash "$GATE")
check "fix/rewrite: unquoted hcat command word" '"command":"hcat \"' "$out"
check_absent "fix/rewrite: quoted command word gone" '"command":"\"hcat\"' "$out"
check "fix/rewrite: explains itself via additionalContext" '"additionalContext"' "$out"

# a multiline command is never rewritten — the other lines would be dropped
ml=$(printf 'git add notes.md\ncat %s' "$big44")
out=$(bash_gate_input "$ml" v271-g2 | HCAT_PYTHON="$FENG/python" bash "$GATE")
check_eq "fix/rewrite: multiline command untouched" "" "$out"

# the badge still counts the OLD quoted rewrite form living in past transcripts
printf '%s\n%s\n' \
  "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"vq1\",\"name\":\"Bash\",\"input\":{\"command\":\"\\\"hcat\\\" \\\"/tmp/x.json\\\"\"}}]}}" \
  "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"vq1\",\"content\":[{\"type\":\"text\",\"text\":\"── hcat: /tmp/x.json · 10 lines · 5.0 KB · ~900 tok → ~300 tok (66.7% saved) · original on disk\"}]}]}}" \
  > "$TMP/t_v271_legacy.jsonl"
out=$(badge "$TMP/t_v271_legacy.jsonl" claude-opus-4-8 sess-v271a)
check "fix/attrib: legacy quoted rewrite counts" "600" "$out"

# ...while a mid-command quoted "hcat" (grep over docs) still counts as nothing
printf '%s\n%s\n' \
  "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"vq2\",\"name\":\"Bash\",\"input\":{\"command\":\"grep \\\"hcat\\\" README.md\"}}]}}" \
  "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"vq2\",\"content\":[{\"type\":\"text\",\"text\":\"── hcat: /tmp/x.json · 10 lines · 5.0 KB · ~900 tok → ~300 tok (66.7% saved) · original on disk\"}]}]}}" \
  > "$TMP/t_v271_grep.jsonl"
out=$(badge "$TMP/t_v271_grep.jsonl" claude-opus-4-8 sess-v271b)
check_absent "fix/attrib: quoted hcat mid-command not an invocation" "●" "$out"

# exempt output classes are not "missed savings" — ledger and badge agree
trX="$TMP/t_v271_exempt.jsonl"
{
  compress_event vx1 500
  jq -n '{message:{content:[{type:"tool_use",id:"vx2",name:"WebFetch",input:{url:"https://x.test"}}]}}'
  jq -n '{message:{content:[{type:"tool_result",tool_use_id:"vx2",content:[{type:"text",text:("w"*9000)}]}]}}'
} > "$trX"
printf '{"session_id":"v271-led","transcript_path":"%s"}' "$trX" | bash "$LEDGERH"
check "fix/ledger: exempt class not a miss" '"miss_count":0' "$(grep v271-led "$HEADROOM_STATE_DIR/ledger.jsonl" 2>/dev/null)"
out=$(badge "$trX" claude-opus-4-8 sess-v271c)
check_absent "fix/badge: exempt class not missed" "missed" "$out"

# offender learning requires structure: a big source file is never recorded
py44="$TMP/v271-src.py"
{ i=0; while [ "$i" -lt 400 ]; do printf 'def fn_%s():\n    return "code line %s"\n' "$i" "$i"; i=$((i+1)); done; } > "$py44"
jq -n --arg fp "$py44" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"v271-l1", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | bash "$DANGI" >/dev/null
check_absent "fix/learn: source file not recorded" "$py44" "$(cat "$HEADROOM_STATE_DIR/offenders" 2>/dev/null)"

# ...while a JSON-shaped extensionless file still is (sniff), stored canonical
sn44="$TMP/v271-sniff"
mkuniform "$sn44"
jq -n --arg fp "$sn44" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"v271-l2", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | bash "$DANGI" >/dev/null
check "fix/learn: sniffed structured file recorded" "$sn44" "$(cat "$HEADROOM_STATE_DIR/offenders" 2>/dev/null)"

# a relative Bash token is recorded canonical so the gate's absolute lookup matches
rel44="$TMP/v271-rel.json"
mkuniform "$rel44"
( cd "$TMP" && jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"v271-l3",
    tool_input:{command:"cat v271-rel.json"}, tool_response:("x"*9000)}' | bash "$DANGI" >/dev/null )
check "fix/learn: relative token stored canonical" "$rel44" "$(cat "$HEADROOM_STATE_DIR/offenders" 2>/dev/null)"

# size escalation only for whole-file ingests
gr44="$TMP/v271-filter.log"
head -c 200000 /dev/zero | tr '\0' x > "$gr44"
out=$(jq -n --arg cmd "grep ERROR $gr44" '{hook_event_name:"PostToolUse", tool_name:"Bash",
  session_id:"v271-l4", tool_input:{command:$cmd}, tool_response:("x"*6000)}' | bash "$DANGI")
check_absent "fix/size: filtered output not escalated" "too large to compress in place" "$out"
check "fix/size: filtered output reports payload size" "~5 KB" "$out"
out=$(jq -n --arg fp "$gr44" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"v271-l5", tool_input:{file_path:$fp, offset:100, limit:50}, tool_response:("x"*6000)}' | bash "$DANGI")
check_absent "fix/size: bounded Read not escalated" "too large to compress in place" "$out"
out=$(jq -n --arg cmd "cat $gr44" '{hook_event_name:"PostToolUse", tool_name:"Bash",
  session_id:"v271-l6", tool_input:{command:$cmd}, tool_response:("x"*6000)}' | bash "$DANGI")
check "fix/size: whole-file cat still escalates" "195 KB" "$out"

# huge non-file payload: no literal <path> handed to a subagent
out=$(hook_input Bash 140000 v271-l7 | bash "$DANGI")
check "fix/nudge: non-file huge advises re-derive" "not traceable to a file" "$out"
check_absent "fix/nudge: no literal placeholder in huge advice" '<path>' "$out"

# huge extensionless file: the REAL path is named
out=$(jq -n --arg fp "$sn44" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"v271-l8", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | DANGI_HUGE_BYTES=20000 bash "$DANGI")
check "fix/nudge: extensionless huge names the real path" "v271-sniff" "$out"
check "fix/nudge: extensionless huge routes to delegation" "too large to compress in place" "$out"

# health: never-installed engine leaves NO broken badge; dead override records one
pr44="$TMP/v271-prose.txt"; printf 'plain prose, nothing structured here\n' > "$pr44"
rm -f "$HEADROOM_STATE_DIR/last-error"
env -u HCAT_PYTHON HOME="$TMP/nohome" HEADROOM_STATE_DIR="$HEADROOM_STATE_DIR" \
  PATH="$STUB:/usr/bin:/bin" bash "$ROOT/bin/hcat" "$pr44" >/dev/null 2>&1; rc=$?
check_eq "fix/health: never-installed exit 3" "3" "$rc"
if [ -f "$HEADROOM_STATE_DIR/last-error" ]; then
  echo "FAIL - fix/health: never-installed leaves no last-error"; FAIL=$((FAIL+1))
else
  echo "ok - fix/health: never-installed leaves no last-error"; PASS=$((PASS+1))
fi
HCAT_PYTHON=/nonexistent/python bash "$ROOT/bin/hcat" "$pr44" >/dev/null 2>&1; rc=$?
check_eq "fix/health: dead override exit 3" "3" "$rc"
check "fix/health: dead override records engine error" "engine" "$(cat "$HEADROOM_STATE_DIR/last-error" 2>/dev/null)"
rm -f "$HEADROOM_STATE_DIR/last-error"

# TOON-lite losslessness: comma keys and scalar-looking strings stay quoted
tk44="$TMP/v271-toon.json"
jq -n '[range(0; 40) | {"a,b": (tostring), n:., s:"null"}]' > "$tk44"
out=$(env -u HCAT_PYTHON HOME="$TMP/nohome" PATH="$STUB:/usr/bin:/bin" bash "$ROOT/bin/hcat" "$tk44")
check 'fix/toon: comma key quoted in header' '"a,b",n,s' "$out"
check 'fix/toon: numeric string cell stays quoted' '"7",7' "$out"
check 'fix/toon: null-looking string stays quoted' '"null"' "$out"

# --- 45. v2.7 F2 review fixes: advice hygiene, ledger durability/accounting,
# path resolution, Bash true-size parity, shared-lib consolidation
export HEADROOM_STATE_DIR="$TMP/state-v272"
mkdir -p "$HEADROOM_STATE_DIR"

# #2 — Dangi advice rejects $/backtick paths (falls back to <path> placeholder)
danger_dir="$TMP/v272-\$(id)"; mkdir -p "$danger_dir"
danger_f="$danger_dir/data.json"; mkuniform "$danger_f"
out=$(jq -n --arg fp "$danger_f" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"v272-d1", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | bash "$DANGI")
check "fix/advice: metachar path → generic placeholder" 'hcat \"<path>\"' "$out"
check_absent "fix/advice: metachar path not embedded" 'id)' "$out"
# a clean path is still named
clean_f="$TMP/v272-clean.json"; mkuniform "$clean_f"
out=$(jq -n --arg fp "$clean_f" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"v272-d2", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | bash "$DANGI")
check "fix/advice: clean path still named" "v272-clean.json" "$out"

# #6 — gate DENY message single-quotes the suggested path (no runnable $(...))
dgate_dir="$TMP/v272g-\$(id)"; mkdir -p "$dgate_dir"
dgate_f="$dgate_dir/big.json"; mkuniform "$dgate_f"
out=$(gate_input "$dgate_f" v272-g1 | HCAT_PYTHON="$FENG/python" bash "$GATE")
check "fix/gate-deny: path single-quoted" "hcat '" "$out"
check_absent "fix/gate-deny: no double-quoted metachar command" 'hcat \"'"$dgate_dir" "$out"

# #12 — a relative Bash cat is resolved against the payload cwd, not the hook's
rel_dir="$TMP/v272-rel"; mkdir -p "$rel_dir"
rel_f="$rel_dir/r.json"; mkuniform "$rel_f"
out=$(jq -n --arg cmd "cat r.json" --arg cwd "$rel_dir" '{hook_event_name:"PreToolUse",
  tool_name:"Bash", session_id:"v272-r1", cwd:$cwd, tool_input:{command:$cmd}}' \
  | HCAT_PYTHON="$FENG/python" bash "$GATE")
check "fix/gate-cwd: relative cat resolved against payload cwd" "$rel_dir/r.json" "$out"
# no payload cwd for a relative token → gate stays silent (no wrong-file rewrite)
out=$(jq -n --arg cmd "cat r.json" '{hook_event_name:"PreToolUse", tool_name:"Bash",
  session_id:"v272-r2", tool_input:{command:$cmd}}' | HCAT_PYTHON="$FENG/python" bash "$GATE"); rc=$?
check_eq "fix/gate-cwd: relative cat with no cwd → silent" "" "$out"
check_eq "fix/gate-cwd: relative cat with no cwd → exit 0" "0" "$rc"

# AN-2 — Bash cat of an EXTENSIONLESS huge file is stat'd, tiered, and named
noext_huge="$rel_dir/dump"; head -c 200000 /dev/zero | tr '\0' x > "$noext_huge"
out=$(jq -n --arg cmd "cat $noext_huge" '{hook_event_name:"PostToolUse", tool_name:"Bash",
  session_id:"v272-an1", tool_input:{command:$cmd}, tool_response:("x"*9000)}' | bash "$DANGI")
check "fix/an2: Bash extensionless huge → delegation" "too large to compress in place" "$out"
check "fix/an2: Bash extensionless huge → true size" "195 KB" "$out"
check "fix/an2: Bash extensionless huge → names the file" "dump" "$out"

# #4 — a failed ledger append leaves the size-marker stale so the retry re-parses
led_dir="$TMP/state-v272-led"; mkdir -p "$led_dir"
trF="$TMP/t_v272_led.jsonl"
{
  compress_event lf1 500
  jq -n '{message:{content:[{type:"tool_use",id:"lfm1",name:"Read",input:{file_path:"/var/data/x.json"}}]}}'
  jq -n '{message:{content:[{type:"tool_result",tool_use_id:"lfm1",content:[{type:"text",text:("z"*9000)}]}]}}'
} > "$trF"
# make the append fail: ledger.jsonl is an unwritable directory
mkdir -p "$led_dir/ledger.jsonl"
HEADROOM_STATE_DIR="$led_dir" bash "$LEDGERH" <<EOF
{"session_id":"v272-lf","transcript_path":"$trF"}
EOF
if [ -f "$led_dir/session-v272-lf.ledgersize" ]; then
  echo "FAIL - fix/ledger: failed append must not mark size handled"; FAIL=$((FAIL+1))
else
  echo "ok - fix/ledger: failed append leaves size-marker stale"; PASS=$((PASS+1))
fi
# once the append can succeed, the snapshot IS recorded (not stranded)
rmdir "$led_dir/ledger.jsonl"
HEADROOM_STATE_DIR="$led_dir" bash "$LEDGERH" <<EOF
{"session_id":"v272-lf","transcript_path":"$trF"}
EOF
check "fix/ledger: retry after writable records the snapshot" "v272-lf" "$(cat "$led_dir/ledger.jsonl" 2>/dev/null)"

# #7 — a blob later MCP-compressed is not priced as a miss (ledger matches badge)
trM="$TMP/t_v272_mcp.jsonl"
{
  # one big output that is ALSO covered by an MCP compress call
  jq -n '{message:{content:[{type:"tool_use",id:"mm1",name:"Bash",input:{command:"echo hi"}}]}}'
  jq -n '{message:{content:[{type:"tool_result",tool_use_id:"mm1",content:[{type:"text",text:("q"*9000)}]}]}}'
  compress_event mm2 700
} > "$trM"
export HEADROOM_STATE_DIR="$TMP/state-v272-mcp"; mkdir -p "$HEADROOM_STATE_DIR"
bash "$LEDGERH" <<EOF
{"session_id":"v272-mcp","transcript_path":"$trM"}
EOF
lgm=$(grep v272-mcp "$HEADROOM_STATE_DIR/ledger.jsonl" 2>/dev/null)
check "fix/ledger: MCP-compressed blob discounted from misses" '"miss_count":0' "$lgm"
out=$(badge "$trM" claude-opus-4-8 sess-v272mcp)
check_absent "fix/badge: same blob not shown as missed" "missed" "$out"

# #5 — Python-tier TOON-lite (<5% engine savings) via a fake headroom shim,
# so the lossless quoting path is exercised WITHOUT a real engine install.
REALPY=$(real_python || echo /nonexistent/python3)
if [ -x "$REALPY" ]; then
  hshim="$TMP/hshim"; mkdir -p "$hshim/headroom"
  : > "$hshim/headroom/__init__.py"
  cat > "$hshim/headroom/compress.py" <<'PYSHIM'
class _R:
    def __init__(self, raw):
        self.messages = [{"content": raw}]
        self.tokens_before = 1000
        self.tokens_after = 980   # 2% savings → <5% → TOON-lite fallback path
def compress(_msgs):
    return _R(_msgs[0]["content"])
PYSHIM
  cat > "$hshim/headroom/paths.py" <<'PYSHIM'
import os, pathlib
def workspace_dir():
    return pathlib.Path(os.environ.get("HEADROOM_WORKSPACE_DIR", "/tmp/hshim-ws"))
def session_stats_path():
    return workspace_dir() / "stats.jsonl"
PYSHIM
  pywrap="$TMP/hshim-python"
  printf '#!/bin/sh\nexport PYTHONPATH="%s:${PYTHONPATH:-}"\nexec "%s" "$@"\n' "$hshim" "$REALPY" > "$pywrap"
  chmod +x "$pywrap"
  ptoon="$TMP/v272-ptoon.json"
  jq -n '[range(0; 40) | {"a,b": (tostring), n:., s:"null"}]' > "$ptoon"
  out=$(HCAT_PYTHON="$pywrap" HEADROOM_WORKSPACE_DIR="$TMP/hshim-ws" bash "$ROOT/bin/hcat" "$ptoon"); rc=$?
  check_eq "fix/ptoon: python <5% engine path exit 0" "0" "$rc"
  check "fix/ptoon: python tier used (lossless, not engine-absent)" "toon-lite lossless)" "$out"
  check_absent "fix/ptoon: not the engine-absent jq tier" "engine absent" "$out"
  check 'fix/ptoon: comma key quoted' '"a,b",n,s' "$out"
  check 'fix/ptoon: numeric string quoted' '"7",7' "$out"
  check 'fix/ptoon: null-looking string quoted' '"null"' "$out"
  check "fix/ptoon: stats event strategy toon-lite" '"strategy":"toon-lite"' "$(cat "$TMP"/hshim-ws/*.jsonl 2>/dev/null)"
else
  skip_note "python-tier TOON-lite test (no python3)"
fi

# lib-missing degrade: hooks source a flat sibling; with NO lib present they
# must still run (exit 0, single JSON decision), features simply off.
nolib="$TMP/nolib"; mkdir -p "$nolib"
cp "$ROOT/scripts/dangi-hook.sh" "$ROOT/scripts/hcat-gate.sh" "$ROOT/scripts/session-probe.sh" "$nolib/"
cp "$ROOT/bin/hcat" "$nolib/hcat"
chmod +x "$nolib"/*.sh "$nolib/hcat"
nolib_f="$TMP/nolib-in.json"; mkuniform "$nolib_f"
out=$(jq -n --arg fp "$nolib_f" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"nolib-1", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' \
  | HEADROOM_STATE_DIR="$TMP/nolib-state" bash "$nolib/dangi-hook.sh"); rc=$?
check_eq "fix/nolib: dangi still exits 0 without lib" "0" "$rc"
check "fix/nolib: dangi still nudges without lib" "additionalContext" "$out"
out=$(gate_input "$nolib_f" nolib-2 | HEADROOM_STATE_DIR="$TMP/nolib-state" HCAT_PYTHON="$FENG/python" bash "$nolib/hcat-gate.sh"); rc=$?
check_eq "fix/nolib: gate still exits 0 without lib" "0" "$rc"
check "fix/nolib: gate still gates .json by extension without lib" "deny" "$out"

# --- 46. v2.8 Windows support (issue #9)
ER="$ROOT/scripts/lib/engine-resolve.sh"
er() {  # er <fn> [args] — call a resolver function in a clean subshell
  ( set -u; . "$ER"; "$@" )
}
W="$TMP/w"; mkdir -p "$W"

# w1. is_windows: DOCTOR_OS override wins, OSTYPE next, uname last
check_eq "w1: DOCTOR_OS=windows → is_windows" "0" "$(DOCTOR_OS=windows er is_windows; echo $?)"
check_eq "w1: DOCTOR_OS=unix → not windows"   "1" "$(DOCTOR_OS=unix OSTYPE=msys er is_windows; echo $?)"
check_eq "w1: OSTYPE=msys → is_windows"       "0" "$(unset DOCTOR_OS; OSTYPE=msys er is_windows; echo $?)"
check_eq "w1: darwin → not windows"           "1" "$(unset DOCTOR_OS; OSTYPE=darwin24 er is_windows; echo $?)"

# w1. venv_bindir: bin/ vs Scripts/ layouts
W1U="$W/venv-unix"; mkdir -p "$W1U/bin"; printf '#!/bin/sh\nexit 0\n' > "$W1U/bin/python"; chmod +x "$W1U/bin/python"
W1W="$W/venv-win";  mkdir -p "$W1W/Scripts"
printf '#!/bin/sh\necho "win-python $*"\n' > "$W1W/Scripts/python.exe"; chmod +x "$W1W/Scripts/python.exe"
printf '#!/bin/sh\necho "win-headroom $*"\n' > "$W1W/Scripts/headroom.exe"; chmod +x "$W1W/Scripts/headroom.exe"
check_eq "w1: venv_bindir unix layout"    "bin"     "$(er venv_bindir "$W1U")"
check_eq "w1: venv_bindir windows layout" "Scripts" "$(er venv_bindir "$W1W")"
check_eq "w1: venv_bindir empty dir fails" "1"      "$(er venv_bindir "$W" >/dev/null; echo $?)"

# w1. resolve_engine_python: Scripts\python.exe venv found when nothing else is
out=$(unset HCAT_PYTHON; PATH="/usr/bin:/bin" DOCTOR_VENV_DIR="$W1W" er resolve_engine_python)
check_eq "w1: resolver finds Scripts/python.exe" "$W1W/Scripts/python.exe" "$out"
out=$(unset HCAT_PYTHON; PATH="/usr/bin:/bin" DOCTOR_VENV_DIR="$W1U" er resolve_engine_python)
check_eq "w1: resolver finds bin/python" "$W1U/bin/python" "$out"
check_eq "w1: resolver exits 1 with no engine" "1" \
  "$(unset HCAT_PYTHON; PATH="/usr/bin:/bin" DOCTOR_VENV_DIR="$W/none" er resolve_engine_python >/dev/null; echo $?)"

# w1. HCAT_PYTHON is authoritative even when broken (callers decide what to do)
check_eq "w1: HCAT_PYTHON verbatim" "/nonexistent/py" \
  "$(HCAT_PYTHON=/nonexistent/py DOCTOR_VENV_DIR="$W1W" er resolve_engine_python)"
check_eq "w1: candidates = only HCAT_PYTHON when set" "/nonexistent/py" \
  "$(HCAT_PYTHON=/nonexistent/py DOCTOR_VENV_DIR="$W1W" er engine_python_candidates)"

# w1. PATH sibling beats venv; python.exe sibling accepted
W1P="$W/pathbin"; mkdir -p "$W1P"
printf '#!/bin/sh\nexit 0\n' > "$W1P/headroom"; chmod +x "$W1P/headroom"
printf '#!/bin/sh\nexit 0\n' > "$W1P/python.exe"; chmod +x "$W1P/python.exe"
out=$(unset HCAT_PYTHON; PATH="$W1P:/usr/bin:/bin" DOCTOR_VENV_DIR="$W1W" er resolve_engine_python)
check_eq "w1: python.exe sibling of headroom on PATH wins" "$W1P/python.exe" "$out"

# w1. MZ trampoline (uv / pip-on-Windows launcher): no shebang parse, fall through
W1M="$W/mzbin"; mkdir -p "$W1M"
printf 'MZ\220\000\003garbage #!/should/not/be/parsed\n' > "$W1M/headroom"; chmod +x "$W1M/headroom"
out=$(unset HCAT_PYTHON; PATH="$W1M:/usr/bin:/bin" DOCTOR_VENV_DIR="$W1W" er resolve_engine_python)
check_eq "w1: MZ trampoline skips shebang, falls to venv" "$W1W/Scripts/python.exe" "$out"

# w1. uv tool dir layout (stub uv prints a dir for `uv tool dir`)
W1UV="$W/uvtools"; mkdir -p "$W1UV/headroom-ai/Scripts" "$W/uvbin"
printf '#!/bin/sh\nexit 0\n' > "$W1UV/headroom-ai/Scripts/python.exe"; chmod +x "$W1UV/headroom-ai/Scripts/python.exe"
printf '#!/bin/sh\nexit 0\n' > "$W1UV/headroom-ai/Scripts/headroom.exe"; chmod +x "$W1UV/headroom-ai/Scripts/headroom.exe"
printf '#!/bin/sh\n[ "$1" = tool ] && [ "$2" = dir ] && printf "%%s" "%s"\n' "$W1UV" > "$W/uvbin/uv"; chmod +x "$W/uvbin/uv"
out=$(unset HCAT_PYTHON; PATH="$W/uvbin:/usr/bin:/bin" DOCTOR_VENV_DIR="$W/none" er resolve_engine_python)
check_eq "w1: uv tool dir python found" "$W1UV/headroom-ai/Scripts/python.exe" "$out"
out=$(unset HCAT_PYTHON; PATH="$W/uvbin:/usr/bin:/bin" DOCTOR_VENV_DIR="$W/none" er resolve_headroom_cli)
check_eq "w1: uv tool dir CLI found" "$W1UV/headroom-ai/Scripts/headroom.exe" "$out"

# w1. resolve_headroom_cli: HCAT_PYTHON dir authoritative; venv Scripts/headroom.exe; PATH
out=$(HCAT_PYTHON="$W1W/Scripts/python.exe" PATH="$W1P:/usr/bin:/bin" er resolve_headroom_cli)
check_eq "w1: CLI next to HCAT_PYTHON wins over PATH" "$W1W/Scripts/headroom.exe" "$out"
out=$(unset HCAT_PYTHON; PATH="/usr/bin:/bin" DOCTOR_VENV_DIR="$W1W" er resolve_headroom_cli)
check_eq "w1: CLI from venv Scripts/" "$W1W/Scripts/headroom.exe" "$out"
out=$(unset HCAT_PYTHON; PATH="$W1P:/usr/bin:/bin" DOCTOR_VENV_DIR="$W/none" er resolve_headroom_cli)
check_eq "w1: CLI from PATH" "$W1P/headroom" "$out"
check_eq "w1: CLI exits 1 when absent" "1" \
  "$(unset HCAT_PYTHON; PATH="/usr/bin:/bin" DOCTOR_VENV_DIR="$W/none" er resolve_headroom_cli >/dev/null; echo $?)"

# w1. win_path / unix_path: stubbed cygpath, else passthrough
# NOTE: written via printf '%s\n' (not echo) — /bin/sh here is bash-3.2 in
# POSIX mode, whose echo builtin interprets "\f" as a form-feed escape and
# would corrupt the literal "C:\fake\..." fixture value; printf's %s leaves
# its argument uninterpreted. See task-1-report.md for details.
cat > "$W/cygpath" <<'CYGEOF'
#!/bin/sh
case $1 in
  -w) printf '%s\n' "C:\\fake\\$(basename "$2")";;
  -u) p=$(printf '%s' "$2" | tr '\\' '/'); printf '%s\n' "${CYGPATH_UNIX_DIR:-/c/fake}/$(basename "$p")";;
esac
CYGEOF
chmod +x "$W/cygpath"
check_eq "w1: win_path via DOCTOR_CYGPATH" 'C:\fake\x.sh' "$(DOCTOR_CYGPATH="$W/cygpath" er win_path /tmp/x.sh)"
# real cygpath -u splits backslash-separated Windows paths natively; the stub
# normalizes "\" to "/" before basename() so it does the same (basename()
# itself only ever splits on "/").
check_eq "w1: unix_path via DOCTOR_CYGPATH" '/c/fake/x.sh' "$(DOCTOR_CYGPATH="$W/cygpath" er unix_path 'C:\x.sh')"
check_eq "w1: win_path passthrough without cygpath" "/tmp/x.sh" "$(unset DOCTOR_CYGPATH; PATH="/usr/bin:/bin" er win_path /tmp/x.sh)"

# w2. hcat: Windows venv layout resolved; exec env is UTF-8 safe
W2="$W/w2"; mkdir -p "$W2/venv/Scripts" "$W2/home"
# a fake python.exe that prints the env vars hcat is supposed to set, then its args
cat > "$W2/venv/Scripts/python.exe" <<'W2EOF'
#!/bin/sh
echo "ioenc=${PYTHONIOENCODING:-unset} utf8=${PYTHONUTF8:-unset} args=$*"
W2EOF
chmod +x "$W2/venv/Scripts/python.exe"
printf '{"k":1}' > "$W2/tiny.json"
out=$(env -u HCAT_PYTHON HOME="$W2/home" DOCTOR_VENV_DIR="$W2/venv" PATH="/usr/bin:/bin" bash "$HCAT" "$W2/tiny.json" 2>&1); rc=$?
check "w2: hcat resolves Scripts/python.exe" "args=- $W2/tiny.json" "$out"
check "w2: hcat sets PYTHONIOENCODING=utf-8" "ioenc=utf-8" "$out"
check "w2: hcat sets PYTHONUTF8=1"           "utf8=1"      "$out"
check_eq "w2: hcat exit 0" "0" "$rc"
# the legacy flat layout (no lib/ next to hcat) still resolves the plain venv
W2L="$W/w2legacy"; mkdir -p "$W2L/home/.headroom-venv/bin"
cp "$HCAT" "$W2L/hcat"; chmod +x "$W2L/hcat"
printf '#!/bin/sh\necho "legacy-py $*"\n' > "$W2L/home/.headroom-venv/bin/python"; chmod +x "$W2L/home/.headroom-venv/bin/python"
out=$(env -u HCAT_PYTHON -u DOCTOR_VENV_DIR HOME="$W2L/home" PATH="/usr/bin:/bin" bash "$W2L/hcat" "$W2/tiny.json" 2>&1)
check "w2: legacy flat hcat (no lib) still finds ~/.headroom-venv" "legacy-py" "$out"

# w3. gate + probe see a Scripts\python.exe engine
W3="$W/w3"; mkdir -p "$W3/venv/Scripts" "$W3/home"
printf '#!/bin/sh\nexit 0\n' > "$W3/venv/Scripts/python.exe"; chmod +x "$W3/venv/Scripts/python.exe"
out=$(gate_input "$BIGJSON" w3-g1 | env -u HCAT_PYTHON HOME="$W3/home" DOCTOR_VENV_DIR="$W3/venv" PATH="/usr/bin:/bin" \
      HEADROOM_STATE_DIR="$W3/state" bash "$GATE"); rc=$?
check "w3: gate denies with a Scripts/ engine" "deny" "$out"
check_eq "w3: gate exit 0" "0" "$rc"
PROBE="$ROOT/scripts/session-probe.sh"
out=$(printf '{"session_id":"w3"}' | env -u HCAT_PYTHON HOME="$W3/home" DOCTOR_VENV_DIR="$W3/venv" PATH="/usr/bin:/bin" \
      HEADROOM_STATE_DIR="$W3/state" bash "$PROBE"); rc=$?
check_absent "w3: probe does not call a Scripts/ engine 'not installed'" "engine not installed" "$out"
check_eq "w3: probe exit 0" "0" "$rc"

# w4. doctor: engine found in a Scripts/ venv; bootstrap works with `python` only
W4="$W/w4"; mkdir -p "$W4/cd" "$W4/venv/Scripts"
printf '#!/bin/sh\nexit 0\n' > "$W4/venv/Scripts/python.exe"; chmod +x "$W4/venv/Scripts/python.exe"
S4="$W4/s.json"; doc_settings_wired "$W4/cd" > "$S4"
out=$(env -u HCAT_PYTHON PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S4" DOCTOR_CLAUDE_DIR="$W4/cd" \
      DOCTOR_VENV_DIR="$W4/venv" bash "$DOCTOR" 2>&1)
check "w4: doctor engine via Scripts/python.exe" "engine python: $W4/venv/Scripts/python.exe" "$out"

# a toolchain with `python` but NO `python3` (typical Windows) — stub creates a Scripts/ venv
W4B="$W/w4boot"; mkdir -p "$W4B/stub" "$W4B/cd"
link_tool "$(command -v jq)" "$W4B/stub/jq"
cat > "$W4B/stub/python" <<'W4EOF'
#!/bin/sh
if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
  mkdir -p "$3/Scripts"
  printf '#!/bin/sh\necho "$@" >> "$(dirname "$0")/../pip.calls"\n' > "$3/Scripts/pip.exe"
  printf '#!/bin/sh\nexit 0\n' > "$3/Scripts/python.exe"
  printf 'MZ() { :; }\nexit 0\n' > "$3/Scripts/headroom.exe"   # PE magic (review #3) yet still shell-runnable
  chmod +x "$3/Scripts/pip.exe" "$3/Scripts/python.exe" "$3/Scripts/headroom.exe"
fi
exit 0
W4EOF
chmod +x "$W4B/stub/python"
S4B="$W4B/s.json"; doc_settings_wired "$W4B/cd" > "$S4B"
# DOCTOR_OS=windows forces the py/python/python3 preference order used by a real
# Windows toolchain; without it, this POSIX test box's real /usr/bin/python3
# would be tried first (same macOS-python3 hazard the w4none note calls out).
out=$(env -u HCAT_PYTHON PATH="$W4B/stub:/usr/bin:/bin" DOCTOR_OS=windows DOCTOR_SETTINGS="$S4B" DOCTOR_CLAUDE_DIR="$W4B/cd" \
      DOCTOR_VENV_DIR="$W4B/venv" DOCTOR_SHIM_DIR="$W4B/shim" bash "$DOCTOR" --fix 2>&1)
check "w4: bootstrap succeeds with python (no python3)" "engine bootstrapped: python -m venv" "$out"
check "w4: bootstrap used Scripts/pip.exe" "install headroom-ai[all]" "$(cat "$W4B/venv/pip.calls" 2>/dev/null)"
# no interpreter at all → honest FAIL naming what was tried
W4N="$W/w4none"; mkdir -p "$W4N/stub" "$W4N/cd"; link_tool "$(command -v jq)" "$W4N/stub/jq"
# shadow /usr/bin/python3 so the FAIL branch (not a real bootstrap) is exercised
printf '#!/bin/sh\nexit 1\n' > "$W4N/stub/python3"; chmod +x "$W4N/stub/python3"
printf '#!/bin/sh\nexit 1\n' > "$W4N/stub/python"; chmod +x "$W4N/stub/python"
S4N="$W4N/s.json"; doc_settings_wired "$W4N/cd" > "$S4N"
out=$(env -u HCAT_PYTHON PATH="$W4N/stub:/usr/bin:/bin" DOCTOR_SETTINGS="$S4N" DOCTOR_CLAUDE_DIR="$W4N/cd" \
      DOCTOR_VENV_DIR="$W4N/venv" bash "$DOCTOR" --fix 2>&1)
check "w4: no interpreter → FAIL names python3/python/py -3" "python3, python, py -3" "$out"

# w5. doctor 4b greens the bare command and names the CLI check
out=$(HCAT_PYTHON="$FENG/python" PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S4" DOCTOR_CLAUDE_DIR="$W4/cd" \
      DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check "w5: 4b ok for bare command" ".mcp.json spawns \`headroom mcp serve\` by name" "$out"

# w6. check 2b: shim + verify
W6="$W/w6"; mkdir -p "$W6/cd" "$W6/venv/bin" "$W6/shim"
printf '#!/bin/sh\nexit 0\n' > "$W6/venv/bin/python";   chmod +x "$W6/venv/bin/python"
printf '#!/bin/sh\necho hr\n' > "$W6/venv/bin/headroom"; chmod +x "$W6/venv/bin/headroom"
S6="$W6/s.json"; doc_settings_wired "$W6/cd" > "$S6"
# engine found in the venv, headroom NOT on PATH → fixable
out=$(env -u HCAT_PYTHON PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S6" DOCTOR_CLAUDE_DIR="$W6/cd" \
      DOCTOR_VENV_DIR="$W6/venv" DOCTOR_SHIM_DIR="$W6/shim" bash "$DOCTOR" 2>&1)
check "w6: CLI off PATH is fixable" "headroom CLI not on PATH (engine at $W6/venv/bin/headroom)" "$out"
# --fix with the shim dir ON PATH → fixed, shim is a symlink to the venv CLI
out=$(env -u HCAT_PYTHON PATH="$W6/shim:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S6" DOCTOR_CLAUDE_DIR="$W6/cd" \
      DOCTOR_VENV_DIR="$W6/venv" DOCTOR_SHIM_DIR="$W6/shim" bash "$DOCTOR" --fix 2>&1)
check "w6: --fix shims and verifies" "headroom shimmed to $W6/shim/headroom (resolves on PATH)" "$out"
check_eq "w6: shim is a symlink to the venv CLI" "$W6/venv/bin/headroom" "$(readlink "$W6/shim/headroom")"
# second run: ok, no change
out=$(env -u HCAT_PYTHON PATH="$W6/shim:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S6" DOCTOR_CLAUDE_DIR="$W6/cd" \
      DOCTOR_VENV_DIR="$W6/venv" DOCTOR_SHIM_DIR="$W6/shim" bash "$DOCTOR" --fix 2>&1)
check "w6: second --fix reports ok" "headroom CLI on PATH ($W6/shim/headroom)" "$out"
check_absent "w6: second --fix does not re-shim" "headroom shimmed" "$out"
# --fix with the shim dir NOT on PATH → FAIL with the exact snippet
W6N="$W/w6nopath"; mkdir -p "$W6N/cd" "$W6N/shim"
S6N="$W6N/s.json"; doc_settings_wired "$W6N/cd" > "$S6N"
out=$(env -u HCAT_PYTHON SHELL=/bin/zsh PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S6N" DOCTOR_CLAUDE_DIR="$W6N/cd" \
      DOCTOR_VENV_DIR="$W6/venv" DOCTOR_SHIM_DIR="$W6N/shim" bash "$DOCTOR" --fix 2>&1); rc=$?
check "w6: unresolved after shim is FAIL" "but $W6N/shim is not on PATH" "$out"
check "w6: FAIL carries the zsh snippet" "export PATH=\"$W6N/shim:\$PATH\"' >> ~/.zshrc" "$out"
check_eq "w6: doctor exits 1 on that FAIL" "1" "$rc"
# Windows: the shim is a COPY named headroom.exe and the hint names the user Path
W6W="$W/w6win"; mkdir -p "$W6W/cd" "$W6W/venv/Scripts" "$W6W/shim"
printf '#!/bin/sh\nexit 0\n' > "$W6W/venv/Scripts/python.exe";  chmod +x "$W6W/venv/Scripts/python.exe"
# review #3: the Windows copy branch now refuses a non-PE CLI, so this fixture
# must start with the "MZ" magic. It is still runnable here because the bytes
# are also valid shell: bash falls back to running a non-binary file as a
# script when execve returns ENOEXEC, so shim_runs' `--help` still succeeds.
printf 'MZ() { :; }\nexit 0\n' > "$W6W/venv/Scripts/headroom.exe"; chmod +x "$W6W/venv/Scripts/headroom.exe"
S6W="$W6W/s.json"; doc_settings_wired "$W6W/cd" > "$S6W"
out=$(env -u HCAT_PYTHON DOCTOR_OS=windows PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S6W" DOCTOR_CLAUDE_DIR="$W6W/cd" \
      DOCTOR_VENV_DIR="$W6W/venv" DOCTOR_SHIM_DIR="$W6W/shim" bash "$DOCTOR" --fix 2>&1)
if [ -f "$W6W/shim/headroom.exe" ] && [ ! -L "$W6W/shim/headroom.exe" ]; then
  echo "ok - w6: windows shim is a copy named headroom.exe"; PASS=$((PASS+1))
else
  echo "FAIL - w6: windows shim is a copy named headroom.exe"; FAIL=$((FAIL+1))
fi
# review #14: the hint interpolates the SHIM_DIR this run actually uses instead
# of a hardcoded %USERPROFILE%\.local\bin that contradicted the line beside it
check "w6: windows hint names the shim dir this run uses" "add $W6W/shim to your user Path" "$out"
# no engine at all → skip (check 2 already says fixable)
out=$(env -u HCAT_PYTHON PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S6N" DOCTOR_CLAUDE_DIR="$W6N/cd" \
      DOCTOR_VENV_DIR="$W/none" DOCTOR_SHIM_DIR="$W6N/shim2" bash "$DOCTOR" 2>&1)
check "w6: no engine → CLI check skips" "headroom CLI on PATH (no engine yet" "$out"

# w7. Windows status-line wiring + Git Bash prerequisite
W7="$W/w7"; mkdir -p "$W7/cd" "$W7/bashdir"
printf '#!/bin/sh\nexit 0\n' > "$W7/bashdir/bash.exe"; chmod +x "$W7/bashdir/bash.exe"
S7="$W7/s.json"; printf '{}\n' > "$S7"
# check 7 now validates the INTERPRETER token too, not just the script token.
# The stub cygpath is deliberately lossy (it keeps only the basename and
# re-roots onto CYGPATH_UNIX_DIR), so the "C:\fake\bash.exe" this fixture ends
# up wiring translates back to $W7/cd/bash.exe — put a real file there so a
# HEALTHY wiring stays healthy under the stub's round trip. On a real host
# cygpath is lossless and the round trip lands on the actual bash.
mkdir -p "$W7/cd"; printf '#!/bin/sh\nexit 0\n' > "$W7/cd/bash.exe"; chmod +x "$W7/cd/bash.exe"
# NOTE: CLAUDE_CODE_GIT_BASH_PATH is the REAL bash.exe fixture created above
# ($W7/bashdir/bash.exe), not a fabricated 'C:\...' literal: check 0 does a
# direct `-f` test with no cygpath translation (real Git Bash's MSYS runtime
# already translates a native Windows path for free, so doctor.sh never needs
# to convert it itself) -- a literal backslash string can never resolve to a
# real file outside real Git Bash, so a hermetic non-Windows test host needs
# an existing path here to exercise the "present" branch at all. See
# task-7-report.md for why this departs from the brief's literal fixture.
out=$(env -u HCAT_PYTHON DOCTOR_OS=windows DOCTOR_CYGPATH="$W/cygpath" CYGPATH_UNIX_DIR="$W7/cd" CLAUDE_CODE_GIT_BASH_PATH="$W7/bashdir/bash.exe" \
      PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S7" DOCTOR_CLAUDE_DIR="$W7/cd" DOCTOR_VENV_DIR="$NOVENV" \
      DOCTOR_SHIM_DIR="$W7/shim" bash "$DOCTOR" --fix 2>&1)
check "w7: windows wire reports fixed" "statusLine wired to" "$out"
# review #9: an ACCEPTED CLAUDE_CODE_GIT_BASH_PATH is normalized through
# win_path too (it may be POSIX-spelled), so the stub cygpath rewrites this
# fixture's own path the same way it rewrites the script path.
check_eq "w7: windows statusLine command shape" '"C:\fake\bash.exe" "C:\fake\headroom-statusline.sh"' \
  "$(jq -r '.statusLine.command' "$S7")"
check "w7: doctor names Git Bash on Windows" "Windows (Git Bash)" "$out"
# re-run: check 7 must recognise the backslash token as the canonical copy (no re-wire, no FAIL)
out=$(env -u HCAT_PYTHON DOCTOR_OS=windows DOCTOR_CYGPATH="$W/cygpath" CYGPATH_UNIX_DIR="$W7/cd" CLAUDE_CODE_GIT_BASH_PATH="$W7/bashdir/bash.exe" \
      PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S7" DOCTOR_CLAUDE_DIR="$W7/cd" DOCTOR_VENV_DIR="$NOVENV" \
      DOCTOR_SHIM_DIR="$W7/shim" bash "$DOCTOR" 2>&1)
check "w7: re-run sees the wiring as healthy" "statusLine wired (" "$out"
check_absent "w7: re-run does not FAIL the windows path" "no such file exists" "$out"
# CLAUDE_CODE_GIT_BASH_PATH pointing nowhere → FAIL
out=$(env -u HCAT_PYTHON DOCTOR_OS=windows CLAUDE_CODE_GIT_BASH_PATH="$W7/missing/bash.exe" PATH="$FENG:$STUB:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$S7" DOCTOR_CLAUDE_DIR="$W7/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check "w7: broken CLAUDE_CODE_GIT_BASH_PATH is FAIL" "hooks and the status line run through Git Bash" "$out"
# the FAIL must be ACTIONABLE (review doc item 2): the usual cause is a stale
# variable on a box that already has Git Bash, so it names where the value lives
check "w7: that FAIL names settings.json env as the fix point" "fix that path in settings.json env" "$out"
check "w7: that FAIL still names the Git for Windows requirement" "Git for Windows" "$out"
# probe: same prerequisite, one problem line
out=$(printf '{"session_id":"w7"}' | env -u HCAT_PYTHON DOCTOR_OS=windows CLAUDE_CODE_GIT_BASH_PATH="$W7/missing/bash.exe" \
      HOME="$W7" HEADROOM_STATE_DIR="$W7/state" bash "$PROBE")
check "w7: probe flags a broken Git Bash path" "Git Bash" "$out"
# POSIX wiring unchanged
S7U="$W7/su.json"; printf '{}\n' > "$S7U"
env -u HCAT_PYTHON DOCTOR_OS=unix PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S7U" DOCTOR_CLAUDE_DIR="$W7/cdu" \
  DOCTOR_VENV_DIR="$NOVENV" DOCTOR_SHIM_DIR="$W7/shim" bash "$DOCTOR" --fix >/dev/null 2>&1
check_eq "w7: posix statusLine command unchanged" "bash \"$W7/cdu/headroom-statusline.sh\"" "$(jq -r '.statusLine.command' "$S7U")"

# w9. CI files exist and are well-formed
WF="$ROOT/.github/workflows/test.yml"
check "w9: workflow has a windows-latest job" "windows-latest" "$(cat "$WF" 2>/dev/null)"
check "w9: workflow runs the suite on ubuntu+macos" "macos-latest" "$(cat "$WF" 2>/dev/null)"
check "w9: windows job runs windows-check.sh" "scripts/ci/windows-check.sh" "$(cat "$WF" 2>/dev/null)"
check "w9: spawn probe exists" "child_process" "$(cat "$ROOT/scripts/ci/spawn-probe.mjs" 2>/dev/null)"
if [ -x "$ROOT/scripts/ci/windows-check.sh" ]; then echo "ok - w9: windows-check.sh executable"; PASS=$((PASS+1)); else echo "FAIL - w9: windows-check.sh executable"; FAIL=$((FAIL+1)); fi

# w10. docs + manifests
check "w10: README has a Windows section"      "## Windows"           "$(cat "$ROOT/README.md")"
check "w10: README names Git Bash prerequisite" "Git for Windows"     "$(cat "$ROOT/README.md")"
check "w10: README upgrade note for the shim"   "headroom on PATH"    "$(cat "$ROOT/README.md")"
check_absent "w10: README no launcher"          "mcp-launcher"        "$(cat "$ROOT/README.md")"
check_eq "w10: plugin.json 2.8.0"      "2.8.0" "$(jq -r .version "$ROOT/.claude-plugin/plugin.json")"
check_eq "w10: marketplace.json 2.8.0" "2.8.0" "$(jq -r '.plugins[0].version // .version' "$ROOT/.claude-plugin/marketplace.json")"

# w11. final whole-branch review fix wave (C1, I1, I2, I3, M4 + shim idempotency)

# w11-C1. The window between a plugin update and the next `/doctor --fix`: a
# v2.7.x install whose engine lives in the doctor's own venv still RESOLVES, but
# the v2.8 .mcp.json spawns the bare name, so its MCP stops connecting with no
# in-product signal (the badge's "idle" is indistinguishable from "nothing
# compressed yet"). The SessionStart probe must nudge — via add_problem, NOT
# note_error: this is a setup gap, not a breakage, so it must not flip the badge
# to "broken" (same reasoning as the never-installed case).
W11="$W/w11"; mkdir -p "$W11/venv/bin" "$W11/home"
printf '#!/bin/sh\nexit 0\n'  > "$W11/venv/bin/python";   chmod +x "$W11/venv/bin/python"
printf '#!/bin/sh\necho hr\n' > "$W11/venv/bin/headroom"; chmod +x "$W11/venv/bin/headroom"
out=$(printf '{"session_id":"w11"}' | env -u HCAT_PYTHON HOME="$W11/home" DOCTOR_VENV_DIR="$W11/venv" \
      PATH="$STUB:/usr/bin:/bin" HEADROOM_STATE_DIR="$W11/state" bash "$PROBE"); rc=$?
check        "w11: probe nudges when the engine resolves but headroom is off PATH" "not on PATH" "$out"
check        "w11: the nudge names the v2.8 bare-name MCP spawn" "the bundled MCP spawns it by name" "$out"
check_absent "w11: an off-PATH engine is not reported as never-installed" "engine not installed" "$out"
check_eq     "w11: probe exits 0 on the PATH nudge" "0" "$rc"
check_eq     "w11: probe still prints exactly one line" "1" "$(printf '%s\n' "$out" | grep -c .)"
check_eq     "w11: the nudge is a well-formed SessionStart line" "SessionStart" \
             "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)"
if [ -f "$W11/state/last-error" ]; then
  echo "FAIL - w11: the PATH nudge does not flip the badge to broken"; FAIL=$((FAIL+1))
else
  echo "ok - w11: the PATH nudge does not flip the badge to broken"; PASS=$((PASS+1))
fi
# the same install with the engine's bin dir on PATH → silent
out=$(printf '{"session_id":"w11b"}' | env -u HCAT_PYTHON HOME="$W11/home" DOCTOR_VENV_DIR="$W11/venv" \
      PATH="$W11/venv/bin:$STUB:/usr/bin:/bin" HEADROOM_STATE_DIR="$W11/state" bash "$PROBE")
check_absent "w11: no nudge once headroom resolves on PATH" "not on PATH" "$out"

# w11-I1. spec §1: the doctor's lib-provisioning must ship engine-resolve.sh too.
# A legacy FLAT install repaired with `/doctor --fix` (rather than by re-running
# the SKILL.md installer) otherwise gets a ~/.claude/lib without it, and its flat
# hcat / hcat-gate.sh / session-probe.sh permanently run on the minimal inline
# fallback (HCAT_PYTHON → ~/.headroom-venv only) — no uv-tool, no shebang and no
# Scripts/ resolution, for exactly the population that fallback exists to protect.
W11D="$W/w11lib"; mkdir -p "$W11D/cd"
S11D="$W11D/s.json"; printf '{}\n' > "$S11D"
out=$(env -u HCAT_PYTHON PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S11D" \
      DOCTOR_CLAUDE_DIR="$W11D/cd" DOCTOR_VENV_DIR="$NOVENV" DOCTOR_SHIM_DIR="$W11D/shim" \
      HEADROOM_STATE_DIR="$W11D/state" bash "$DOCTOR" --fix 2>&1)
if cmp -s "$ROOT/scripts/lib/engine-resolve.sh" "$W11D/cd/lib/engine-resolve.sh"; then
  echo "ok - w11: --fix provisions lib/engine-resolve.sh byte-identical to the plugin's"; PASS=$((PASS+1))
else
  echo "FAIL - w11: --fix provisions lib/engine-resolve.sh byte-identical to the plugin's"; FAIL=$((FAIL+1))
fi
# NOTE (review #13): engine-resolve.sh is reported on its OWN line, separate from
# the badge deps — it is not a badge dep and is never demanded next to a
# custom-path copy the doctor refuses to write to.
check "w11: the badge deps are reported without engine-resolve.sh" \
      "statusline lib deps current (attribution.jq, headroom-state.sh)" "$out"
check "w11: the shared engine resolver gets its own ok line" \
      "shared engine resolver current ($W11D/cd/lib/engine-resolve.sh)" "$out"
# and a missing engine-resolve.sh ALONE is reported, not masked by the other two
rm -f "$W11D/cd/lib/engine-resolve.sh"
out=$(env -u HCAT_PYTHON PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S11D" \
      DOCTOR_CLAUDE_DIR="$W11D/cd" DOCTOR_VENV_DIR="$NOVENV" DOCTOR_SHIM_DIR="$W11D/shim" \
      HEADROOM_STATE_DIR="$W11D/state" bash "$DOCTOR" 2>&1)
check        "w11: a missing engine-resolve.sh alone is reported fixable" \
             "shared engine resolver missing/stale (engine-resolve.sh)" "$out"
check_absent "w11: a missing engine-resolve.sh does not drag the badge deps down with it" \
             "statusline lib deps missing/stale" "$out"

# w11-I3 + idempotency. The shim is verified by EXECUTION, not just by name
# resolution, and the shim path stays idempotent (a second --fix prints no
# `fixed` line at all — the one cross-platform regression the Windows gate exists
# to catch).
W11S="$W/w11shim"; mkdir -p "$W11S/cd/lib" "$W11S/venv/bin" "$W11S/shim"
printf '#!/bin/sh\nexit 0\n'  > "$W11S/venv/bin/python";   chmod +x "$W11S/venv/bin/python"
printf '#!/bin/sh\necho hr\n' > "$W11S/venv/bin/headroom"; chmod +x "$W11S/venv/bin/headroom"
S11S="$W11S/s.json"; doc_settings_wired "$W11S/cd" > "$S11S"
cp "$ROOT/scripts/statusline.sh" "$W11S/cd/headroom-statusline.sh"
cp "$ROOT/scripts/lib/attribution.jq" "$ROOT/scripts/lib/headroom-state.sh" \
   "$ROOT/scripts/lib/engine-resolve.sh" "$W11S/cd/lib/"
run1=$(env -u HCAT_PYTHON PATH="$W11S/shim:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S11S" \
       DOCTOR_CLAUDE_DIR="$W11S/cd" DOCTOR_VENV_DIR="$W11S/venv" DOCTOR_SHIM_DIR="$W11S/shim" \
       HEADROOM_STATE_DIR="$W11S/state" bash "$DOCTOR" --fix 2>&1)
run2=$(env -u HCAT_PYTHON PATH="$W11S/shim:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S11S" \
       DOCTOR_CLAUDE_DIR="$W11S/cd" DOCTOR_VENV_DIR="$W11S/venv" DOCTOR_SHIM_DIR="$W11S/shim" \
       HEADROOM_STATE_DIR="$W11S/state" bash "$DOCTOR" --fix 2>&1)
check    "w11: run 1 shims the venv CLI and verifies it runs" \
         "headroom shimmed to $W11S/shim/headroom (resolves on PATH)" "$run1"
check    "w11: run 2 sees the shim already on PATH" "headroom CLI on PATH ($W11S/shim/headroom)" "$run2"
check_eq "w11: run 2 of --fix prints no ^fixed lines (idempotent shim path)" "0" \
         "$(printf '%s\n' "$run2" | grep -cE '^fixed ')"
# a shim that RESOLVES by name but does not start (uv's relocatable trampolines, a
# name-squatted `headroom`, a broken console script) must not be reported `fixed`
W11X="$W/w11norun"; mkdir -p "$W11X/cd" "$W11X/venv/bin" "$W11X/shim"
printf '#!/bin/sh\nexit 0\n' > "$W11X/venv/bin/python";   chmod +x "$W11X/venv/bin/python"
printf '#!/bin/sh\nexit 1\n' > "$W11X/venv/bin/headroom"; chmod +x "$W11X/venv/bin/headroom"
S11X="$W11X/s.json"; doc_settings_wired "$W11X/cd" > "$S11X"
out=$(env -u HCAT_PYTHON PATH="$W11X/shim:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S11X" \
      DOCTOR_CLAUDE_DIR="$W11X/cd" DOCTOR_VENV_DIR="$W11X/venv" DOCTOR_SHIM_DIR="$W11X/shim" \
      HEADROOM_STATE_DIR="$W11X/state" bash "$DOCTOR" --fix 2>&1); rc=$?
check        "w11: a shim that resolves but does not run is a FAIL" \
             "headroom shimmed to $W11X/shim/headroom but it does not run (\`$W11X/shim/headroom --help\` failed)" "$out"
check        "w11: the does-not-run FAIL carries the reinstall hint" \
             "reinstall the engine: $W11X/venv/bin/python -m pip install \"headroom-ai[all]\"" "$out"
check_absent "w11: a non-running shim is never reported fixed" "(resolves on PATH)" "$out"
check_eq     "w11: doctor exits 1 on the does-not-run FAIL" "1" "$rc"

# w11-I2. ~/.local/bin is NOT doctor-owned territory: pipx, `uv tool install` and
# `pip install --user` put real binaries there. A pre-existing FOREIGN `headroom`
# with that dir off the CURRENT PATH is the exact shape that used to be silently
# replaced by a symlink into ~/.headroom-venv — unrecoverable, no backup. Refuse,
# name it, and leave the file untouched.
W11F="$W/w11foreign"; mkdir -p "$W11F/cd" "$W11F/shim"
printf '#!/bin/sh\necho pipx-headroom\n' > "$W11F/shim/headroom"; chmod +x "$W11F/shim/headroom"
w11f_before=$(cat "$W11F/shim/headroom")
S11F="$W11F/s.json"; doc_settings_wired "$W11F/cd" > "$S11F"
out=$(env -u HCAT_PYTHON PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S11F" DOCTOR_CLAUDE_DIR="$W11F/cd" \
      DOCTOR_VENV_DIR="$W11S/venv" DOCTOR_SHIM_DIR="$W11F/shim" HEADROOM_STATE_DIR="$W11F/state" \
      bash "$DOCTOR" --fix 2>&1); rc=$?
check    "w11: a foreign headroom in the shim dir is refused, not clobbered" \
         "a different headroom already exists at $W11F/shim/headroom — not on PATH; add $W11F/shim to PATH or remove that file, then re-run --fix" "$out"
check_eq "w11: the foreign binary is left byte-for-byte alone" "$w11f_before" "$(cat "$W11F/shim/headroom")"
check_eq "w11: doctor exits 1 on the foreign-shim FAIL" "1" "$rc"
if [ -L "$W11F/shim/headroom" ]; then
  echo "FAIL - w11: the foreign binary was not turned into a symlink"; FAIL=$((FAIL+1))
else
  echo "ok - w11: the foreign binary was not turned into a symlink"; PASS=$((PASS+1))
fi

# w11-M4. "engine python found but no `headroom` CLI next to it" — the FAIL branch
# had no fixture (deferred item 12), and its hint used to suggest pip-installing
# into whatever $PY was, i.e. the SYSTEM interpreter for an HCAT_PYTHON user.
W11M="$W/w11nocli"; mkdir -p "$W11M/cd" "$W11M/venv/bin"
printf '#!/bin/sh\nexit 0\n' > "$W11M/venv/bin/python"; chmod +x "$W11M/venv/bin/python"
S11M="$W11M/s.json"; doc_settings_wired "$W11M/cd" > "$S11M"
out=$(env -u HCAT_PYTHON PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S11M" DOCTOR_CLAUDE_DIR="$W11M/cd" \
      DOCTOR_VENV_DIR="$W11M/venv" DOCTOR_SHIM_DIR="$W11M/shim" HEADROOM_STATE_DIR="$W11M/state" \
      bash "$DOCTOR" 2>&1); rc=$?
check    "w11: an engine python with no sibling CLI is a FAIL" \
         "engine python found ($W11M/venv/bin/python) but no \`headroom\` CLI next to it" "$out"
check    "w11: that FAIL's hint names the resolved interpreter" \
         "reinstall: $W11M/venv/bin/python -m pip install \"headroom-ai[all]\"" "$out"
check_eq "w11: the no-CLI FAIL exits 1" "1" "$rc"
# with HCAT_PYTHON authoritative, pip-ing $PY may be the SYSTEM python — say so instead
out=$(HCAT_PYTHON="$W11M/venv/bin/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S11M" \
      DOCTOR_CLAUDE_DIR="$W11M/cd" DOCTOR_VENV_DIR="$NOVENV" DOCTOR_SHIM_DIR="$W11M/shim" \
      HEADROOM_STATE_DIR="$W11M/state" bash "$DOCTOR" 2>&1)
check        "w11: the HCAT_PYTHON hint names the override, not a pip command" \
             "install headroom-ai into the interpreter HCAT_PYTHON points at, or unset HCAT_PYTHON" "$out"
check_absent "w11: the HCAT_PYTHON hint does not suggest -m pip install" "-m pip install" "$out"


# w12. verified-review wave: statusLine command injection (#2), execution
# verification of an already-on-PATH headroom (#5), removal of a dead shim the
# doctor itself wrote (#7), engine-resolve.sh off the custom-path badge-dep loop
# (#13), the flat ~/.claude/lib resolver lookup (#11), the inline fallback's
# PATH-sibling tier (#12), the Windows project-dir name hijack (#1) and the
# stats-event write that used to die with `import fcntl` on Windows (#6).

# w12-#2. CLAUDE_CODE_GIT_BASH_PATH is env, and env can come from a PROJECT
# settings.json — i.e. from repo config. `--fix` persists sl_hr_cmd's output into
# ~/.claude/settings.json as statusLine.command, which Claude Code EXECUTES, so a
# value carrying a double quote closes our quoting and appends commands. The
# value must be refused (not merely FAILed elsewhere and then written anyway).
W12A="$W/w12inj"; mkdir -p "$W12A/cd"
S12A="$W12A/s.json"; printf '{}\n' > "$S12A"
env -u HCAT_PYTHON DOCTOR_OS=windows DOCTOR_CYGPATH="$W/cygpath" \
    CLAUDE_CODE_GIT_BASH_PATH='C:\bash.exe" & calc.exe & "' \
    PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S12A" DOCTOR_CLAUDE_DIR="$W12A/cd" \
    DOCTOR_VENV_DIR="$NOVENV" DOCTOR_SHIM_DIR="$W12A/shim" bash "$DOCTOR" --fix >/dev/null 2>&1
cmd12=$(jq -r '.statusLine.command' "$S12A")
check_absent "w12: an injected CLAUDE_CODE_GIT_BASH_PATH never reaches statusLine.command" \
             "calc.exe" "$cmd12"
check_absent "w12: and not anywhere else in settings.json either" "calc.exe" "$(cat "$S12A")"
check_eq     "w12: the quote-bearing value is dropped for the PATH bash fallback" \
             '"C:\fake\bash" "C:\fake\headroom-statusline.sh"' "$cmd12"
# a quote-free value that simply does not exist is refused the same way
S12A2="$W12A/s2.json"; printf '{}\n' > "$S12A2"
env -u HCAT_PYTHON DOCTOR_OS=windows DOCTOR_CYGPATH="$W/cygpath" \
    CLAUDE_CODE_GIT_BASH_PATH="$W12A/missing/bash.exe" \
    PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S12A2" DOCTOR_CLAUDE_DIR="$W12A/cd2" \
    DOCTOR_VENV_DIR="$NOVENV" DOCTOR_SHIM_DIR="$W12A/shim" bash "$DOCTOR" --fix >/dev/null 2>&1
check_eq "w12: a missing Git Bash override falls back rather than being written through" \
         '"C:\fake\bash" "C:\fake\headroom-statusline.sh"' "$(jq -r '.statusLine.command' "$S12A2")"

# w12-#5. `command -v headroom` succeeding is a NAME lookup, nothing more. A
# headroom on PATH that does not start (relocated uv trampoline, broken console
# script, name squatter) means the bundled MCP cannot connect — so this branch
# must verify by EXECUTION, exactly like the shim branch below it always has.
W12C="$W/w12deadpath"; mkdir -p "$W12C/cd" "$W12C/bin" "$W12C/venv/bin"
printf '#!/bin/sh\nexit 1\n' > "$W12C/bin/headroom";    chmod +x "$W12C/bin/headroom"
printf '#!/bin/sh\nexit 0\n' > "$W12C/venv/bin/python"; chmod +x "$W12C/venv/bin/python"
S12C="$W12C/s.json"; doc_settings_wired "$W12C/cd" > "$S12C"
out=$(env -u HCAT_PYTHON PATH="$W12C/bin:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S12C" \
      DOCTOR_CLAUDE_DIR="$W12C/cd" DOCTOR_VENV_DIR="$W12C/venv" DOCTOR_SHIM_DIR="$W12C/shim" \
      HEADROOM_STATE_DIR="$W12C/state" bash "$DOCTOR" 2>&1); rc=$?
check        "w12: a headroom on PATH that does not run is a FAIL" \
             "headroom on PATH at $W12C/bin/headroom does not run" "$out"
check        "w12: that FAIL says the bundled MCP will not connect" \
             "the bundled MCP spawns \`headroom\` by name and will fail to connect" "$out"
check        "w12: that FAIL carries the reinstall hint" \
             "reinstall the engine: $W12C/venv/bin/python -m pip install \"headroom-ai[all]\"" "$out"
check_absent "w12: a dead headroom on PATH is never greened as verified" \
             "headroom CLI on PATH ($W12C/bin/headroom)" "$out"
check_eq     "w12: doctor exits 1 on the dead-PATH-headroom FAIL" "1" "$rc"
if [ -f "$W12C/bin/headroom" ]; then
  echo "ok - w12: a headroom the doctor did not write is never deleted"; PASS=$((PASS+1))
else
  echo "FAIL - w12: a headroom the doctor did not write is never deleted"; FAIL=$((FAIL+1))
fi

# w12-#7. The shim branch's does-not-run FAIL used to LEAVE the dead file behind,
# so the next run took #5's `command -v headroom` branch and greened it. Remove
# what this run wrote, and say so.
W12B="$W/w12deadshim"; mkdir -p "$W12B/cd" "$W12B/venv/bin" "$W12B/shim"
printf '#!/bin/sh\nexit 0\n' > "$W12B/venv/bin/python";   chmod +x "$W12B/venv/bin/python"
printf '#!/bin/sh\nexit 1\n' > "$W12B/venv/bin/headroom"; chmod +x "$W12B/venv/bin/headroom"
S12B="$W12B/s.json"; doc_settings_wired "$W12B/cd" > "$S12B"
out=$(env -u HCAT_PYTHON PATH="$W12B/shim:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S12B" \
      DOCTOR_CLAUDE_DIR="$W12B/cd" DOCTOR_VENV_DIR="$W12B/venv" DOCTOR_SHIM_DIR="$W12B/shim" \
      HEADROOM_STATE_DIR="$W12B/state" bash "$DOCTOR" --fix 2>&1); rc=$?
check    "w12: the does-not-run FAIL reports the shim was removed" \
         "(the broken shim was removed)" "$out"
check_eq "w12: doctor still exits 1 after removing the dead shim" "1" "$rc"
if [ -e "$W12B/shim/headroom" ]; then
  echo "FAIL - w12: the dead shim is gone from disk"; FAIL=$((FAIL+1))
else
  echo "ok - w12: the dead shim is gone from disk"; PASS=$((PASS+1))
fi
# and the run after it diagnoses the engine again instead of greening a dead file
out=$(env -u HCAT_PYTHON PATH="$W12B/shim:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S12B" \
      DOCTOR_CLAUDE_DIR="$W12B/cd" DOCTOR_VENV_DIR="$W12B/venv" DOCTOR_SHIM_DIR="$W12B/shim" \
      HEADROOM_STATE_DIR="$W12B/state" bash "$DOCTOR" 2>&1)
check_absent "w12: the next run does not green the removed shim" \
             "headroom CLI on PATH ($W12B/shim/headroom)" "$out"
check        "w12: the next run reports the CLI as off PATH again" \
             "headroom CLI not on PATH (engine at $W12B/venv/bin/headroom)" "$out"

# w12-#13. engine-resolve.sh is not a badge dep. Demanding it next to a
# custom-path statusline copy — a directory the doctor refuses to write into —
# produced a FAIL that `--fix` could never clear, so the doctor exited nonzero
# forever. It belongs on its own line, resolved and repaired under $CLAUDE_DIR.
W12D="$W/w12custom"; mkdir -p "$W12D/cd" "$W12D/custom/lib"
cp "$ROOT/scripts/statusline.sh" "$W12D/custom/headroom-statusline.sh"
cp "$ROOT/scripts/lib/attribution.jq" "$ROOT/scripts/lib/headroom-state.sh" "$W12D/custom/lib/"
jq -n --arg c "$W12D/custom/headroom-statusline.sh" \
  '{statusLine:{type:"command",command:("bash \"" + $c + "\"")}}' > "$W12D/s.json"
d12() {  # d12 [--fix] — one doctor run against the custom-path fixture
  HCAT_PYTHON="$FENG/python" PATH="$FENG:$STUB:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$W12D/s.json" DOCTOR_CLAUDE_DIR="$W12D/cd" DOCTOR_VENV_DIR="$NOVENV" \
      DOCTOR_SHIM_DIR="$W12D/shim" HEADROOM_STATE_DIR="$W12D/state" bash "$DOCTOR" "$@" 2>&1
}
out=$(d12)
check        "w12: the custom copy's badge deps are current without engine-resolve.sh" \
             "statusline lib deps current (attribution.jq, headroom-state.sh)" "$out"
check_absent "w12: no unfixable custom-path FAIL about the missing engine-resolve.sh" \
             "statusline lib deps at $W12D/custom missing/stale" "$out"
check        "w12: the resolver is reported against \$CLAUDE_DIR instead, and is fixable" \
             "shared engine resolver missing/stale (engine-resolve.sh)" "$out"
fix12=$(d12 --fix)
check "w12: --fix provisions the resolver into \$CLAUDE_DIR/lib" \
      "installed the shared engine resolver to $W12D/cd/lib/engine-resolve.sh" "$fix12"
if cmp -s "$ROOT/scripts/lib/engine-resolve.sh" "$W12D/cd/lib/engine-resolve.sh"; then
  echo "ok - w12: the provisioned resolver is byte-identical to the plugin's"; PASS=$((PASS+1))
else
  echo "FAIL - w12: the provisioned resolver is byte-identical to the plugin's"; FAIL=$((FAIL+1))
fi
if [ -e "$W12D/custom/lib/engine-resolve.sh" ]; then
  echo "FAIL - w12: --fix never writes into the custom-path lib dir"; FAIL=$((FAIL+1))
else
  echo "ok - w12: --fix never writes into the custom-path lib dir"; PASS=$((PASS+1))
fi
fix12b=$(d12 --fix)
check_eq "w12: the second --fix is a no-op (idempotent)" "0" \
         "$(printf '%s\n' "$fix12b" | grep -cE '^fixed ')"
check    "w12: the second run reports the resolver current" \
         "shared engine resolver current ($W12D/cd/lib/engine-resolve.sh)" "$fix12b"

# w12-#11. A flat ~/.claude/hcat could never load what check 7c provisions FOR it:
# its source loop tried ../scripts/lib and a flat sibling, but never $here/lib —
# which is exactly where --fix installs the shared resolver. Discriminator: only
# the shared resolver honours DOCTOR_VENV_DIR; the inline fallback does not.
W12E="$W/w12flat"; mkdir -p "$W12E/cd/lib" "$W12E/home" "$W12E/venv/bin"
cp "$HCAT" "$W12E/cd/hcat"; chmod +x "$W12E/cd/hcat"
cp "$ROOT/scripts/lib/engine-resolve.sh" "$ROOT/scripts/lib/headroom-state.sh" "$W12E/cd/lib/"
printf '#!/bin/sh\necho "shared-resolver-py $*"\n' > "$W12E/venv/bin/python"
chmod +x "$W12E/venv/bin/python"
printf '{"k":1}' > "$W12E/tiny.json"
out=$(env -u HCAT_PYTHON HOME="$W12E/home" DOCTOR_VENV_DIR="$W12E/venv" PATH="/usr/bin:/bin" \
      bash "$W12E/cd/hcat" "$W12E/tiny.json" 2>&1)
check "w12: a flat ~/.claude/hcat loads the resolver from ~/.claude/lib/" "shared-resolver-py" "$out"
# control: with that lib dir gone it falls back to the inline resolver, which
# knows nothing about DOCTOR_VENV_DIR — proof the assertion above discriminates
mv "$W12E/cd/lib" "$W12E/cd/lib-off"
out=$(env -u HCAT_PYTHON HOME="$W12E/home" DOCTOR_VENV_DIR="$W12E/venv" PATH="/usr/bin:/bin" \
      bash "$W12E/cd/hcat" "$W12E/tiny.json" 2>&1)
check_absent "w12: control — without ~/.claude/lib the shared resolver is not loaded" \
             "shared-resolver-py" "$out"
mv "$W12E/cd/lib-off" "$W12E/cd/lib"

# w12-#12. The inline fallback must not be narrower than what base hcat had
# before the shared lib existed: HCAT_PYTHON, then a python sibling of `headroom`
# on PATH (pipx / uv / pip --user), then ~/.headroom-venv. The flat install that
# lands on this fallback is precisely the population it exists to protect.
W12F="$W/w12inline"; mkdir -p "$W12F/flat" "$W12F/home" "$W12F/pathbin"
cp "$HCAT" "$W12F/flat/hcat"; chmod +x "$W12F/flat/hcat"   # no lib anywhere
printf '#!/bin/sh\nexit 0\n'                 > "$W12F/pathbin/headroom"
printf '#!/bin/sh\necho "sibling-py $*"\n'   > "$W12F/pathbin/python"
chmod +x "$W12F/pathbin/headroom" "$W12F/pathbin/python"
out=$(env -u HCAT_PYTHON -u DOCTOR_VENV_DIR HOME="$W12F/home" PATH="$W12F/pathbin:/usr/bin:/bin" \
      bash "$W12F/flat/hcat" "$W12E/tiny.json" 2>&1)
check "w12: the inline fallback finds a PATH sibling python with no venv present" \
      "sibling-py" "$out"
# HCAT_PYTHON stays authoritative ahead of it (no fallback — the standing contract)
out=$(env -u DOCTOR_VENV_DIR HCAT_PYTHON="$W12E/venv/bin/python" HOME="$W12F/home" \
      PATH="$W12F/pathbin:/usr/bin:/bin" bash "$W12F/flat/hcat" "$W12E/tiny.json" 2>&1)
check        "w12: HCAT_PYTHON still wins over the PATH sibling" "shared-resolver-py" "$out"
check_absent "w12: the PATH sibling does not override HCAT_PYTHON" "sibling-py" "$out"
# and all three copies of the fallback stay byte-identical to each other
w12_fb() { sed -n '/resolve_engine_python() {  # partial legacy copy/,/^}/p' "$1"; }
w12_fb_hcat=$(w12_fb "$HCAT")
check_eq "w12: hcat and hcat-gate share one inline fallback" \
         "$w12_fb_hcat" "$(w12_fb "$ROOT/scripts/hcat-gate.sh")"
check_eq "w12: hcat and session-probe share one inline fallback" \
         "$w12_fb_hcat" "$(w12_fb "$ROOT/scripts/session-probe.sh")"
check    "w12: the inline fallback carries the PATH-sibling lookup" \
         "command -v headroom" "$w12_fb_hcat"

# w12-#1. .mcp.json spawns the BARE name `headroom` and cannot express a
# per-platform or absolute command. On Windows a bare name is resolved from the
# spawning process's current directory BEFORE PATH, so a headroom executable
# committed to a repo would be spawned instead of the engine. Detection is the
# mitigation: doctor FAILs, the session probe nudges, and neither fires on POSIX.
W12G="$W/w12hijack"; mkdir -p "$W12G/cd" "$W12G/proj" "$W12G/clean" "$W12G/home"
printf '#!/bin/sh\nexit 0\n' > "$W12G/proj/headroom.exe"; chmod +x "$W12G/proj/headroom.exe"
S12G="$W12G/s.json"; doc_settings_wired "$W12G/cd" > "$S12G"
d12g() {  # d12g <DOCTOR_OS> <project-dir>
  env -u HCAT_PYTHON DOCTOR_OS="$1" DOCTOR_PROJECT_DIR="$2" PATH="$FENG:$STUB:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$S12G" DOCTOR_CLAUDE_DIR="$W12G/cd" DOCTOR_VENV_DIR="$NOVENV" \
      DOCTOR_SHIM_DIR="$W12G/shim" HEADROOM_STATE_DIR="$W12G/state" bash "$DOCTOR" 2>&1
}
out=$(d12g windows "$W12G/proj"); rc=$?
check    "w12: a headroom.exe in the project dir is a FAIL on Windows" \
         "an executable $W12G/proj/headroom.exe sits in the project directory" "$out"
check    "w12: that FAIL explains Windows' project-dir-before-PATH resolution" \
         "resolves from the project directory BEFORE PATH" "$out"
check_eq "w12: doctor exits 1 on the name-hijack FAIL" "1" "$rc"
out=$(d12g unix "$W12G/proj")
check_absent "w12: the name-hijack check does not fire on POSIX" \
             "sits in the project directory" "$out"
out=$(d12g windows "$W12G/clean")
check_absent "w12: no hijack FAIL for a clean project dir" \
             "sits in the project directory" "$out"
# the SessionStart probe carries the same one-line nudge (a setup problem, never
# note_error: it must not flip the badge to broken)
out=$(printf '{"session_id":"w12h"}' | env -u HCAT_PYTHON DOCTOR_OS=windows HOME="$W12G/home" \
      DOCTOR_PROJECT_DIR="$W12G/proj" PATH="$STUB:/usr/bin:/bin" \
      HEADROOM_STATE_DIR="$W12G/pstate" bash "$PROBE"); rc=$?
check    "w12: the probe nudges about a project-dir headroom on Windows" \
         "sits in this project" "$out"
check_eq "w12: the probe exits 0 on that nudge" "0" "$rc"
check_eq "w12: the probe still prints exactly one line" "1" "$(printf '%s\n' "$out" | grep -c .)"
if [ -f "$W12G/pstate/last-error" ]; then
  echo "FAIL - w12: the hijack nudge does not flip the badge to broken"; FAIL=$((FAIL+1))
else
  echo "ok - w12: the hijack nudge does not flip the badge to broken"; PASS=$((PASS+1))
fi
out=$(printf '{"session_id":"w12h2"}' | env -u HCAT_PYTHON DOCTOR_OS=unix HOME="$W12G/home" \
      DOCTOR_PROJECT_DIR="$W12G/proj" PATH="$STUB:/usr/bin:/bin" \
      HEADROOM_STATE_DIR="$W12G/pstate2" bash "$PROBE")
check_absent "w12: the probe's hijack nudge does not fire on POSIX" "sits in this project" "$out"

# w12-#6. `import fcntl` used to sit inside _append_event's one broad try/except,
# so on Windows (no fcntl) EVERY hcat run silently failed to record its savings.
# The import is guarded on its own now — this is the POSIX regression guard that
# the flock path still writes the event after that refactor.
W12PY=$(real_python || echo /nonexistent/python3)
if [ -x "$W12PY" ]; then
  h12="$W/w12shim"; mkdir -p "$h12/headroom"
  : > "$h12/headroom/__init__.py"
  cat > "$h12/headroom/compress.py" <<'W12SHIM'
class _R:
    def __init__(self, raw):
        self.messages = [{"content": "compressed"}]
        self.tokens_before = 1000
        self.tokens_after = 100   # 90% savings → the main engine tier
def compress(_msgs):
    return _R(_msgs[0]["content"])
W12SHIM
  cat > "$h12/headroom/paths.py" <<'W12SHIM'
import os, pathlib
def workspace_dir():
    return pathlib.Path(os.environ["HEADROOM_WORKSPACE_DIR"])
def session_stats_path():
    return workspace_dir() / "stats.jsonl"
W12SHIM
  w12wrap="$W/w12-python"
  printf '#!/bin/sh\nexport PYTHONPATH="%s:${PYTHONPATH:-}"\nexec "%s" "$@"\n' "$h12" "$W12PY" > "$w12wrap"
  chmod +x "$w12wrap"
  w12src="$W/w12-stats.json"; jq -n '[range(0;30) | {id:., name:"row"}]' > "$w12src"
  out=$(HCAT_PYTHON="$w12wrap" HEADROOM_WORKSPACE_DIR="$W/w12-ws" bash "$HCAT" "$w12src"); rc=$?
  check_eq "w12: hcat engine tier exit 0 after the fcntl refactor" "0" "$rc"
  check    "w12: the engine tier still prints its receipt" "90.0% saved" "$out"
  check    "w12: the stats event still lands via the POSIX flock path" \
           '"strategy":"hcat"' "$(cat "$W/w12-ws/stats.jsonl" 2>/dev/null)"
  check    "w12: the event carries the token counts" '"input_tokens":1000' \
           "$(cat "$W/w12-ws/stats.jsonl" 2>/dev/null)"
else
  skip_note "w12: hcat stats-event test (no python3)"
fi


# --- w13. second verified-review wave (findings #1, #2, #3, #4, #5, #9, #10,
# #11, #12, #13, #14). Every fixture below reproduces the exact shape a reviewer
# demonstrated, so a regression fails here rather than only on a Windows box.

# w13-#1. The statusLine injection guard rejected ONLY the double quote. Inside
# the double-quoted word sl_hr_cmd prints, `$` is just as active: a bash.exe
# under a directory literally NAMED `$(cmd)` is a real file, so `[ -f ]` passes,
# the value is persisted verbatim, and the substitution runs when Claude Code
# executes the status line. Backtick, newline and carriage return are the same
# class of bypass. A BACKSLASH must stay allowed — Windows paths need it.
W13I="$W/w13inject"; mkdir -p "$W13I/cd"
w13_evil="$W13I/"'$(touch pwned)dir'          # a REAL directory whose name is a command substitution
mkdir -p "$w13_evil"
printf '#!/bin/sh\nexit 0\n' > "$w13_evil/bash.exe"; chmod +x "$w13_evil/bash.exe"
if [ -f "$w13_evil/bash.exe" ]; then
  echo "ok - w13: the command-substitution fixture really is an existing file (the old -f guard would pass it)"; PASS=$((PASS+1))
else
  echo "FAIL - w13: the command-substitution fixture really is an existing file"; FAIL=$((FAIL+1))
fi
w13_inj() {  # w13_inj <settings> <claude-dir> <CLAUDE_CODE_GIT_BASH_PATH value>
  env -u HCAT_PYTHON DOCTOR_OS=windows DOCTOR_CYGPATH="$W/cygpath" \
      CLAUDE_CODE_GIT_BASH_PATH="$3" PATH="$FENG:$STUB:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$1" DOCTOR_CLAUDE_DIR="$2" DOCTOR_VENV_DIR="$NOVENV" \
      DOCTOR_SHIM_DIR="$W13I/shim" bash "$DOCTOR" --fix >/dev/null 2>&1
  jq -r '.statusLine.command' "$1"
}
S13I="$W13I/s.json"; printf '{}\n' > "$S13I"
cmd13=$(w13_inj "$S13I" "$W13I/cd" "$w13_evil/bash.exe")
check_absent "w13: a \$(...) directory in the Git Bash override never reaches statusLine.command" \
             '$(' "$cmd13"
check_absent "w13: nor anywhere else in settings.json" '$(' "$(cat "$S13I")"
check_eq     "w13: the \$-bearing value is dropped for the PATH bash fallback" \
             '"C:\fake\bash" "C:\fake\headroom-statusline.sh"' "$cmd13"
# backtick and newline are the same class of bypass
W13I2="$W13I/bt"; mkdir -p "$W13I2/"'`touch pwned`dir'
printf '#!/bin/sh\nexit 0\n' > "$W13I2/"'`touch pwned`dir/bash.exe'
chmod +x "$W13I2/"'`touch pwned`dir/bash.exe'
S13I2="$W13I/s2.json"; printf '{}\n' > "$S13I2"
check_eq "w13: a backtick value is refused too" '"C:\fake\bash" "C:\fake\headroom-statusline.sh"' \
         "$(w13_inj "$S13I2" "$W13I/cd2" "$W13I2/"'`touch pwned`dir/bash.exe')"
# NOTE: a newline cannot come from $(printf '\n') — command substitution strips
# trailing newlines, which would silently make this an ordinary "nldir" fixture
w13_nl='
'
w13_nldir="$W13I/nl${w13_nl}dir"; mkdir -p "$w13_nldir"
printf '#!/bin/sh\nexit 0\n' > "$w13_nldir/bash.exe"; chmod +x "$w13_nldir/bash.exe"
S13I3="$W13I/s3.json"; printf '{}\n' > "$S13I3"
check_eq "w13: a newline-bearing value is refused too" '"C:\fake\bash" "C:\fake\headroom-statusline.sh"' \
         "$(w13_inj "$S13I3" "$W13I/cd3" "$w13_nldir/bash.exe")"
# ...and the guard must NOT reject a backslash: every native Windows path has them
W13I4="$W13I/bs"; mkdir -p "$W13I4"
printf '#!/bin/sh\nexit 0\n' > "$W13I4/back\\slash.exe"; chmod +x "$W13I4/back\\slash.exe"
S13I4="$W13I/s4.json"; printf '{}\n' > "$S13I4"
check_eq "w13: a backslash in the override is still accepted (Windows paths need it)" \
         '"C:\fake\back\slash.exe" "C:\fake\headroom-statusline.sh"' \
         "$(w13_inj "$S13I4" "$W13I/cd4" "$W13I4/back\\slash.exe")"

# w13-#9. An ACCEPTED override was written raw while the script token beside it
# went through win_path, so a perfectly valid POSIX-spelled value was persisted
# unconverted — and Claude Code runs that command outside Git Bash, where only
# the native spelling resolves.
W13W="$W/w13winpath"; mkdir -p "$W13W/cd" "$W13W/c/Program Files/Git/bin"
w13_posix_bash="$W13W/c/Program Files/Git/bin/bash.exe"
printf '#!/bin/sh\nexit 0\n' > "$w13_posix_bash"; chmod +x "$w13_posix_bash"
S13W="$W13W/s.json"; printf '{}\n' > "$S13W"
cmd13w=$(w13_inj "$S13W" "$W13W/cd" "$w13_posix_bash")
check_eq     "w13: a POSIX-spelled accepted override is persisted in Windows form" \
             '"C:\fake\bash.exe" "C:\fake\headroom-statusline.sh"' "$cmd13w"
check_absent "w13: the raw POSIX spelling never survives into settings.json" \
             "$w13_posix_bash" "$(cat "$S13W")"

# w13-#5. A pre-existing SYMLINK at the shim path used to fall straight through
# to `ln -sfn` and be repointed with no backup — and pipx installs ~/.local/bin
# console scripts as symlinks. A link that already names the resolved CLI is
# ours (idempotent); anything else is foreign and gets the rc 2 refusal.
W13L="$W/w13symlink"; mkdir -p "$W13L/cd" "$W13L/venv/bin" "$W13L/shim" "$W13L/pipx"
printf '#!/bin/sh\nexit 0\n'   > "$W13L/venv/bin/python";  chmod +x "$W13L/venv/bin/python"
printf '#!/bin/sh\necho hr\n'  > "$W13L/venv/bin/headroom"; chmod +x "$W13L/venv/bin/headroom"
printf '#!/bin/sh\necho pipx\n'> "$W13L/pipx/headroom";     chmod +x "$W13L/pipx/headroom"
ln -sfn "$W13L/pipx/headroom" "$W13L/shim/headroom"
S13L="$W13L/s.json"; doc_settings_wired "$W13L/cd" > "$S13L"
w13_shim() {  # w13_shim <shim-dir> <settings> <claude-dir> <extra-PATH-prefix> [--fix]
  local sd=$1 st=$2 cd=$3 pre=$4; shift 4
  env -u HCAT_PYTHON PATH="$pre$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$st" \
      DOCTOR_CLAUDE_DIR="$cd" DOCTOR_VENV_DIR="$W13L/venv" DOCTOR_SHIM_DIR="$sd" \
      HEADROOM_STATE_DIR="$W13L/state" bash "$DOCTOR" "$@" 2>&1
}
out=$(w13_shim "$W13L/shim" "$S13L" "$W13L/cd" "" --fix); rc=$?
check    "w13: a foreign SYMLINK at the shim path is refused, not repointed" \
         "a different headroom already exists at $W13L/shim/headroom" "$out"
check_eq "w13: the foreign symlink still points where it did" "$W13L/pipx/headroom" \
         "$(readlink "$W13L/shim/headroom")"
check_absent "w13: a refused symlink is never reported as shimmed" "headroom shimmed to" "$out"
check_eq "w13: doctor exits 1 on the foreign-symlink FAIL" "1" "$rc"
# a link that ALREADY names the resolved CLI is ours: adopted, not refused
W13L2="$W/w13symlink-ours"; mkdir -p "$W13L2/cd" "$W13L2/shim"
ln -sfn "$W13L/venv/bin/headroom" "$W13L2/shim/headroom"
S13L2="$W13L2/s.json"; doc_settings_wired "$W13L2/cd" > "$S13L2"
out=$(w13_shim "$W13L2/shim" "$S13L2" "$W13L2/cd" "" --fix)
check_absent "w13: a link that already names the resolved CLI is not called foreign" \
             "a different headroom already exists" "$out"
check_eq "w13: and it is left exactly as it was" "$W13L/venv/bin/headroom" \
         "$(readlink "$W13L2/shim/headroom")"
# ...and with that dir on PATH the run is a plain ok with no `fixed` line at all
out=$(w13_shim "$W13L2/shim" "$S13L2" "$W13L2/cd" "$W13L2/shim:" --fix)
check    "w13: an adopted shim resolves on PATH" "headroom CLI on PATH ($W13L2/shim/headroom)" "$out"
check_eq "w13: adopting an existing symlink prints no ^fixed line (idempotent)" "0" \
         "$(printf '%s\n' "$out" | grep -cE '^fixed ')"

# w13-#3. On Windows the shim is a COPY. Copying a `#!`-shebang console script
# to headroom.exe produces a file Windows cannot spawn — while shim_runs (which
# goes through bash) succeeds, so the doctor used to report `fixed` over an MCP
# that can never connect. A bin/ venv holding a shebang `headroom` is exactly
# the layout venv_bindir and resolve_headroom_cli both select.
W13N="$W/w13nonpe"; mkdir -p "$W13N/cd" "$W13N/venv/bin" "$W13N/shim"
printf '#!/bin/sh\nexit 0\n'  > "$W13N/venv/bin/python";   chmod +x "$W13N/venv/bin/python"
printf '#!/bin/sh\necho hr\n' > "$W13N/venv/bin/headroom"; chmod +x "$W13N/venv/bin/headroom"
S13N="$W13N/s.json"; doc_settings_wired "$W13N/cd" > "$S13N"
out=$(env -u HCAT_PYTHON -u DOCTOR_FAKE_PE DOCTOR_OS=windows PATH="$W13N/shim:$STUB:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$S13N" DOCTOR_CLAUDE_DIR="$W13N/cd" DOCTOR_VENV_DIR="$W13N/venv" \
      DOCTOR_SHIM_DIR="$W13N/shim" HEADROOM_STATE_DIR="$W13N/state" bash "$DOCTOR" --fix 2>&1); rc=$?
check        "w13: a non-PE headroom is refused on the Windows copy branch" \
             "is not a Windows executable" "$out"
check        "w13: that FAIL explains Windows cannot spawn a #! console script" \
             "console script (no MZ/PE header), and Windows cannot spawn one shell-less" "$out"
check        "w13: that FAIL names the py -3 venv remedy" "py -3 -m venv $W13N/venv" "$out"
check        "w13: that FAIL names the uv remedy too" "uv tool install headroom-ai" "$out"
check_absent "w13: a non-PE CLI is never reported as shimmed" "headroom shimmed to" "$out"
check_eq     "w13: doctor exits 1 on the non-PE FAIL" "1" "$rc"
if [ -e "$W13N/shim/headroom.exe" ]; then
  echo "FAIL - w13: no headroom.exe is written for a non-PE CLI"; FAIL=$((FAIL+1))
else
  echo "ok - w13: no headroom.exe is written for a non-PE CLI"; PASS=$((PASS+1))
fi
# control: the same fixture with a PE-magic CLI shims and verifies normally
printf 'MZ() { :; }\nexit 0\n' > "$W13N/venv/bin/headroom"; chmod +x "$W13N/venv/bin/headroom"
out=$(env -u HCAT_PYTHON DOCTOR_OS=windows PATH="$W13N/shim:$STUB:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$S13N" DOCTOR_CLAUDE_DIR="$W13N/cd" DOCTOR_VENV_DIR="$W13N/venv" \
      DOCTOR_SHIM_DIR="$W13N/shim" HEADROOM_STATE_DIR="$W13N/state" bash "$DOCTOR" --fix 2>&1)
check "w13: control — a PE CLI still shims (so the check above discriminates)" \
      "headroom shimmed to $W13N/shim/headroom.exe" "$out"

# w13-#11. A dead shim in the doctor's OWN shim dir produced the identical FAIL
# on every --fix run with the file untouched, and its "reinstall the engine"
# hint misdirected — check 2 had just found a healthy engine. Read-only says how
# to clear it; --fix clears it and repairs in the same run.
W13R="$W/w13deadown"; mkdir -p "$W13R/cd" "$W13R/venv/bin" "$W13R/shim"
printf '#!/bin/sh\nexit 0\n'  > "$W13R/venv/bin/python";   chmod +x "$W13R/venv/bin/python"
printf '#!/bin/sh\necho hr\n' > "$W13R/venv/bin/headroom"; chmod +x "$W13R/venv/bin/headroom"
printf '#!/bin/sh\nexit 1\n'  > "$W13R/shim/headroom";     chmod +x "$W13R/shim/headroom"
S13R="$W13R/s.json"; doc_settings_wired "$W13R/cd" > "$S13R"
w13_dead() {
  env -u HCAT_PYTHON PATH="$W13R/shim:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S13R" \
      DOCTOR_CLAUDE_DIR="$W13R/cd" DOCTOR_VENV_DIR="$W13R/venv" DOCTOR_SHIM_DIR="$W13R/shim" \
      HEADROOM_STATE_DIR="$W13R/state" bash "$DOCTOR" "$@" 2>&1
}
out=$(w13_dead)
check "w13: a dead OWN shim is diagnosed as the doctor's own file" \
      "this file is the doctor's own shim from an earlier run: delete it and re-run /doctor --fix" "$out"
if [ -f "$W13R/shim/headroom" ]; then
  echo "ok - w13: a read-only run never deletes it"; PASS=$((PASS+1))
else
  echo "FAIL - w13: a read-only run never deletes it"; FAIL=$((FAIL+1))
fi
# ...and the same diagnosis must survive the WINDOWS spelling. shim_target() is
# headroom.exe there, while `command -v headroom` inside Git Bash returns the
# suffix-less name, so the old raw string compare never matched and this branch
# was dead on the one platform that writes the shim as a copy.
W13RW="$W/w13deadown-win"; mkdir -p "$W13RW/cd" "$W13RW/venv/Scripts" "$W13RW/shim"
printf 'MZ() { :; }\nexit 0\n' > "$W13RW/venv/Scripts/python.exe";   chmod +x "$W13RW/venv/Scripts/python.exe"
printf 'MZ() { :; }\nexit 0\n' > "$W13RW/venv/Scripts/headroom.exe"; chmod +x "$W13RW/venv/Scripts/headroom.exe"
printf '#!/bin/sh\nexit 1\n'   > "$W13RW/shim/headroom";             chmod +x "$W13RW/shim/headroom"
S13RW="$W13RW/s.json"; doc_settings_wired "$W13RW/cd" > "$S13RW"
out=$(env -u HCAT_PYTHON DOCTOR_OS=windows PATH="$W13RW/shim:$STUB:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$S13RW" DOCTOR_CLAUDE_DIR="$W13RW/cd" DOCTOR_VENV_DIR="$W13RW/venv" \
      DOCTOR_SHIM_DIR="$W13RW/shim" HEADROOM_STATE_DIR="$W13RW/state" bash "$DOCTOR" 2>&1)
check "w13: a dead own shim is recognised through the .exe spelling too" \
      "this file is the doctor's own shim from an earlier run" "$out"

out=$(w13_dead --fix)
check        "w13: --fix removes the dead own shim and repairs in the same run" \
             "headroom shimmed to $W13R/shim/headroom (resolves on PATH)" "$out"
check_absent "w13: the repaired run no longer reports the does-not-run FAIL" \
             "does not run" "$out"
check_eq     "w13: the repaired shim points at the engine CLI" "$W13R/venv/bin/headroom" \
             "$(readlink "$W13R/shim/headroom")"
out=$(w13_dead --fix)
check_eq     "w13: the next --fix is a no-op (no ^fixed line)" "0" \
             "$(printf '%s\n' "$out" | grep -cE '^fixed ')"
check        "w13: and it greens the repaired shim" "headroom CLI on PATH ($W13R/shim/headroom)" "$out"

# w13-#10. shim_runs executes whatever `command -v headroom` resolves on every
# plain /doctor run — by its own comment that may be a name squatter or a wedged
# binary — and it had no time bound at all.
W13T="$W/w13timeout"; mkdir -p "$W13T/cd" "$W13T/bin" "$W13T/venv/bin" "$W13T/shim"
printf '#!/bin/sh\nsleep 120\n' > "$W13T/bin/headroom";   chmod +x "$W13T/bin/headroom"
printf '#!/bin/sh\nexit 0\n'    > "$W13T/venv/bin/python"; chmod +x "$W13T/venv/bin/python"
S13T="$W13T/s.json"; doc_settings_wired "$W13T/cd" > "$S13T"
w13_t0=$(date +%s)
out=$(env -u HCAT_PYTHON PATH="$W13T/bin:$STUB:/usr/bin:/bin" DOCTOR_SHIM_RUNS_TIMEOUT=1 \
      DOCTOR_SETTINGS="$S13T" DOCTOR_CLAUDE_DIR="$W13T/cd" DOCTOR_VENV_DIR="$W13T/venv" \
      DOCTOR_SHIM_DIR="$W13T/shim" HEADROOM_STATE_DIR="$W13T/state" bash "$DOCTOR" 2>&1)
w13_elapsed=$(( $(date +%s) - w13_t0 ))
check "w13: a headroom that never returns is reported as not running, not hung" \
      "headroom on PATH at $W13T/bin/headroom does not run" "$out"
if [ "$w13_elapsed" -lt 30 ]; then
  echo "ok - w13: the doctor finished in ${w13_elapsed}s despite a 120s headroom (bounded probe)"; PASS=$((PASS+1))
else
  echo "FAIL - w13: the doctor took ${w13_elapsed}s — the shim_runs probe is not bounded"; FAIL=$((FAIL+1))
fi
# The run above took the portable watchdog branch (no timeout(1) on the fixture
# PATH). Cover the coreutils branch too — that is the one every Linux box and CI
# takes — with a faithful mini-`timeout` so the assertion is deterministic here.
W13T2="$W13T/withtimeout"; mkdir -p "$W13T2" "$W13T2/live"
cat > "$W13T2/timeout" <<'W13TO'
#!/bin/sh
s=$1; shift
"$@" & p=$!
i=0
while kill -0 "$p" 2>/dev/null; do
  if [ "$i" -ge "$s" ]; then kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; exit 124; fi
  sleep 1; i=$((i+1))
done
wait "$p"
W13TO
chmod +x "$W13T2/timeout"
w13_t0=$(date +%s)
out=$(env -u HCAT_PYTHON PATH="$W13T2:$W13T/bin:$STUB:/usr/bin:/bin" DOCTOR_SHIM_RUNS_TIMEOUT=1 \
      DOCTOR_SETTINGS="$S13T" DOCTOR_CLAUDE_DIR="$W13T/cd" DOCTOR_VENV_DIR="$W13T/venv" \
      DOCTOR_SHIM_DIR="$W13T/shim" HEADROOM_STATE_DIR="$W13T/state" bash "$DOCTOR" 2>&1)
w13_elapsed2=$(( $(date +%s) - w13_t0 ))
check "w13: the timeout(1) branch bounds the probe as well" \
      "headroom on PATH at $W13T/bin/headroom does not run" "$out"
if [ "$w13_elapsed2" -lt 30 ]; then
  echo "ok - w13: the timeout(1) branch finished in ${w13_elapsed2}s"; PASS=$((PASS+1))
else
  echo "FAIL - w13: the timeout(1) branch took ${w13_elapsed2}s"; FAIL=$((FAIL+1))
fi
# a healthy CLI through the SAME branch must still report its own (zero) status
printf '#!/bin/sh\necho hr\n' > "$W13T2/live/headroom"; chmod +x "$W13T2/live/headroom"
out=$(env -u HCAT_PYTHON PATH="$W13T2:$W13T2/live:$STUB:/usr/bin:/bin" DOCTOR_SHIM_RUNS_TIMEOUT=5 \
      DOCTOR_SETTINGS="$S13T" DOCTOR_CLAUDE_DIR="$W13T/cd" DOCTOR_VENV_DIR="$W13T/venv" \
      DOCTOR_SHIM_DIR="$W13T/shim" HEADROOM_STATE_DIR="$W13T/state" bash "$DOCTOR" 2>&1)
check "w13: a healthy CLI still passes through the bounded probe" \
      "headroom CLI on PATH ($W13T2/live/headroom)" "$out"

# w13-#12. The merge-aware statusLine template applied sl_hr_cmd to the badge
# fragment ONLY: the surrounding chain was raw POSIX shell, and on Windows that
# whole string became the persisted command — so a user who already had a status
# line lost both theirs and the badge. The chain now lives in a script file.
W13C="$W/w13chain"; mkdir -p "$W13C/cd"
# same lossy-stub accommodation as w7: the chain wiring's interpreter token
# round-trips through the stub cygpath to $W13C/cd/bash.exe, and check 7 now
# verifies that interpreter exists before calling the wiring healthy.
# both spellings: the stub keeps only the basename, and which one appears
# depends on what this host's `command -v bash` returned (/bin/bash → "bash").
for _b in bash bash.exe; do
  printf '#!/bin/sh\nexit 0\n' > "$W13C/cd/$_b"; chmod +x "$W13C/cd/$_b"
done
S13C="$W13C/s.json"
jq -n '{statusLine:{type:"command",command:"printf LEFT-SIDE"}}' > "$S13C"
w13_chain() {
  env -u HCAT_PYTHON DOCTOR_OS=windows DOCTOR_CYGPATH="$W/cygpath" CYGPATH_UNIX_DIR="$W13C/cd" \
      PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S13C" DOCTOR_CLAUDE_DIR="$W13C/cd" \
      DOCTOR_VENV_DIR="$NOVENV" DOCTOR_SHIM_DIR="$W13C/shim" \
      HEADROOM_STATE_DIR="$W13C/state" bash "$DOCTOR" "$@" 2>&1
}
out=$(w13_chain --fix)
w13_chain_file="$W13C/cd/headroom-statusline-chain.sh"
check    "w13: the windows merge still reports the merge" \
         "statusLine merged — your command kept and backed up under _headroomStatusLineBackup" "$out"
check_eq "w13: the persisted command keeps the \"<bash>\" \"<win path>\" shape" \
         '"C:\fake\bash" "C:\fake\headroom-statusline-chain.sh"' \
         "$(jq -r '.statusLine.command' "$S13C")"
check_absent "w13: no raw POSIX chain is persisted on Windows" 'in=$(cat)' \
             "$(jq -r '.statusLine.command' "$S13C")"
check_eq "w13: the user's own command is still backed up verbatim" "printf LEFT-SIDE" \
         "$(jq -r '._headroomStatusLineBackup.command' "$S13C")"
if [ -f "$w13_chain_file" ]; then
  echo "ok - w13: the chain script was written next to the statusline copy"; PASS=$((PASS+1))
else
  echo "FAIL - w13: the chain script was written next to the statusline copy"; FAIL=$((FAIL+1))
fi
check "w13: the chain script runs the user's command" "printf LEFT-SIDE" "$(cat "$w13_chain_file" 2>/dev/null)"
check "w13: the chain script runs the badge" "bash \"$W13C/cd/headroom-statusline.sh\"" \
      "$(cat "$w13_chain_file" 2>/dev/null)"
# and it actually renders both halves when Git Bash runs it
w13_rendered=$(printf '{"transcript_path":"","model":{"id":"claude-opus-4-8"},"session_id":"w13c"}' \
  | HEADROOM_STATE_DIR="$W13C/state" bash "$w13_chain_file" 2>/dev/null)
check "w13: the chain renders the user's status line" "LEFT-SIDE" "$w13_rendered"
check "w13: the chain renders the headroom badge after it" "headroom" "$w13_rendered"
out=$(w13_chain --fix)
check_eq "w13: a second windows --fix is a no-op" "0" "$(printf '%s\n' "$out" | grep -cE '^fixed ')"
check    "w13: and the chain wiring reads as healthy" "statusLine wired (" "$out"
# POSIX control: the inline chain is unchanged and no chain script is written
W13CU="$W/w13chain-posix"; mkdir -p "$W13CU/cd"
S13CU="$W13CU/s.json"; jq -n '{statusLine:{type:"command",command:"printf LEFT-SIDE"}}' > "$S13CU"
env -u HCAT_PYTHON DOCTOR_OS=unix PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S13CU" \
    DOCTOR_CLAUDE_DIR="$W13CU/cd" DOCTOR_VENV_DIR="$NOVENV" DOCTOR_SHIM_DIR="$W13CU/shim" \
    HEADROOM_STATE_DIR="$W13CU/state" bash "$DOCTOR" --fix >/dev/null 2>&1
check "w13: POSIX still gets the inline chain" 'in=$(cat); left=$(printf' \
      "$(jq -r '.statusLine.command' "$S13CU")"
if [ -e "$W13CU/cd/headroom-statusline-chain.sh" ]; then
  echo "FAIL - w13: POSIX writes no chain script"; FAIL=$((FAIL+1))
else
  echo "ok - w13: POSIX writes no chain script"; PASS=$((PASS+1))
fi

# w13-#14. The Windows PATH hint hardcoded %USERPROFILE%\.local\bin while the
# message beside it named the real $SHIM_DIR.
W13H="$W/w13hint"; mkdir -p "$W13H/cd" "$W13H/venv/Scripts" "$W13H/customshim"
printf '#!/bin/sh\nexit 0\n'    > "$W13H/venv/Scripts/python.exe";   chmod +x "$W13H/venv/Scripts/python.exe"
printf 'MZ() { :; }\nexit 0\n'  > "$W13H/venv/Scripts/headroom.exe"; chmod +x "$W13H/venv/Scripts/headroom.exe"
S13H="$W13H/s.json"; doc_settings_wired "$W13H/cd" > "$S13H"
out=$(env -u HCAT_PYTHON DOCTOR_OS=windows PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S13H" \
      DOCTOR_CLAUDE_DIR="$W13H/cd" DOCTOR_VENV_DIR="$W13H/venv" DOCTOR_SHIM_DIR="$W13H/customshim" \
      HEADROOM_STATE_DIR="$W13H/state" bash "$DOCTOR" --fix 2>&1)
check        "w13: the windows PATH hint names the shim dir actually in use" \
             "add $W13H/customshim to your user Path" "$out"
check_absent "w13: the hint no longer hardcodes %USERPROFILE%" '%USERPROFILE%' "$out"
# and the dir is converted to its native spelling when cygpath is available
out=$(env -u HCAT_PYTHON DOCTOR_OS=windows DOCTOR_CYGPATH="$W/cygpath" PATH="$STUB:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$S13H" DOCTOR_CLAUDE_DIR="$W13H/cd" DOCTOR_VENV_DIR="$W13H/venv" \
      DOCTOR_SHIM_DIR="$W13H/customshim" HEADROOM_STATE_DIR="$W13H/state" bash "$DOCTOR" --fix 2>&1)
check "w13: the hint uses the native spelling of that dir" 'add C:\fake\customshim to your user Path' "$out"

# w13-#2. The Windows bootstrap order is `py:-3 python python3`, whose colon
# splitting hands `-3` to the py launcher — nothing exercised it (the Windows
# order fixture supplied only `python`, and CI pre-creates the venv). Stub a py
# launcher that ONLY accepts `-3 -m venv DIR`, with python/python3 failing, so
# the assertion can come from nowhere else.
W13B="$W/w13pyboot"; mkdir -p "$W13B/stub" "$W13B/cd" "$W13B/shim"
link_tool "$(command -v jq)" "$W13B/stub/jq"
cat > "$W13B/stub/py" <<'W13PY'
#!/bin/sh
# the real Windows py launcher: a version selector, then the python arguments
[ "$1" = "-3" ] || exit 1
shift
if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
  mkdir -p "$3/Scripts"
  printf '#!/bin/sh\necho "$@" >> "$(dirname "$0")/../pip.calls"\n' > "$3/Scripts/pip.exe"
  printf '#!/bin/sh\nexit 0\n'   > "$3/Scripts/python.exe"
  printf 'MZ() { :; }\nexit 0\n' > "$3/Scripts/headroom.exe"   # PE magic, still shell-runnable
  chmod +x "$3/Scripts/pip.exe" "$3/Scripts/python.exe" "$3/Scripts/headroom.exe"
  exit 0
fi
exit 1
W13PY
chmod +x "$W13B/stub/py"
printf '#!/bin/sh\nexit 1\n' > "$W13B/stub/python";  chmod +x "$W13B/stub/python"
printf '#!/bin/sh\nexit 1\n' > "$W13B/stub/python3"; chmod +x "$W13B/stub/python3"
S13B="$W13B/s.json"; doc_settings_wired "$W13B/cd" > "$S13B"
out=$(env -u HCAT_PYTHON DOCTOR_OS=windows PATH="$W13B/shim:$W13B/stub:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$S13B" DOCTOR_CLAUDE_DIR="$W13B/cd" DOCTOR_VENV_DIR="$W13B/venv" \
      DOCTOR_SHIM_DIR="$W13B/shim" HEADROOM_STATE_DIR="$W13B/state" bash "$DOCTOR" --fix 2>&1)
check "w13: the py launcher bootstraps the engine (colon-split -3 argument)" \
      "engine bootstrapped: py -3 -m venv $W13B/venv" "$out"
check "w13: it pip-installed through the Scripts layout" "Scripts/pip.exe install" "$out"
check "w13: the stub pip really was called" "install headroom-ai[all]" \
      "$(cat "$W13B/venv/pip.calls" 2>/dev/null)"
check_absent "w13: no bootstrap FAIL when only py works" "engine bootstrap failed" "$out"
if [ -x "$W13B/venv/Scripts/python.exe" ]; then
  echo "ok - w13: py -3 -m venv produced a Scripts/ venv"; PASS=$((PASS+1))
else
  echo "FAIL - w13: py -3 -m venv produced a Scripts/ venv"; FAIL=$((FAIL+1))
fi
# control: with py gone, the same toolchain honestly fails (so the check above
# is really attributing the bootstrap to the py launcher)
W13B2="$W/w13pyboot-nopy"; mkdir -p "$W13B2/stub" "$W13B2/cd"
link_tool "$(command -v jq)" "$W13B2/stub/jq"
printf '#!/bin/sh\nexit 1\n' > "$W13B2/stub/python";  chmod +x "$W13B2/stub/python"
printf '#!/bin/sh\nexit 1\n' > "$W13B2/stub/python3"; chmod +x "$W13B2/stub/python3"
S13B2="$W13B2/s.json"; doc_settings_wired "$W13B2/cd" > "$S13B2"
out=$(env -u HCAT_PYTHON DOCTOR_OS=windows PATH="$W13B2/stub:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$S13B2" DOCTOR_CLAUDE_DIR="$W13B2/cd" DOCTOR_VENV_DIR="$W13B2/venv" \
      DOCTOR_SHIM_DIR="$W13B2/shim" HEADROOM_STATE_DIR="$W13B2/state" bash "$DOCTOR" --fix 2>&1)
check "w13: control — without py the bootstrap FAILs honestly" "engine bootstrap failed" "$out"
check "w13: the by-hand hint names the Windows Scripts/ bindir" \
      "$W13B2/venv/Scripts/pip install" "$out"
check_absent "w13: ...and not the POSIX bin/ one, on Windows" "/venv/bin/pip install" "$out"

# --- w15. Windows-on-ARM: headroom-ai ships compiled abi3 wheels and publishes
# NO win_arm64 one, so an ARM64 interpreter matches nothing, falls back to the
# sdist and fails both installs. Repeating the command by hand cannot fix that,
# so the FAIL has to name the cause and the real remedy (the x64 Python runs
# emulated there and matches win_amd64). Detection asks the interpreter for its
# wheel tag — uname would say x86_64, since Git for Windows is an x86_64 build.
w15_case() {  # w15_case <name> <platform tag> — a venv that builds but whose pip refuses
  local d="$W/w15-$1"; mkdir -p "$d/stub" "$d/cd"
  link_tool "$(command -v jq)" "$d/stub/jq"
  cat > "$d/stub/python3" <<STUB15
#!/bin/sh
if [ "\$1" = "-c" ]; then echo $2; exit 0; fi
if [ "\$1" = "-m" ] && [ "\$2" = "venv" ]; then
  mkdir -p "\$3/Scripts"
  printf '#!/bin/sh\\nexit 1\\n' > "\$3/Scripts/pip.exe"
  printf '#!/bin/sh\\nexit 1\\n' > "\$3/Scripts/python.exe"
  chmod +x "\$3/Scripts/pip.exe" "\$3/Scripts/python.exe"
  exit 0
fi
exit 1
STUB15
  chmod +x "$d/stub/python3"
  printf '#!/bin/sh\nexit 1\n' > "$d/stub/python"; chmod +x "$d/stub/python"
  printf '#!/bin/sh\nexit 1\n' > "$d/stub/py";     chmod +x "$d/stub/py"
  doc_settings_wired "$d/cd" > "$d/s.json"
  env -u HCAT_PYTHON DOCTOR_OS=windows PATH="$d/stub:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$d/s.json" DOCTOR_CLAUDE_DIR="$d/cd" DOCTOR_VENV_DIR="$d/venv" \
      DOCTOR_SHIM_DIR="$d/shim" HEADROOM_STATE_DIR="$d/state" bash "$DOCTOR" --fix 2>&1
}
out=$(w15_case arm win-arm64)
check "w15: an ARM64 interpreter still reaches the bootstrap FAIL" "engine bootstrap failed" "$out"
check "w15: the FAIL names the missing win_arm64 wheel" "no win_arm64 wheel" "$out"
check "w15: ...and prescribes the x64 Python that has one" "install the x64 build of Python" "$out"
check "w15: the tag it actually read is quoted back" 'is "win-arm64"' "$out"
# control: same fixture, x64 tag — the hint must NOT appear, or the check above
# is only proving that the string exists in the script.
out=$(w15_case amd win-amd64)
check "w15: control — the x64 interpreter still FAILs honestly" "engine bootstrap failed" "$out"
check_absent "w15: control — no ARM advice for an x64 interpreter" "no win_arm64 wheel" "$out"

# w13-#13. The FLAT (non-lib/) engine-resolve.sh tier of check 7c-2 — the legacy
# manual-install layout — had no fixture at all.
W13E="$W/w13flatres"; mkdir -p "$W13E/cd/lib"
cp "$ROOT/scripts/statusline.sh" "$W13E/cd/headroom-statusline.sh"
cp "$ROOT/scripts/lib/attribution.jq" "$ROOT/scripts/lib/headroom-state.sh" "$W13E/cd/lib/"
cp "$ROOT/scripts/lib/engine-resolve.sh" "$W13E/cd/engine-resolve.sh"   # FLAT sibling, no lib/ copy
S13E="$W13E/s.json"; doc_settings_wired "$W13E/cd" > "$S13E"
out=$(HCAT_PYTHON="$FENG/python" PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S13E" \
      DOCTOR_CLAUDE_DIR="$W13E/cd" DOCTOR_VENV_DIR="$NOVENV" DOCTOR_SHIM_DIR="$W13E/shim" \
      HEADROOM_STATE_DIR="$W13E/state" bash "$DOCTOR" 2>&1)
check        "w13: a flat \$CLAUDE_DIR/engine-resolve.sh is recognised as current" \
             "shared engine resolver current ($W13E/cd/engine-resolve.sh)" "$out"
check_absent "w13: the flat copy is not reported missing/stale" \
             "shared engine resolver missing/stale" "$out"
check_absent "w13: and nothing is reported as fixable for it" \
             "--fix installs it to $W13E/cd/lib" "$out"
check_absent "w13: no --fix line is printed for the flat resolver" \
             "installed the shared engine resolver" "$out"
# a STALE flat copy is still caught (the branch is currency-checked, not just existence)
printf '\n# drift\n' >> "$W13E/cd/engine-resolve.sh"
out=$(HCAT_PYTHON="$FENG/python" PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S13E" \
      DOCTOR_CLAUDE_DIR="$W13E/cd" DOCTOR_VENV_DIR="$NOVENV" DOCTOR_SHIM_DIR="$W13E/shim" \
      HEADROOM_STATE_DIR="$W13E/state" bash "$DOCTOR" 2>&1)
check "w13: a stale flat resolver is reported fixable" \
      "shared engine resolver missing/stale (engine-resolve.sh)" "$out"

# w13-#4. Windows' default PATHEXT resolves .COM FIRST, and both hijack lists
# omitted exactly that spelling. The list now lives in the shared lib so the two
# call sites cannot drift apart again.
check_eq "w13: .com leads the shared name list" "headroom.com" "$(er headroom_name_variants | head -1)"
check_eq "w13: the shared list carries all five spellings" "5" "$(er headroom_name_variants | grep -c .)"
check    "w13: doctor uses the shared list"        "headroom_name_variants" "$(cat "$DOCTOR")"
check    "w13: session-probe uses the shared list" "headroom_name_variants" "$(cat "$PROBE")"
# ...and MENTIONING the shared function is not the same as agreeing with it:
# session-probe keeps an inline literal fallback for a partial/legacy copy with
# no lib beside it, which is a second copy of the list the shared function's own
# comment claims "cannot drift apart again". Compare them for real.
probe_list=$(grep -o "printf '%s\\\\n' headroom\.com[^)]*" "$PROBE" | sed "s/printf '%s\\\\n' //" | tr -s ' ')
shared_list=$(er headroom_name_variants | tr '\n' ' ' | sed 's/ *$//')
check_eq "w13: session-probe's inline list matches the shared one exactly" \
         "$shared_list" "$probe_list"
W13X="$W/w13com"; mkdir -p "$W13X/cd" "$W13X/proj" "$W13X/home"
printf 'MZ() { :; }\nexit 0\n' > "$W13X/proj/headroom.com"    # no +x: Windows needs none
S13X="$W13X/s.json"; doc_settings_wired "$W13X/cd" > "$S13X"
out=$(env -u HCAT_PYTHON DOCTOR_OS=windows DOCTOR_PROJECT_DIR="$W13X/proj" \
      PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S13X" DOCTOR_CLAUDE_DIR="$W13X/cd" \
      DOCTOR_VENV_DIR="$NOVENV" DOCTOR_SHIM_DIR="$W13X/shim" HEADROOM_STATE_DIR="$W13X/state" \
      bash "$DOCTOR" 2>&1)
check "w13: doctor FAILs on a project-dir headroom.com (PATHEXT's first match)" \
      "an executable $W13X/proj/headroom.com sits in the project directory" "$out"
out=$(printf '{"session_id":"w13com"}' | env -u HCAT_PYTHON DOCTOR_OS=windows HOME="$W13X/home" \
      DOCTOR_PROJECT_DIR="$W13X/proj" PATH="$STUB:/usr/bin:/bin" \
      HEADROOM_STATE_DIR="$W13X/pstate" bash "$PROBE")
check    "w13: the probe nudges about a project-dir headroom.com too" \
         "$W13X/proj/headroom.com sits in this project" "$out"
check_eq "w13: the probe still prints exactly one line" "1" "$(printf '%s\n' "$out" | grep -c .)"

# ============================================================================
# w14. Defects found by the independent Windows tester on PR #10 (issue #9).
#      Each fixture below FAILED before the fix that follows it.
# ============================================================================
W14="$W/w14"; mkdir -p "$W14"
# These fixtures assert on WHICH bash the doctor picked, not on how the path is
# spelled. On a POSIX host there is no cygpath and win_path/unix_path are
# passthroughs; on a genuine Windows host they are real and would rewrite every
# path into its C:\... spelling, so the same assertion could not hold on both.
# Pin the translation to identity to take spelling out of the question.
cat > "$W14/cygpath" <<'W14CYG'
#!/bin/sh
shift; printf '%s\n' "$1"
W14CYG
chmod +x "$W14/cygpath"

# --- w14a (defect 1): the sl_hr_cmd() fallback must prefer <gitroot>/bin/bash.exe.
# Git for Windows ships TWO bashes: usr/bin/bash.exe (the MSYS-internal one,
# whose PATH has no coreutils when spawned from a native Windows process) and
# bin/bash.exe (the wrapper meant for external invocation, which sets MSYS
# PATH up first). `command -v bash` inside Git Bash finds usr/bin/bash.exe.
# Claude Code spawns the status line from a native process, so wiring
# usr/bin/bash.exe gives a badge whose dirname/cat/wc/tr are all missing.
# CI cannot catch this: windows-latest has Git\usr\bin on PATH, masking it.
W14G="$W14/gitroot"; mkdir -p "$W14G/bin" "$W14G/usr/bin"
# These stand in for Git for Windows' two bashes. They must be REAL working
# bashes, not inert stubs: the fixture puts their directory first on PATH so
# the doctor's own `command -v bash` finds them, and anything else on that PATH
# that shebangs to `#!/usr/bin/env bash` (the stub jq does) would otherwise be
# hijacked by an inert stub — which silently turned every JSON check in the
# doctor into a failure. What is under test is WHICH path gets picked, not that
# the binary is fake.
fake_bash() { printf '#!/bin/sh\nexec %s "$@"\n' "$BASHBIN" > "$1"; chmod +x "$1"; }
fake_bash "$W14G/usr/bin/bash"
fake_bash "$W14G/bin/bash"
S14A="$W14/sa.json"; printf '{}\n' > "$S14A"
# no DOCTOR_CYGPATH and no cygpath on PATH → win_path is a passthrough, so the
# written command carries the raw POSIX path and the assertion can see which
# bash was chosen. CLAUDE_CODE_GIT_BASH_PATH is unset → the fallback runs.
out=$(env -u HCAT_PYTHON -u CLAUDE_CODE_GIT_BASH_PATH DOCTOR_OS=windows \
  PATH="$W14G/usr/bin:$FENG:$STUB:/usr/bin:/bin" \
  DOCTOR_SETTINGS="$S14A" DOCTOR_CLAUDE_DIR="$W14/cd" DOCTOR_VENV_DIR="$NOVENV" \
  DOCTOR_SHIM_DIR="$W14/shim" DOCTOR_CYGPATH="$W14/cygpath" "$BASHBIN" "$DOCTOR" --fix 2>&1)
check "w14a: the wire actually happened" "statusLine wired to" "$out"
# Assert on the distinctive path TAIL, not the absolute path: MSYS resolves
# PATH entries to their native spelling, so the doctor's own `command -v bash`
# returns C:/Users/RUNNER~1/... on a real Windows host where a POSIX host
# returns /tmp/... . Which bash got chosen is the point; how it is spelled is not.
check    "w14a: fallback prefers <gitroot>/bin/bash.exe over usr/bin" \
         "/gitroot/bin/bash" "$(jq -r '.statusLine.command' "$S14A")"
check_absent "w14a: the coreutils-less usr/bin/bash.exe is not wired" \
         "/gitroot/usr/bin/bash" "$(jq -r '.statusLine.command' "$S14A")"

# the sibling-bin promotion must only fire when that bash really exists —
# a lone usr/bin/bash.exe with no bin/ sibling still has to be usable
W14H="$W14/gitroot-nobin"; mkdir -p "$W14H/usr/bin"
fake_bash "$W14H/usr/bin/bash"
S14B="$W14/sb.json"; printf '{}\n' > "$S14B"
env -u HCAT_PYTHON -u CLAUDE_CODE_GIT_BASH_PATH DOCTOR_OS=windows \
  PATH="$W14H/usr/bin:$FENG:$STUB:/usr/bin:/bin" \
  DOCTOR_SETTINGS="$S14B" DOCTOR_CLAUDE_DIR="$W14/cdb" DOCTOR_VENV_DIR="$NOVENV" \
  DOCTOR_SHIM_DIR="$W14/shim" DOCTOR_CYGPATH="$W14/cygpath" "$BASHBIN" "$DOCTOR" --fix >/dev/null 2>&1
check    "w14a: no bin/ sibling → usr/bin/bash.exe still wired" \
         "/gitroot-nobin/usr/bin/bash" "$(jq -r '.statusLine.command' "$S14B")"

# --- w14b (defect 2): check 7 must validate the INTERPRETER, not just the script.
# The token loop only ever considered tokens ending in headroom-statusline.sh,
# so a stale/wrong bash path was both undetected and unfixable: the doctor said
# "ok      - statusLine wired" over a command that cannot execute.
W14C="$W14/cdc"; mkdir -p "$W14C"
printf '#!/bin/sh\nexit 0\n' > "$W14C/headroom-statusline.sh"; chmod +x "$W14C/headroom-statusline.sh"
S14C="$W14/sc.json"
# jq -n, not printf: a `\"` inside a printf FORMAT string is not portable
# across bash builds and produced unparseable JSON under Git for Windows' bash.
jq -n --arg c "\"$W14/nope/does-not-exist/bash.exe\" \"$W14C/headroom-statusline.sh\"" \
  '{statusLine:{type:"command",command:$c}}' > "$S14C"
out=$(env -u HCAT_PYTHON -u CLAUDE_CODE_GIT_BASH_PATH DOCTOR_OS=windows \
      PATH="$W14G/usr/bin:$FENG:$STUB:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$S14C" DOCTOR_CLAUDE_DIR="$W14C" DOCTOR_VENV_DIR="$NOVENV" \
      DOCTOR_SHIM_DIR="$W14/shim" DOCTOR_CYGPATH="$W14/cygpath" "$BASHBIN" "$DOCTOR" 2>&1)
check_absent "w14b: a dead interpreter is not reported as wired" "ok      - statusLine wired" "$out"
check        "w14b: the dead interpreter is named in the finding" \
             "/nope/does-not-exist/bash.exe" "$out"
# and --fix must actually repair it, not just report it
env -u HCAT_PYTHON -u CLAUDE_CODE_GIT_BASH_PATH DOCTOR_OS=windows \
  PATH="$W14G/usr/bin:$FENG:$STUB:/usr/bin:/bin" \
  DOCTOR_SETTINGS="$S14C" DOCTOR_CLAUDE_DIR="$W14C" DOCTOR_VENV_DIR="$NOVENV" \
  DOCTOR_SHIM_DIR="$W14/shim" DOCTOR_CYGPATH="$W14/cygpath" "$BASHBIN" "$DOCTOR" --fix >/dev/null 2>&1
check_absent "w14b: --fix removes the dead interpreter" \
             "/nope/does-not-exist/bash.exe" "$(jq -r '.statusLine.command' "$S14C")"
check        "w14b: --fix rewires to a real bash" \
             "/gitroot/bin/bash" "$(jq -r '.statusLine.command' "$S14C")"
# ...and the same repair with a NATIVE, backslash-spelled dead interpreter -- the
# spelling a real Windows settings.json actually carries. The fixture above uses
# forward slashes, which is precisely why the replacement pattern being an
# unquoted GLOB stayed invisible: backslashes are eaten as pattern escapes, so
# `${sl//$missing/$good}` could never match a native path and --fix fell through
# to "could not locate ... fix it by hand" on every run, forever.
S14CW="$W14/scw.json"
W14WINMISS='C:\zz-missing\bin\bash.exe'
jq -n --arg c "\"$W14WINMISS\" \"$W14C/headroom-statusline.sh\"" \
  '{statusLine:{type:"command",command:$c}}' > "$S14CW"
env -u HCAT_PYTHON -u CLAUDE_CODE_GIT_BASH_PATH DOCTOR_OS=windows \
  PATH="$W14G/usr/bin:$FENG:$STUB:/usr/bin:/bin" \
  DOCTOR_SETTINGS="$S14CW" DOCTOR_CLAUDE_DIR="$W14C" DOCTOR_VENV_DIR="$NOVENV" \
  DOCTOR_SHIM_DIR="$W14/shim" DOCTOR_CYGPATH="$W14/cygpath" "$BASHBIN" "$DOCTOR" --fix >/dev/null 2>&1
check_absent "w14b: --fix removes a NATIVE-spelled dead interpreter" \
             "$W14WINMISS" "$(jq -r '.statusLine.command' "$S14CW")"
check        "w14b: ...and repoints it at a real bash" \
             "/gitroot/bin/bash" "$(jq -r '.statusLine.command' "$S14CW")"
# a HEALTHY windows wiring must still pass untouched (no false alarm)
S14D="$W14/sd.json"
jq -n --arg c "\"$W14G/bin/bash\" \"$W14C/headroom-statusline.sh\"" \
  '{statusLine:{type:"command",command:$c}}' > "$S14D"
out=$(env -u HCAT_PYTHON -u CLAUDE_CODE_GIT_BASH_PATH DOCTOR_OS=windows \
      PATH="$W14G/usr/bin:$FENG:$STUB:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$S14D" DOCTOR_CLAUDE_DIR="$W14C" DOCTOR_VENV_DIR="$NOVENV" \
      DOCTOR_SHIM_DIR="$W14/shim" DOCTOR_CYGPATH="$W14/cygpath" "$BASHBIN" "$DOCTOR" 2>&1)
check "w14b: a live interpreter still reads as wired" "ok      - statusLine wired" "$out"
# POSIX is unaffected: `bash "<script>"` has no absolute interpreter token
S14E="$W14/se.json"
jq -n --arg c "bash \"$W14C/headroom-statusline.sh\"" \
  '{statusLine:{type:"command",command:$c}}' > "$S14E"
out=$(env -u HCAT_PYTHON DOCTOR_OS=unix PATH="$FENG:$STUB:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$S14E" DOCTOR_CLAUDE_DIR="$W14C" DOCTOR_VENV_DIR="$NOVENV" \
      DOCTOR_SHIM_DIR="$W14/shim" DOCTOR_CYGPATH="$W14/cygpath" "$BASHBIN" "$DOCTOR" 2>&1)
check "w14b: posix bare-bash wiring still reads as wired" "ok      - statusLine wired" "$out"

# --- w17. A flat install missing ONLY engine-resolve.sh still works: each entry
# point carries a narrower inline resolver for exactly that layout. So it must
# NUDGE, not flip the sticky yellow "headroom broken" badge that note_error
# writes -- doctor.sh calls the same condition merely `fixable`.
W17="$W/w17-degrade"; mkdir -p "$W17/flat" "$W17/state" "$W17/eng"
cp "$PROBE" "$W17/flat/session-probe.sh"
cp "$ROOT/scripts/lib/headroom-state.sh" "$W17/flat/headroom-state.sh"
cp "$ROOT/scripts/lib/attribution.jq"    "$W17/flat/attribution.jq"
cp "$ROOT/bin/hcat"                      "$W17/flat/hcat"
# ...and deliberately NOT engine-resolve.sh
printf '#!/bin/sh\nexit 0\n' > "$W17/eng/python"; chmod +x "$W17/eng/python"
out=$(env HCAT_PYTHON="$W17/eng/python" HEADROOM_STATE_DIR="$W17/state" \
      PATH="$STUB:/usr/bin:/bin" bash "$W17/flat/session-probe.sh" 2>&1)
check "w17: the missing lib is still reported" "engine-resolve.sh is missing" "$out"
if [ -s "$W17/state/last-error" ]; then
  echo "FAIL - w17: a degraded-but-working install must not flip the broken badge"
  echo "    last-error: $(cat "$W17/state/last-error")"; FAIL=$((FAIL+1))
else
  echo "ok - w17: a degraded-but-working install does not flip the broken badge"; PASS=$((PASS+1))
fi
# control: with NO engine resolvable at all, the badge SHOULD go broken
rm -rf "$W17/state2"; mkdir -p "$W17/state2"
out=$(env -u HCAT_PYTHON HEADROOM_STATE_DIR="$W17/state2" HOME="$W17/nohome" \
      PATH="$STUB:/usr/bin:/bin" bash "$W17/flat/session-probe.sh" 2>&1)
if [ -s "$W17/state2/last-error" ]; then
  echo "ok - w17: control — with no engine at all the badge does go broken"; PASS=$((PASS+1))
else
  echo "FAIL - w17: control — with no engine at all the badge does go broken"; FAIL=$((FAIL+1))
fi

# --- w16. The /bin -> /usr/bin ALIAS trap (the bug the windows job exposed).
# Every other w14 fixture stubs cygpath as a passthrough, so /bin/bash and
# /usr/bin/bash look like different files and the POSIX promotion appears to
# work. A REAL Git Bash aliases /bin onto /usr/bin: the promoted /bin/bash
# passes `-f`, and cygpath -w maps it straight back to ...\usr\bin\bash.exe, so
# the coreutils-less bash gets wired anyway and sl_prefer_wrapper_bash silently
# no-ops. This stub models the alias, and puts the wrapper only under the DRIVE
# mount (/c/...) -- which is where it really lives, and which is not aliased.
W16="$W/w16-alias"; mkdir -p "$W16/cd" "$W16/gitbash/usr/bin" "$W16/gitbash/bin" \
                             "$W16/drives/c/GitRoot/bin" "$W16/drives/c/GitRoot/usr/bin"
fake_bash "$W16/gitbash/usr/bin/bash"
fake_bash "$W16/gitbash/bin/bash"          # the /bin alias: resolvable, same file
: > "$W16/drives/c/GitRoot/usr/bin/bash.exe"; chmod +x "$W16/drives/c/GitRoot/usr/bin/bash.exe"
: > "$W16/drives/c/GitRoot/bin/bash.exe";     chmod +x "$W16/drives/c/GitRoot/bin/bash.exe"
cat > "$W16/cygpath" <<'W16CYG'
#!/bin/sh
# -w: BOTH POSIX spellings collapse onto the MSYS-internal native path. That
# collapse IS the alias, and it is what made the old promotion a no-op.
mode=$1; shift
case "$mode" in
  -w) case "$1" in
        */bin/bash|*/bin/bash.exe) printf '%s\n' 'C:\GitRoot\usr\bin\bash.exe' ;;
        *) printf '%s\n' "$1" ;;
      esac ;;
  *) printf '%s\n' "$1" ;;
esac
W16CYG
chmod +x "$W16/cygpath"
w16_run() {  # fresh settings each run, so the doctor has to actually re-wire
  printf '{}\n' > "$W16/s.json"
  env -u HCAT_PYTHON -u CLAUDE_CODE_GIT_BASH_PATH DOCTOR_OS=windows \
      PATH="$W16/gitbash/usr/bin:$FENG:$STUB:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$W16/s.json" DOCTOR_CLAUDE_DIR="$W16/cd" DOCTOR_VENV_DIR="$NOVENV" \
      DOCTOR_SHIM_DIR="$W16/shim" DOCTOR_CYGPATH="$W16/cygpath" \
      DOCTOR_DRIVE_ROOT="$W16/drives" HEADROOM_STATE_DIR="$W16/state" \
      "$BASHBIN" "$DOCTOR" --fix >/dev/null 2>&1
  jq -r '.statusLine.command' "$W16/s.json" 2>/dev/null
}
cmd16=$(w16_run)
check "w16: the alias does not defeat the promotion" 'GitRoot\bin\bash.exe' "$cmd16"
check_absent "w16: the coreutils-less usr/bin bash is not wired" 'usr\bin\bash.exe' "$cmd16"
# control: with no wrapper on disk under the drive mount, inventing a path would
# be worse than keeping usr/bin -- so it must stay put.
rm -f "$W16/drives/c/GitRoot/bin/bash.exe"
cmd16b=$(w16_run)
check "w16: control — no wrapper on disk keeps usr/bin rather than inventing one" \
      'usr\bin\bash.exe' "$cmd16b"

# --- w14c (defect 3): --fix bootstrap must not hang on torch.
# On Windows `headroom-ai[all]` pulls the `ml` extra -> torch>=2.12.1 (~2.5 GB)
# because the sys_platform != "darwin" marker applies. CI already hedges with
# `|| pip install headroom-ai`; doctor.sh had no fallback, so a slow link got a
# long silent hang and then "engine bootstrap failed".
W14V="$W14/boot"; mkdir -p "$W14V/stub"
# a python stub whose `-m venv` builds a venv whose pip REFUSES [all] but
# accepts the bare package — exactly the torch-unavailable shape
cat > "$W14V/stub/python3" <<STUBEOF
#!/bin/sh
if [ "\$1" = "-m" ] && [ "\$2" = "venv" ]; then
  mkdir -p "\$3/bin"
  cat > "\$3/bin/pip" <<'PIPEOF'
#!/bin/sh
# [all] is what pulls torch — refuse it, accept the bare package
case " \$* " in *"headroom-ai[all]"*) exit 1 ;; esac
case " \$* " in *"headroom-ai"*) touch "\$(dirname "\$0")/.installed"; exit 0 ;; esac
exit 1
PIPEOF
  chmod +x "\$3/bin/pip"
  cat > "\$3/bin/python" <<'PYEOF'
#!/bin/sh
# `import headroom.compress` only succeeds once pip actually installed
[ -f "\$(dirname "\$0")/.installed" ] || exit 1
exit 0
PYEOF
  chmod +x "\$3/bin/python"
  exit 0
fi
exit 0
STUBEOF
chmod +x "$W14V/stub/python3"
S14F="$W14/sf.json"; printf '{}\n' > "$S14F"
out=$(env -u HCAT_PYTHON DOCTOR_OS=unix PATH="$W14V/stub:$STUB:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$S14F" DOCTOR_CLAUDE_DIR="$W14/cdf" \
      DOCTOR_VENV_DIR="$W14V/venv" DOCTOR_SHIM_DIR="$W14/shim" \
      bash "$DOCTOR" --fix 2>&1)
check        "w14c: bootstrap falls back to bare headroom-ai when [all] fails" \
             "engine bootstrapped" "$out"
check_absent "w14c: the fallback bootstrap is not reported as a failure" \
             "engine bootstrap failed" "$out"
check_eq     "w14c: the venv really was built by the fallback" "0" \
             "$([ -f "$W14V/venv/bin/.installed" ]; echo $?)"

# --- shellcheck (when available) — warning severity: info-level findings
# (e.g. SC2016 on intentionally-literal single quotes) don't fail the suite
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity=warning "$SCRIPT" "$DANGI" "$ROOT/scripts/hcat-gate.sh" \
       "$ROOT/scripts/doctor.sh" \
       "$ROOT/scripts/session-probe.sh" "$ROOT/scripts/ledger-hook.sh" \
       "$ROOT/scripts/lib/headroom-state.sh" \
       "$ROOT/scripts/lib/engine-resolve.sh" \
       "$HCAT" "$ROOT/scripts/ci/windows-check.sh"; then
    echo "ok - shellcheck"; PASS=$((PASS+1))
  else
    echo "FAIL - shellcheck"; FAIL=$((FAIL+1))
  fi
else
  skip_note "shellcheck not installed"
fi

echo
echo "$PASS passed, $FAIL failed${SKIP:+, $SKIP skipped}"
[ "$FAIL" -eq 0 ]
