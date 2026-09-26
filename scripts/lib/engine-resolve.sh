#!/usr/bin/env bash
# engine-resolve.sh — ONE definition of "where is the headroom engine" for the
# plugin's entry points (bin/hcat, hcat-gate.sh, session-probe.sh, doctor.sh).
# Sourced, never executed; must not print (except the documented results) or
# exit. Replaces five hand-rolled copies that had drifted (issue #9).
#
# Layouts covered: POSIX venv (bin/python), Windows venv (Scripts\python.exe),
# pip --user / pipx console scripts (shebang interpreter, no sibling python),
# uv `tool install` (trampoline .exe under `uv tool dir`), and Windows PE
# launchers (start with "MZ": no shebang to parse).
#
# Test overrides: DOCTOR_OS=windows|unix, DOCTOR_VENV_DIR, DOCTOR_CYGPATH.

is_windows() {  # exit 0 on Git Bash / MSYS / Cygwin
  case "${DOCTOR_OS:-}" in windows) return 0 ;; unix) return 1 ;; esac
  case "${OSTYPE:-}" in msys*|cygwin*) return 0 ;; esac
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
  return 1
}

_er_venv() { printf '%s' "${DOCTOR_VENV_DIR:-${HOME:-}/.headroom-venv}"; }

headroom_name_variants() {  # every spelling Windows resolves for a bare `headroom`, in search order
  # Windows' DEFAULT PATHEXT is `.COM;.EXE;.BAT;.CMD;...` and it is searched IN
  # THAT ORDER, so `.com` is tried FIRST -- a headroom.com sitting in the
  # spawning process's current directory beats every other spelling. The
  # extensionless name comes last: only Git Bash would ever run it.
  # ONE definition, shared by doctor.sh (check 2b-win) and session-probe.sh
  # (engine_name_hijack), so the two lists cannot drift apart again.
  printf '%s\n' headroom.com headroom.exe headroom.bat headroom.cmd headroom
}

venv_bindir() {  # venv_bindir <venv> — "bin" or "Scripts"; exit 1 if neither holds an interpreter
  if   [ -e "$1/bin/python" ];         then printf 'bin'
  elif [ -e "$1/Scripts/python.exe" ]; then printf 'Scripts'
  else return 1; fi
}

_er_is_pe() {  # PE executable (Windows launcher / uv trampoline): first two bytes "MZ"
  [ "$(head -c 2 "$1" 2>/dev/null)" = "MZ" ]
}

_er_shebang_interp() {  # interpreter path from a script's #! line (env form via PATH)
  local line rest
  IFS= read -r line < "$1" 2>/dev/null || return 1
  case $line in '#!'*) ;; *) return 1 ;; esac
  rest=${line#'#!'}
  # shellcheck disable=SC2086
  set -- $rest
  [ $# -ge 1 ] || return 1
  case $1 in
    */env|env) [ $# -ge 2 ] || return 1; command -v "$2" 2>/dev/null ;;
    *) printf '%s\n' "$1" ;;
  esac
}

_er_bounded() {  # _er_bounded <secs> <cmd...> — coreutils timeout, else a watchdog
  # The lib is sourced by SessionStart, by every gated Read and by every hcat, so
  # nothing here may hang unboundedly. doctor.sh's run_bounded is the same idea,
  # but it lives in doctor.sh and never reached these entry points. Keep it
  # bash-3.2 safe: no `wait -n`, no arrays.
  local t secs pid waited ticks unit
  t=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
  secs=$1; shift
  # secs arrives from the environment (ER_PY_TIMEOUT / ER_UV_TIMEOUT), and bash
  # evaluates a variable's CONTENTS inside $(( )) -- `a[$(cmd)]` runs cmd. Only
  # a plain integer may reach the arithmetic below or the timeout binary.
  case $secs in ''|*[!0-9]*) secs=5 ;; esac
  # -k: a child that ignores SIGTERM is SIGKILLed 2s later, the guarantee the
  # watchdog below already gives. GNU coreutils (Linux, Git for Windows, brew
  # gtimeout) all accept it.
  # A -k kill surfaces as 137, not 124; callers read 124 as "outran the bound".
  if [ -n "$t" ]; then
    "$t" -k 2 "$secs" "$@"; t=$?
    [ "$t" -eq 137 ] && t=124
    return "$t"
  fi
  # Poll sub-second where the platform allows. The previous `sleep 1` ran BEFORE
  # the first re-poll, so on a host without coreutils (stock macOS) every bounded
  # call paid a full second even when the child exited immediately -- and this
  # runs per candidate, on every gated Read, every hcat and every SessionStart.
  # Resolve the unit once per process; `none` means no usable sleep at all.
  # The cache is process-local; anything inherited from the environment is
  # untrusted and ends up in $(( )) too, so accept only the values set below.
  case "${_ER_SLEEP_UNIT:-}:${_ER_SLEEP_TICKS:-}" in 0.1:10|1:1|none:0) ;; *) _ER_SLEEP_UNIT="" ;; esac
  if [ -z "${_ER_SLEEP_UNIT:-}" ]; then
    if sleep 0.1 2>/dev/null; then _ER_SLEEP_UNIT=0.1; _ER_SLEEP_TICKS=10
    elif sleep 1 2>/dev/null; then _ER_SLEEP_UNIT=1;   _ER_SLEEP_TICKS=1
    else _ER_SLEEP_UNIT=none; _ER_SLEEP_TICKS=0; fi
  fi
  # No usable sleep: run UNBOUNDED rather than spin. A failing `sleep` used to
  # return instantly while `waited` still advanced, so the watchdog SIGKILLed a
  # perfectly healthy child within milliseconds and reported 124 -- the exact
  # shape that made doctor.sh's native probe unreachable (see run_bounded).
  if [ "$_ER_SLEEP_UNIT" = none ]; then "$@"; return $?; fi
  unit=$_ER_SLEEP_UNIT; ticks=$(( secs * _ER_SLEEP_TICKS ))
  "$@" &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$ticks" ]; then
      kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124
    fi
    sleep "$unit"; waited=$((waited+1))
  done
  wait "$pid"; return $?
}

resolve_engine_python_validated() {  # first IMPORTABLE candidate, not first executable
  # ONE definition of "which interpreter is the engine", shared by bin/hcat,
  # hcat-gate.sh and doctor.sh (check 2). Resolving by mere executability picks up a stray
  # `python` beside the headroom console script (pyenv/asdf/mise shims, uv's
  # default install, ~/.local/bin once --fix shims there) which cannot import
  # headroom -- so consumers disagreed about the engine on the same machine.
  #
  # Exit status carries the distinction an empty result cannot:
  #   0  prints a working interpreter
  #   2  prints the last EXECUTABLE-but-broken one (a resolved-but-broken engine)
  #   1  prints nothing (no engine installed at all)
  # Callers need 1 vs 2: one is the ordinary red-idle state, the other is an
  # outage that must fail open AND light the badge.
  local c seen="" st slow=""
  # HCAT_PYTHON is authoritative with no fallback (an existing contract, pinned by
  # the suite), so it is returned unprobed -- status 0 here means "this is the
  # engine", not "its import was verified". Callers that must know re-check it.
  if [ -n "${HCAT_PYTHON:-}" ]; then printf '%s\n' "$HCAT_PYTHON"; return 0; fi
  while IFS= read -r c; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    seen=$c
    _er_bounded "${ER_PY_TIMEOUT:-5}" "$c" -c 'import headroom.compress' >/dev/null 2>&1
    st=$?
    # 0 imports. 124 means the probe outran its bound -- and doctor.sh's own
    # comment concedes a cold headroom-ai[all] import with torch can do that on a
    # slow disk. Calling a working engine broken is the worse error, so a slow
    # candidate is still ACCEPTED -- but only after the walk has ruled out a later
    # candidate that imports in time. Returning on the first 124 let one wedged
    # interpreter preempt a healthy one, and bin/hcat then execs its pick
    # unbounded.
    if [ "$st" -eq 0 ]; then printf '%s\n' "$c"; return 0; fi
    [ "$st" -eq 124 ] && [ -z "$slow" ] && slow=$c
  done < <(engine_python_candidates)
  [ -n "$slow" ] && { printf '%s\n' "$slow"; return 0; }
  [ -n "$seen" ] && { printf '%s\n' "$seen"; return 2; }
  return 1
}

_er_uv_root() {  # <uv tool dir>/headroom-ai when uv is installed
  # BOUND the spawn. This runs on SessionStart (session-probe.sh), on every gated
  # Read (hcat-gate.sh) and on every hcat, so a wedged uv cache lock, a cold AV
  # scan of the trampoline on Windows, or a stalled filesystem would otherwise
  # hang session startup with no way out short of killing the process. doctor.sh
  # already bounds its external calls with run_bounded; that helper lives in
  # doctor.sh and never reached here.
  local d
  command -v uv >/dev/null 2>&1 || return 1
  d=$(_er_bounded "${ER_UV_TIMEOUT:-2}" uv tool dir 2>/dev/null) || return 1
  [ -n "$d" ] || return 1
  printf '%s/headroom-ai' "$d"
}

_er_cli_on_path() {  # `headroom` on PATH; on Windows prefer the explicit .exe
  local c
  c=$(command -v headroom 2>/dev/null) || return 1
  [ -n "$c" ] || return 1
  if is_windows && [ -f "$c.exe" ]; then c="$c.exe"; fi
  printf '%s' "$c"
}

engine_python_candidates() {  # every candidate, one per line, resolution order
  local cli dir uvr venv
  if [ -n "${HCAT_PYTHON:-}" ]; then printf '%s\n' "$HCAT_PYTHON"; return 0; fi
  if cli=$(_er_cli_on_path); then
    dir=$(dirname "$cli")
    printf '%s\n%s\n' "$dir/python" "$dir/python.exe"
    _er_is_pe "$cli" || _er_shebang_interp "$cli" || true
  fi
  if uvr=$(_er_uv_root); then printf '%s\n%s\n' "$uvr/bin/python" "$uvr/Scripts/python.exe"; fi
  venv=$(_er_venv)
  printf '%s\n%s\n' "$venv/bin/python" "$venv/Scripts/python.exe"
}

resolve_engine_python() {  # first executable candidate; HCAT_PYTHON verbatim when set
  local c
  if [ -n "${HCAT_PYTHON:-}" ]; then printf '%s\n' "$HCAT_PYTHON"; return 0; fi
  while IFS= read -r c; do
    [ -n "$c" ] && [ -f "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done < <(engine_python_candidates)
  return 1
}

resolve_headroom_cli() {  # first executable `headroom` CLI (.exe first: harmless on POSIX)
  local dir uvr venv c
  if [ -n "${HCAT_PYTHON:-}" ]; then
    dir=$(dirname "$HCAT_PYTHON")
    for c in "$dir/headroom.exe" "$dir/headroom"; do
      [ -f "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1   # authoritative override: no fallback (same contract as bin/hcat)
  fi
  if c=$(_er_cli_on_path) && [ -f "$c" ] && [ -x "$c" ]; then printf '%s\n' "$c"; return 0; fi
  if uvr=$(_er_uv_root); then
    for c in "$uvr/Scripts/headroom.exe" "$uvr/bin/headroom"; do
      [ -f "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
  fi
  venv=$(_er_venv)
  for c in "$venv/Scripts/headroom.exe" "$venv/bin/headroom"; do
    [ -f "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

_er_cygpath() {
  if [ -n "${DOCTOR_CYGPATH:-}" ]; then "$DOCTOR_CYGPATH" "$@"
  elif command -v cygpath >/dev/null 2>&1; then cygpath "$@"
  else return 1; fi
}
win_path()  { _er_cygpath -w "$1" 2>/dev/null || printf '%s\n' "$1"; }   # /c/x → C:\x
unix_path() { _er_cygpath -u "$1" 2>/dev/null || printf '%s\n' "$1"; }   # C:\x → /c/x
