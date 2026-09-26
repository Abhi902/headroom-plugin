#!/usr/bin/env bash
# hcat-gate — PreToolUse gate for the headroom-usage-indicator plugin.
# Registered on the Read tool. When Claude is about to Read a large structured
# file (json/jsonl/ndjson/csv/tsv/log), deny ONCE per file per session with a
# pointer to `hcat`, which compresses at the source so the raw bytes never
# enter context. A retry of the same Read passes — the gate is a redirect with
# an escape hatch, never a wall. If hcat can't run (headroom missing), the
# gate allows everything.
# MUST always exit 0 and print nothing except the single JSON decision.

set -u

GATE_BYTES=${HCAT_GATE_BYTES:-16384}   # gate files at least this large

[ -n "${HCAT_GATE_OFF:-}" ] && exit 0

# Shared state helpers (STATE_DIR, note_error, canon_path). The plugin layout
# ships lib/ next to this script; a legacy flat install keeps a sibling copy.
# A partial copy must not kill the hook — degrade to inline minimal stubs.
_here="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"
# shellcheck disable=SC1090,SC1091
for _sl in "$_here/lib/headroom-state.sh" "$_here/headroom-state.sh"; do
  [ -f "$_sl" ] && { . "$_sl"; break; }
done
# shellcheck disable=SC1090,SC1091
for _er in "$_here/lib/engine-resolve.sh" "$_here/engine-resolve.sh"; do
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
type note_error >/dev/null 2>&1 || note_error() { :; }
type canon_path >/dev/null 2>&1 || canon_path() { printf '%s' "$1"; }
# Eligibility predicates come from the same lib (one definition shared with
# dangi-hook); a partial copy degrades to "extension only", never a crash.
type structured_ext >/dev/null 2>&1 || structured_ext() {
  case "$1" in *.json|*.jsonl|*.ndjson|*.csv|*.tsv|*.log) return 0 ;; esac; return 1
}
type sniff_structured >/dev/null 2>&1 || sniff_structured() { return 1; }
# HOME can be unset in hook environments (set -u would kill every Read);
# degrade to a temp-dir state location rather than dying.
[ -n "${STATE_DIR:-}" ] || STATE_DIR="${HEADROOM_STATE_DIR:-${HOME:-${TMPDIR:-/tmp}}/.claude/headroom-indicator}"

in=$(cat)

tool=$(printf '%s' "$in" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
case "$tool" in
  Read)
    fp=$(printf '%s' "$in" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
    ;;
  Bash)
    # Only a bare, single-file `cat <path>` — a raw whole-file dump. Pipes,
    # redirects, flags, and bounded peeks (head/tail) are real processing.
    cmd=$(printf '%s' "$in" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
    # A multiline command can contain a bare `cat` on ONE of its lines; acting
    # on that line would silently drop the others in a rewrite. Any newline →
    # not ours (bash-3.2-safe literal).
    nl=$(printf '\nx'); nl=${nl%x}
    case "$cmd" in *"$nl"*) exit 0 ;; esac
    case "$cmd" in *'|'*|*'>'*|*'<'*|*';'*|*'&'*|*'$('*|*'`'*) exit 0 ;; esac
    fp=$(printf '%s' "$cmd" | sed -nE 's/^[[:space:]]*cat[[:space:]]+("([^"]+)"|'\''([^'\'']+)'\''|([^[:space:]]+))[[:space:]]*$/\2\3\4/p')
    # A relative token resolves against the BASH TOOL's cwd, not the hook's; use
    # the payload cwd so we gate/rewrite the file Claude's `cat` actually names.
    # No payload cwd → skip rather than risk a same-named wrong file at ours.
    case "$fp" in
      ''|/*) : ;;
      *)
        hookcwd=$(printf '%s' "$in" | jq -r '.cwd // empty' 2>/dev/null) || hookcwd=""
        [ -n "$hookcwd" ] && fp="$hookcwd/$fp" || exit 0
        ;;
    esac
    ;;
  *) exit 0 ;;
esac
[ -n "$fp" ] && [ -f "$fp" ] || exit 0
# Canonical absolute path: dangi records offenders canonical, the once-per-file
# state stays stable across cwd changes, and a rewritten command keeps working
# even when the Bash tool's cwd differs from the hook's.
fp=$(canon_path "$fp")

size=$(wc -c < "$fp" 2>/dev/null | tr -d ' ') || exit 0
case "$size" in (*[!0-9]*|"") exit 0 ;; esac
[ "$size" -ge "$GATE_BYTES" ] || exit 0

# Eligibility (predicates shared with dangi-hook via the lib): structured
# extension (innate list), OR a learned offender (this exact path burned
# context before — recorded by dangi-hook, TTL-decayed), OR a 512-byte
# structural sniff for big files whose extension lies (extensionless API dumps,
# .txt JSON). The learned/sniff tiers close the narrow-gate misses without
# widening the fragile static pattern list.
eligible=0
structured_ext "$fp" && eligible=1
if [ "$eligible" -eq 0 ] && [ -f "$STATE_DIR/offenders" ]; then
  now_g=$(date +%s)
  ttl=${HEADROOM_OFFENDER_TTL:-1209600}   # learned entries decay after 14 days
  if LC_ALL=C awk -v now="$now_g" -v ttl="$ttl" -v p="$fp" '
       {path=substr($0, index($0, " ") + 1)}
       path == p && ($1+0) >= now - ttl {found=1; exit}
       END{exit !found}' "$STATE_DIR/offenders" 2>/dev/null; then
    eligible=1
  fi
fi
if [ "$eligible" -eq 0 ] && [ -z "${HCAT_GATE_NO_SNIFF:-}" ] && sniff_structured "$fp"; then
  eligible=1
fi
[ "$eligible" -eq 1 ] || exit 0

# hcat must actually be runnable, or we'd deny Reads and point at a dead end.
# Plugin layout ships it in bin/ (on Bash PATH while the plugin is enabled);
# a legacy ~/.claude install keeps it as a sibling of this script.
here="$(cd "$(dirname "$0")" && pwd)"
HCAT="$here/../bin/hcat"
legacy=0
if [ ! -x "$HCAT" ]; then
  HCAT="$here/hcat"
  legacy=1
fi
[ -x "$HCAT" ] || exit 0
# Pick the first IMPORTABLE candidate, not merely the first EXECUTABLE one --
# doctor.sh check 2 has always walked the list this way, and resolve_engine_python
# stops at the first -x hit. A stray `python` beside the `headroom` console script
# (pyenv/asdf/mise shims, uv's default install, or ~/.local/bin once /doctor --fix
# puts its own shim there) is executable but cannot import headroom, so the gate
# recorded a broken badge and stopped denying while /doctor on the SAME machine
# reported `ok - engine python`. Before this lib landed the gate only ever saw
# $HCAT_PYTHON or ~/.headroom-venv, so a decoy could not reach it.
# py_seen records that SOME candidate was executable. Without it, "every
# candidate failed to import" and "there is no engine at all" both end with an
# empty $py -- and the else branch below only exits 0 when `headroom` is absent
# from PATH, so a broken-but-installed engine fell through and DENIED the Read
# with no badge. The pre-lib code failed OPEN and recorded the outage; losing
# that was strictly worse than the decoy bug this loop exists to fix.
py=""; py_seen=""; py_validated=""
if type resolve_engine_python_validated >/dev/null 2>&1; then
  py=$(resolve_engine_python_validated); case $? in
    # Status 0 means the resolver already ran the import probe, bounded -- EXCEPT
    # for an HCAT_PYTHON override, which it returns authoritatively without
    # probing. Only the probed case may skip the re-check below.
    0) [ -z "${HCAT_PYTHON:-}" ] && py_validated=1 ;;
    2) py_seen=$py; py="" ;;    # resolved but cannot import: an OUTAGE, not absence
    *) py="" ;;                 # nothing installed: ordinary red-idle
  esac
else
  py=$(resolve_engine_python) || py=""   # partial legacy copy: narrower lookup
fi
if [ -n "$py_seen" ]; then
  # Fail OPEN and light the badge. Denying here would be worse than the decoy bug
  # this resolution fixes: the user loses Reads with no idea why.
  note_error engine "engine import failed ($py_seen) — gate failing open; run /doctor"
  exit 0
fi
if [ -n "$py" ]; then
  # A resolved-but-broken engine is a real outage the fail-open would otherwise
  # hide — record it so the badge can show "broken" instead of mimicking idle.
  # (An engine that was never installed is NOT recorded: that is the ordinary
  # red-idle state, not a breakage.)
  if [ ! -x "$py" ]; then
    note_error engine "engine python not executable ($py) — gate failing open; run /doctor"
    exit 0
  fi
  # A half-created venv passes -x yet cannot `import headroom.compress` (hcat
  # exits 4) — verify the import and fail OPEN (allow the Read) on a broken
  # engine. `.compress` also distinguishes the real headroom-ai package from
  # a name-squatted `headroom` on PyPI (see doctor.sh/bin/hcat).
  #
  # SKIP it when resolve_engine_python_validated already probed this exact
  # candidate: this runs on every gated Read (before the per-session dedup
  # below), so repeating the resolver's own bounded probe doubled the spawns
  # the shared resolver was introduced to bound. What is left -- an
  # HCAT_PYTHON override, or the legacy narrow resolver -- is bounded too.
  if [ -z "$py_validated" ]; then
    if type _er_bounded >/dev/null 2>&1; then
      _er_bounded "${ER_PY_TIMEOUT:-5}" "$py" -c 'import headroom.compress' >/dev/null 2>&1
    else
      "$py" -c 'import headroom.compress' >/dev/null 2>&1
    fi
    _gate_st=$?
    # 124 = the probe outran its bound, not proof of a broken engine; treat it
    # the way the resolver does and let the Read through on the engine we have.
    if [ "$_gate_st" -ne 0 ] && [ "$_gate_st" -ne 124 ]; then
      note_error engine "engine import failed ($py) — gate failing open; run /doctor"
      exit 0
    fi
  fi
else
  # No interpreter resolved at all. Denying here would point the user at hcat,
  # which without an engine exits 3 unless jq can carry the toon-lite tier --
  # so only deny when that tier can actually deliver. `headroom` resolving on
  # PATH is not enough: this PR's own Windows shim can put the CLI in a
  # python-less ~/.local/bin, and the gate now shares hcat's broad resolver, so
  # it already knows hcat will find no interpreter either.
  command -v headroom >/dev/null 2>&1 || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # jq being installed proves nothing about THIS file: bin/hcat's toon-lite tier
  # renders only a uniform array of flat objects and exits 3 on anything else
  # (CSV, logs, nested JSON). Ask the same question hcat will, or let it through.
  jq -e 'type=="array" and length>1
         and all(.[]; type=="object" and (to_entries | all(.value | (type=="object" or type=="array") | not)))
         and ((.[0] | keys_unsorted) as $k | all(.[]; keys_unsorted == $k))' "$fp" >/dev/null 2>&1 || exit 0
fi

sid=$(printf '%s' "$in" | jq -r '.session_id // "unknown"' 2>/dev/null) || sid="unknown"
[ -n "$sid" ] || sid="unknown"

# Escape hatch: deny each file only once per session; a retry passes.
state="$STATE_DIR/session-$sid.gate"
if [ -f "$state" ] && grep -qFx -- "$fp" "$state" 2>/dev/null; then
  exit 0
fi
if mkdir -p "$STATE_DIR" 2>/dev/null; then
  { printf '%s\n' "$fp" >> "$state"; } 2>/dev/null || true
fi

kb=$(( size / 1024 ))
# Install-aware pointer: the plugin layout has hcat on Bash PATH; a legacy
# sibling install does not, so cite the absolute path we actually resolved.
if [ "$legacy" -eq 1 ]; then
  hcat_cmd="$HCAT"
  path_note=""
else
  hcat_cmd="hcat"
  path_note=" (hcat is on PATH while this plugin is enabled)"
fi

# Bash `cat` gets REWRITTEN, not denied: the gate already computed the exact
# replacement command, and updatedInput delivers it in one shot — no deny→
# re-plan→retry round trip, no compliance bet. The hcat receipt line makes the
# substitution visible in the output. The once-per-file state still applies:
# if the rewrite already happened once this session (e.g. hcat failed and
# Claude re-ran cat), the raw command passes — a rewrite loop must not wedge.
# Paths/commands with shell-metacharacters fall through to the deny path
# rather than risk building an injectable command line.
if [ "$tool" = "Bash" ] && [ -z "${HCAT_GATE_NO_REWRITE:-}" ]; then
  safe=1
  case "$fp$hcat_cmd" in *'"'*|*'\'*|*'$'*|*'`'*) safe=0 ;; esac
  # The command word must stay a bare unquoted token — that is the only shape
  # the attribution regexes (statusline/ledger/dangi) recognise as an hcat
  # run; a quoted word would score every rewrite as a MISS. A legacy hcat
  # path containing whitespace cannot be written unquoted → deny path.
  case "$hcat_cmd" in *[[:space:]]*) safe=0 ;; esac
  if [ "$safe" -eq 1 ]; then
    printf '%s' "$in" | jq -c --arg cmd "$hcat_cmd \"$fp\"" --arg fp "$fp" --arg kb "$kb" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",
        permissionDecisionReason:("🤖 hcat-gate: rewrote the raw `cat` to `" + $cmd + "` — \($fp) is \($kb) KB of structured data; hcat prints a compressed rendering with a receipt (raw bytes never enter context; Read the path with offset/limit for exact details)."),
        additionalContext:("🤖 hcat-gate: your `cat` was rewritten to `" + $cmd + "` — \($fp) is \($kb) KB of structured data, so what you received is the hcat compressed rendering (see the receipt line; raw bytes never entered context; Read the path with offset/limit for exact details)."),
        updatedInput: ((.tool_input // {}) | .command = $cmd)}}' 2>/dev/null
    exit 0
  fi
fi

# The suggested command is SINGLE-quoted, not double-quoted: the path reaches
# this deny message unsanitized (the rewrite path routes every "/\/$/backtick
# path here), and a double-quoted "$(...)" path would be a runnable-command
# injection if copy-pasted. Single quotes make every metacharacter literal;
# an embedded single quote becomes the '\'' splice (bash-3.2 parameter expand).
fpq=${fp//\'/\'\\\'\'}
jq -cn --arg fpq "'$fpq'" --arg fp "$fp" --arg kb "$kb" --arg hcat "$hcat_cmd" --arg note "$path_note" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
    permissionDecisionReason:("🤖 hcat-gate: \($fp) is a \($kb) KB structured file. Run `\($hcat) \($fpq)` in Bash instead\($note) — it prints a compressed rendering (raw bytes never enter context; Read the path with offset/limit later for exact details). To read it raw anyway, just Read it again — this gate only fires once per file.")}}' 2>/dev/null
exit 0
