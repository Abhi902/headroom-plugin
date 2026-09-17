#!/usr/bin/env bash
# windows-check.sh — the required Windows CI gate for issue #9. Runs under Git
# Bash on windows-latest with a REAL headroom engine installed by the workflow.
# Every assertion here is something the macOS fixtures can only simulate.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()   { echo "ok - $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL - $1"; shift; [ $# -gt 0 ] && printf '    %s\n' "$@"; FAIL=$((FAIL+1)); }
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
  echo "skip - uv tool layout (uv not installed on this runner)"
fi

# 4. hcat on non-ASCII JSON with the real engine (UTF-8 regression)
TMPD=$(mktemp -d)
python - "$TMPD/uni.json" <<'PY'
import json, sys
rows = [{"id": i, "name": "naïve ✓ 日本 %d" % i, "note": "ünïcode"} for i in range(300)]
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(rows, ensure_ascii=False, indent=2))
PY
out=$(env -u HCAT_PYTHON DOCTOR_VENV_DIR="$VENV_DIR" PATH="/usr/bin:/bin" bash "$ROOT/bin/hcat" "$TMPD/uni.json" 2>"$TMPD/hcat.err"); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "── hcat:"; then ok "hcat compresses non-ASCII JSON on Windows (rc=0, receipt printed)"
else fail "hcat on non-ASCII JSON" "rc=$rc" "$(head -3 "$TMPD/hcat.err")"; fi

# 5. doctor --fix in a sandbox HOME with the real venv: engine ok, shim created, status line wired with Windows paths
SB="$TMPD/home"; mkdir -p "$SB/.claude" "$SB/.local/bin"
out=$(env -u HCAT_PYTHON HOME="$SB" PATH="$SB/.local/bin:$PATH" DOCTOR_SETTINGS="$SB/.claude/settings.json" DOCTOR_CLAUDE_DIR="$SB/.claude" \
      DOCTOR_VENV_DIR="$VENV_DIR" DOCTOR_SHIM_DIR="$SB/.local/bin" DOCTOR_PROJECT_DIR="$TMPD/noproj" bash "$ROOT/scripts/doctor.sh" --fix 2>&1); rc=$?
echo "$out" | sed 's/^/    doctor: /'
printf '%s' "$out" | grep -q "engine python:" && ok "doctor: engine found" || fail "doctor: engine"
printf '%s' "$out" | grep -qE "headroom (shimmed to|CLI on PATH)" && ok "doctor: headroom on PATH / shimmed" || fail "doctor: shim"
[ -f "$SB/.local/bin/headroom.exe" ] && ok "doctor: shim is headroom.exe" || echo "skip - shim file (headroom already on PATH)"
cmd=$(jq -r '.statusLine.command' "$SB/.claude/settings.json")
case $cmd in \"*bash.exe\"\ \"*headroom-statusline.sh\") ok "doctor: statusLine command uses Windows paths ($cmd)" ;; *) fail "statusLine command shape" "got: $cmd" ;; esac
out2=$(env -u HCAT_PYTHON HOME="$SB" PATH="$SB/.local/bin:$PATH" DOCTOR_SETTINGS="$SB/.claude/settings.json" DOCTOR_CLAUDE_DIR="$SB/.claude" \
       DOCTOR_VENV_DIR="$VENV_DIR" DOCTOR_SHIM_DIR="$SB/.local/bin" DOCTOR_PROJECT_DIR="$TMPD/noproj" bash "$ROOT/scripts/doctor.sh" --fix 2>&1)
printf '%s' "$out2" | grep -q " fixed " && fail "doctor: second --fix not idempotent" "$out2" || ok "doctor: second --fix is a no-op"
printf '%s\n' "$cmd" > "$ROOT/statusline.cmd"   # consumed by the PowerShell step

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
