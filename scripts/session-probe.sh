#!/usr/bin/env bash
# session-probe — SessionStart micro-doctor for the headroom-usage-indicator
# plugin. A fast subset of doctor.sh that runs once per session: silent when
# healthy, one additionalContext line when the install is broken — so an outage
# is announced at session start instead of silently mimicking the idle badge.
# Checks stay cheap (existence/parse checks only, no `import headroom`): the
# gate and hcat verify the import at use time and record failures themselves.
# MUST always exit 0 and print nothing except the single JSON context line.

set -u

# Shared state helpers (STATE_DIR, note_error). The plugin layout ships lib/
# next to this script; a legacy flat install keeps a sibling copy. A partial
# copy must not kill the hook — degrade to inline minimal stubs.
here="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"
# shellcheck disable=SC1090,SC1091
for _sl in "$here/lib/headroom-state.sh" "$here/headroom-state.sh"; do
  [ -f "$_sl" ] && { . "$_sl"; break; }
done
# shellcheck disable=SC1090,SC1091
for _er in "$here/lib/engine-resolve.sh" "$here/engine-resolve.sh"; do
  [ -f "$_er" ] && { . "$_er"; break; }
done
type resolve_engine_python >/dev/null 2>&1 || resolve_engine_python() {  # partial legacy copy
  # Deliberately NARROWER than scripts/lib/engine-resolve.sh: no uv tool dir and
  # no shebang-interpreter tier. Keep the PATH-sibling lookup though — a flat
  # install that lands here is exactly the pipx/uv population that needs it.
  local c d
  if [ -n "${HCAT_PYTHON:-}" ]; then printf '%s\n' "$HCAT_PYTHON"; return 0; fi
  if d=$(command -v headroom 2>/dev/null) && [ -n "$d" ]; then
    d=$(dirname "$d")
    for c in "$d/python" "$d/python.exe"; do
      [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
  fi
  for c in "${HOME:-}/.headroom-venv/bin/python" "${HOME:-}/.headroom-venv/Scripts/python.exe"; do
    [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}
type is_windows >/dev/null 2>&1 || is_windows() { return 1; }
type note_error >/dev/null 2>&1 || note_error() { :; }
[ -n "${STATE_DIR:-}" ] || STATE_DIR="${HEADROOM_STATE_DIR:-${HOME:-${TMPDIR:-/tmp}}/.claude/headroom-indicator}"

problems=""
setup=""
add_problem() { problems="${problems:+$problems; }$1"; }

# --- 1. jq — every hook and the badge lean on it
if ! command -v jq >/dev/null 2>&1; then
  # Inconsistent install (the plugin is running but its toolchain is gone):
  # record it so the badge shows broken, not just idle.
  note_error jq "jq not found — hooks and badge are disabled"
  add_problem "jq not found (brew install jq / apt install jq)"
fi

# --- 1b. Windows: hooks and the badge run through Git Bash; a stale override is an outage
if is_windows && [ -n "${CLAUDE_CODE_GIT_BASH_PATH:-}" ] && [ ! -f "$CLAUDE_CODE_GIT_BASH_PATH" ]; then
  note_error install "CLAUDE_CODE_GIT_BASH_PATH points at a missing file"
  add_problem "CLAUDE_CODE_GIT_BASH_PATH points at a missing Git Bash ($CLAUDE_CODE_GIT_BASH_PATH) — fix it in settings.json env"
fi

# --- 2. hcat present + executable (plugin layout, legacy sibling fallback)
HCAT="$here/../bin/hcat"
[ -x "$HCAT" ] || HCAT="$here/hcat"
if [ ! -x "$HCAT" ]; then
  note_error install "hcat missing or not executable"
  add_problem "hcat is missing or not executable — reinstall the plugin or run /doctor"
fi

# --- 2b. shared libs — the badge/ledger read attribution.jq; the hooks source
# headroom-state.sh for ambient-health + offender-learning, and engine-resolve.sh
# for the one shared "where is the engine" order (without it this hook, hcat and
# the gate each fall back to a minimal HCAT_PYTHON-or-~/.headroom-venv lookup).
# Without them those features silently degrade to no-ops. Plugin installs ship
# them in lib/; a legacy flat install keeps them as siblings (copied by the
# manual installer, and re-provisioned by /doctor --fix).
for _lib in attribution.jq headroom-state.sh engine-resolve.sh; do
  if [ ! -f "$here/lib/$_lib" ] && [ ! -f "$here/$_lib" ]; then
    # engine-resolve.sh is the one entry here that DEGRADES instead of breaking:
    # this hook, hcat-gate.sh and bin/hcat each carry a narrower inline
    # resolve_engine_python for precisely the partial/legacy layout that lands
    # here, so an install missing only this lib still finds its engine and still
    # compresses. note_error is the STICKY yellow "headroom broken — run
    # /doctor" badge, which this file reserves for real outages — doctor.sh
    # classifies the very same condition as merely `fixable`. So badge it only
    # when the inline fallback ALSO comes up empty, and otherwise just nudge,
    # exactly as the never-installed-engine case below does.
    if [ "$_lib" = "engine-resolve.sh" ] && resolve_engine_python >/dev/null 2>&1; then
      add_problem "$_lib is missing — the inline fallback is resolving the engine for now; reinstall the plugin, or (legacy install) re-run the manual installer to copy scripts/lib/*"
      continue
    fi
    note_error install "$_lib missing — badge/ledger/health degraded"
    add_problem "$_lib is missing — reinstall the plugin, or (legacy install) re-run the manual installer to copy scripts/lib/*"
  fi
done

# --- 3. engine python resolvable (existence only — import is checked at use time)
# `headroom` on PATH gets its own nudge (engine_off_path below): since v2.8 the
# bundled .mcp.json spawns the BARE name with no shell and no launcher, so an
# install whose engine resolves only through the doctor's venv — the doctor's own
# happy path before v2.8 — silently loses its MCP the moment the plugin updates.
# Nothing else announces it: the badge's "idle" is indistinguishable from "you
# haven't compressed anything yet", and /doctor only runs when the user already
# suspects something. A hook's PATH is the closest proxy available for the MCP
# spawn environment. On POSIX it is not merely a proxy: the hook's PATH IS the
# PATH the MCP is spawned with, so a miss here is authoritative. On Windows it is
# a NUDGE-level proxy only -- a native process sees a different PATH, and
# doctor.sh check 2b re-asks natively (cmd.exe /c where, MSYS dirs pruned) and is
# the one to believe when the two disagree.
engine_off_path() {
  command -v headroom >/dev/null 2>&1 && return 0
  add_problem "headroom engine found but \`headroom\` is not on PATH — since v2.8 the bundled MCP spawns it by name; run /doctor --fix to shim it"
  # The engine WORKS and the MCP still cannot start: that is a live feature
  # outage, not a setup gap, and the badge has to say so. Leaving it at a nudge
  # is what makes a v2.7.x -> v2.8 update go silent -- a dead MCP renders as an
  # idle badge, which is indistinguishable from "nothing compressed yet".
  # Windows keeps the nudge: flipping a sticky badge on a non-authoritative
  # answer there would be a permanent false "broken", the exact failure mode the
  # native-PATH advisory was removed for.
  # Component `mcp`, NOT `engine`. bin/hcat clears engine/runtime errors after every
  # successful compression -- correctly, because a working compression proves the
  # ENGINE. It proves nothing about whether the MCP can spawn `headroom` by name,
  # and those are different failures. Filed as `engine` this badge flapped: yellow
  # at session start, cleared by the first compression, yellow again next session,
  # forever, for a condition that never changed -- which is the fastest way to
  # teach someone to ignore the one always-visible health signal. Under `mcp` it
  # persists until /doctor actually resolves it and clears the file.
  is_windows || note_error mcp "\`headroom\` is not on PATH — the bundled MCP cannot spawn it by name; run /doctor --fix"
}
# ...and the other half of "spawned by name": on Windows a bare command name is
# resolved from the spawning process's current directory BEFORE PATH, so a
# headroom executable committed to the repo you just opened would be spawned
# instead of the installed engine. .mcp.json cannot express an absolute or
# per-platform command, so detection is the mitigation.
engine_name_hijack() {
  is_windows || return 0
  local d f
  # Scan the real cwd AND the test/scan seam -- never only the seam. As a
  # REPLACEMENT, DOCTOR_PROJECT_DIR let the same project-scoped settings.json
  # `env` channel this detector exists to catch point it at an empty directory
  # and switch the detector off with one extra key.
  for d in "$PWD" ${DOCTOR_PROJECT_DIR:+"$DOCTOR_PROJECT_DIR"}; do
  # the spellings come from scripts/lib/engine-resolve.sh (PATHEXT order, .com
  # FIRST -- Windows resolves it before .exe), with the same inline fallback the
  # rest of this file keeps for a partial/legacy copy with no lib beside it
  for f in $(headroom_name_variants 2>/dev/null \
             || printf '%s\n' headroom.com headroom.exe headroom.bat headroom.cmd headroom); do
    [ -f "$d/$f" ] || continue
    case $f in headroom) [ -x "$d/$f" ] || continue ;; esac
    add_problem "an executable $d/$f sits in this project — on Windows a bare command name resolves from the project directory before PATH, so the bundled MCP would spawn it instead of the headroom engine; remove or rename it"
    return 0
  done
  done
}
engine_name_hijack
if [ -n "${HCAT_PYTHON:-}" ]; then
  # An explicit override pointing nowhere is a breakage, not an absence.
  if [ ! -x "$HCAT_PYTHON" ]; then
    note_error engine "HCAT_PYTHON is set but not executable ($HCAT_PYTHON)"
    add_problem "HCAT_PYTHON points at a non-executable python ($HCAT_PYTHON) — unset or fix it"
  else
    engine_off_path
  fi
elif resolve_engine_python >/dev/null 2>&1; then
  engine_off_path
elif ! command -v headroom >/dev/null 2>&1; then
  # Never-installed engine is the ordinary red-idle state, not a breakage:
  # say it once at session start, but do not flip the badge to broken. Same
  # reasoning for the off-PATH nudge above: add_problem, never note_error.
  add_problem "headroom engine not installed — run /doctor --fix to bootstrap it"
fi

# --- 4. bundled price table parses (when jq is available to check)
PRICES="$here/../data/model-prices.json"
[ -f "$PRICES" ] || PRICES="$here/headroom-model-prices.json"
if [ -f "$PRICES" ] && command -v jq >/dev/null 2>&1 \
   && ! jq -e '(.prices | type) == "array"' "$PRICES" >/dev/null 2>&1; then
  note_error prices "model price table invalid ($PRICES)"
  add_problem "model price table is invalid ($PRICES) — badge money figures disabled"
fi

# --- 5. surface a fresh recorded error even when today's checks pass
if [ -z "$problems" ] && [ -f "$STATE_DIR/last-error" ]; then
  { read -r le_ts _le_comp le_msg < "$STATE_DIR/last-error"; } 2>/dev/null || true
  case "${le_ts:-}" in (*[!0-9]*|"") le_ts=0 ;; esac
  le_age=$(( $(date +%s) - le_ts ))
  if [ "$le_age" -ge 0 ] 2>/dev/null && [ "$le_age" -le 86400 ] 2>/dev/null; then
    add_problem "a recent failure was recorded: ${le_msg:-see last-error} — run /doctor (doctor clears this once healthy)"
  fi
fi

# --- 5b. status line not wired yet — the one setup step a plugin can't perform
# for you: Claude Code has no plugin field for the status line, so wiring it means
# writing the user's settings.json, which only /doctor does (with consent). A
# freshly installed plugin therefore shows no badge until that step. Nudge about
# it — but only when everything else is healthy: a broken toolchain is the bigger
# fish, and /doctor --fix wires the status line while repairing it anyway. This is
# a setup reminder, never a breakage: it does not write last-error or flip the
# badge to "broken".
if [ -z "$problems" ] && command -v jq >/dev/null 2>&1; then
  SETTINGS="${HEADROOM_SETTINGS:-${HOME:-}/.claude/settings.json}"
  CLAUDE_DIR=$(dirname "$SETTINGS")
  sl_cmd=""
  [ -f "$SETTINGS" ] && { sl_cmd=$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null) || sl_cmd=""; }
  case "$sl_cmd" in
    *headroom-statusline.sh*)
      # Wired — but the badge resolves attribution.jq from a lib/ dir (or a flat
      # sibling) next to its copy; without it compute() reads a permanent zero
      # (issue #2). Nudge if a wired copy is missing those deps.
      if [ -f "$CLAUDE_DIR/headroom-statusline.sh" ] \
         && [ ! -f "$CLAUDE_DIR/lib/attribution.jq" ] && [ ! -f "$CLAUDE_DIR/attribution.jq" ]; then
        setup="status line badge is missing its deps and will read zero — run /headroom-usage-indicator:doctor --fix"
      fi
      ;;
    *)
      setup="status line badge isn't set up yet — run /headroom-usage-indicator:doctor --fix to show it"
      ;;
  esac
fi

# --- 6. healthy and quiet? surface the previous session's invoice, once.
# The ledger hook (Stop/SessionEnd) records what each session saved and what
# it burned; the next session start is the natural moment to show the bill.
LEDGER="$STATE_DIR/ledger.jsonl"
invoice=""
if [ -z "$problems" ] && [ -z "$setup" ] && [ -f "$LEDGER" ] && command -v jq >/dev/null 2>&1; then
  last=$(tail -1 "$LEDGER" 2>/dev/null) || last=""
  key=$(printf '%s' "$last" | jq -r '"\(.session_id)|\(.ts)"' 2>/dev/null) || key=""
  mark=$(cat "$STATE_DIR/last-invoice-mark" 2>/dev/null) || mark=""
  if [ -n "$key" ] && [ "$key" != "null|null" ] && [ "$key" != "$mark" ]; then
    invoice=$(printf '%s' "$last" | jq -r '
      def k: if . >= 1000 then (((. / 100 | floor) / 10 | tostring) + "k") else tostring end;
      "last session: saved ~" + (.save_tokens | k) + " tok"
      + (if .save_usd then " (~$" + .save_usd + ")" else "" end)
      + (if .miss_count > 0 then
           " · " + (.miss_count | tostring) + " big output(s) went uncompressed (~"
           + (.miss_est_tokens | k) + " tok"
           + (if .miss_usd then " ≈ $" + .miss_usd + " left on the table" else "" end)
           + (if (.top_misses[0].path // null) then " — biggest: " + .top_misses[0].path else "" end)
           + ")"
         else "" end)' 2>/dev/null) || invoice=""
    [ -n "$invoice" ] && { printf '%s' "$key" > "$STATE_DIR/last-invoice-mark"; } 2>/dev/null
  fi
fi

if [ -n "$problems" ] && command -v jq >/dev/null 2>&1; then
  jq -cn --arg p "$problems" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",
      additionalContext:("🤖 headroom probe: " + $p)}}' 2>/dev/null
elif [ -n "$setup" ] && command -v jq >/dev/null 2>&1; then
  jq -cn --arg p "$setup" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",
      additionalContext:("🤖 headroom setup: " + $p)}}' 2>/dev/null
elif [ -n "$invoice" ]; then
  jq -cn --arg p "$invoice" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",
      additionalContext:("🤖 headroom invoice: " + $p)}}' 2>/dev/null
elif [ -n "$problems" ]; then
  # No jq: emit the JSON by hand from a fixed-format string (problems built
  # above contain no quotes/backslashes in the no-jq path).
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"🤖 headroom probe: %s"}}' \
    "$(printf '%s' "$problems" | tr -d '"\\')"
fi
exit 0
