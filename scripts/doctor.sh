#!/usr/bin/env bash
# doctor.sh — setup health checks (and --fix repairs) for the
# headroom-usage-indicator plugin.
#
# Read-only by default: prints aligned ok/FAIL/fixable/skip lines and exits 0
# iff nothing FAILed. `--fix` applies the repairs reported as fixable:
#   * engine bootstrap — <python3|python|py -3> -m venv ~/.headroom-venv + pip install "headroom-ai[all]" (bin/ or Scripts/ layout)
#   * legacy hooks     — remove pre-plugin dangi/gate hook entries from
#                        settings.json (timestamped .bak written first)
#   * statusLine       — copy scripts/statusline.sh to ~/.claude/headroom-statusline.sh
#                        and wire settings.json statusLine at it (.bak first);
#                        merge-aware: an existing non-headroom command is kept
#                        under _headroomStatusLineBackup and chained before the
#                        badge (same semantics as the SKILL.md installer). On
#                        Windows that chain lives in a script file next to the
#                        copy (headroom-statusline-chain.sh) so the persisted
#                        command stays the `"<bash.exe>" "<C:\...>"` pair
#                        Claude Code can actually spawn there
#   * wired-missing copy — re-copy statusline.sh (+ lib deps, price table) to
#                        ~/.claude when settings already point at the canonical
#                        path but the script is absent; if the wiring named it
#                        by a respelling bash can never expand (a quoted ~),
#                        also rewrites statusLine.command to the absolute path
#                        (.bak first)
#   * (removed in v2.8) quoted mcp cmd — .mcp.json now names the bare `headroom`; nothing to rewrite
#   * headroom on PATH — shim the resolved `headroom` CLI into ~/.local/bin
#                        (symlink; a copy of headroom.exe on Windows) so the
#                        bundled .mcp.json's bare command resolves; verified
#                        afterwards by NAME and by EXECUTION, FAIL with the PATH
#                        snippet if it still doesn't resolve and FAIL if it
#                        resolves but won't start. A foreign (non-symlink,
#                        non-identical) file already at the shim path is never
#                        overwritten — ~/.local/bin belongs to pipx/uv/pip too
#   * stale copies     — delete pre-plugin script copies in ~/.claude, but only
#                        once plugin-native hooks are confirmed and no legacy
#                        hook entries remain
# All fixes are idempotent: a second --fix run changes nothing.
#
# Env overrides (used by the hermetic test suite):
#   DOCTOR_SETTINGS    settings.json path   (default ~/.claude/settings.json)
#   DOCTOR_CLAUDE_DIR  legacy-copy dir      (default ~/.claude)
#   DOCTOR_VENV_DIR    engine venv dir      (default ~/.headroom-venv)
#   HCAT_PYTHON        engine python override (authoritative, no fallback —
#                      same contract as bin/hcat)
#   DOCTOR_OS          windows|unix — force platform branches (default: detect)
#   DOCTOR_SHIM_DIR    where --fix shims `headroom` (default ~/.local/bin)
#   DOCTOR_DRIVE_ROOT  prefix for the Windows drive mount (default "" => /c/...)
#   DOCTOR_CYGPATH     cygpath stub for tests (default: cygpath when present)
#   DOCTOR_SHIM_RUNS_TIMEOUT  seconds a `headroom --help` probe may take (default 5)
#
# Exit codes: 0 no FAILs · 1 at least one FAIL · 2 usage
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$SELF_DIR/.." && pwd)
SETTINGS=${DOCTOR_SETTINGS:-$HOME/.claude/settings.json}
CLAUDE_DIR=${DOCTOR_CLAUDE_DIR:-$HOME/.claude}
VENV_DIR=${DOCTOR_VENV_DIR:-$HOME/.headroom-venv}
SHIM_DIR=${DOCTOR_SHIM_DIR:-${HOME:-}/.local/bin}

# Ambient-health state (see statusline.sh): checked before the run because the
# hcat smoke test itself clears engine errors on a working compression. Source
# the shared STATE_DIR definition; fall back to the inline default if the lib
# is absent (legacy flat install).
# shellcheck disable=SC1090,SC1091
for _sl in "$SELF_DIR/lib/headroom-state.sh" "$SELF_DIR/headroom-state.sh"; do
  [ -f "$_sl" ] && { . "$_sl"; break; }
done
# shellcheck disable=SC1090,SC1091
for _er in "$SELF_DIR/lib/engine-resolve.sh" "$SELF_DIR/engine-resolve.sh"; do
  [ -f "$_er" ] && { . "$_er"; break; }
done
if ! type engine_python_candidates >/dev/null 2>&1; then
  echo "doctor: scripts/lib/engine-resolve.sh missing — partial plugin checkout; reinstall the plugin" >&2
  exit 1
fi
HEALTH_STATE_DIR="${STATE_DIR:-${HEADROOM_STATE_DIR:-${HOME:-${TMPDIR:-/tmp}}/.claude/headroom-indicator}}"
HEALTH_HAD_ERROR=0
HEALTH_ERR_SNAP=""
if [ -f "$HEALTH_STATE_DIR/last-error" ]; then
  HEALTH_HAD_ERROR=1
  # Snapshot the CONTENT, not just existence: a --fix run can take a while,
  # and the final all-clear must not wipe a fresh error some other session
  # recorded mid-run.
  HEALTH_ERR_SNAP=$(cat "$HEALTH_STATE_DIR/last-error" 2>/dev/null) || HEALTH_ERR_SNAP=""
fi

FIX=0
for arg in "$@"; do
  case $arg in
    --fix) FIX=1 ;;
    *) echo "doctor: unknown argument: $arg (usage: doctor.sh [--fix])" >&2; exit 2 ;;
  esac
done

OK=0; FIXABLE=0; FAILED=0; SKIPPED=0
say() {  # say <ok|fixed|FAIL|fixable|skip> <message> — aligned status lines
  printf '%-7s - %s\n' "$1" "$2"
  case $1 in
    ok|fixed) OK=$((OK+1)) ;;
    fixable)  FIXABLE=$((FIXABLE+1)) ;;
    FAIL)     FAILED=$((FAILED+1)) ;;
    skip)     SKIPPED=$((SKIPPED+1)) ;;
  esac
}

TMPD=$(mktemp -d) || exit 1
trap 'rm -rf "$TMPD"' EXIT

# one timestamped settings.json backup per doctor run, before the first edit.
# Returns failure (and keeps returning it for the rest of this run, via
# BAK_FAILED) when the cp itself fails -- callers must refuse to proceed with
# a destructive rewrite when this returns nonzero, the same way the .mcp.json
# fix already gates its own rewrite on a checked backup.
BAK_DONE=0; BAK_FAILED=0
backup_settings() {
  if [ "$BAK_DONE" -eq 0 ]; then
    BAK_DONE=1
    if [ -f "$SETTINGS" ] && ! cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null; then
      BAK_FAILED=1
    fi
  fi
  [ "$BAK_FAILED" -eq 0 ]
}

# --- 0. platform — on Windows every hook and the status line run through Git Bash
if is_windows; then
  if [ -n "${CLAUDE_CODE_GIT_BASH_PATH:-}" ] && [ ! -f "$CLAUDE_CODE_GIT_BASH_PATH" ]; then
    # Actionable like session-probe.sh's twin line: the usual cause is a STALE
    # variable on a box that has Git Bash, so name where the value lives before
    # suggesting an install.
    say FAIL "CLAUDE_CODE_GIT_BASH_PATH points at a missing file ($CLAUDE_CODE_GIT_BASH_PATH) — hooks and the status line run through Git Bash: fix that path in settings.json env, or unset it when Git for Windows is already on PATH (and install Git for Windows if it is not)"
  else
    say ok "Windows (Git Bash) — hooks and the status line run through it"
  fi
fi

# --- 1. jq — everything else that reads JSON leans on it
HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then
  HAVE_JQ=1
  say ok "jq found ($(command -v jq))"
else
  say FAIL "jq not found — install it (brew install jq / apt install jq)"
fi

# --- 2. headroom engine python — candidates come from scripts/lib/engine-resolve.sh
# (HCAT_PYTHON authoritative → PATH sibling → shebang interp unless PE → uv tool
# dir → venv bin/ or Scripts/); the first one that imports headroom.compress wins.
PY=""
HCAT_PY_BROKEN=0
# set when this run just bootstrapped the venv itself; check 3 must not smoke
# a stub/fresh venv on the same run it was created (see check 3 below)
boot_used=""
if [ -n "${HCAT_PYTHON:-}" ]; then
  if [ -x "$HCAT_PYTHON" ] && "$HCAT_PYTHON" -c 'import headroom.compress' >/dev/null 2>&1; then
    PY=$HCAT_PYTHON
  else
    HCAT_PY_BROKEN=1
  fi
else
  while IFS= read -r cand; do
    if [ -n "$cand" ] && [ -x "$cand" ] && "$cand" -c 'import headroom.compress' >/dev/null 2>&1; then
      PY=$cand; break
    fi
  done < <(engine_python_candidates)
fi
if [ -n "$PY" ]; then
  say ok "engine python: $PY (import headroom.compress works)"
elif [ "$HCAT_PY_BROKEN" -eq 1 ] && [ "$FIX" -eq 1 ]; then
  # the override is authoritative, so a bootstrapped venv would never be used:
  # bootstrapping here burns time every run and the check still never turns ok
  say FAIL "HCAT_PYTHON is set but broken ($HCAT_PYTHON) — unset it or point it at a working python (refusing to bootstrap while it is set)"
elif [ "$FIX" -eq 1 ]; then
  venv_preexisted=0; [ -e "$VENV_DIR" ] && venv_preexisted=1
  # interpreter order: POSIX prefers python3; Windows prefers the py launcher and
  # plain python (python3 there is often the Store alias stub that only nags)
  if is_windows; then boot_order="py:-3 python python3"; else boot_order="python3 python py:-3"; fi
  for boot_c in $boot_order; do
    boot_cmd=${boot_c%%:*}; boot_arg=""
    [ "$boot_c" != "$boot_cmd" ] && boot_arg=${boot_c#*:}
    command -v "$boot_cmd" >/dev/null 2>&1 || continue
    # shellcheck disable=SC2086
    if "$boot_cmd" $boot_arg -m venv "$VENV_DIR" >/dev/null 2>&1; then
      boot_used="$boot_cmd${boot_arg:+ $boot_arg}"; break
    fi
    # a failed attempt must not leave a half-venv for the next interpreter to trip on
    [ "$venv_preexisted" -eq 0 ] && rm -rf "$VENV_DIR"
  done
  boot_bindir=""; [ -n "$boot_used" ] && boot_bindir=$(venv_bindir "$VENV_DIR" 2>/dev/null) || boot_bindir=""
  boot_py="python"; boot_pip="pip"
  [ "$boot_bindir" = "Scripts" ] && { boot_py="python.exe"; boot_pip="pip.exe"; }
  # `[all]` is preferred, but it is NOT safe to require: on Windows it resolves
  # the `ml` extra → torch>=2.12.1 (~2.5 GB), because that dependency's
  # `sys_platform != "darwin"` marker applies there. On a slow link that is a
  # long silent hang followed by "engine bootstrap failed" for what would have
  # been a perfectly usable engine. The CI step has always hedged with
  # `|| pip install headroom-ai`; the doctor must hedge identically. The bare
  # package still carries everything hcat and the MCP server need.
  boot_pkg=""
  if [ -n "$boot_used" ] && [ -n "$boot_bindir" ] && [ -x "$VENV_DIR/$boot_bindir/$boot_pip" ]; then
    if "$VENV_DIR/$boot_bindir/$boot_pip" install "headroom-ai[all]" >/dev/null 2>&1; then
      boot_pkg="headroom-ai[all]"
    elif "$VENV_DIR/$boot_bindir/$boot_pip" install "headroom-ai" >/dev/null 2>&1; then
      boot_pkg="headroom-ai"
    fi
  fi
  if [ -n "$boot_pkg" ] \
     && [ -x "$VENV_DIR/$boot_bindir/$boot_py" ] \
     && "$VENV_DIR/$boot_bindir/$boot_py" -c 'import headroom.compress' >/dev/null 2>&1; then
    say fixed "engine bootstrapped: $boot_used -m venv $VENV_DIR + $boot_bindir/$boot_pip install \"$boot_pkg\""
    PY="$VENV_DIR/$boot_bindir/$boot_py"
  else
    # never leave a half-created venv behind: its python would pass -x
    # checks elsewhere while pip and the headroom package are missing
    [ "$venv_preexisted" -eq 0 ] && rm -rf "$VENV_DIR"
    hint=""
    command -v apt-get >/dev/null 2>&1 \
      && hint=" (on Debian/Ubuntu, python3 -m venv needs the python3-venv package: sudo apt install python3-venv)"
    # headroom-ai ships COMPILED abi3 wheels and publishes none for win_arm64, so
    # on Windows-on-ARM with an ARM64 interpreter pip matches nothing, falls back
    # to the source dist and wants a full build toolchain — BOTH installs above
    # then fail for a reason that repeating the command by hand cannot change.
    # Ask the interpreter for its wheel tag instead of guessing: `uname` is no use
    # here, because Git for Windows is an x86_64 build and reports x86_64 even on
    # an ARM64 host. The remedy is real — the x64 Python runs emulated there and
    # matches the win_amd64 wheel.
    if [ -n "$boot_used" ]; then
      # shellcheck disable=SC2086
      boot_plat=$($boot_used -c 'import sysconfig;print(sysconfig.get_platform())' 2>/dev/null)
      case $boot_plat in
        *arm64*|*aarch64*)
          is_windows && hint=" — this interpreter is \"$boot_plat\" and headroom-ai publishes no win_arm64 wheel, so pip fell back to the source dist: install the x64 build of Python (it runs emulated on Windows-on-ARM and matches the win_amd64 wheel), then re-run" ;;
      esac
    fi
    # the by-hand path has to name the bindir THIS platform builds: a Windows venv
    # has Scripts/, and sending a Windows user to $VENV_DIR/bin/pip — on the very
    # platform this check exists for — is a dead end.
    boot_hint_bin=bin; is_windows && boot_hint_bin=Scripts
    say FAIL "engine bootstrap failed (tried python3, python, py -3) — by hand: python3 -m venv $VENV_DIR && $VENV_DIR/$boot_hint_bin/pip install \"headroom-ai[all]\"$hint"
  fi
elif [ "$HCAT_PY_BROKEN" -eq 1 ]; then
  say fixable "engine python not found — HCAT_PYTHON is set but broken ($HCAT_PYTHON); unset it or point it at a working python (--fix refuses to bootstrap while it is set)"
else
  say fixable "engine python not found — --fix creates $VENV_DIR (python3/python/py -3 -m venv) and pip-installs headroom-ai"
fi

# --- 2b. `headroom` on PATH — .mcp.json spawns the bare name (no shell, no launcher)
shim_target() {  # the shim file this platform writes (a copy named headroom.exe on Windows)
  if is_windows; then printf '%s' "$SHIM_DIR/headroom.exe"; else printf '%s' "$SHIM_DIR/headroom"; fi
}
is_own_shim() {  # is_own_shim <path> — is this the file THIS run would have written?
  # Compare with the .exe suffix normalized OFF both sides. shim_target() is
  # "$SHIM_DIR/headroom.exe" on Windows, but `command -v headroom` inside Git
  # Bash yields the suffix-less spelling (engine-resolve.sh appends .exe AFTER
  # its lookup, for exactly this reason). A raw string compare therefore never
  # matched on Windows, so the dead-own-shim self-repair and its "this is your
  # own shim" hint were both unreachable there — the misdiagnosis loop that
  # cli_healed/cli_retry exist to kill, still live on the one platform that
  # writes the shim as a copy.
  local a b
  a=${1%.exe}; b=$(shim_target); b=${b%.exe}
  [ "$a" = "$b" ]
}
shim_headroom() {  # shim_headroom <cli> — link/copy into SHIM_DIR; prints the shim path
  # rc 2 = a FOREIGN file already occupies the target. $SHIM_DIR (~/.local/bin by
  # default) is not doctor-owned territory: pipx, `uv tool install` and `pip
  # install --user` put real binaries there — and the only way we get here is that
  # `headroom` did NOT resolve on the current PATH, which is exactly the shape of
  # "their install exists, their PATH is stale". Replacing it would be
  # unrecoverable (every other destructive write in this file takes a .bak first),
  # so refuse and let 2b say so. A symlink is ours to replace; a byte-identical
  # regular file already IS the shim, so leave it alone — that keeps --fix
  # idempotent on Windows, where the shim is a copy rather than a link.
  # $TMPD/shim-written records whether this run actually WROTE the file (as
  # opposed to finding a byte-identical one already in place). The verify
  # branch below removes a shim that does not start, and it must only ever
  # remove one the doctor itself just created. This is a marker FILE rather
  # than a variable because the caller runs us in a command substitution.
  local target link; target=$(shim_target)
  rm -f "$TMPD/shim-written"
  if [ -L "$target" ]; then
    # A SYMLINK here is NOT automatically ours. pipx (and `pip install --user`
    # on some layouts) install ~/.local/bin console scripts as symlinks, so
    # `ln -sfn` over one silently repointed somebody else's install with no
    # backup and no way back — the very thing the foreign-file refusal below
    # exists to prevent. Only a link that ALREADY names the CLI we resolved is
    # ours to keep (that is what makes the POSIX shim path idempotent);
    # anything else — including a dangling link — gets the same rc 2 refusal.
    link=$(readlink "$target" 2>/dev/null) || link=""
    [ "$link" = "$1" ] || return 2
    printf '%s' "$target"; return 0
  elif [ -e "$target" ]; then
    cmp -s "$1" "$target" || return 2
    printf '%s' "$target"; return 0
  fi
  mkdir -p "$SHIM_DIR" 2>/dev/null || return 1
  if is_windows; then
    # rc 3 = the resolved CLI is not a PE image. CreateProcess can only spawn a
    # real executable, but a venv built with a bin/ layout (or a pip --user /
    # pipx console script) leaves a `#!`-shebang SCRIPT named `headroom` — which
    # venv_bindir and resolve_headroom_cli both happily select. Copying that to
    # headroom.exe yields a file Windows cannot start while shim_runs (which
    # runs it through bash) still succeeds, so the doctor used to report `fixed`
    # over an MCP that can never connect. Refuse instead; 2b explains the remedy.
    # DOCTOR_FAKE_PE is a TEST-ONLY seam, in the same family as DOCTOR_OS and
    # DOCTOR_CYGPATH. The suite's Windows fixtures fake the OS while building
    # their fake engine as a POSIX `#!` script — it has to stay runnable by
    # whichever host is actually executing the suite. On a POSIX host that is
    # self-consistent; on a GENUINE Windows host is_windows() is really true,
    # so this guard correctly refuses those fixtures and they could never pass
    # there. The seam lets such a fixture say "treat the engine as a PE image";
    # the fixture that tests THIS refusal deliberately leaves it unset. No real
    # user ever sets it, so the guard stays at full strength in production.
    [ "${DOCTOR_FAKE_PE:-0}" = "1" ] || _er_is_pe "$1" || return 3
    # never write the copy THROUGH a link someone else left here (cp would
    # follow it and clobber its target); the guards above already refused to
    # adopt any link that is not ours
    rm -f "$target" 2>/dev/null
    cp "$1" "$target" 2>/dev/null && { : > "$TMPD/shim-written"; printf '%s' "$target"; }
  else
    ln -sfn "$1" "$target" 2>/dev/null && { : > "$TMPD/shim-written"; printf '%s' "$target"; }
  fi
}
run_bounded() {  # run_bounded <seconds> <cmd> [args...] — the command's own status, nonzero if it overran
  # Portable bounded wait: coreutils `timeout` when the box has it (gtimeout on a
  # brew-installed macOS), else a background child plus a watchdog loop. Keep it
  # bash-3.2 safe — no `wait -n`, no arrays, no process substitution.
  local secs pid waited
  secs=$1; shift
  if   command -v timeout  >/dev/null 2>&1; then timeout  "$secs" "$@"; return $?
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?
  fi
  "$@" &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124          # same status coreutils `timeout` uses for a kill
    fi
    sleep 1
    waited=$((waited+1))
  done
  wait "$pid"             # finished on its own: report ITS status, not ours
  return $?
}
shim_runs() {  # shim_runs <shim> — the shimmed CLI actually STARTS, not just resolves
  # Name resolution alone proves nothing: uv's relocatable trampolines resolve the
  # interpreter relative to their own directory (so a copy elsewhere resolves and
  # then dies at spawn), and a name-squatted `headroom` on PyPI would greenlight
  # the line that stands in for "the MCP will connect". Cheap flag, engine env.
  #
  # BOUNDED: a plain `/doctor` executes whatever `command -v headroom` resolves —
  # by this function's own reasoning that may be a squatter or a wedged binary —
  # so a hang here would hang the doctor (and the skill that runs it) forever.
  # `env` carries the engine vars because run_bounded is a function, not a command.
  run_bounded "${DOCTOR_SHIM_RUNS_TIMEOUT:-5}" \
    env HEADROOM_UPDATE_CHECK=off HF_HUB_OFFLINE=1 "$1" --help >/dev/null 2>&1
}
reinstall_hint() {  # how to repair an engine whose `headroom` CLI is missing or broken
  # HCAT_PYTHON is authoritative with no fallback, so "$PY -m pip install …" would
  # be telling an HCAT_PYTHON=/usr/bin/python3 user to pip into the SYSTEM python.
  if [ -n "${HCAT_PYTHON:-}" ]; then
    printf 'install headroom-ai into the interpreter HCAT_PYTHON points at, or unset HCAT_PYTHON'
  elif [ -n "$PY" ]; then
    printf '%s -m pip install "headroom-ai[all]"' "$PY"
  else
    printf 'pip install "headroom-ai[all]" into the engine environment'
  fi
}
# Git for Windows ships TWO bash binaries and they are NOT interchangeable for
# our purpose. <gitroot>/usr/bin/bash.exe is the MSYS-INTERNAL one: spawned
# from a native Windows process — which is exactly how Claude Code spawns the
# status line — its PATH carries no MSYS coreutils, so dirname/cat/wc/tr are
# all "command not found", the badge degrades to a permanent idle and stderr
# fills with noise. <gitroot>/bin/bash.exe is the wrapper Git for Windows ships
# FOR external invocation precisely because it sets that PATH up first.
# `command -v bash` inside Git Bash resolves to the usr/bin one, so whenever
# that bin/ sibling really exists on disk we must promote to it.
# CI cannot catch this: windows-latest has Git\usr\bin on PATH, which masks it.
_sl_same_native() {  # same file once both are spelled natively? (catches the /bin -> /usr/bin alias)
  [ "$(win_path "$1")" = "$(win_path "$2")" ]
}
_sl_drive_posix() {  # C:\a\b -> /c/a/b via the DRIVE mount, bypassing the mount table
  local w=$1 drive rest
  case $w in
    [A-Za-z]:[\\/]*) drive=${w%%:*}; rest=${w#?:} ;;
    *) printf '%s\n' "$w"; return ;;
  esac
  drive=$(printf '%s' "$drive" | tr 'A-Z' 'a-z')
  rest=$(printf '%s' "$rest" | tr '\\' '/')
  # DOCTOR_DRIVE_ROOT re-bases the drive mount so a POSIX host can stage one
  # (a real Git Bash has /c, /d, ... at the filesystem root; a test cannot).
  printf '%s/%s%s\n' "${DOCTOR_DRIVE_ROOT:-}" "$drive" "$rest"
}
sl_prefer_wrapper_bash() {  # <bash path, native or POSIX spelling> → possibly promoted
  local p=$1 sep base root cand cw
  case $p in
    *[\\/]usr[\\/]bin[\\/]bash|*[\\/]usr[\\/]bin[\\/]bash.exe) ;;
    *) printf '%s\n' "$p"; return ;;
  esac
  base=${p##*[\\/]}                       # bash | bash.exe
  root=${p%[\\/]*}; root=${root%[\\/]*}; root=${root%[\\/]*}   # strip /usr/bin/<base>
  case $p in *\\*) sep='\' ;; *) sep='/' ;; esac
  cand="${root}${sep}bin${sep}${base}"
  # `-f` has to be applied to a path THIS shell can stat: inside Git Bash that
  # is the POSIX spelling, and unix_path is a no-op on one that already is.
  if [ -f "$(unix_path "$cand")" ] && ! _sl_same_native "$cand" "$p"; then
    p=$cand
  else
    # ...but inside a REAL Git Bash the POSIX branch above is a trap: /bin is an
    # alias for /usr/bin there, so /usr/bin/bash -> /bin/bash passes `-f` and
    # cygpath -w maps it straight back to ...\usr\bin\bash.exe. The promotion
    # then silently no-ops and we wire the coreutils-less bash after all -- which
    # is exactly what this function exists to prevent, and what CI could not see
    # while windows-latest carried Git\usr\bin on PATH. So retry in the NATIVE
    # namespace and reach the candidate through the DRIVE mount (/c/...), which
    # is not aliased, instead of through / (the Git root).
    cw=$(win_path "$p")
    case $cw in
      *\\usr\\bin\\*)
        cand="${cw%\\usr\\bin\\*}\\bin\\${cw##*\\}"
        [ -f "$(_sl_drive_posix "$cand")" ] && p=$cand ;;
    esac
  fi
  printf '%s\n' "$p"
}
sl_bash_path() {  # → the bash a Windows statusLine.command should run through
  local b nl cr
  # CLAUDE_CODE_GIT_BASH_PATH is env, and env can come from a PROJECT-scoped
  # settings.json — i.e. from repo config. `--fix` persists what we print here
  # into ~/.claude/settings.json as statusLine.command, which Claude Code then
  # EXECUTES, so a hostile value must not survive into it.
  #
  # Rejecting only the double quote was not enough: inside the double-quoted
  # word we print, exactly four things stay ACTIVE — `"` (closes the quoting),
  # `$` (parameter AND command substitution: a path under a directory literally
  # named `$(cmd)` is a real, existing file, so the -f test below passes), a
  # backtick (command substitution) and a newline/carriage return (starts a
  # second command line). Reject all four. A BACKSLASH is deliberately
  # ALLOWED: every native Windows path is full of them, and with the four
  # above gone a backslash can neither introduce an expansion nor terminate
  # the quoting — the worst it can do is name a file that does not exist,
  # which the -f test already catches.
  nl='
'
  cr=$(printf '\r')
  b=${CLAUDE_CODE_GIT_BASH_PATH:-}
  case $b in *'"'*|*'$'*|*'`'*|*"$nl"*|*"$cr"*) b="" ;; esac
  if [ -z "$b" ] || [ ! -f "$b" ]; then b=$(command -v bash); fi
  b=$(sl_prefer_wrapper_bash "$b")
  # normalize the ACCEPTED value too, not just the fallback: an override may be
  # POSIX-spelled (/c/Program Files/Git/bin/bash.exe) and Claude Code executes
  # this command outside Git Bash, where only the native spelling resolves.
  # `cygpath -w` on an already-Windows path is a no-op, so one pass covers both.
  win_path "$b"
}
sl_hr_cmd() {  # sl_hr_cmd <script> — the statusLine.command to write for this platform
  if is_windows; then
    printf '"%s" "%s"' "$(sl_bash_path)" "$(win_path "$1")"
  else
    printf 'bash "%s"' "$1"
  fi
}
path_hint() {  # the one line the user must run/do to put SHIM_DIR on PATH
  local rc
  if is_windows; then
    # name the dir this run actually shims into (DOCTOR_SHIM_DIR overrides the
    # default) — the surrounding FAIL text already names it, and a hardcoded
    # %USERPROFILE%\.local\bin contradicted it whenever they differed
    printf 'add %s to your user Path (Settings → System → About → Advanced system settings → Environment Variables), then restart Claude Code' "$(win_path "$SHIM_DIR")"
  else
    # shellcheck disable=SC2088  # literal ~ is intentional — a display string, not a path to expand
    case "${SHELL:-}" in *zsh) rc="~/.zshrc" ;; *) rc="~/.bashrc" ;; esac
    printf "run: echo 'export PATH=\"%s:\$PATH\"' >> %s — then restart Claude Code" "$SHIM_DIR" "$rc"
  fi
}
# cli_healed guards the one self-repair retry below: a dead shim the doctor
# itself wrote is removed under --fix and the whole check re-runs once, so the
# same run can rewrite it instead of telling the user to reinstall a healthy
# engine. Never more than once — a second dead file is a real diagnosis.
cli_healed=0; cli_retry=1
while [ "$cli_retry" -eq 1 ]; do
  cli_retry=0
# NOTE — there was a native-PATH probe here (cmd.exe /c where, MSYS dirs pruned)
# and it has been REMOVED, deliberately, not lost in a refactor.
#
# It returned a FALSE NEGATIVE on real Windows. In the e45dfb0 CI run it reported
# "a NATIVE process could not find `headroom`" about $SHIM_DIR — a directory that
# the SAME run proved holds a real PE headroom.exe, and which was FIRST on the
# doctor's PATH. Shipped, that means every correctly installed Windows user gets
# a standing "add this to your user Path" instruction for a directory that
# already works. An advisory that never clears is one people learn to ignore,
# including the times it is right, so this is worse than the honestly-caveated
# message it replaced.
#
# The mechanism is NOT yet known, and the two live candidates are
# indistinguishable by symptom: (a) MSYS_NO_PATHCONV=1 also suppressing MSYS's
# conversion of the PATH env var, so cmd receives a colon-separated POSIX PATH;
# (b) the PATH prune leaving System32 unresolvable, so `where` itself never runs
# and cmd's nonzero exit reads as "not found". The windows job now prints a
# diagnostic that separates them.
#
# Doing this properly means reading the PERSISTED user Path (HKCU\Environment),
# which is the only thing that actually answers "will Claude Code's MCP spawn
# resolve this name". Until then the check says what it can honestly verify.
if cli_now=$(command -v headroom 2>/dev/null) && [ -n "$cli_now" ]; then
  # Name resolution alone is not "verified": the shim branch below has always
  # re-checked by EXECUTION, and this branch must hold the same bar — a
  # `headroom` on PATH that resolves and then dies (a relocated uv trampoline,
  # a broken console script, a name squatter) would otherwise be greened here,
  # including on the doctor run right after this branch's own FAIL removed a
  # dead shim.
  if shim_runs "$cli_now"; then
    # The native probe ADVISES, it does not gate. A false negative here would
    # hard-FAIL every correctly configured Windows install on every run, and the
    # probe is not trustworthy enough to carry that: it asks through a native
    # child of Git Bash, whose PATH is MSYS-translated, and the argument-
    # conversion guards it needs may themselves perturb that translation. So say
    # what each namespace answered and let the user judge; `fixable` keeps the
    # exit status clean (only FAIL moves it) while still surfacing the mismatch.
    say ok "headroom CLI on PATH ($cli_now) — the bundled MCP spawns it by name (verified in this Bash environment, the closest proxy for Claude Code's MCP spawn env)"
  elif [ "$FIX" -eq 1 ] && [ "$cli_healed" -eq 0 ] && is_own_shim "$cli_now" \
       && rm -f "$cli_now" 2>/dev/null; then
    # The dead file is the doctor's OWN shim from an earlier run. Reporting it
    # as "reinstall the engine" misdiagnoses an engine that check 2 just found
    # healthy, and the identical FAIL repeated on every subsequent --fix with
    # the file untouched. Delete it and re-run this check so the shim path
    # below can repair it in this same run.
    hash -r 2>/dev/null
    cli_healed=1; cli_retry=1
    continue
  else
    cli_own=""
    is_own_shim "$cli_now" \
      && cli_own=" — this file is the doctor's own shim from an earlier run: delete it and re-run /doctor --fix to rewrite it"
    say FAIL "headroom on PATH at $cli_now does not run (\`$cli_now --help\` failed) — the bundled MCP spawns \`headroom\` by name and will fail to connect; reinstall the engine: $(reinstall_hint)$cli_own"
  fi
elif cli_res=$(resolve_headroom_cli); then
  if [ "$FIX" -eq 1 ]; then
    shim=$(shim_headroom "$cli_res"); shim_rc=$?
    if [ "$shim_rc" -eq 2 ]; then
      say FAIL "a different headroom already exists at $(shim_target) — not on PATH; add $SHIM_DIR to PATH or remove that file, then re-run --fix"
    elif [ "$shim_rc" -eq 3 ]; then
      say FAIL "the resolved headroom CLI ($cli_res) is not a Windows executable — it is a \`#!\` console script (no MZ/PE header), and Windows cannot spawn one shell-less, so copying it to $(shim_target) would leave the bundled MCP unable to connect; reinstall the engine with a Windows layout so pip produces a real Scripts\\headroom.exe: py -3 -m venv $VENV_DIR && $VENV_DIR/Scripts/python.exe -m pip install \"headroom-ai[all]\" (or: uv tool install headroom-ai)"
    elif [ "$shim_rc" -ne 0 ]; then
      say FAIL "could not shim $cli_res into $SHIM_DIR"
    else
      hash -r 2>/dev/null
      # NOTE: this asks the POSIX question, like the branch above. When a native
      # probe is reinstated (see the removal note at check 2b), it has to gate
      # BOTH sites or it gates neither in practice: a native "no" here falls
      # through to `command -v`, which finds the same MSYS-only copy because
      # PATH never changed, skips the "not on PATH" FAIL, and reports
      # `fixed - ... (resolves on PATH)` with exit 0.
      if ! command -v headroom >/dev/null 2>&1; then
        say FAIL "headroom shimmed to $shim but $SHIM_DIR is not on PATH — $(path_hint)"
      elif ! shim_runs "$shim"; then
        # Remove the dead file we just wrote. Leaving it behind is worse than
        # never writing it: the next run's `command -v headroom` branch would
        # find it, and a shim that resolves is exactly what that branch used to
        # green. Only ever delete a shim THIS run created — a byte-identical
        # pre-existing file is the user's, not ours.
        shim_gone=""
        if [ -f "$TMPD/shim-written" ]; then
          rm -f "$shim" && shim_gone=" (the broken shim was removed)"
        fi
        say FAIL "headroom shimmed to $shim but it does not run (\`$shim --help\` failed)$shim_gone — reinstall the engine: $(reinstall_hint)"
      else
        say fixed "headroom shimmed to $shim (resolves on PATH)"
      fi
    fi
  else
    say fixable "headroom CLI not on PATH (engine at $cli_res) — the bundled MCP spawns \`headroom\` by name; --fix shims it into $SHIM_DIR"
  fi
elif [ -z "$PY" ]; then
  say skip "headroom CLI on PATH (no engine yet — fix the engine first)"
else
  say FAIL "engine python found ($PY) but no \`headroom\` CLI next to it — reinstall: $(reinstall_hint)"
fi
done   # end of the one-shot self-repair retry that begins at `while [ "$cli_retry" ...`

# 2b-win. Windows resolves a BARE command name from the spawning process's current
# directory before it looks at PATH. The bundled .mcp.json can express neither a
# per-platform nor an absolute command, so it spawns the bare `headroom` — which
# means an executable of that name sitting in the project you just opened would be
# spawned instead of the installed engine. Nothing in .mcp.json can prevent that;
# the doctor can at least see it and say so.
if is_windows; then
  hj_dir=${DOCTOR_PROJECT_DIR:-$PWD}
  hj_found=""
  # the spellings come from scripts/lib/engine-resolve.sh (PATHEXT order, .com
  # FIRST) so this list and session-probe.sh's cannot drift apart again
  for hj in $(headroom_name_variants); do
    [ -f "$hj_dir/$hj" ] || continue
    # .exe/.cmd/.bat are executable to Windows by extension; the extensionless
    # name only matters when Git Bash would run it
    case $hj in headroom) [ -x "$hj_dir/$hj" ] || continue ;; esac
    hj_found="$hj_dir/$hj"; break
  done
  if [ -n "$hj_found" ]; then
    say FAIL "an executable $hj_found sits in the project directory — on Windows a bare command name resolves from the project directory BEFORE PATH, so the bundled MCP would spawn that file instead of the installed headroom engine; remove or rename it"
  fi
fi

# --- 3. bin/hcat + a real smoke compression of a generated ~26 KB JSON
HCAT="$PLUGIN_ROOT/bin/hcat"
if [ ! -x "$HCAT" ]; then
  say FAIL "bin/hcat missing or not executable ($HCAT)"
elif [ -z "$PY" ] || [ -n "$boot_used" ]; then
  # engine absent at detection time — even if --fix just bootstrapped it, a
  # stubbed/new venv is smoke-tested on the next doctor run, not this one
  say skip "hcat smoke (engine missing — fix the engine, then re-run the doctor)"
else
  say ok "bin/hcat is executable"
  "$PY" -c '
import json, sys
rows = [{"id": i, "user": "user_%d" % (i % 50), "event": "click",
         "ts": 1700000000 + i, "ok": True} for i in range(250)]
open(sys.argv[1], "w").write(json.dumps(rows, indent=2))' "$TMPD/big.json" >/dev/null 2>&1
  if [ ! -s "$TMPD/big.json" ]; then
    say FAIL "hcat smoke: could not generate fixture JSON with $PY"
  else
    out=$(HCAT_PYTHON="$PY" HEADROOM_WORKSPACE_DIR="$TMPD/ws" bash "$HCAT" "$TMPD/big.json" 2>"$TMPD/hcat.err"); rc=$?
    raw=$(($(wc -c < "$TMPD/big.json")))
    got=$(printf '%s' "$out" | wc -c); got=$((got))
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "── hcat:" && [ "$got" -lt "$raw" ]; then
      say ok "hcat smoke: compressed a ${raw}-byte JSON to ${got} bytes"
    else
      say FAIL "hcat smoke: hcat exit $rc ($(head -1 "$TMPD/hcat.err" 2>/dev/null))"
    fi
  fi
fi

# --- 4. plugin-native hooks definition
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
PLUGNAT=0
if [ "$HAVE_JQ" -eq 0 ]; then
  say skip "hooks.json (needs jq)"
elif jq -e '.hooks.PreToolUse and .hooks.PostToolUse' "$HOOKS_JSON" >/dev/null 2>&1; then
  PLUGNAT=1
  say ok "hooks.json parses with PreToolUse + PostToolUse (plugin-native hooks)"
else
  say FAIL "hooks.json missing/invalid or lacks PreToolUse+PostToolUse ($HOOKS_JSON)"
fi

# --- 4b. bundled .mcp.json — shape only. Since v2.8 the server is spawned by its
# bare name (`headroom mcp serve`): MCP stdio commands run without a shell on
# every OS, and Windows cannot exec a .sh that way, so no launcher script may be
# referenced. Whether the bare name RESOLVES is check 2b's job (one report).
MCP_DEF="$PLUGIN_ROOT/.mcp.json"
if [ "$HAVE_JQ" -eq 0 ]; then
  say skip ".mcp.json (needs jq)"
elif ! jq -e '.mcpServers.headroom.command' "$MCP_DEF" >/dev/null 2>&1; then
  say FAIL ".mcp.json missing/invalid or lacks the headroom server ($MCP_DEF)"
else
  mcp_cmd=$(jq -r '.mcpServers.headroom.command' "$MCP_DEF")
  mcp_args=$(jq -r '.mcpServers.headroom.args // [] | join(" ")' "$MCP_DEF")
  if [ "$mcp_cmd" = "headroom" ] && [ "$mcp_args" = "mcp serve" ]; then
    say ok ".mcp.json spawns \`headroom mcp serve\` by name (needs headroom on PATH — see the CLI check)"
  else
    say FAIL ".mcp.json command is '$mcp_cmd $mcp_args' — v2.8 spawns the bare \`headroom\` name; this looks like a stale plugin copy: /plugin update headroom-usage-indicator@headroom-tools"
  fi
fi

# --- 4c. bundled model price table — the badge reads it so adding a model is a
# data edit, not a code change; --fix copies it beside the statusline copy
PRICES_DEF="$PLUGIN_ROOT/data/model-prices.json"
if [ "$HAVE_JQ" -eq 0 ]; then
  say skip "model-prices.json (needs jq)"
elif jq -e '(.prices | type) == "array" and (.prices | length) > 0' "$PRICES_DEF" >/dev/null 2>&1; then
  say ok "model-prices.json parses ($(jq -r '.prices | length' "$PRICES_DEF") model prices)"
else
  say FAIL "model-prices.json missing or invalid ($PRICES_DEF)"
fi

# --- 5–8. settings.json + ~/.claude legacy state (need jq)
LEGACY_JQ='[.hooks // {} | to_entries[] | .value[]?.hooks[]?
      | select((.command // "") | test("dangi-hook\\.sh|hcat-gate\\.sh"))
      | select((.command // "") | contains("CLAUDE_PLUGIN_ROOT") | not)] | length'
# the one strip program every legacy-hook fix uses (settings.json,
# settings.local.json, project-level settings) — one definition, no drift
LEGACY_STRIP_JQ='.hooks |= (with_entries(.value |= (map(.hooks |= map(select(
        (((.command // "") | test("dangi-hook\\.sh|hcat-gate\\.sh"))
         and ((.command // "") | contains("CLAUDE_PLUGIN_ROOT") | not)) | not)))
      | map(select((.hooks | length) > 0))))
      | with_entries(select((.value | length) > 0)))
      | if .hooks == {} then del(.hooks) else . end'
if [ "$HAVE_JQ" -eq 0 ]; then
  say skip "legacy hooks / statusLine / stale copies (need jq)"
else
  # 5. settings.json must be a single valid JSON document before anything may
  # read or edit it — jq errors otherwise collapse into false "ok" results,
  # and a rewrite of a multi-document file stays unparseable
  SETTINGS_OK=1
  if [ -f "$SETTINGS" ]; then
    ndocs=$(jq -n '[inputs] | length' "$SETTINGS" 2>/dev/null) || ndocs=bad
    if [ "$ndocs" = "1" ]; then
      say ok "settings.json parses as a single JSON document"
    else
      SETTINGS_OK=0
      say FAIL "settings.json is not a single valid JSON document ($SETTINGS) — repair it by hand; all settings-editing fixes are disabled"
    fi
  fi

  # 6. legacy dual-registration: pre-plugin hook entries in settings.json that
  # now double-fire alongside the plugin-native hooks. settings.local.json in
  # the same directory is scanned too — its hooks fire just the same.
  legacy=0
  if [ "$SETTINGS_OK" -eq 0 ]; then
    legacy=1   # unparseable: scan inconclusive, keep the stale-copy gate shut
    say skip "legacy hooks (settings.json unparseable — repair it first)"
  else
    if [ -f "$SETTINGS" ]; then
      legacy=$(jq "$LEGACY_JQ" "$SETTINGS" 2>/dev/null || echo 0)
    fi
    if [ "$legacy" -eq 0 ]; then
      say ok "no legacy hook registrations in settings.json"
    elif [ "$FIX" -eq 1 ]; then
      if ! backup_settings; then
        say FAIL "could not back up settings.json before rewriting it — refusing to overwrite without one"
      elif jq "$LEGACY_STRIP_JQ" \
          "$SETTINGS" > "$TMPD/settings.new" && cat "$TMPD/settings.new" > "$SETTINGS"; then
        say fixed "removed $legacy legacy hook entries from settings.json (backup: settings.json.bak.*)"
        legacy=0
      else
        say FAIL "could not rewrite settings.json to drop the legacy hook entries"
      fi
    else
      say fixable "legacy hooks in settings.json ($legacy entries double-firing with the plugin-native hooks)"
    fi
  fi
  LOCAL_SETTINGS=$(dirname "$SETTINGS")/settings.local.json
  legacy_local=0
  if [ -f "$LOCAL_SETTINGS" ]; then
    legacy_local=$(jq "$LEGACY_JQ" "$LOCAL_SETTINGS" 2>/dev/null) || legacy_local=""
    case $legacy_local in
      ''|*[!0-9]*) legacy_local=-1 ;;   # unparseable → scan inconclusive
    esac
    if [ "$legacy_local" -gt 0 ] && [ "$FIX" -eq 1 ]; then
      if ! cp "$LOCAL_SETTINGS" "$LOCAL_SETTINGS.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null; then
        say FAIL "could not back up settings.local.json before rewriting it — refusing to overwrite without one"
      elif jq "$LEGACY_STRIP_JQ" "$LOCAL_SETTINGS" > "$TMPD/settings.local.new" \
         && cat "$TMPD/settings.local.new" > "$LOCAL_SETTINGS"; then
        say fixed "removed $legacy_local legacy hook entries from settings.local.json (backup: settings.local.json.bak.*)"
        legacy_local=0
      else
        say FAIL "could not rewrite settings.local.json to drop the legacy hook entries"
      fi
    elif [ "$legacy_local" -gt 0 ]; then
      say fixable "legacy hooks in settings.local.json ($legacy_local entries double-firing with the plugin-native hooks)"
    elif [ "$legacy_local" -lt 0 ]; then
      say FAIL "settings.local.json did not parse ($LOCAL_SETTINGS) — legacy-hook scan inconclusive"
    fi
  fi

  # 6b. project-level settings in the CURRENT directory: the same legacy-hook
  # scan + fix, for the project the doctor is being run from. Other projects'
  # .claude dirs are out of reach — the stale-copy note below says so.
  PROJ_DIR=${DOCTOR_PROJECT_DIR:-$PWD}
  proj_legacy=0
  for pj in "$PROJ_DIR/.claude/settings.json" "$PROJ_DIR/.claude/settings.local.json"; do
    [ -f "$pj" ] || continue
    [ "$pj" -ef "$SETTINGS" ] && continue          # already scanned above
    [ "$pj" -ef "$LOCAL_SETTINGS" ] && continue
    pl=$(jq "$LEGACY_JQ" "$pj" 2>/dev/null) || pl=""
    case $pl in
      ''|*[!0-9]*)
        proj_legacy=1
        say FAIL "project settings did not parse ($pj) — legacy-hook scan inconclusive"
        continue ;;
    esac
    if [ "$pl" -eq 0 ]; then
      say ok "no legacy hook registrations in $pj"
    elif [ "$FIX" -eq 1 ]; then
      if ! cp "$pj" "$pj.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null; then
        proj_legacy=1
        say FAIL "could not back up $pj before rewriting it — refusing to overwrite without one"
      elif jq "$LEGACY_STRIP_JQ" "$pj" > "$TMPD/proj.new" && cat "$TMPD/proj.new" > "$pj"; then
        say fixed "removed $pl legacy hook entries from $pj (backup: $pj.bak.*)"
      else
        proj_legacy=1
        say FAIL "could not rewrite $pj to drop the legacy hook entries"
      fi
    else
      proj_legacy=1
      say fixable "legacy hooks in project settings ($pj: $pl entries double-firing with the plugin-native hooks)"
    fi
  done

  # 7. statusLine wiring — merge-aware, mirroring the SKILL installer: an
  # existing non-headroom command is preserved under _headroomStatusLineBackup
  # and chained ahead of the badge
  sl=""
  [ "$SETTINGS_OK" -eq 1 ] && [ -f "$SETTINGS" ] && sl=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)
  if [ "$SETTINGS_OK" -eq 0 ]; then
    say skip "statusLine (settings.json unparseable — repair it first)"
  elif printf '%s' "$sl" | grep -q "headroom-statusline"; then
    # A bare string match is not proof the script is on disk. Extract every path
    # token that names the statusline script — absolute, quoted-tilde, or a
    # foreign home synced from dotfiles — expand a leading ~, and require at
    # least one to exist; otherwise the badge renders nothing while 7b/7c only
    # `skip` (guarded on the same absent file) and block 9 clears any recorded
    # failure — a silent pass for every respelling of the canonical path. Only
    # the canonical $CLAUDE_DIR copy is ours to re-copy under --fix; a script
    # missing at a hand-edited custom path is a FAIL, not a fixable — the
    # doctor won't guess where to place a copy (no-orphan policy), and a
    # fixable that --fix cannot repair would break the fixable contract. A
    # command with no extractable path token is trusted as wired.
    # Candidate tokens are whole quote/space-delimited words, not a substring
    # regex match: a substring match has no token boundary, so it silently
    # truncates a suffixed filename (headroom-statusline.sh.bak -> verifies
    # the wrong, unsuffixed file) and can start mid-token on a false match
    # (matching the '/' inside "$HOME/..." instead of the token's real start).
    # Each token is then structurally validated (starts with ~/ or /, ends
    # exactly at "headroom-statusline.sh") before being trusted as a real
    # candidate; anything else falls through to the no-extractable-token
    # trust rule below, same as before.
    sl_present=0; sl_seen=0; sl_canonical_missing=0; sl_respelled_raw=""
    sl_respelled_delim=""; sl_custom_missing=""; sl_wired_path=""
    sl_interp_missing=""
    while IFS= read -r sl_tok; do
      [ -n "$sl_tok" ] || continue
      # The INTERPRETER half of a Windows wiring ("<bash.exe>" "<script>") was
      # never validated — only the script token was — so a stale or simply
      # wrong bash path read as `ok - statusLine wired` over a command that
      # cannot execute, and --fix would not repair it. Combined with a bash
      # that lacks coreutils that is exactly how a silently dead badge gets a
      # clean bill of health. Match ONLY an absolute bash: every other token
      # keeps falling through untouched, so a foreign chained script (which
      # may legitimately live anywhere, or nowhere we can stat) never starts
      # failing this check.
      case $sl_tok in
        /*bash | /*bash.exe | [A-Za-z]:[\\/]*bash | [A-Za-z]:[\\/]*bash.exe)
          # stat it the way THIS shell can: inside Git Bash the native
          # spelling needs translating, and unix_path no-ops on a POSIX one.
          [ -f "$sl_tok" ] || [ -f "$(unix_path "$sl_tok")" ] || sl_interp_missing=$sl_tok
          continue ;;
      esac
      # shellcheck disable=SC2088 # matching a LITERAL ~ the shell never expanded — this just structurally validates the token shape
      case $sl_tok in
        "~/"*headroom-statusline.sh | /*headroom-statusline.sh) ;;
        [A-Za-z]:[\\/]*headroom-statusline.sh) sl_tok=$(unix_path "$sl_tok") ;;
        *) continue ;;
      esac
      sl_cand=$sl_tok
      sl_seen=1
      sl_raw=$sl_cand
      # shellcheck disable=SC2088 # matching a LITERAL ~ the shell never expanded — we expand it here
      case $sl_cand in "~/"*) sl_cand="$HOME/${sl_cand#"~/"}" ;; esac
      if [ "$sl_cand" = "$CLAUDE_DIR/headroom-statusline.sh" ] && [ "$sl_raw" != "$CLAUDE_DIR/headroom-statusline.sh" ]; then
        # names the canonical file only via a ~ respelling. Whether that
        # actually resolves at spawn time depends on how the shell sees it:
        # bash expands an UNQUOTED ~, but never one inside single OR double
        # quotes. The [^"' ]+ extraction above already treats both quote
        # characters as equally valid delimiters, so detection must too —
        # check which one (if either) actually wraps this exact token in the
        # raw command, and remember it so the eventual rewrite anchors on the
        # SAME delimiter it detected, not an assumed one.
        sl_sq="'"
        # shellcheck disable=SC2027 # $sl_raw is deliberately unquoted here -- it's a case-pattern glob segment, not a quoting typo
        case $sl in
          *\"$sl_raw\"*) sl_respelled_raw=$sl_raw; sl_respelled_delim='"' ;;
          *"$sl_sq"$sl_raw"$sl_sq"*) sl_respelled_raw=$sl_raw; sl_respelled_delim=$sl_sq ;;
          *) : ;;  # unquoted -- bash expands this fine at spawn time, nothing to rewrite
        esac
      fi
      if [ -f "$sl_cand" ]; then sl_present=1; sl_wired_path=$sl_cand
      elif [ "$sl_cand" = "$CLAUDE_DIR/headroom-statusline.sh" ]; then sl_canonical_missing=1
      else sl_custom_missing=$sl_cand
      fi
    done < <(printf '%s\n' "$sl" | grep -oE "\"[^\"]*\"|'[^']*'|[^\"' ]+" | sed -e "s/^[\"']//" -e "s/[\"']\$//")
    # A present token from one candidate must not mask a co-occurring missing
    # signal from a DIFFERENT candidate token in the same command -- require
    # no missing signal was raised by ANY token, not just that ONE resolved.
    if [ -n "$sl_interp_missing" ]; then
      # repair the interpreter IN PLACE rather than re-running the whole merge:
      # it swaps the one dead token for the bash this platform resolves now and
      # leaves everything else (a chained foreign command included) untouched.
      sl_good_bash=$(sl_bash_path)
      if [ "$FIX" -ne 1 ]; then
        say fixable "statusLine runs through $sl_interp_missing but no such interpreter exists — the badge cannot render; --fix repoints it at $sl_good_bash"
      elif [ ! -f "$sl_good_bash" ] && [ ! -f "$(unix_path "$sl_good_bash")" ]; then
        say FAIL "statusLine runs through $sl_interp_missing but no such interpreter exists, and no working bash was found to replace it with — install Git for Windows, or fix statusLine.command in settings.json by hand"
      elif ! backup_settings; then
        say FAIL "could not back up settings.json before repointing the dead '$sl_interp_missing' interpreter — refusing to overwrite without one"
      else
        # QUOTE the pattern. Unquoted, it is a GLOB: a native
        # C:\Program Files\Git\usr\bin\bash.exe has its backslashes eaten as
        # pattern escapes and can never match the literal path in $sl, so on the
        # only platform this repair exists for --fix always fell through to
        # "could not locate ... fix it by hand" and kept exiting 1 every run.
        # (A token containing * would over-match and persist a mangled command.)
        # With it quoted, the `= "$sl"` guard below is a real no-match check.
        sl_new_cmd=${sl//"$sl_interp_missing"/$sl_good_bash}
        if [ "$sl_new_cmd" = "$sl" ]; then
          say FAIL "could not locate '$sl_interp_missing' in the statusLine command to repoint it — fix statusLine.command in settings.json by hand"
        elif jq --arg c "$sl_new_cmd" '.statusLine.command = $c' \
            "$SETTINGS" > "$TMPD/settings.sl3" && cat "$TMPD/settings.sl3" > "$SETTINGS"; then
          say fixed "repointed the statusLine interpreter from the missing $sl_interp_missing to $sl_good_bash (settings.json backup: .bak.*)"
        else
          say FAIL "could not repoint the dead '$sl_interp_missing' statusLine interpreter in settings.json"
        fi
      fi
    elif [ "$sl_present" -eq 1 ] && [ -z "$sl_respelled_raw" ] \
       && [ "$sl_canonical_missing" -eq 0 ] && [ -z "$sl_custom_missing" ]; then
      say ok "statusLine wired ($sl)"
    elif [ "$sl_seen" -eq 0 ]; then
      say ok "statusLine wired ($sl)"
    elif [ -n "$sl_respelled_raw" ] || [ "$sl_canonical_missing" -eq 1 ]; then
      # the canonical file's identity was only proven via doctor's OWN tilde
      # expansion above; the wired command itself never expands it (bash
      # never expands a ~ inside double quotes), so this is broken even when
      # the script already exists on disk — must not report ok either way
      if [ "$FIX" -eq 1 ]; then
        sl_copy_ok=1
        if [ "$sl_canonical_missing" -eq 1 ]; then
          mkdir -p "$CLAUDE_DIR/lib"
          # model-prices.json degrades gracefully when absent (statusline.sh
          # falls back to a built-in table), so it stays best-effort; the two
          # deps below are load-bearing for a working badge and must gate
          # sl_copy_ok, same as the sibling fix in 7c just below
          [ -f "$PLUGIN_ROOT/data/model-prices.json" ] \
            && cp "$PLUGIN_ROOT/data/model-prices.json" "$CLAUDE_DIR/headroom-model-prices.json" 2>/dev/null || true
          cp "$PLUGIN_ROOT/scripts/lib/attribution.jq"    "$CLAUDE_DIR/lib/" \
            && cp "$PLUGIN_ROOT/scripts/lib/headroom-state.sh" "$CLAUDE_DIR/lib/" \
            && cp "$PLUGIN_ROOT/scripts/lib/engine-resolve.sh" "$CLAUDE_DIR/lib/" \
            && cp "$PLUGIN_ROOT/scripts/statusline.sh" "$CLAUDE_DIR/headroom-statusline.sh" \
            && chmod +x "$CLAUDE_DIR/headroom-statusline.sh" || sl_copy_ok=0
        fi
        if [ "$sl_copy_ok" -eq 0 ]; then
          say FAIL "could not re-copy statusline.sh and its lib deps to $CLAUDE_DIR"
        elif [ -z "$sl_respelled_raw" ]; then
          # literal canonical wiring, file was just missing -- the re-copy
          # above already fixes it; no settings.json mutation needed
          say fixed "re-copied the missing statusline script to $CLAUDE_DIR/headroom-statusline.sh (settings already pointed at it)"
        elif ! backup_settings; then
          say FAIL "could not back up settings.json before rewriting the '$sl_respelled_raw' wiring — refusing to overwrite without one"
        else
          # Anchor the replace on the SAME closing quote character detection
          # found wrapping this token (' or ") -- a global substring replace
          # with the wrong (or no) anchor can't also mangle an unrelated
          # sibling token that merely shares this one's prefix (e.g. a
          # coexisting ...headroom-statusline.sh.bak).
          sl_new_cmd=${sl//"$sl_respelled_raw$sl_respelled_delim"/$CLAUDE_DIR/headroom-statusline.sh$sl_respelled_delim}
          if [ "$sl_new_cmd" = "$sl" ]; then
            # the replace found nothing to change -- never claim "fixed" for a
            # rewrite that silently did nothing, which would violate the
            # idempotent contract and mask the wiring staying broken
            say FAIL "could not identify how '$sl_respelled_raw' is quoted in the statusLine command — refusing to rewrite it blindly"
          elif jq --arg c "$sl_new_cmd" '.statusLine.command = $c' \
              "$SETTINGS" > "$TMPD/settings.sl2" && cat "$TMPD/settings.sl2" > "$SETTINGS"; then
            if [ "$sl_canonical_missing" -eq 1 ]; then
              say fixed "re-copied the missing statusline script to $CLAUDE_DIR/headroom-statusline.sh and rewrote the unexpandable '$sl_respelled_raw' wiring to an absolute path (settings.json backup: .bak.*)"
            else
              say fixed "rewrote the unexpandable '$sl_respelled_raw' statusLine wiring to an absolute path — the script was already present at $CLAUDE_DIR/headroom-statusline.sh (settings.json backup: .bak.*)"
            fi
          else
            say FAIL "could not rewrite the '$sl_respelled_raw' wiring in settings.json"
          fi
        fi
      elif [ "$sl_canonical_missing" -eq 1 ]; then
        say fixable "statusLine points at $CLAUDE_DIR/headroom-statusline.sh but the script is missing — --fix re-copies it"
      else
        say fixable "statusLine wiring '$sl_respelled_raw' can never resolve (bash never expands a ~ inside quotes) even though $CLAUDE_DIR/headroom-statusline.sh already exists — --fix rewrites it to an absolute path"
      fi
    else
      say FAIL "statusLine points at $sl_custom_missing but no such file exists — restore it or re-wire settings.json (--fix will not guess a custom location)"
    fi
  elif [ "$FIX" -eq 1 ]; then
    mkdir -p "$CLAUDE_DIR"
    [ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
    sl_bak_ok=1; backup_settings || sl_bak_ok=0
    sl_path="$CLAUDE_DIR/headroom-statusline.sh"
    case $sl_path in
      "$HOME"/*) sl_disp="~${sl_path#"$HOME"}" ;;
      *)         sl_disp=$sl_path ;;
    esac
    # same merge DECISION as the SKILL.md installer python (keep an existing
    # non-headroom command under _headroomStatusLineBackup, chain it ahead of
    # the badge) -- but the badge command itself comes from sl_hr_cmd, not a
    # hardcoded `bash "<path>"`: POSIX gets `bash "<path>"`, Windows gets
    # `"<bash.exe>" "<C:\...>"`. The SKILL.md installer stays POSIX-only.
    # the ONE definition of "which command is chained ahead of the badge" (an
    # existing _headroomStatusLineBackup wins, else a non-headroom statusLine).
    # Shared by the base EXTRACTION below (which the Windows chain script needs)
    # and by the merge program, so the two can never disagree about the base.
    sl_base_sel=$(cat <<'JQEOF'
(._headroomStatusLineBackup // null) as $bak
| (.statusLine // null) as $ex
| (if ($bak | type) == "object" and $bak.type == "command" and (($bak.command // "") != "") then $bak
   elif ($ex | type) == "object" and $ex.type == "command" and (($ex.command // "") != "")
        and (($ex.command | contains("headroom-statusline.sh")) | not)
        and (($ex.command | contains("mcp__headroom__headroom_compress")) | not)
   then $ex else null end) as $base
JQEOF
)
    # $chain (empty on POSIX) is the pre-built command for a chain SCRIPT; when
    # it is set the inline POSIX chain is not written at all — see below.
    sl_merge_tail=$(cat <<'JQEOF'
| if $base != null then
    ._headroomStatusLineBackup = $base
    | .statusLine = {type: "command",
        command: (if $chain != "" then $chain else
                    ("in=$(cat); left=$(printf '%s' \"$in\" | { " + $base.command
                     + "; }); hr=$(printf '%s' \"$in\" | " + $hr
                     + "); printf '%s  %s' \"$left\" \"$hr\"") end),
        refreshInterval: 1}
  else
    .statusLine = {type: "command", command: $hr, refreshInterval: 1}
  end
JQEOF
)
    sl_merge_jq="$sl_base_sel
$sl_merge_tail"
    if [ "$sl_bak_ok" -eq 0 ]; then
      say FAIL "could not back up settings.json before wiring the statusLine — refusing to overwrite without one"
    else
      # a failed backup must refuse every disk write this fix makes, not just
      # the final script copy and settings rewrite -- so these stay gated
      # behind the check above rather than running unconditionally first
      [ -f "$PLUGIN_ROOT/data/model-prices.json" ] \
        && cp "$PLUGIN_ROOT/data/model-prices.json" "$CLAUDE_DIR/headroom-model-prices.json" 2>/dev/null || true
      # statusline.sh resolves attribution.jq + headroom-state.sh from a lib/ dir
      # next to itself; without them compute() degrades to a permanent idle badge
      # showing zero savings (issue #2). engine-resolve.sh rides along because a
      # legacy FLAT install's hcat/hcat-gate.sh/session-probe.sh source
      # "$here/lib/engine-resolve.sh" first and otherwise run forever on their
      # minimal inline fallback (spec §1, v2.8). Provision them alongside the
      # copy, and gate the "fixed" claim on them actually landing -- a
      # silently-failed lib-dep copy must not be reported as a successful wire.
      # WINDOWS MERGE. statusLine.command is executed by Claude Code OUTSIDE Git
      # Bash, which is why sl_hr_cmd writes it as a `"<bash.exe>" "<C:\...>"`
      # pair. A merge used to wrap that pair in a raw POSIX chain
      # (`in=$(cat); left=$(...); hr=$(...); printf ...`) and persist the whole
      # string — not a runnable command there, so the user lost BOTH their own
      # status line and the badge. Put the same chain body in a script file next
      # to the statusline copy and point the command at THAT file instead, so
      # the persisted command keeps its two-token shape. The POSIX branch is
      # untouched: it still gets the inline chain, exactly as before.
      # $chain is "" on POSIX (and when there is nothing to chain), and the jq
      # program falls back to the inline chain whenever it is empty.
      sl_chain=""; sl_chain_ok=1
      sl_base_cmd=$(jq -r "$sl_base_sel
| (\$base.command // \"\")" "$SETTINGS" 2>/dev/null) || sl_base_cmd=""
      if is_windows && [ -n "$sl_base_cmd" ]; then
        sl_chain_path="$CLAUDE_DIR/headroom-statusline-chain.sh"
        {
          cat <<'CHEOF'
#!/usr/bin/env bash
# headroom-statusline-chain.sh — written by `/doctor --fix` on Windows.
# Claude Code executes statusLine.command without a POSIX shell, so the command
# it stores must stay a `"<bash.exe>" "<C:\path>"` pair; the shell chain that
# renders your own status line first and the headroom badge after it lives here.
# Regenerated (identically) by every --fix. Your original command is also kept
# verbatim under _headroomStatusLineBackup in settings.json.
in=$(cat)
CHEOF
          printf 'left=$(printf %s "$in" | { %s; })\n' "'%s'" "$sl_base_cmd"
          printf 'hr=$(printf %s "$in" | bash "%s")\n'  "'%s'" "$sl_path"
          printf '%s\n' "printf '%s  %s' \"\$left\" \"\$hr\""
        } > "$sl_chain_path" && chmod +x "$sl_chain_path" || sl_chain_ok=0
        [ "$sl_chain_ok" -eq 1 ] && sl_chain=$(sl_hr_cmd "$sl_chain_path")
      fi
      mkdir -p "$CLAUDE_DIR/lib"
      if [ "$sl_chain_ok" -eq 1 ] \
         && cp "$PLUGIN_ROOT/scripts/lib/attribution.jq"    "$CLAUDE_DIR/lib/" \
         && cp "$PLUGIN_ROOT/scripts/lib/headroom-state.sh" "$CLAUDE_DIR/lib/" \
         && cp "$PLUGIN_ROOT/scripts/lib/engine-resolve.sh" "$CLAUDE_DIR/lib/" \
         && cp "$PLUGIN_ROOT/scripts/statusline.sh" "$sl_path" && chmod +x "$sl_path" \
         && jq --arg hr "$(sl_hr_cmd "$sl_path")" --arg chain "$sl_chain" "$sl_merge_jq" \
            "$SETTINGS" > "$TMPD/settings.sl" && cat "$TMPD/settings.sl" > "$SETTINGS"; then
        if [ -n "$sl" ] && ! printf '%s' "$sl" | grep -q "mcp__headroom__headroom_compress"; then
          say fixed "statusLine merged — your command kept and backed up under _headroomStatusLineBackup, badge appended ($sl_disp)"
        else
          say fixed "statusLine wired to $sl_disp (script copied, backup: settings.json.bak.*)"
        fi
      elif [ "$sl_chain_ok" -eq 0 ]; then
        say FAIL "could not write the status-line chain script to $CLAUDE_DIR/headroom-statusline-chain.sh — settings.json left untouched"
      else
        say FAIL "could not copy statusline.sh (+ lib deps) to $sl_path and wire settings.json"
      fi
    fi
  elif [ -n "$sl" ]; then
    say fixable "statusLine present without the headroom badge — --fix appends it, preserving your command under _headroomStatusLineBackup"
  else
    say fixable "statusLine not wired — --fix copies the script to $CLAUDE_DIR and points settings.json at it"
  fi

  # 7b. the wired copy must match the plugin's statusline.sh (upgrade path).
  # sl_copy follows whatever check 7 actually validated as wired — including
  # a doctor-blessed custom path — instead of always assuming the canonical
  # location. Previously 7b/7c only ever looked at $CLAUDE_DIR, so a custom
  # install's stale/missing script or deps went undetected forever (`skip`,
  # not FAILED/FIXABLE) and block 9's all-clear cleared any recorded failure
  # regardless — issue #2's original symptom, for the custom-path population.
  sl_copy=${sl_wired_path:-"$CLAUDE_DIR/headroom-statusline.sh"}
  sl_custom_copy=0
  [ "$sl_copy" != "$CLAUDE_DIR/headroom-statusline.sh" ] && sl_custom_copy=1
  if [ ! -f "$sl_copy" ]; then
    say skip "statusline copy refresh (no $sl_copy yet)"
  elif cmp -s "$PLUGIN_ROOT/scripts/statusline.sh" "$sl_copy"; then
    say ok "statusline copy is current ($sl_copy)"
  elif [ "$sl_custom_copy" -eq 1 ]; then
    # no-orphan policy (matches check 7): a custom path is the user's own to
    # own, so doctor detects but never overwrites it
    say FAIL "statusline copy at $sl_copy is stale — a custom-path install is yours to update (doctor will not overwrite it)"
  elif [ "$FIX" -eq 1 ]; then
    [ -f "$PLUGIN_ROOT/data/model-prices.json" ] \
      && cp "$PLUGIN_ROOT/data/model-prices.json" "$CLAUDE_DIR/headroom-model-prices.json" 2>/dev/null || true
    mkdir -p "$CLAUDE_DIR/lib"
    if cp "$PLUGIN_ROOT/scripts/lib/attribution.jq"    "$CLAUDE_DIR/lib/" \
       && cp "$PLUGIN_ROOT/scripts/lib/headroom-state.sh" "$CLAUDE_DIR/lib/" \
       && cp "$PLUGIN_ROOT/scripts/lib/engine-resolve.sh" "$CLAUDE_DIR/lib/" \
       && cp "$PLUGIN_ROOT/scripts/statusline.sh" "$sl_copy" && chmod +x "$sl_copy"; then
      say fixed "statusline copy refreshed from the plugin ($sl_copy)"
    else
      say FAIL "could not refresh $sl_copy (+ lib deps) from the plugin"
    fi
  else
    say fixable "statusline copy differs from the plugin's scripts/statusline.sh — --fix refreshes it"
  fi

  # 7c. the installed BADGE deps. statusline.sh's runtime deps (attribution.jq +
  # headroom-state.sh) must sit next to the installed copy, or compute() silently
  # degrades to a permanent idle badge showing zero savings (issue #2). The plain
  # cmp in 7b only covers the script itself — these are separate files and were
  # never provisioned. engine-resolve.sh is NOT one of these: it is not loaded by
  # statusline.sh at all, it has no business being demanded next to a custom-path
  # copy the doctor refuses to write to (that combination FAILs forever, since
  # --fix can never clear it), and it gets its own check just below.
  # statusline.sh resolves each dep from EITHER a lib/ subdir OR a flat sibling
  # (the legacy full-manual install layout), preferring lib/. Mirror that here so
  # a healthy flat install is not falsely flagged (which would also block block 9's
  # ambient-health all-clear via a spurious FIXABLE).
  if [ ! -f "$sl_copy" ]; then
    say skip "statusline lib deps (no $sl_copy yet)"
  else
    sl_dep_dir=$(dirname "$sl_copy")
    lib_stale=""
    for f in attribution.jq headroom-state.sh; do
      # Resolve each dep exactly as statusline.sh does — by EXISTENCE, lib/ first,
      # else the flat sibling next to the copy actually wired (canonical or
      # custom-path), then currency-check only the file it would load.
      # A plain "lib matches OR flat matches" would green a stale lib/ copy that
      # shadows a current flat sibling: statusline.sh sources the stale lib/ one
      # (it takes lib/ the moment the file exists, content-blind) and never falls
      # through, so the badge would silently run on the stale dep.
      if   [ -f "$sl_dep_dir/lib/$f" ]; then dep="$sl_dep_dir/lib/$f"
      elif [ -f "$sl_dep_dir/$f" ];     then dep="$sl_dep_dir/$f"
      else dep=""; fi
      if [ -n "$dep" ] && cmp -s "$PLUGIN_ROOT/scripts/lib/$f" "$dep"; then
        :   # the exact file statusline.sh loads is present and current
      else
        lib_stale="$lib_stale $f"
      fi
    done
    if [ -z "$lib_stale" ]; then
      say ok "statusline lib deps current (attribution.jq, headroom-state.sh)"
    elif [ "$sl_custom_copy" -eq 1 ]; then
      say FAIL "statusline lib deps at $sl_dep_dir missing/stale —$lib_stale (custom-path install is yours to update; doctor will not write there)"
    elif [ "$FIX" -eq 1 ]; then
      mkdir -p "$CLAUDE_DIR/lib"
      if cp "$PLUGIN_ROOT/scripts/lib/attribution.jq"    "$CLAUDE_DIR/lib/" \
         && cp "$PLUGIN_ROOT/scripts/lib/headroom-state.sh" "$CLAUDE_DIR/lib/"; then
        say fixed "installed statusline lib deps to $CLAUDE_DIR/lib —$lib_stale"
      else
        say FAIL "could not copy statusline lib deps to $CLAUDE_DIR/lib"
      fi
    else
      say fixable "statusline lib deps missing/stale —$lib_stale (badge shows zero savings without them; --fix installs attribution.jq + headroom-state.sh)"
    fi

    # 7c-2. the shared engine resolver. engine-resolve.sh is not a badge dep —
    # statusline.sh never loads it — but a legacy FLAT install's hcat /
    # hcat-gate.sh / session-probe.sh source it ahead of their (narrower) inline
    # fallback, so /doctor --fix is the one place that population gets it
    # (spec §1, v2.8). It is resolved and repaired against $CLAUDE_DIR ONLY,
    # never next to a custom-path statusline copy: the doctor refuses to write
    # into a custom path, so demanding the file there produced a FAIL that --fix
    # could never clear and the doctor could never exit 0 from. It rides in this
    # branch (rather than standing alone) so it keeps the same "there is an
    # installed statusline copy to look after" scope the deps above have had.
    er_dep=""
    if   [ -f "$CLAUDE_DIR/lib/engine-resolve.sh" ]; then er_dep="$CLAUDE_DIR/lib/engine-resolve.sh"
    elif [ -f "$CLAUDE_DIR/engine-resolve.sh" ];     then er_dep="$CLAUDE_DIR/engine-resolve.sh"
    fi
    if [ -n "$er_dep" ] && cmp -s "$PLUGIN_ROOT/scripts/lib/engine-resolve.sh" "$er_dep"; then
      say ok "shared engine resolver current ($er_dep)"
    elif [ "$FIX" -eq 1 ]; then
      mkdir -p "$CLAUDE_DIR/lib"
      if cp "$PLUGIN_ROOT/scripts/lib/engine-resolve.sh" "$CLAUDE_DIR/lib/"; then
        say fixed "installed the shared engine resolver to $CLAUDE_DIR/lib/engine-resolve.sh"
      else
        say FAIL "could not copy engine-resolve.sh to $CLAUDE_DIR/lib"
      fi
    else
      say fixable "shared engine resolver missing/stale (engine-resolve.sh) — a legacy flat install's hcat and hooks fall back to a narrower engine lookup without it; --fix installs it to $CLAUDE_DIR/lib"
    fi
  fi

  # 8. stale pre-plugin copies in ~/.claude (headroom-statusline.sh stays: the
  # statusLine points at it by design)
  stale=""
  for f in dangi-hook.sh hcat-gate.sh hcat; do
    [ -e "$CLAUDE_DIR/$f" ] && stale="$stale $f"
  done
  if [ -z "$stale" ]; then
    say ok "no stale pre-plugin copies in $CLAUDE_DIR"
  elif [ "$FIX" -eq 1 ]; then
    if [ "$PLUGNAT" -eq 1 ] && [ "$legacy" -eq 0 ] && [ "$legacy_local" -eq 0 ] && [ "$proj_legacy" -eq 0 ]; then
      for f in $stale; do rm -f "$CLAUDE_DIR/$f"; done
      say fixed "removed stale copies from $CLAUDE_DIR:$stale"
      printf '%-7s - %s\n' note "project-level .claude settings in OTHER directories are not scanned (this one was) — if another project still registers the deleted paths, remove those entries by hand"
    else
      say skip "stale copies kept:$stale (plugin-native hooks unconfirmed, or legacy hooks still registered in settings.json / settings.local.json / project settings)"
    fi
  else
    say fixable "stale copies in $CLAUDE_DIR:$stale"
  fi
fi

# --- 9. ambient-health state: hooks/hcat record failures in a last-error file
# that flips the badge to "broken". A fully-clean doctor run (nothing failed,
# nothing fixable) is the all-clear that restores the badge; the hcat smoke
# test may already have cleared an engine error mid-run — report that too.
if [ "$HEALTH_HAD_ERROR" -eq 1 ]; then
  if [ ! -f "$HEALTH_STATE_DIR/last-error" ]; then
    say ok "cleared recorded failure state — badge restored"
  elif [ "$FAILED" -eq 0 ] && [ "$FIXABLE" -eq 0 ]; then
    if [ "$(cat "$HEALTH_STATE_DIR/last-error" 2>/dev/null)" = "$HEALTH_ERR_SNAP" ]; then
      rm -f "$HEALTH_STATE_DIR/last-error" 2>/dev/null || true
      say ok "cleared recorded failure state — badge restored"
    else
      say skip "a NEW failure was recorded while this run was in progress — badge kept broken; run /doctor again"
    fi
  else
    say skip "recorded failure state kept (badge shows broken until a clean doctor run)"
  fi
fi

# --- summary
echo
summary="$OK ok"
[ "$FIXABLE" -gt 0 ] && summary="$summary · $FIXABLE fixable"
[ "$FAILED"  -gt 0 ] && summary="$summary · $FAILED failed"
[ "$SKIPPED" -gt 0 ] && summary="$summary · $SKIPPED skipped"
echo "$summary"
if [ "$FIXABLE" -gt 0 ] && [ "$FIX" -eq 0 ]; then
  echo "→ re-run with --fix to repair."
fi
[ "$FAILED" -eq 0 ]
