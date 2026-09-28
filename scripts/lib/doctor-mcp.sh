#!/usr/bin/env bash
# doctor-mcp.sh — helpers for doctor.sh's workspace containment and check 2c (MCP
# registration by absolute path). Sourced by doctor.sh only (mandatory, like
# engine-resolve.sh); uses doctor.sh's run_bounded, TMPD and unix_path at call time.
# Kept out of doctor.sh so the checks read top to bottom.

real_file() {  # real_file <path> — follow symlinks to the file itself (bash-3.2 safe, no readlink -f)
  local p=$1 l n=0
  while [ -L "$p" ] && [ "$n" -lt 20 ]; do
    l=$(readlink "$p") || break
    case $l in /*) p=$l ;; *) p=$(dirname "$p")/$l ;; esac
    n=$((n+1))
  done
  printf '%s\n' "$(cd "$(dirname "$p")" 2>/dev/null && pwd -P || dirname "$p")/$(basename "$p")"
}

_dm_git() {  # _dm_git <dir> <rev-parse args...> — git, answering for <dir> ONLY
  # The GIT_* discovery variables are environment, and environment can come from
  # a project-scoped settings.json: left in place they make git answer for some
  # other repository and move every root computed here. Scrub them.
  # Bounded like every other external spawn here (_er_uv_root, shim_runs): a
  # stalled git -- network mount, AV scan, a locked repo -- must not hang the
  # doctor; a timeout reads as "no answer" and the .git walk takes over.
  local d=$1; shift
  command -v git >/dev/null 2>&1 || return 1
  _er_bounded "${ER_GIT_TIMEOUT:-3}" env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_CEILING_DIRECTORIES \
      -u GIT_DISCOVERY_ACROSS_FILESYSTEM -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
      -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT \
      git -C "$d" rev-parse "$@" 2>/dev/null
}
_dm_canon() { (cd "$1" 2>/dev/null && pwd -P); }

# Per-run memo files in the doctor's own TMPD, keyed on the cwd. ONE reader and
# ONE writer for every cache here: builtins only (callers may run under a
# restricted PATH), silent on a cold cache, and a file counts only when it is
# COMPLETE -- the writer ends it with a "." line, so a half-written file (a run
# killed mid-write) is a miss, never a stale answer.
_dm_cache_get() {  # _dm_cache_get <name> <key> -- prints the cached lines; 1 on a miss
  local f l out="" seen=0
  [ -n "${TMPD:-}" ] && [ -f "$TMPD/$1" ] || return 1
  f="$TMPD/$1"
  { IFS= read -r l && [ "$l" = "$2" ]; } < "$f" 2>/dev/null || return 1
  while IFS= read -r l; do
    [ "$seen" -eq 1 ] || { seen=1; continue; }      # skip the key line
    [ "$l" = "." ] && { printf '%s' "$out"; return 0; }
    out="$out$l"$'\n'
  done < "$f"
  return 1
}
_dm_cache_put() {  # _dm_cache_put <name> <key> <line...>
  local n=$1 k=$2; shift 2
  [ -n "${TMPD:-}" ] || return 0
  { printf '%s\n' "$k"; [ $# -gt 0 ] && printf '%s\n' "$@"; printf '.\n'; } > "$TMPD/$n" 2>/dev/null
}

_dm_dotgit_walk() {  # nearest ancestor of <dir> holding .git (dir or file), empty if none
  # Pure parameter expansion: this is the no-git fallback, so it must not lean
  # on any other external tool either.
  local r=$1
  while [ -n "$r" ] && [ "$r" != / ]; do [ -e "$r/.git" ] && { printf '%s\n' "$r"; return 0; }; r=${r%/*}; done
  return 0
}

worktree_top() {  # worktree_top <dir> — the checkout <dir> is in (a linked worktree's own top), empty if none
  local r
  r=$(_dm_git "$1" --show-toplevel) && r=$(_dm_canon "$r") && [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
  _dm_dotgit_walk "$1"
}

workspace_root() {  # workspace_root <dir> — the REPOSITORY <dir> belongs to, empty if none
  # A linked worktree belongs to its MAIN repository: the CLI files local-scoped
  # servers under the main root (verified against Claude Code 2.1.280); for a
  # bare repository's worktree, under the bare repo's own directory. git answers
  # both; the .git walk is the fallback for hosts without git or with a git
  # older than --path-format (2.31).
  local d=$1 c r
  if c=$(_dm_git "$d" --path-format=absolute --git-common-dir); then
    case $c in
      */.git) r=$(_dm_canon "$(dirname "$c")") && [ -n "$r" ] && { printf '%s\n' "$r"; return 0; } ;;
      *) if [ "$(_dm_git "$c" --is-bare-repository)" = true ]; then
           r=$(_dm_canon "$c") && [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
         fi ;;
    esac
  fi
  worktree_top "$d"
}

_dm_roots() {  # the project roots, one per line: the cwd, its checkout, that checkout's main repo
  # They depend only on the cwd: computed (up to three bounded git spawns) once
  # per cwd per run, not once per candidate, via the run's TMPD.
  local pwd_c cached r2 r3
  pwd_c=$(_dm_canon "$PWD") || pwd_c=$PWD
  if cached=$(_dm_cache_get ws-roots "$pwd_c"); then
    # read, not expansions: an EMPTY r3 must stay empty (r2's value is not a
    # stand-in for it), and $() already dropped the trailing newline
    { IFS= read -r r2; IFS= read -r r3; } <<< "$cached"
  else
    r2=$(worktree_top "$pwd_c"); r3=$(workspace_root "$pwd_c")
    _dm_cache_put ws-roots "$pwd_c" "$r2" "$r3"
  fi
  printf '%s\n%s\n%s\n' "$pwd_c" "$r2" "$r3"
}
dm_cygpath_trusted() {  # DOCTOR_CYGPATH is unset, or absolute and outside every project root
  # The ONE rule for the test seam every win_path/unix_path (and the native
  # profile) goes through: it is environment, so a project's settings env could
  # plant it. Checked against the RAW roots -- never home-dropped ones.
  local c
  [ -n "${DOCTOR_CYGPATH:-}" ] || return 0
  case $DOCTOR_CYGPATH in /*) ;; *) return 1 ;; esac
  # No . or .. segment: the vet resolves logically, but the file that RUNS is the
  # raw string, and <proj>/lnk/../.. differs between the two when lnk is a symlink
  case /$DOCTOR_CYGPATH/ in */./*|*/../*) return 1 ;; esac
  # nor a UNC (//host/...: vetting would already stat the share) or a backslash
  # (MSYS dirname and the spawner can disagree on where it splits)
  case $DOCTOR_CYGPATH in //*|*\\*) return 1 ;; esac
  c=$(_dm_canon "$(dirname "$DOCTOR_CYGPATH")") || return 1
  ! _dm_under_any "$c" "$(_dm_roots)"
}
under_workspace() {  # under_workspace <dir> — <dir> is inside the project the doctor runs in
  # A UNION of roots, never a replacement: the directory the doctor runs in, the
  # checkout it belongs to, and that checkout's main repository. Replacing the
  # cwd with one git-derived root let a sibling worktree (or redirected git
  # discovery) move the boundary off the directory holding a planted file.
  # $HOME and / are never a root: a dotfiles repo at $HOME is not a workspace,
  # and widening to it would refuse every Git for Windows under the profile.
  # Compared by IDENTITY (-ef: same device and inode, the NTFS file id under
  # MSYS), walking <dir>'s ancestors -- a string prefix is case- and
  # 8.3-sensitive, and Windows paths are neither.
  local d=$1 home r1 r2 r3
  # Only an absolute path can be walked; anything else is refused as "inside"
  # (fail closed) rather than looping on a string that never reaches /.
  case $d in /*) ;; *) return 0 ;; esac
  home=$(_dm_canon "${HOME:-/}") || home=${HOME:-/}
  { IFS= read -r r1; IFS= read -r r2; IFS= read -r r3; } <<< "$(_dm_roots)"
  # A root that CONTAINS $HOME (a cwd of /Users, C:\ or / itself) is no project
  # boundary either: taking it would put ~/.headroom-venv, ~/.local/bin and every
  # user-level install "inside the workspace". Drop such roots up front.
  # Only a root that really holds a home: never every drive root (a project at
  # E:\ with no home on it is still a project). On Windows the user's files also
  # live under the NATIVE profile, which an MSYS HOME of /home/me does not
  # reveal -- but take it from the OS (cygpath -F 40, CSIDL_PROFILE), NEVER from
  # $USERPROFILE: that is environment, and a project's settings env could point
  # it at the project to erase this very boundary.
  local r h hs kept="" uprof=""
  # ...and DOCTOR_CYGPATH (the test seam native_profile_dir honours) is
  # environment too: only a trusted one may decide which roots are homes
  # (doctor.sh already dropped an untrusted one at start; this is defence in
  # depth for any other caller of this lib).
  dm_cygpath_trusted && { uprof=$(native_profile_dir 2>/dev/null) || uprof=""; }
  # a RELATIVE HOME (HOME=. from a project's settings env) is canonicalised
  # against the cwd -- it must not turn the project itself into "a home"
  case ${HOME:-} in /*|[A-Za-z]:[\\/]*) hs=$home ;; *) hs="" ;; esac
  hs="$hs
$uprof"
  for r in "$r1" "$r2" "$r3"; do
    { [ -z "$r" ] || [ "$r" = / ]; } && continue
    while IFS= read -r h; do
      case $h in /*) _dm_under_any "$h" "$r" && continue 2 ;; esac
    done <<< "$hs"
    kept="$kept$r
"
  done
  _dm_under_any "$d" "$kept"
}
_dm_under_any() {  # _dm_under_any <path> <roots, one per line> — <path> or an ancestor IS one of them
  # By IDENTITY (-ef), never by string prefix; stops at / or when nothing is
  # left to strip, so no spelling of <path> can loop.
  local a=$1 r b
  while [ -n "$a" ]; do
    while IFS= read -r r; do
      [ -n "$r" ] && [ "$a" -ef "$r" ] && return 0
    done <<< "$2"
    [ "$a" = / ] && break
    b=${a%/*}; [ -n "$b" ] || b=/
    [ "$b" = "$a" ] && break
    a=$b
  done
  return 1
}

# MCP registration state is read from the config FILE, not `claude mcp get`:
# `get` reports only the winning scope (local > project > user), and it
# health-checks by spawning the server, which a cold engine can outrun.
mcp_user_cmd() {  # the command of the USER-scoped `headroom` MCP, empty if none
  local cj; cj=$(claude_json_path)
  [ -f "$cj" ] || return 0
  # tr -d '\r': a native jq.exe (Windows) writes CRLF in -r mode; a stray \r
  # would become part of the command it names
  jq -r '.mcpServers.headroom.command // empty' "$cj" 2>/dev/null | tr -d '\r'
}
_dm_jqj() {  # jq for the NUL-terminated (-j) readers: -b on a real MSYS/Cygwin host,
  # where a native jq.exe otherwise turns every \n INSIDE a value into \r\n
  # (and only if this jq accepts -b: a non-WIN32 jq 1.6 build rejects it)
  if [ -z "${_DM_JQ_B+x}" ]; then
    _DM_JQ_B=""
    case "$(uname -s 2>/dev/null)" in
      MINGW*|MSYS*|CYGWIN*) jq -b -n 1 >/dev/null 2>&1 && _DM_JQ_B=-b ;;
    esac
  fi
  jq ${_DM_JQ_B:+"$_DM_JQ_B"} "$@"
}
_dm_jq_items() {  # _dm_jq_items <filter yielding an array of strings> [file] — each item NUL-terminated
  # A string holding NUL cannot be passed to a process (Claude Code's spawn
  # refuses it) and would split the item here: fail instead, so the caller
  # judges the entry "does not start" without running anything.
  # explode, not contains("\u0000"): on jq 1.6 contains() of a NUL is true for EVERY string
  _dm_jqj -j "($1) | if any(.[]; any(explode[]; . == 0)) then error(\"NUL\") else .[] + \"\\u0000\" end" "${@:2}" 2>/dev/null
}
mcp_user_args() {  # its args, each NUL-terminated (an arg may hold a newline)
  local cj; cj=$(claude_json_path)
  [ -f "$cj" ] || return 0
  _dm_jq_items '(.mcpServers.headroom.args // []) | map(tostring)' "$cj"
}
mcp_user_env() {  # its env block as KEY=VALUE, each NUL-terminated
  local cj; cj=$(claude_json_path)
  [ -f "$cj" ] || return 0
  _dm_jq_items '(.mcpServers.headroom.env // {}) | to_entries | map("\(.key)=\(.value|tostring)")' "$cj"
}
mcp_project_root() {  # the key the CLI files local-scoped servers under: the repository root, else $PWD
  local d r; d=$(_dm_canon "$PWD") || d=$PWD
  r=$(workspace_root "$d"); printf '%s\n' "${r:-$d}"
}
_mcp_local_entry() {  # the LOCAL-scoped `headroom` for this project: command, then args and env as JSON lines
  # Matched by IDENTITY, not by key spelling: the CLI keys projects by its own
  # native path (C:/Users/... on Windows, possibly another case or an 8.3
  # name), while the root here is an MSYS path. unix_path + -ef matches both.
  local cj root k c aj ej ku
  cj=$(claude_json_path); root=$(mcp_project_root)
  [ -f "$cj" ] || return 0
  # Raw key/command/args LINE TRIPLES, not @tsv: @tsv escapes every backslash,
  # which would double every separator in a native Windows command. The args
  # travel as one compact JSON line, so no value ever passes through argv here.
  while IFS= read -r k && IFS= read -r c && IFS= read -r aj && IFS= read -r ej; do
    [ -n "$k" ] && [ -n "$c" ] || continue
    ku=$(unix_path "$k" 2>/dev/null) || ku=$k
    if [ "$ku" = "$root" ] || [ "$ku" -ef "$root" ]; then printf '%s\n%s\n%s\n' "$c" "$aj" "$ej"; return 0; fi
  done < <(jq -r '(.projects // {}) | to_entries[]
                  | select(.value.mcpServers.headroom.command? // empty | length > 0)
                  | .key, .value.mcpServers.headroom.command,
                    ((.value.mcpServers.headroom.args // []) | tojson),
                    ((.value.mcpServers.headroom.env // {}) | tojson)' "$cj" 2>/dev/null | tr -d '\r')
  return 0
}
mcp_local_cmd() {  # the command of a LOCAL-scoped `headroom` MCP for this project, empty if none
  _mcp_local_entry | head -1
}
mcp_local_args() {  # its args, each NUL-terminated
  _mcp_local_entry | sed -n 2p | _dm_jq_items 'map(tostring)'
}
mcp_local_env() {  # its env block as KEY=VALUE, each NUL-terminated
  _mcp_local_entry | sed -n 3p | _dm_jq_items 'to_entries | map("\(.key)=\(.value|tostring)")'
}
# The server NAME must precede -e: -e is variadic and swallows every following
# bare token, so `-e A=1 headroom` is rejected by the real CLI with "Invalid
# environment variable format: headroom". One array feeds both the call and the
# hint printed for the user, so the two cannot disagree again.
MCP_ADD_ARGV=(mcp add -s user headroom -e HEADROOM_UPDATE_CHECK=off -e HF_HUB_OFFLINE=1 --)
mcp_add() {  # mcp_add <engine path>
  ( export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
    run_bounded 20 claude "${MCP_ADD_ARGV[@]}" "$1" mcp serve ) >"$TMPD/mcp-add.out" 2>&1
}
mcp_add_hint() {  # the same command, for the user to run by hand
  printf 'claude %s "%s" mcp serve' "${MCP_ADD_ARGV[*]}" "$1"
}
same_file() {  # same_file <a> <b> [bytes] — both name one file (symlinks, MSYS spellings)
  # With `bytes`, identical contents count too: a Windows shim is a byte COPY
  # of the engine, and a copy that RUNS proves the engine runs. Never used for a
  # dead verdict -- a relocatable launcher can fail as a copy and still work.
  local a b
  [ -n "$1" ] && [ -n "$2" ] || return 1
  a=$(real_file "$(unix_path "$1")"); b=$(real_file "$(unix_path "$2")")
  [ "$a" = "$b" ] && return 0
  [ "${3:-}" = bytes ] && [ -f "$a" ] && [ -f "$b" ] && cmp -s "$a" "$b"
}
