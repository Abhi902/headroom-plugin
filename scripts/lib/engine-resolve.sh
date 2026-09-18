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

_er_uv_root() {  # <uv tool dir>/headroom-ai when uv is installed
  local d
  command -v uv >/dev/null 2>&1 || return 1
  d=$(uv tool dir 2>/dev/null) || return 1
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
