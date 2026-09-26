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
  local d=$1; shift
  command -v git >/dev/null 2>&1 || return 1
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_CEILING_DIRECTORIES \
      -u GIT_DISCOVERY_ACROSS_FILESYSTEM -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
      -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT \
      git -C "$d" rev-parse "$@" 2>/dev/null
}
_dm_canon() { (cd "$1" 2>/dev/null && pwd -P); }

_dm_dotgit_walk() {  # nearest ancestor of <dir> holding .git (dir or file), empty if none
  local r=$1
  while [ -n "$r" ] && [ "$r" != / ]; do [ -e "$r/.git" ] && { printf '%s\n' "$r"; return 0; }; r=$(dirname "$r"); done
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

under_workspace() {  # under_workspace <dir> — <dir> is inside the project the doctor runs in
  # A UNION of roots, never a replacement: the directory the doctor runs in, the
  # checkout it belongs to, and that checkout's main repository. Replacing the
  # cwd with one git-derived root let a sibling worktree (or redirected git
  # discovery) move the boundary off the directory holding a planted file.
  # $HOME and / are never a root: a dotfiles repo at $HOME is not a workspace,
  # and widening to it would refuse every Git for Windows under the profile.
  local d=$1 pwd_c home root
  pwd_c=$(_dm_canon "$PWD") || pwd_c=$PWD
  home=$(_dm_canon "${HOME:-/}") || home=${HOME:-/}
  for root in "$pwd_c" "$(worktree_top "$pwd_c")" "$(workspace_root "$pwd_c")"; do
    { [ -z "$root" ] || [ "$root" = / ] || [ "$root" = "$home" ]; } && continue
    [ "$d" = "$root" ] && return 0
    case "$d/" in "$root"/*) return 0 ;; esac
  done
  return 1
}

# MCP registration state is read from the config FILE, not `claude mcp get`:
# `get` reports only the winning scope (local > project > user), and it
# health-checks by spawning the server, which a cold engine can outrun.
mcp_user_cmd() {  # the command of the USER-scoped `headroom` MCP, empty if none
  local cj; cj=$(claude_json_path)
  [ -f "$cj" ] || return 0
  jq -r '.mcpServers.headroom.command // empty' "$cj" 2>/dev/null
}
mcp_project_root() {  # the key the CLI files local-scoped servers under: the repository root, else $PWD
  local d r; d=$(_dm_canon "$PWD") || d=$PWD
  r=$(workspace_root "$d"); printf '%s\n' "${r:-$d}"
}
mcp_local_cmd() {  # the command of a LOCAL-scoped `headroom` MCP for this project, empty if none
  local cj root; cj=$(claude_json_path); root=$(mcp_project_root)
  [ -f "$cj" ] || return 0
  jq -r --arg r "$root" '.projects[$r].mcpServers.headroom.command // empty' "$cj" 2>/dev/null
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
same_file() {  # same_file <a> <b> — both name one file: through symlinks and MSYS
  # spellings, or (a Windows shim is a byte COPY, not a link) identical bytes.
  local a b
  [ -n "$1" ] && [ -n "$2" ] || return 1
  a=$(real_file "$(unix_path "$1")"); b=$(real_file "$(unix_path "$2")")
  [ "$a" = "$b" ] && return 0
  [ -f "$a" ] && [ -f "$b" ] && cmp -s "$a" "$b"
}
