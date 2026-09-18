#!/usr/bin/env bash
# windows-check.sh — the required Windows CI gate for issue #9. Runs under Git
# Bash on windows-latest with a REAL headroom engine installed by the workflow.
# Every assertion here is something the macOS fixtures can only simulate.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0; SKIP=0; SKIP_NAMES=""
ok()   { echo "ok - $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL - $1"; shift; [ $# -gt 0 ] && printf '    %s\n' "$@"; FAIL=$((FAIL+1)); }
# A skip must be COUNTED. The workflow makes `uv tool install` non-fatal on
# purpose (a transient PyPI failure must not red a required gate), so a bare
# `echo skip` let a whole layout stop being tested while the summary still read
# "N passed, 0 failed". Visibility is the fix, not fatality.
skip() { echo "skip - $1"; SKIP=$((SKIP+1)); SKIP_NAMES="${SKIP_NAMES:+$SKIP_NAMES; }$1"; }
need() { [ -n "${!1:-}" ] || { echo "windows-check: env $1 is required" >&2; exit 2; }; }
need VENV_DIR          # a venv the workflow created with `python -m venv` + pip install headroom-ai
need HOME

# shellcheck disable=SC1091
. "$ROOT/scripts/lib/engine-resolve.sh"

# 1. platform + real layouts
is_windows && ok "is_windows detects Git Bash (OSTYPE=$OSTYPE)" || fail "is_windows false on Windows" "OSTYPE=$OSTYPE uname=$(uname -s)"
[ "$(venv_bindir "$VENV_DIR")" = "Scripts" ] && ok "real venv uses Scripts/" || fail "venv_bindir on a real Windows venv" "$(ls "$VENV_DIR")"
[ "$(head -c 2 "$VENV_DIR/Scripts/headroom.exe")" = "MZ" ] && ok "pip's headroom.exe is a PE launcher (MZ)" || fail "headroom.exe not MZ"

# 2. resolver against the real venv (nothing on PATH)
got=$(env -u HCAT_PYTHON PATH="/usr/bin:/bin" DOCTOR_VENV_DIR="$VENV_DIR" bash -c ". '$ROOT/scripts/lib/engine-resolve.sh'; resolve_engine_python")
case $got in "$VENV_DIR/Scripts/python.exe"|"$VENV_DIR/Scripts/python") ok "resolver finds Scripts/python.exe ($got)" ;; *) fail "resolver on real venv" "got: $got" ;; esac
got=$(env -u HCAT_PYTHON PATH="/usr/bin:/bin" DOCTOR_VENV_DIR="$VENV_DIR" bash -c ". '$ROOT/scripts/lib/engine-resolve.sh'; resolve_headroom_cli")
case $got in *Scripts/headroom.exe) ok "resolver finds Scripts/headroom.exe" ;; *) fail "CLI resolver on real venv" "got: $got" ;; esac
# resolver with the venv's Scripts dir ON PATH: sibling python.exe must win, MZ must not be parsed as a shebang
got=$(env -u HCAT_PYTHON PATH="$VENV_DIR/Scripts:/usr/bin:/bin" DOCTOR_VENV_DIR=/nonexistent bash -c ". '$ROOT/scripts/lib/engine-resolve.sh'; resolve_engine_python")
case $got in *python.exe|*python) ok "PATH sibling python.exe wins next to MZ launcher ($got)" ;; *) fail "PATH sibling resolution" "got: $got" ;; esac

# 3. uv tool layout (workflow ran `uv tool install headroom-ai`)
if command -v uv >/dev/null 2>&1 && [ -d "$(uv tool dir)/headroom-ai" ]; then
  got=$(env -u HCAT_PYTHON PATH="$(dirname "$(command -v uv)"):/usr/bin:/bin" DOCTOR_VENV_DIR=/nonexistent bash -c ". '$ROOT/scripts/lib/engine-resolve.sh'; resolve_engine_python")
  case $got in *headroom-ai*python*) ok "uv tool dir python found ($got)" ;; *) fail "uv tool dir resolution" "got: $got" ;; esac
else
  skip "uv tool layout (uv not installed on this runner)"
fi

# 4. hcat on non-ASCII JSON with the real engine (UTF-8 regression)
TMPD=$(mktemp -d)
python - "$TMPD/uni.json" <<'PY'
import json, sys
rows = [{"id": i, "name": "naïve ✓ 日本 %d" % i, "note": "ünïcode"} for i in range(300)]
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(rows, ensure_ascii=False, indent=2))
PY
out=$(env -u HCAT_PYTHON DOCTOR_VENV_DIR="$VENV_DIR" PATH="/usr/bin:/bin" bash "$ROOT/bin/hcat" "$TMPD/uni.json" 2>"$TMPD/hcat.err"); rc=$?
# "rc=0 + receipt" alone can never fail: hcat prints the SAME `── hcat:` receipt
# with rc 0 from three tiers, including the pure-jq tier it falls back to when no
# engine resolves at all. Require the engine tier explicitly — then prove the
# assertion can tell them apart with the negative control right below.
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "── hcat:" \
   && ! printf '%s' "$out" | grep -q "engine absent"; then
  ok "hcat compresses non-ASCII JSON on Windows with the REAL engine (rc=0, receipt, no engine-absent tier)"
else fail "hcat on non-ASCII JSON" "rc=$rc" "$(printf '%s' "$out" | head -1)" "$(head -3 "$TMPD/hcat.err")"; fi
# negative control: same file, resolver deliberately broken (no HCAT_PYTHON, venv
# pointed at nothing, engine nowhere on PATH) must land in the jq tier and SAY so.
neg=$(env -u HCAT_PYTHON DOCTOR_VENV_DIR=/nonexistent \
      PATH="$(dirname "$(command -v jq)"):/usr/bin:/bin" bash "$ROOT/bin/hcat" "$TMPD/uni.json" 2>/dev/null)
if printf '%s' "$neg" | grep -q "engine absent"; then
  ok "negative control: with no engine, hcat's receipt says 'engine absent' (the check above can fail)"
else
  fail "negative control: hcat without an engine did not report 'engine absent'" "$(printf '%s' "$neg" | head -1)"
fi

# 5. doctor --fix in a sandbox HOME with the real venv: engine ok, shim created,
# status line wired with Windows paths.
#
# The sandbox PATH deliberately carries ONLY the sandbox shim dir, jq's dir and the
# Git Bash system dirs — no uv tool bin, no $VENV_DIR/Scripts — so resolution must
# go venv → Scripts/headroom.exe → `cp` shim. That copy is the one Windows-only
# mutation in this release, and it used to be asserted with a `|| echo skip` whose
# branch depended on whether the workflow's `uv tool install` happened to land
# `headroom` on the runner's PATH; a runner-image change would have turned it into
# a permanent silent skip (review I4). Every assertion below is anchored at column
# 0 (`say()` prints `printf '%-7s - %s\n'`, so status words start there) — the old
# `grep -q " fixed "` could never match anything and the old shim grep also matched
# 2b's FAIL text (review C2).
SB="$TMPD/home"; mkdir -p "$SB/.claude" "$SB/.local/bin"
SB_PATH="$SB/.local/bin:$(dirname "$(command -v jq)"):/usr/bin:/bin:/mingw64/bin"
doctor_sb() {  # one sandboxed `doctor.sh --fix` run; prints its output, returns its rc
  env -u HCAT_PYTHON HOME="$SB" PATH="$SB_PATH" DOCTOR_SETTINGS="$SB/.claude/settings.json" \
      DOCTOR_CLAUDE_DIR="$SB/.claude" DOCTOR_VENV_DIR="$VENV_DIR" DOCTOR_SHIM_DIR="$SB/.local/bin" \
      DOCTOR_PROJECT_DIR="$TMPD/noproj" bash "$ROOT/scripts/doctor.sh" --fix 2>&1
}
out=$(doctor_sb); rc=$?
echo "$out" | sed 's/^/    doctor: /'
[ "$rc" -eq 0 ] && ok "doctor --fix run 1 exits 0" || fail "doctor --fix run 1 exited $rc"
printf '%s\n' "$out" | grep -qE '^FAIL' && fail "doctor --fix run 1 printed a FAIL line" "$out" || ok "doctor --fix run 1 has no FAIL lines"
printf '%s\n' "$out" | grep -q "engine python:" && ok "doctor: engine found" || fail "doctor: engine"
printf '%s\n' "$out" | grep -qE '^fixed +- headroom shimmed to' && ok "doctor: shimmed headroom (Windows cp branch)" || fail "doctor: run 1 did not report the shim as fixed" "$out"
[ -f "$SB/.local/bin/headroom.exe" ] && ok "doctor: shim is headroom.exe" || fail "doctor: shim file headroom.exe missing" "$(ls -l "$SB/.local/bin")"
cmd=$(jq -r '.statusLine.command' "$SB/.claude/settings.json")
case $cmd in \"*bash.exe\"\ \"*headroom-statusline.sh\") ok "doctor: statusLine command uses Windows paths ($cmd)" ;; *) fail "statusLine command shape" "got: $cmd" ;; esac
out2=$(doctor_sb); rc2=$?
[ "$rc2" -eq 0 ] && ok "doctor --fix run 2 exits 0" || fail "doctor --fix run 2 exited $rc2"
printf '%s\n' "$out2" | grep -qE '^FAIL' && fail "doctor --fix run 2 printed a FAIL line" "$out2" || ok "doctor --fix run 2 has no FAIL lines"
printf '%s\n' "$out2" | grep -qE '^fixed ' && fail "doctor: second --fix not idempotent" "$out2" || ok "doctor: second --fix is a no-op"
printf '%s\n' "$out2" | grep -qE '^ok +- headroom CLI on PATH' && ok "doctor: run 2 resolves the shimmed headroom on PATH" || fail "doctor: run 2 did not report headroom CLI on PATH" "$out2"
printf '%s\n' "$cmd" > "$ROOT/statusline.cmd"   # consumed by the PowerShell step

echo
summary="$PASS passed, $FAIL failed, $SKIP skipped"
[ "$SKIP" -gt 0 ] && summary="$summary — skipped: $SKIP_NAMES"
echo "$summary"
[ "$FAIL" -eq 0 ]
