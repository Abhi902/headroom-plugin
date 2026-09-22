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
elif [ "${UV_EXPECTED:-0}" = "1" ]; then
  # the workflow exports UV_EXPECTED=1 only when `uv tool install headroom-ai`
  # SUCCEEDED in this job — the layout must exist, so a skip here would be the
  # gate quietly agreeing to stop testing it (review #6)
  fail "uv tool layout absent although \`uv tool install headroom-ai\` succeeded in this job (UV_EXPECTED=1)" \
       "uv: $(command -v uv 2>/dev/null || echo 'not on PATH')" \
       "uv tool dir: $(uv tool dir 2>/dev/null || echo 'n/a')"
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
HCAT_WS="$TMPD/ws"; rm -rf "$HCAT_WS"
out=$(env -u HCAT_PYTHON DOCTOR_VENV_DIR="$VENV_DIR" HEADROOM_WORKSPACE_DIR="$HCAT_WS" PATH="/usr/bin:/bin" bash "$ROOT/bin/hcat" "$TMPD/uni.json" 2>"$TMPD/hcat.err"); rc=$?
# "rc=0 + receipt" alone can never fail: hcat prints the SAME `── hcat:` receipt
# with rc 0 from three tiers, including the pure-jq tier it falls back to when no
# engine resolves at all. Require the engine tier explicitly — then prove the
# assertion can tell them apart with the negative control right below.
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "── hcat:" \
   && ! printf '%s' "$out" | grep -q "engine absent"; then
  ok "hcat compresses non-ASCII JSON on Windows with the REAL engine (rc=0, receipt, no engine-absent tier)"
else fail "hcat on non-ASCII JSON" "rc=$rc" "$(printf '%s' "$out" | head -1)" "$(head -3 "$TMPD/hcat.err")"; fi
# ...and the SAVINGS EVENT must actually land. bin/hcat's `import fcntl` used to
# sit inside _append_event's one broad try/except, so on Windows every run
# silently recorded nothing -- the whole reason the lock-free branch exists.
# _append_event STILL swallows every exception, so nothing but this assertion
# can tell a regression from a working run: rc and the receipt are identical
# either way, and the POSIX stats fixtures are gated behind a HEADROOM_PY that
# used to be unresolvable under Git Bash.
# glob, not a fixed name: the REAL engine writes session_stats.jsonl (headroom's
# own _paths.session_stats_path()). The w12 POSIX fixture asserts "stats.jsonl"
# only because it drives hcat through a STUB python that fabricates that file --
# modelling this assertion on it produced a false FAIL against a working engine.
if grep -qs '"strategy":"hcat"' "$HCAT_WS"/*.jsonl; then
  ok "hcat recorded its savings event on Windows (no fcntl, stats written)"
else
  fail "hcat wrote no stats event on Windows — the no-fcntl branch regressed silently" \
       "looked for *.jsonl in: $HCAT_WS" "$(ls -l "$HCAT_WS" 2>&1 | head -5)"
fi
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
# System32 is here so check 2b's NATIVE probe (cmd.exe /c where) can actually
# run: without it `command -v cmd.exe` misses, the probe takes its "cannot ask"
# early return, and the whole native-visibility fix has zero coverage on every
# host -- exactly how the wrapper-bash bug hid. headroom is not in System32, so
# the sandbox's isolation is unchanged.
SB_PATH="$SB/.local/bin:$(dirname "$(command -v jq)"):/usr/bin:/bin:/mingw64/bin:/c/Windows/System32"
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

# 5b. ...and it must be Git's EXTERNAL wrapper bash, not the MSYS-INTERNAL one.
# <gitroot>/usr/bin/bash.exe carries no MSYS coreutils when it is spawned from a
# native Windows process -- which is exactly how Claude Code spawns the status
# line -- so dirname/cat/wc/tr vanish and the badge degrades to a permanent idle.
# The shape check above cannot see the difference (both spellings end
# `bash.exe`), and the PowerShell smoke step cannot either, because
# windows-latest carries Git\usr\bin on the MACHINE PATH and that masks it at
# runtime. So assert the WIRING here, where masking cannot reach. Mirrors
# doctor.sh's sl_prefer_wrapper_bash: only demand the promotion when the wrapper
# really exists on disk (a Git install without the bin/ sibling legitimately
# keeps usr/bin, and the w14a fixtures cover that branch).
sl_b=$(command -v bash)
case $sl_b in
  */usr/bin/bash|*/usr/bin/bash.exe)
    # Resolve the wrapper in the NATIVE namespace, the way doctor.sh's
    # _sl_drive_posix/_sl_same_native do. Stripping three /-components off
    # /usr/bin/bash leaves an empty root, so the old form tested "/bin/bash" --
    # and inside a real Git Bash /bin is a MOUNT ALIAS of /usr/bin, which
    # doctor.sh itself calls out as a trap. So `[ -f ]` was unconditionally true:
    # this gate never checked that <gitroot>/bin/bash.exe exists, and the skip it
    # documents for a Git install without the bin/ sibling could never be taken.
    sl_b_win=$(cygpath -w "$sl_b" 2>/dev/null || printf '%s' "$sl_b")
    sl_wrapper_win="${sl_b_win%\\usr\\bin\\*}\\bin\\${sl_b_win##*\\}"
    sl_wrapper=$(cygpath -u "$sl_wrapper_win" 2>/dev/null || printf '%s' "$sl_wrapper_win")
    if [ -f "$sl_wrapper" ]; then
      case $cmd in
        *[\\/]usr[\\/]bin[\\/]bash*)
          fail "doctor wired the MSYS-internal bash although $sl_wrapper exists" \
               "got: $cmd" \
               "that bash loses MSYS coreutils when Claude Code spawns it natively" ;;
        *) ok "doctor: statusLine uses Git's external wrapper bash, not usr/bin ($cmd)" ;;
      esac
    elif [ "${WRAPPER_BASH_EXPECTED:-0}" = "1" ]; then
      # Same shape as UV_EXPECTED above: the workflow knows this runner is Git
      # for Windows, so the wrapper MUST be there. This assertion is the only
      # regression guard on the wrapper-bash fix — the PowerShell differential is
      # explicitly not evidence for it — so letting it skip would retire the
      # guard silently (review #9).
      fail "wrapper bash $sl_wrapper absent although WRAPPER_BASH_EXPECTED=1" "command -v bash: $sl_b"
    else
      skip "wrapper-bash promotion (no $sl_wrapper on this runner)"
    fi ;;
  *) if [ "${WRAPPER_BASH_EXPECTED:-0}" = "1" ]; then
       fail "command -v bash is $sl_b, not a usr/bin spelling, so the wrapper-bash guard did not run (WRAPPER_BASH_EXPECTED=1)"
     else
       skip "wrapper-bash promotion (command -v bash is $sl_b, not usr/bin)"
     fi ;;
esac
out2=$(doctor_sb); rc2=$?
[ "$rc2" -eq 0 ] && ok "doctor --fix run 2 exits 0" || fail "doctor --fix run 2 exited $rc2"
printf '%s\n' "$out2" | grep -qE '^FAIL' && fail "doctor --fix run 2 printed a FAIL line" "$out2" || ok "doctor --fix run 2 has no FAIL lines"
printf '%s\n' "$out2" | grep -qE '^fixed ' && fail "doctor: second --fix not idempotent" "$out2" || ok "doctor: second --fix is a no-op"
# ...and a settled install must be CLEAN, not merely FAIL-free. This gate greps
# only ^FAIL, so a permanently-firing `fixable` — an advisory the user can never
# clear because it is simply wrong — sailed through it green. That is exactly how
# the native-probe false negative survived a passing required gate.
printf '%s\n' "$out2" | grep -qE '^fixable ' \
  && fail "doctor: a settled --fix still reports fixable — an advisory the user cannot clear" "$out2" \
  || ok "doctor: a settled --fix reports nothing fixable"
printf '%s\n' "$out2" | grep -qE '^ok +- headroom CLI on PATH' && ok "doctor: run 2 resolves the shimmed headroom on PATH" || fail "doctor: run 2 did not report headroom CLI on PATH" "$out2"
printf '%s\n' "$cmd" > "$ROOT/statusline.cmd"   # consumed by the PowerShell step
# Hand the sandbox shim dir off the same way, in its NATIVE spelling: the
# PowerShell step prepends it to PATH and spawns the doctor's own `headroom.exe`
# shell-lessly. Without this the only thing ever proven about that copy was that
# Git Bash could run `--help` on it (review #7).
printf '%s\n' "$(cygpath -w "$SB/.local/bin")" > "$ROOT/shimdir.path"

echo
summary="$PASS passed, $FAIL failed, $SKIP skipped"
[ "$SKIP" -gt 0 ] && summary="$summary — skipped: $SKIP_NAMES"
echo "$summary"
# A required gate that reports success no matter how many of its assertions
# stopped running is the F8 shape one level down. Genuinely optional layouts may
# still skip, but the count is bounded so a runner-image change cannot quietly
# retire assertions (review #9).
if [ "$SKIP" -gt "${WINDOWS_CHECK_MAX_SKIPS:-1}" ]; then
  echo "windows-check: $SKIP skipped exceeds max ${WINDOWS_CHECK_MAX_SKIPS:-1} — assertions stopped running: $SKIP_NAMES" >&2
  exit 1
fi
[ "$FAIL" -eq 0 ]
