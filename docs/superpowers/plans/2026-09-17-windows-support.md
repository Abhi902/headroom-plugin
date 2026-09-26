# Windows Support (v2.8.0, issue #9) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the headroom-usage-indicator plugin work on Windows (Git Bash): bundled MCP connects, engine found in `Scripts\` / uv layouts, hcat is UTF-8 safe, doctor bootstraps and wires the status line correctly — with a `windows-latest` CI job proving it.

**Architecture:** One shared resolver (`scripts/lib/engine-resolve.sh`) replaces five hand-rolled engine lookups. `.mcp.json` spawns the bare `headroom` name and the doctor guarantees that name resolves on PATH via a shim in `~/.local/bin`. Windows-only behaviour is isolated behind `is_windows` with `DOCTOR_OS`/`DOCTOR_CYGPATH`/`DOCTOR_SHIM_DIR` test overrides so every branch is exercised on macOS; a GitHub Actions job runs the real thing on Windows.

**Tech Stack:** bash (Git Bash on Windows), jq, Python venv, GitHub Actions, Node (CI spawn probe only). Test suite is `./test.sh` (plain bash, `check`/`check_eq`/`check_absent` helpers, shellcheck at the end).

**Spec:** `docs/superpowers/specs/2026-09-17-windows-support-design.md`

## Global Constraints

- Every hook script MUST always exit 0 and print nothing but its single JSON line (existing contract). The resolver is sourced, never executed, and must not print or exit.
- `HCAT_PYTHON` stays authoritative with no fallback (existing contract, tests 22-25 pin it).
- Legacy flat installs (`~/.claude/*.sh` siblings, no `lib/`) must keep working: every script that sources the new lib keeps an inline minimal fallback.
- Doctor `--fix` is idempotent; a second run changes nothing. Doctor never edits shell rc files or the Windows registry; the only new write is the shim under `$SHIM_DIR` (`${DOCTOR_SHIM_DIR:-$HOME/.local/bin}`).
- shellcheck `--severity=warning` clean for every `*.sh` and `bin/hcat`.
- All test fixtures are hermetic (under `$TMP`), the suite runs on macOS + Linux; Windows-only branches are forced with `DOCTOR_OS=windows`.
- Version bump to `2.8.0` in BOTH `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`.
- Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Run the suite as `./test.sh 2>&1 | tail -5` and read the `N passed, M failed` line; never claim green without it.
- Deviation from spec §4 noted here: the Windows job's required gate is a dedicated `scripts/ci/windows-check.sh`; the full `./test.sh` runs on Windows with `continue-on-error: true` (informational) because its fixtures assume POSIX permission bits, symlinks and `id -u`. Making it green on Windows is a follow-up.

---

## File map

| File | Responsibility | Task |
|---|---|---|
| `scripts/lib/engine-resolve.sh` (new) | `is_windows`, `venv_bindir`, `resolve_engine_python`, `engine_python_candidates`, `resolve_headroom_cli`, `win_path`, `unix_path` | 1 |
| `bin/hcat` | use resolver; UTF-8 env on exec | 2 |
| `scripts/hcat-gate.sh`, `scripts/session-probe.sh` | use resolver | 3 |
| `scripts/doctor.sh` check 2 + bootstrap | resolver candidates with import check; interpreter order; `venv_bindir` | 4 |
| `.mcp.json`, `scripts/mcp-launcher.sh` (deleted), doctor 4b, test.sh 32h/32i/F1/F8/F8b/F8c | bare `headroom mcp serve` | 5 |
| `scripts/doctor.sh` check 2b | shim + PATH verify | 6 |
| `scripts/doctor.sh` check 0 + check 7 wiring | Git Bash prerequisite, Windows status-line command, backslash tokens | 7 |
| `skills/headroom-usage-indicator/SKILL.md`, `skills/doctor/SKILL.md`, test.sh parity checks | installers copy the new lib; consent/fixable lists disclose the shim | 8 |
| `.github/workflows/test.yml`, `scripts/ci/windows-check.sh`, `scripts/ci/spawn-probe.mjs` | CI | 9 |
| `README.md`, manifests, PR, issue comment | docs + release | 10 |

Test section for this release: append `# --- 46. v2.8 Windows support (issue #9)` to `test.sh` right BEFORE the `# --- shellcheck` block (line 2692 today). Fixture names use the `w` prefix (`w1`, `w2`, …). Every task adds its checks inside that section, in order.

---

### Task 1: shared engine resolver

**Files:**
- Create: `scripts/lib/engine-resolve.sh`
- Test: `test.sh` (new section 46, block "w1 resolver")

**Interfaces:**
- Produces (all sourced functions, bash 3.2 compatible, no output except the documented one):
  - `is_windows` → exit 0 on Windows. Honors `DOCTOR_OS=windows|unix` first, then `$OSTYPE` (`msys*|cygwin*`), then `uname -s` (`MINGW*|MSYS*|CYGWIN*`).
  - `venv_bindir <venv>` → prints `bin` or `Scripts`; exit 1 if neither `bin/python` nor `Scripts/python.exe` exists.
  - `engine_python_candidates` → prints every candidate path, one per line, in resolution order (may include non-existent ones; `$HCAT_PYTHON` alone when set).
  - `resolve_engine_python` → prints the first candidate that is an executable file; when `HCAT_PYTHON` is set prints it verbatim (even if broken) and exits 0. Exit 1 when nothing found.
  - `resolve_headroom_cli` → prints the first executable CLI: `$HCAT_PYTHON`'s dir `headroom.exe`/`headroom` (authoritative when set) → `command -v headroom` (+`.exe` sibling on Windows) → uv tool dir → venv both layouts. Exit 1 when none.
  - `win_path <p>` / `unix_path <p>` → `cygpath -w` / `cygpath -u` when available (or `$DOCTOR_CYGPATH`), else echo unchanged.
- Env: `HCAT_PYTHON`, `DOCTOR_VENV_DIR` (default `$HOME/.headroom-venv`), `DOCTOR_OS`, `DOCTOR_CYGPATH`.

- [ ] **Step 1: Write the failing tests** — append to `test.sh` before the shellcheck block:

```bash
# --- 46. v2.8 Windows support (issue #9)
ER="$ROOT/scripts/lib/engine-resolve.sh"
er() {  # er <fn> [args] — call a resolver function in a clean subshell
  ( set -u; . "$ER"; "$@" )
}
W="$TMP/w"; mkdir -p "$W"

# w1. is_windows: DOCTOR_OS override wins, OSTYPE next, uname last
check_eq "w1: DOCTOR_OS=windows → is_windows" "0" "$(DOCTOR_OS=windows er is_windows; echo $?)"
check_eq "w1: DOCTOR_OS=unix → not windows"   "1" "$(DOCTOR_OS=unix OSTYPE=msys er is_windows; echo $?)"
check_eq "w1: OSTYPE=msys → is_windows"       "0" "$(env -u DOCTOR_OS OSTYPE=msys er is_windows; echo $?)"
check_eq "w1: darwin → not windows"           "1" "$(env -u DOCTOR_OS OSTYPE=darwin24 er is_windows; echo $?)"

# w1. venv_bindir: bin/ vs Scripts/ layouts
W1U="$W/venv-unix"; mkdir -p "$W1U/bin"; printf '#!/bin/sh\nexit 0\n' > "$W1U/bin/python"; chmod +x "$W1U/bin/python"
W1W="$W/venv-win";  mkdir -p "$W1W/Scripts"
printf '#!/bin/sh\necho "win-python $*"\n' > "$W1W/Scripts/python.exe"; chmod +x "$W1W/Scripts/python.exe"
printf '#!/bin/sh\necho "win-headroom $*"\n' > "$W1W/Scripts/headroom.exe"; chmod +x "$W1W/Scripts/headroom.exe"
check_eq "w1: venv_bindir unix layout"    "bin"     "$(er venv_bindir "$W1U")"
check_eq "w1: venv_bindir windows layout" "Scripts" "$(er venv_bindir "$W1W")"
check_eq "w1: venv_bindir empty dir fails" "1"      "$(er venv_bindir "$W" >/dev/null; echo $?)"

# w1. resolve_engine_python: Scripts\python.exe venv found when nothing else is
out=$(env -u HCAT_PYTHON PATH="/usr/bin:/bin" DOCTOR_VENV_DIR="$W1W" er resolve_engine_python)
check_eq "w1: resolver finds Scripts/python.exe" "$W1W/Scripts/python.exe" "$out"
out=$(env -u HCAT_PYTHON PATH="/usr/bin:/bin" DOCTOR_VENV_DIR="$W1U" er resolve_engine_python)
check_eq "w1: resolver finds bin/python" "$W1U/bin/python" "$out"
check_eq "w1: resolver exits 1 with no engine" "1" \
  "$(env -u HCAT_PYTHON PATH="/usr/bin:/bin" DOCTOR_VENV_DIR="$W/none" er resolve_engine_python >/dev/null; echo $?)"

# w1. HCAT_PYTHON is authoritative even when broken (callers decide what to do)
check_eq "w1: HCAT_PYTHON verbatim" "/nonexistent/py" \
  "$(HCAT_PYTHON=/nonexistent/py DOCTOR_VENV_DIR="$W1W" er resolve_engine_python)"
check_eq "w1: candidates = only HCAT_PYTHON when set" "/nonexistent/py" \
  "$(HCAT_PYTHON=/nonexistent/py DOCTOR_VENV_DIR="$W1W" er engine_python_candidates)"

# w1. PATH sibling beats venv; python.exe sibling accepted
W1P="$W/pathbin"; mkdir -p "$W1P"
printf '#!/bin/sh\nexit 0\n' > "$W1P/headroom"; chmod +x "$W1P/headroom"
printf '#!/bin/sh\nexit 0\n' > "$W1P/python.exe"; chmod +x "$W1P/python.exe"
out=$(env -u HCAT_PYTHON PATH="$W1P:/usr/bin:/bin" DOCTOR_VENV_DIR="$W1W" er resolve_engine_python)
check_eq "w1: python.exe sibling of headroom on PATH wins" "$W1P/python.exe" "$out"

# w1. MZ trampoline (uv / pip-on-Windows launcher): no shebang parse, fall through
W1M="$W/mzbin"; mkdir -p "$W1M"
printf 'MZ\220\000\003garbage #!/should/not/be/parsed\n' > "$W1M/headroom"; chmod +x "$W1M/headroom"
out=$(env -u HCAT_PYTHON PATH="$W1M:/usr/bin:/bin" DOCTOR_VENV_DIR="$W1W" er resolve_engine_python)
check_eq "w1: MZ trampoline skips shebang, falls to venv" "$W1W/Scripts/python.exe" "$out"

# w1. uv tool dir layout (stub uv prints a dir for `uv tool dir`)
W1UV="$W/uvtools"; mkdir -p "$W1UV/headroom-ai/Scripts" "$W/uvbin"
printf '#!/bin/sh\nexit 0\n' > "$W1UV/headroom-ai/Scripts/python.exe"; chmod +x "$W1UV/headroom-ai/Scripts/python.exe"
printf '#!/bin/sh\nexit 0\n' > "$W1UV/headroom-ai/Scripts/headroom.exe"; chmod +x "$W1UV/headroom-ai/Scripts/headroom.exe"
printf '#!/bin/sh\n[ "$1" = tool ] && [ "$2" = dir ] && printf "%%s" "%s"\n' "$W1UV" > "$W/uvbin/uv"; chmod +x "$W/uvbin/uv"
out=$(env -u HCAT_PYTHON PATH="$W/uvbin:/usr/bin:/bin" DOCTOR_VENV_DIR="$W/none" er resolve_engine_python)
check_eq "w1: uv tool dir python found" "$W1UV/headroom-ai/Scripts/python.exe" "$out"
out=$(env -u HCAT_PYTHON PATH="$W/uvbin:/usr/bin:/bin" DOCTOR_VENV_DIR="$W/none" er resolve_headroom_cli)
check_eq "w1: uv tool dir CLI found" "$W1UV/headroom-ai/Scripts/headroom.exe" "$out"

# w1. resolve_headroom_cli: HCAT_PYTHON dir authoritative; venv Scripts/headroom.exe; PATH
out=$(HCAT_PYTHON="$W1W/Scripts/python.exe" PATH="$W1P:/usr/bin:/bin" er resolve_headroom_cli)
check_eq "w1: CLI next to HCAT_PYTHON wins over PATH" "$W1W/Scripts/headroom.exe" "$out"
out=$(env -u HCAT_PYTHON PATH="/usr/bin:/bin" DOCTOR_VENV_DIR="$W1W" er resolve_headroom_cli)
check_eq "w1: CLI from venv Scripts/" "$W1W/Scripts/headroom.exe" "$out"
out=$(env -u HCAT_PYTHON PATH="$W1P:/usr/bin:/bin" DOCTOR_VENV_DIR="$W/none" er resolve_headroom_cli)
check_eq "w1: CLI from PATH" "$W1P/headroom" "$out"
check_eq "w1: CLI exits 1 when absent" "1" \
  "$(env -u HCAT_PYTHON PATH="/usr/bin:/bin" DOCTOR_VENV_DIR="$W/none" er resolve_headroom_cli >/dev/null; echo $?)"

# w1. win_path / unix_path: stubbed cygpath, else passthrough
printf '#!/bin/sh\ncase $1 in -w) echo "C:\\\\fake\\\\$(basename "$2")";; -u) echo "/c/fake/$(basename "$2")";; esac\n' > "$W/cygpath"; chmod +x "$W/cygpath"
check_eq "w1: win_path via DOCTOR_CYGPATH" 'C:\fake\x.sh' "$(DOCTOR_CYGPATH="$W/cygpath" er win_path /tmp/x.sh)"
check_eq "w1: unix_path via DOCTOR_CYGPATH" '/c/fake/x.sh' "$(DOCTOR_CYGPATH="$W/cygpath" er unix_path 'C:\x.sh')"
check_eq "w1: win_path passthrough without cygpath" "/tmp/x.sh" "$(env -u DOCTOR_CYGPATH PATH="/usr/bin:/bin" er win_path /tmp/x.sh)"
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/abhi/Desktop/headroom-plugin-win && ./test.sh 2>&1 | grep -E '^(FAIL|ok) - w1' | head -30; ./test.sh 2>&1 | tail -1`
Expected: every `w1` line is `FAIL` (the lib does not exist, `. "$ER"` fails).

- [ ] **Step 3: Create `scripts/lib/engine-resolve.sh`**

```bash
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./test.sh 2>&1 | grep -E '^(FAIL|ok) - w1'; ./test.sh 2>&1 | tail -1`
Expected: all `w1` lines `ok`; total `N passed, 0 failed` with N = previous + 24.

- [ ] **Step 5: Add the lib to shellcheck's list** — in `test.sh` shellcheck block, after `"$ROOT/scripts/lib/headroom-state.sh"` add ` \` and a new line `"$ROOT/scripts/lib/engine-resolve.sh"`. Run `shellcheck --severity=warning scripts/lib/engine-resolve.sh` → no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/engine-resolve.sh test.sh
git commit -m "feat(lib): shared engine resolver with Windows/uv layouts (issue #9)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: bin/hcat uses the resolver + UTF-8 env

**Files:**
- Modify: `bin/hcat` lines 13-15 (header comment), 23-28 (lib sourcing), 30-43 (`shebang_interp` → delete), 54-64 (PY resolution), 110 (exec line)
- Test: `test.sh` section 46, block "w2 hcat"

**Interfaces:**
- Consumes: `resolve_engine_python` from Task 1.
- Produces: unchanged hcat CLI contract (exit 0/2/3/4, receipt header `── hcat:`); exec env now includes `PYTHONIOENCODING=utf-8 PYTHONUTF8=1`.

- [ ] **Step 1: Write the failing tests** — append to section 46:

```bash
# w2. hcat: Windows venv layout resolved; exec env is UTF-8 safe
W2="$W/w2"; mkdir -p "$W2/venv/Scripts" "$W2/home"
# a fake python.exe that prints the env vars hcat is supposed to set, then its args
cat > "$W2/venv/Scripts/python.exe" <<'W2EOF'
#!/bin/sh
echo "ioenc=${PYTHONIOENCODING:-unset} utf8=${PYTHONUTF8:-unset} args=$*"
W2EOF
chmod +x "$W2/venv/Scripts/python.exe"
printf '{"k":1}' > "$W2/tiny.json"
out=$(env -u HCAT_PYTHON HOME="$W2/home" DOCTOR_VENV_DIR="$W2/venv" PATH="/usr/bin:/bin" bash "$HCAT" "$W2/tiny.json" 2>&1); rc=$?
check "w2: hcat resolves Scripts/python.exe" "args=- $W2/tiny.json" "$out"
check "w2: hcat sets PYTHONIOENCODING=utf-8" "ioenc=utf-8" "$out"
check "w2: hcat sets PYTHONUTF8=1"           "utf8=1"      "$out"
check_eq "w2: hcat exit 0" "0" "$rc"
# the legacy flat layout (no lib/ next to hcat) still resolves the plain venv
W2L="$W/w2legacy"; mkdir -p "$W2L/home/.headroom-venv/bin"
cp "$HCAT" "$W2L/hcat"; chmod +x "$W2L/hcat"
printf '#!/bin/sh\necho "legacy-py $*"\n' > "$W2L/home/.headroom-venv/bin/python"; chmod +x "$W2L/home/.headroom-venv/bin/python"
out=$(env -u HCAT_PYTHON -u DOCTOR_VENV_DIR HOME="$W2L/home" PATH="/usr/bin:/bin" bash "$W2L/hcat" "$W2/tiny.json" 2>&1)
check "w2: legacy flat hcat (no lib) still finds ~/.headroom-venv" "legacy-py" "$out"
```

- [ ] **Step 2: Run to verify it fails**

Run: `./test.sh 2>&1 | grep -E '^(FAIL|ok) - w2'`
Expected: `w2: hcat resolves Scripts/python.exe` FAIL (exit 3, engine not found), the two env checks FAIL; legacy check may pass already.

- [ ] **Step 3: Edit `bin/hcat`**

Replace lines 13-15 of the header with:
```bash
# Python resolution lives in scripts/lib/engine-resolve.sh (one definition for
# every entry point): $HCAT_PYTHON → sibling python of `headroom` on PATH → its
# shebang interpreter (skipped for MZ/PE launchers) → uv tool dir → ~/.headroom-venv
# (bin/ or Scripts/ layout). A flat legacy copy without the lib falls back to
# HCAT_PYTHON / ~/.headroom-venv only.
```

Replace the lib-sourcing loop (lines 23-28) so it also sources the resolver, with an inline fallback:
```bash
_hb="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"
# shellcheck disable=SC1090,SC1091
for _sl in "$_hb/../scripts/lib/headroom-state.sh" "$_hb/headroom-state.sh"; do
  [ -f "$_sl" ] && { . "$_sl"; break; }
done
# shellcheck disable=SC1090,SC1091
for _er in "$_hb/../scripts/lib/engine-resolve.sh" "$_hb/engine-resolve.sh"; do
  [ -f "$_er" ] && { . "$_er"; break; }
done
type note_error >/dev/null 2>&1 || note_error() { :; }
type resolve_engine_python >/dev/null 2>&1 || resolve_engine_python() {  # partial legacy copy
  local c
  if [ -n "${HCAT_PYTHON:-}" ]; then printf '%s\n' "$HCAT_PYTHON"; return 0; fi
  for c in "${HOME:-}/.headroom-venv/bin/python" "${HOME:-}/.headroom-venv/Scripts/python.exe"; do
    [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}
```

Delete the local `shebang_interp()` function (lines 30-43). Replace the PY block (lines 54-64) with:
```bash
PY=$(resolve_engine_python) || PY=""
```
(the following `if [ -z "$PY" ] || [ ! -x "$PY" ]` block is unchanged: an HCAT_PYTHON pointing nowhere still lands there with PY non-empty and records the broken badge.)

Change the exec line (was line 110) to:
```bash
PYTHONIOENCODING=utf-8 PYTHONUTF8=1 HF_HUB_OFFLINE=1 HEADROOM_UPDATE_CHECK=off exec "$PY" - "$FILE" <<'PYEOF'
```

- [ ] **Step 4: Run the whole suite**

Run: `./test.sh 2>&1 | grep -E '^FAIL'; ./test.sh 2>&1 | tail -1`
Expected: no FAIL lines; sections 22-25 (hcat), 35/F1 (shebang resolution via `$CLI/headroom` on PATH) still pass — F1 at test.sh:1179 relies on the shebang path, which the resolver keeps.

- [ ] **Step 5: Commit**

```bash
git add bin/hcat test.sh
git commit -m "fix(hcat): resolve the engine through the shared lib; UTF-8 stdout on Windows (issue #9)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: gate + probe use the resolver

**Files:**
- Modify: `scripts/hcat-gate.sh` lines 20-26 (sourcing) and 112-138 (engine check)
- Modify: `scripts/session-probe.sh` lines 15-21 (sourcing) and 54-72 (engine check)
- Test: `test.sh` section 46, block "w3"

**Interfaces:**
- Consumes: `resolve_engine_python` (Task 1).
- Produces: no contract change; the gate now denies (routes to hcat) when the engine lives in `Scripts\` or a uv layout; the probe no longer reports "engine not installed" for those layouts.

- [ ] **Step 1: Write the failing tests** — append to section 46 (uses `gate_input` helper defined at test.sh section 26 and `$GATE`, `$BIGJSON`):

```bash
# w3. gate + probe see a Scripts\python.exe engine
W3="$W/w3"; mkdir -p "$W3/venv/Scripts" "$W3/home"
printf '#!/bin/sh\nexit 0\n' > "$W3/venv/Scripts/python.exe"; chmod +x "$W3/venv/Scripts/python.exe"
out=$(gate_input "$BIGJSON" w3-g1 | env -u HCAT_PYTHON HOME="$W3/home" DOCTOR_VENV_DIR="$W3/venv" PATH="/usr/bin:/bin" \
      HEADROOM_STATE_DIR="$W3/state" bash "$GATE"); rc=$?
check "w3: gate denies with a Scripts/ engine" "deny" "$out"
check_eq "w3: gate exit 0" "0" "$rc"
PROBE="$ROOT/scripts/session-probe.sh"
out=$(printf '{"session_id":"w3"}' | env -u HCAT_PYTHON HOME="$W3/home" DOCTOR_VENV_DIR="$W3/venv" PATH="/usr/bin:/bin" \
      HEADROOM_STATE_DIR="$W3/state" bash "$PROBE"); rc=$?
check_absent "w3: probe does not call a Scripts/ engine 'not installed'" "engine not installed" "$out"
check_eq "w3: probe exit 0" "0" "$rc"
```

- [ ] **Step 2: Run to verify it fails**

Run: `./test.sh 2>&1 | grep -E '^(FAIL|ok) - w3'`
Expected: `w3: gate denies…` FAIL (gate exits silently: no `~/.headroom-venv/bin/python`, no `headroom` on PATH) and `w3: probe…` FAIL.

- [ ] **Step 3: Edit `scripts/hcat-gate.sh`**

After the `headroom-state.sh` sourcing loop (line 24) add:
```bash
# shellcheck disable=SC1090,SC1091
for _er in "$_here/lib/engine-resolve.sh" "$_here/engine-resolve.sh"; do
  [ -f "$_er" ] && { . "$_er"; break; }
done
type resolve_engine_python >/dev/null 2>&1 || resolve_engine_python() {  # partial legacy copy
  local c
  if [ -n "${HCAT_PYTHON:-}" ]; then printf '%s\n' "$HCAT_PYTHON"; return 0; fi
  for c in "${HOME:-}/.headroom-venv/bin/python" "${HOME:-}/.headroom-venv/Scripts/python.exe"; do
    [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}
```
Replace lines 112-117 (`py=""` … `fi`) with:
```bash
py=$(resolve_engine_python) || py=""
```
Keep the `if [ -n "$py" ]` block as is. In its `else` branch (line 137) keep `command -v headroom >/dev/null 2>&1 || exit 0` (a CLI with no importable python still lets hcat try TOON-lite).

- [ ] **Step 4: Edit `scripts/session-probe.sh`**

After the sourcing loop (line 19) add the same `for _er in "$here/lib/engine-resolve.sh" "$here/engine-resolve.sh"` loop and the same `type resolve_engine_python … ||` fallback as in Step 3 (copy verbatim, `_here` → `here`). Replace lines 61-72 (`else` … `fi` of the HCAT_PYTHON branch) with:
```bash
else
  if ! resolve_engine_python >/dev/null 2>&1 && ! command -v headroom >/dev/null 2>&1; then
    # Never-installed engine is the ordinary red-idle state, not a breakage:
    # say it once at session start, but do not flip the badge to broken.
    add_problem "headroom engine not installed — run /doctor --fix to bootstrap it"
  fi
fi
```

- [ ] **Step 5: Run the whole suite**

Run: `./test.sh 2>&1 | grep -E '^FAIL'; ./test.sh 2>&1 | tail -1`
Expected: no FAIL; section 38 (probe) and 26-28/40 (gate) unchanged.

- [ ] **Step 6: Commit**

```bash
git add scripts/hcat-gate.sh scripts/session-probe.sh test.sh
git commit -m "fix(gate,probe): resolve the engine through the shared lib (issue #9)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: doctor check 2 via resolver; Windows-aware bootstrap

**Files:**
- Modify: `scripts/doctor.sh` lines 7 (header), 29-34 (env docs), 49-52 (sourcing), 111-175 (check 2 + bootstrap)
- Test: `test.sh` section 46, block "w4"

**Interfaces:**
- Consumes: `engine_python_candidates`, `venv_bindir`, `is_windows` (Task 1).
- Produces: `PY` (engine python that imports) and `VENV_DIR` as before; new function `bootstrap_venv` (creates the venv, prints the interpreter used, exit 1 on failure); new env override `DOCTOR_OS`.

- [ ] **Step 1: Write the failing tests** — append to section 46 (reuses `$DOCD`, `$STUB`, `doc_settings_wired`, `$NOVENV` from section 33/35):

```bash
# w4. doctor: engine found in a Scripts/ venv; bootstrap works with `python` only
W4="$W/w4"; mkdir -p "$W4/cd" "$W4/venv/Scripts"
printf '#!/bin/sh\nexit 0\n' > "$W4/venv/Scripts/python.exe"; chmod +x "$W4/venv/Scripts/python.exe"
S4="$W4/s.json"; doc_settings_wired "$W4/cd" > "$S4"
out=$(env -u HCAT_PYTHON PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S4" DOCTOR_CLAUDE_DIR="$W4/cd" \
      DOCTOR_VENV_DIR="$W4/venv" bash "$DOCTOR" 2>&1)
check "w4: doctor engine via Scripts/python.exe" "engine python: $W4/venv/Scripts/python.exe" "$out"

# a toolchain with `python` but NO `python3` (typical Windows) — stub creates a Scripts/ venv
W4B="$W/w4boot"; mkdir -p "$W4B/stub" "$W4B/cd"
ln -sf "$(command -v jq)" "$W4B/stub/jq"
cat > "$W4B/stub/python" <<'W4EOF'
#!/bin/sh
if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
  mkdir -p "$3/Scripts"
  printf '#!/bin/sh\necho "$@" >> "$(dirname "$0")/../pip.calls"\n' > "$3/Scripts/pip.exe"
  printf '#!/bin/sh\nexit 0\n' > "$3/Scripts/python.exe"
  chmod +x "$3/Scripts/pip.exe" "$3/Scripts/python.exe"
fi
exit 0
W4EOF
chmod +x "$W4B/stub/python"
S4B="$W4B/s.json"; doc_settings_wired "$W4B/cd" > "$S4B"
out=$(env -u HCAT_PYTHON PATH="$W4B/stub:/usr/bin:/bin" DOCTOR_SETTINGS="$S4B" DOCTOR_CLAUDE_DIR="$W4B/cd" \
      DOCTOR_VENV_DIR="$W4B/venv" DOCTOR_SHIM_DIR="$W4B/shim" bash "$DOCTOR" --fix 2>&1)
check "w4: bootstrap succeeds with python (no python3)" "engine bootstrapped: python -m venv" "$out"
check "w4: bootstrap used Scripts/pip.exe" "install headroom-ai[all]" "$(cat "$W4B/venv/pip.calls" 2>/dev/null)"
# no interpreter at all → honest FAIL naming what was tried
W4N="$W/w4none"; mkdir -p "$W4N/stub" "$W4N/cd"; ln -sf "$(command -v jq)" "$W4N/stub/jq"
S4N="$W4N/s.json"; doc_settings_wired "$W4N/cd" > "$S4N"
out=$(env -u HCAT_PYTHON PATH="$W4N/stub:/usr/bin:/bin" DOCTOR_SETTINGS="$S4N" DOCTOR_CLAUDE_DIR="$W4N/cd" \
      DOCTOR_VENV_DIR="$W4N/venv" bash "$DOCTOR" --fix 2>&1)
check "w4: no interpreter → FAIL names python3/python/py" "python3, python, py -3" "$out"
```

Note: `/usr/bin:/bin` on macOS carries a real `python3`. The stubs must shadow it — the `$STUB`/`$W4B/stub` dirs are first on PATH, but `w4none` has no python at all in its stub dir and `/usr/bin/python3` would be found. Guard that fixture: create `$W4N/stub/python3` and `$W4N/stub/python` as `#!/bin/sh\nexit 1` (present but failing `-m venv`), which is what the FAIL branch must handle anyway.

- [ ] **Step 2: Run to verify it fails**

Run: `./test.sh 2>&1 | grep -E '^(FAIL|ok) - w4'`
Expected: all four `w4` checks FAIL.

- [ ] **Step 3: Edit `scripts/doctor.sh`**

Header line 7 → `#   * engine bootstrap — <python3|python|py -3> -m venv ~/.headroom-venv + pip install "headroom-ai[all]" (bin/ or Scripts/ layout)`. Env docs (after line 32) add:
```
#   DOCTOR_OS          windows|unix — force platform branches (default: detect)
#   DOCTOR_SHIM_DIR    where --fix shims `headroom` (default ~/.local/bin)
#   DOCTOR_CYGPATH     cygpath stub for tests (default: cygpath when present)
```
After the `headroom-state.sh` sourcing loop (line 52) add:
```bash
# shellcheck disable=SC1090,SC1091
for _er in "$SELF_DIR/lib/engine-resolve.sh" "$SELF_DIR/engine-resolve.sh"; do
  [ -f "$_er" ] && { . "$_er"; break; }
done
if ! type engine_python_candidates >/dev/null 2>&1; then
  echo "doctor: scripts/lib/engine-resolve.sh missing — partial plugin checkout; reinstall the plugin" >&2
  exit 1
fi
```
(The doctor is only ever run from a full checkout, so a hard error beats a silent degrade here.)

Replace lines 111-146 (the comment, local `shebang_interp`, and the `PY=""` … `done` / `fi` resolution) with:
```bash
# --- 2. headroom engine python — candidates come from scripts/lib/engine-resolve.sh
# (HCAT_PYTHON authoritative → PATH sibling → shebang interp unless PE → uv tool
# dir → venv bin/ or Scripts/); the first one that imports headroom.compress wins.
PY=""
HCAT_PY_BROKEN=0
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
```

Replace the bootstrap branch (lines 155-170, `elif [ "$FIX" -eq 1 ]; then` … the FAIL) with:
```bash
elif [ "$FIX" -eq 1 ]; then
  venv_preexisted=0; [ -e "$VENV_DIR" ] && venv_preexisted=1
  # interpreter order: POSIX prefers python3; Windows prefers the py launcher and
  # plain python (python3 there is often the Store alias stub that only nags)
  if is_windows; then boot_order="py:-3 python python3"; else boot_order="python3 python py:-3"; fi
  boot_used=""
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
  if [ -n "$boot_used" ] && [ -n "$boot_bindir" ] \
     && [ -x "$VENV_DIR/$boot_bindir/$boot_pip" ] \
     && "$VENV_DIR/$boot_bindir/$boot_pip" install "headroom-ai[all]" >/dev/null 2>&1 \
     && [ -x "$VENV_DIR/$boot_bindir/$boot_py" ] \
     && "$VENV_DIR/$boot_bindir/$boot_py" -c 'import headroom.compress' >/dev/null 2>&1; then
    say fixed "engine bootstrapped: $boot_used -m venv $VENV_DIR + $boot_bindir/$boot_pip install \"headroom-ai[all]\""
    PY="$VENV_DIR/$boot_bindir/$boot_py"
  else
    # never leave a half-created venv behind: its python would pass -x
    # checks elsewhere while pip and the headroom package are missing
    [ "$venv_preexisted" -eq 0 ] && rm -rf "$VENV_DIR"
    hint=""
    command -v apt-get >/dev/null 2>&1 \
      && hint=" (on Debian/Ubuntu, python3 -m venv needs the python3-venv package: sudo apt install python3-venv)"
    say FAIL "engine bootstrap failed (tried python3, python, py -3) — by hand: python3 -m venv $VENV_DIR && $VENV_DIR/bin/pip install \"headroom-ai[all]\"$hint"
  fi
```
Note `PY=` is now set after a successful bootstrap so Task 6's check 2b can shim in the same run. Keep the existing `say skip "hcat smoke (engine missing …)"` behaviour: change check 3's condition at line 181 from `elif [ -z "$PY" ]` to `elif [ -z "$PY" ] || [ -n "$boot_used" ]` with `boot_used=""` initialised before the check-2 block, so a stub-bootstrapped venv is still smoke-tested on the next run, not this one (fixtures' fake python cannot compress).

Also update the fixable line (was 174): `say fixable "engine python not found — --fix creates $VENV_DIR (python3/python/py -3 -m venv) and pip-installs headroom-ai"`.

- [ ] **Step 4: Run the whole suite**

Run: `./test.sh 2>&1 | grep -E '^FAIL'; ./test.sh 2>&1 | tail -1`
Expected: no FAIL. Section 33's bootstrap fixture (`$STUB/python3`, test.sh:658-680, asserting `engine bootstrapped: python3 -m venv`) must still pass — the new message keeps that prefix. F1 doctor test at test.sh:1196 (`engine python: $SPY/python3.14`) still passes via the shebang candidate.

- [ ] **Step 5: Commit**

```bash
git add scripts/doctor.sh test.sh
git commit -m "fix(doctor): engine check via shared resolver; bootstrap tries python3/python/py and both venv layouts (issue #9)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: bare `headroom mcp serve` in .mcp.json; launcher deleted; doctor 4b = shape only

**Files:**
- Modify: `.mcp.json`
- Delete: `scripts/mcp-launcher.sh`
- Modify: `scripts/doctor.sh` lines 21-23 (header), 218-253 (check 4b)
- Modify: `scripts/hcat-gate.sh` line 130 comment (drop `mcp-launcher.sh` mention)
- Modify: `test.sh` — lines 642 (`LAUNCHER=`), 809-858 (32h + 32i), 1171-1174 (F1 launcher), 1930-1948 (F8 as-spawned), 1950-2001 (F8b, F8c), shellcheck list line 2696
- Test: `test.sh` section 46, block "w5"

**Interfaces:**
- Produces: `.mcp.json` = `{"mcpServers":{"headroom":{"type":"stdio","command":"headroom","args":["mcp","serve"],"env":{"HEADROOM_UPDATE_CHECK":"off","HF_HUB_OFFLINE":"1"}}}}`. Doctor 4b prints `ok - .mcp.json spawns \`headroom mcp serve\` by name (needs headroom on PATH — see the CLI check)` or `FAIL - .mcp.json command is '<cmd>' — stale plugin copy…`.

- [ ] **Step 1: Rewrite the existing tests that pin the launcher**

In `test.sh`:
- Delete line 642 (`LAUNCHER=…`).
- Replace 32h (lines 809-840) entirely with:
```bash
# 32h. no launcher any more (v2.8): the MCP is spawned by name, so there must be
# nothing left that a shell-less Windows spawn would choke on
if [ ! -e "$ROOT/scripts/mcp-launcher.sh" ]; then
  echo "ok - launcher: removed (bare command since v2.8)"; PASS=$((PASS+1))
else
  echo "FAIL - launcher: scripts/mcp-launcher.sh still present"; FAIL=$((FAIL+1))
fi
```
- Replace 32i lines 849-858 (`mcp_cmd=` through the end-to-end check) with:
```bash
mcp_cmd=$(jq -r '.mcpServers.headroom.command // empty' "$MCP_JSON" 2>/dev/null)
check_eq "mcp.json: command is the bare name (spawned without a shell on every OS)" "headroom" "$mcp_cmd"
check_eq "mcp.json: args = mcp serve" "mcp serve" "$(jq -r '.mcpServers.headroom.args | join(" ")' "$MCP_JSON" 2>/dev/null)"
check "mcp.json: env update off" "off" "$(jq -r '.mcpServers.headroom.env.HEADROOM_UPDATE_CHECK // empty' "$MCP_JSON" 2>/dev/null)"
check_eq "mcp.json: env hf offline" "1"   "$(jq -r '.mcpServers.headroom.env.HF_HUB_OFFLINE // empty' "$MCP_JSON" 2>/dev/null)"
# end-to-end: the bare name resolves through PATH exactly as a shell-less spawn would
mcp_args=$(jq -r '.mcpServers.headroom.args | join(" ")' "$MCP_JSON")
# shellcheck disable=SC2086
out=$(PATH="$FENG:$PATH" HEADROOM_UPDATE_CHECK=off HF_HUB_OFFLINE=1 "$mcp_cmd" $mcp_args 2>&1)
check "mcp.json: end-to-end launch by name" "launched: mcp serve" "$out"
```
- Delete lines 1171-1174 (F1 `launcher: console-script-only layout` two checks).
- Replace the F8 block that computes `f8_spawn` and asserts "as-spawned is the executable launcher" (find it: `grep -n 'f8_spawn' test.sh`) with:
```bash
check_absent "f8: mcp command carries no path (nothing for a shell-less spawn to mis-resolve)" "/" "$mcp_cmd"
check_absent "f8: mcp command carries no quotes" '"' "$mcp_cmd"
```
  Keep the `f8: hooks.json gate command KEEPS its shell quoting` check.
- Replace F8b (lines 1950-1974) with a stale-copy fixture:
```bash
# F8b: doctor 4b judges the .mcp.json SHAPE — a path-style command is what a
# pre-v2.8 cache copy looks like, and it can never spawn on Windows: FAIL, not
# fixable (there is no launcher left to repair; the fix is a plugin update).
F8B="$REVD/f8b"; mkdir -p "$F8B/root/scripts" "$F8B/root/bin" "$F8B/cd"
cp "$DOCTOR" "$F8B/root/scripts/doctor.sh"; cp -R "$ROOT/scripts/lib" "$F8B/root/scripts/lib"
cp "$HCAT" "$F8B/root/bin/hcat"; cp "$ROOT/hooks" -R "$F8B/root/hooks" 2>/dev/null || cp -R "$ROOT/hooks" "$F8B/root/hooks"
jq -n '{mcpServers:{headroom:{type:"stdio",command:"${CLAUDE_PLUGIN_ROOT}/scripts/mcp-launcher.sh",args:[],env:{}}}}' \
  > "$F8B/root/.mcp.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F8B/settings.json" \
      DOCTOR_CLAUDE_DIR="$F8B/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$F8B/root/scripts/doctor.sh" 2>&1)
check        "f8b: path-style mcp command is FAIL (stale copy)" "stale plugin copy" "$out"
check_absent "f8b: path-style mcp command not greened" ".mcp.json spawns" "$out"
```
- Delete F8c entirely (lines 1976-2001): there is no rewrite left to guard.
- Shellcheck list: remove `"$ROOT/scripts/mcp-launcher.sh"`.

- [ ] **Step 2: Write the new w5 checks** — append to section 46:

```bash
# w5. doctor 4b greens the bare command and names the CLI check
out=$(HCAT_PYTHON="$FENG/python" PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S4" DOCTOR_CLAUDE_DIR="$W4/cd" \
      DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check "w5: 4b ok for bare command" ".mcp.json spawns \`headroom mcp serve\` by name" "$out"
```

- [ ] **Step 3: Run to verify the new/rewritten checks fail**

Run: `./test.sh 2>&1 | grep -E '^FAIL' | head; ./test.sh 2>&1 | tail -1`
Expected: `launcher: removed`, `mcp.json: command is the bare name`, `mcp.json: args`, `f8b: …`, `w5: …` FAIL.

- [ ] **Step 4: Change `.mcp.json`**

```json
{
  "mcpServers": {
    "headroom": {
      "type": "stdio",
      "command": "headroom",
      "args": ["mcp", "serve"],
      "env": {
        "HEADROOM_UPDATE_CHECK": "off",
        "HF_HUB_OFFLINE": "1"
      }
    }
  }
}
```

- [ ] **Step 5: `git rm scripts/mcp-launcher.sh`** and edit `scripts/hcat-gate.sh` line 130 comment to `(see doctor.sh/bin/hcat)`.

- [ ] **Step 6: Rewrite doctor check 4b** (lines 218-253) with:

```bash
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
```
Header lines 21-23 → `#   * (removed in v2.8) quoted mcp cmd — .mcp.json now names the bare \`headroom\`; nothing to rewrite`.

- [ ] **Step 7: Run the whole suite**

Run: `./test.sh 2>&1 | grep -E '^FAIL'; ./test.sh 2>&1 | tail -1`
Expected: no FAIL.

- [ ] **Step 8: Commit**

```bash
git add -A .mcp.json scripts/mcp-launcher.sh scripts/doctor.sh scripts/hcat-gate.sh test.sh
git commit -m "feat(mcp): spawn headroom by name — no launcher script, works on Windows (issue #9)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: doctor check 2b — shim `headroom` onto PATH and verify

**Files:**
- Modify: `scripts/doctor.sh` — new block after the bootstrap (before `# --- 3. bin/hcat`), header fix list, `SHIM_DIR` var near line 43
- Test: `test.sh` section 46, block "w6"

**Interfaces:**
- Consumes: `resolve_headroom_cli`, `is_windows` (Task 1); `PY` from Task 4.
- Produces: `SHIM_DIR=${DOCTOR_SHIM_DIR:-$HOME/.local/bin}`; functions `shim_headroom <cli>` (prints shim path), `path_hint`; check lines:
  - `ok - headroom CLI on PATH (<path>) — the bundled MCP spawns it by name (verified in this Bash environment, the closest proxy for Claude Code's MCP spawn env)`
  - `fixable - headroom CLI not on PATH (engine at <cli>) — the bundled MCP spawns \`headroom\` by name; --fix shims it into <SHIM_DIR>`
  - `fixed - headroom shimmed to <shim> (resolves on PATH)`
  - `FAIL - headroom shimmed to <shim> but <SHIM_DIR> is not on PATH — <hint>`
  - `skip - headroom CLI on PATH (no engine yet — fix the engine first)`

- [ ] **Step 1: Write the failing tests** — append to section 46:

```bash
# w6. check 2b: shim + verify
W6="$W/w6"; mkdir -p "$W6/cd" "$W6/venv/bin" "$W6/shim"
printf '#!/bin/sh\nexit 0\n' > "$W6/venv/bin/python";   chmod +x "$W6/venv/bin/python"
printf '#!/bin/sh\necho hr\n' > "$W6/venv/bin/headroom"; chmod +x "$W6/venv/bin/headroom"
S6="$W6/s.json"; doc_settings_wired "$W6/cd" > "$S6"
# engine found in the venv, headroom NOT on PATH → fixable
out=$(env -u HCAT_PYTHON PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S6" DOCTOR_CLAUDE_DIR="$W6/cd" \
      DOCTOR_VENV_DIR="$W6/venv" DOCTOR_SHIM_DIR="$W6/shim" bash "$DOCTOR" 2>&1)
check "w6: CLI off PATH is fixable" "headroom CLI not on PATH (engine at $W6/venv/bin/headroom)" "$out"
# --fix with the shim dir ON PATH → fixed, shim is a symlink to the venv CLI
out=$(env -u HCAT_PYTHON PATH="$W6/shim:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S6" DOCTOR_CLAUDE_DIR="$W6/cd" \
      DOCTOR_VENV_DIR="$W6/venv" DOCTOR_SHIM_DIR="$W6/shim" bash "$DOCTOR" --fix 2>&1)
check "w6: --fix shims and verifies" "headroom shimmed to $W6/shim/headroom (resolves on PATH)" "$out"
check_eq "w6: shim is a symlink to the venv CLI" "$W6/venv/bin/headroom" "$(readlink "$W6/shim/headroom")"
# second run: ok, no change
out=$(env -u HCAT_PYTHON PATH="$W6/shim:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S6" DOCTOR_CLAUDE_DIR="$W6/cd" \
      DOCTOR_VENV_DIR="$W6/venv" DOCTOR_SHIM_DIR="$W6/shim" bash "$DOCTOR" --fix 2>&1)
check "w6: second --fix reports ok" "headroom CLI on PATH ($W6/shim/headroom)" "$out"
check_absent "w6: second --fix does not re-shim" "headroom shimmed" "$out"
# --fix with the shim dir NOT on PATH → FAIL with the exact snippet
W6N="$W/w6nopath"; mkdir -p "$W6N/cd" "$W6N/shim"
S6N="$W6N/s.json"; doc_settings_wired "$W6N/cd" > "$S6N"
out=$(env -u HCAT_PYTHON SHELL=/bin/zsh PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S6N" DOCTOR_CLAUDE_DIR="$W6N/cd" \
      DOCTOR_VENV_DIR="$W6/venv" DOCTOR_SHIM_DIR="$W6N/shim" bash "$DOCTOR" --fix 2>&1); rc=$?
check "w6: unresolved after shim is FAIL" "but $W6N/shim is not on PATH" "$out"
check "w6: FAIL carries the zsh snippet" "export PATH=\"$W6N/shim:\$PATH\"' >> ~/.zshrc" "$out"
check_eq "w6: doctor exits 1 on that FAIL" "1" "$rc"
# Windows: the shim is a COPY named headroom.exe and the hint names the user Path
W6W="$W/w6win"; mkdir -p "$W6W/cd" "$W6W/venv/Scripts" "$W6W/shim"
printf '#!/bin/sh\nexit 0\n' > "$W6W/venv/Scripts/python.exe";  chmod +x "$W6W/venv/Scripts/python.exe"
printf '#!/bin/sh\necho hr\n' > "$W6W/venv/Scripts/headroom.exe"; chmod +x "$W6W/venv/Scripts/headroom.exe"
S6W="$W6W/s.json"; doc_settings_wired "$W6W/cd" > "$S6W"
out=$(env -u HCAT_PYTHON DOCTOR_OS=windows PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S6W" DOCTOR_CLAUDE_DIR="$W6W/cd" \
      DOCTOR_VENV_DIR="$W6W/venv" DOCTOR_SHIM_DIR="$W6W/shim" bash "$DOCTOR" --fix 2>&1)
if [ -f "$W6W/shim/headroom.exe" ] && [ ! -L "$W6W/shim/headroom.exe" ]; then
  echo "ok - w6: windows shim is a copy named headroom.exe"; PASS=$((PASS+1))
else
  echo "FAIL - w6: windows shim is a copy named headroom.exe"; FAIL=$((FAIL+1))
fi
check "w6: windows hint names the user Path" '%USERPROFILE%\.local\bin' "$out"
# no engine at all → skip (check 2 already says fixable)
out=$(env -u HCAT_PYTHON PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S6N" DOCTOR_CLAUDE_DIR="$W6N/cd" \
      DOCTOR_VENV_DIR="$W/none" DOCTOR_SHIM_DIR="$W6N/shim2" bash "$DOCTOR" 2>&1)
check "w6: no engine → CLI check skips" "headroom CLI on PATH (no engine yet" "$out"
```

- [ ] **Step 2: Run to verify it fails**

Run: `./test.sh 2>&1 | grep -E '^(FAIL|ok) - w6'`
Expected: all w6 FAIL.

- [ ] **Step 3: Implement in `scripts/doctor.sh`**

Near line 43 add `SHIM_DIR=${DOCTOR_SHIM_DIR:-${HOME:-}/.local/bin}`. Header fix list add:
```
#   * headroom on PATH — shim the resolved `headroom` CLI into ~/.local/bin
#                        (symlink; a copy of headroom.exe on Windows) so the
#                        bundled .mcp.json's bare command resolves; verified
#                        afterwards, FAIL with the PATH snippet if it still doesn't
```
Insert after the check-2 block (just before `# --- 3. bin/hcat`):
```bash
# --- 2b. `headroom` on PATH — .mcp.json spawns the bare name (no shell, no launcher)
shim_headroom() {  # shim_headroom <cli> — link/copy into SHIM_DIR; prints the shim path
  mkdir -p "$SHIM_DIR" 2>/dev/null || return 1
  if is_windows; then
    cp "$1" "$SHIM_DIR/headroom.exe" 2>/dev/null && printf '%s' "$SHIM_DIR/headroom.exe"
  else
    ln -sfn "$1" "$SHIM_DIR/headroom" 2>/dev/null && printf '%s' "$SHIM_DIR/headroom"
  fi
}
path_hint() {  # the one line the user must run/do to put SHIM_DIR on PATH
  local rc
  if is_windows; then
    printf 'add %%USERPROFILE%%\\.local\\bin to your user Path (Settings → System → About → Advanced system settings → Environment Variables), then restart Claude Code'
  else
    case "${SHELL:-}" in *zsh) rc="~/.zshrc" ;; *) rc="~/.bashrc" ;; esac
    printf "run: echo 'export PATH=\"%s:\$PATH\"' >> %s — then restart Claude Code" "$SHIM_DIR" "$rc"
  fi
}
if cli_now=$(command -v headroom 2>/dev/null) && [ -n "$cli_now" ]; then
  say ok "headroom CLI on PATH ($cli_now) — the bundled MCP spawns it by name (verified in this Bash environment, the closest proxy for Claude Code's MCP spawn env)"
elif cli_res=$(resolve_headroom_cli); then
  if [ "$FIX" -eq 1 ]; then
    if shim=$(shim_headroom "$cli_res"); then
      hash -r 2>/dev/null
      if command -v headroom >/dev/null 2>&1; then
        say fixed "headroom shimmed to $shim (resolves on PATH)"
      else
        say FAIL "headroom shimmed to $shim but $SHIM_DIR is not on PATH — $(path_hint)"
      fi
    else
      say FAIL "could not shim $cli_res into $SHIM_DIR"
    fi
  else
    say fixable "headroom CLI not on PATH (engine at $cli_res) — the bundled MCP spawns \`headroom\` by name; --fix shims it into $SHIM_DIR"
  fi
elif [ -z "$PY" ]; then
  say skip "headroom CLI on PATH (no engine yet — fix the engine first)"
else
  say FAIL "engine python found ($PY) but no \`headroom\` CLI next to it — reinstall: $PY -m pip install \"headroom-ai[all]\""
fi
```
The `%USERPROFILE%` in `printf` must be written `%%USERPROFILE%%` (as above) so printf does not eat it.

- [ ] **Step 4: Run the whole suite**

Run: `./test.sh 2>&1 | grep -E '^FAIL'; ./test.sh 2>&1 | tail -1`
Expected: no FAIL. Watch section 33's healthy-run fixtures (32a etc.): they run with `$FENG` NOT on PATH and `HCAT_PYTHON="$HEADROOM_PY"`; on this Mac `headroom` is on PATH via the real install so 2b is `ok`. If any older fixture now shows a `fixable` where it asserted a fully clean run (e.g. block-9 all-clear tests in section 38 that require `FIXABLE=0`), add `PATH="$FENG:$PATH"` to that fixture's env so `headroom` resolves — the fixture's intent (a clean install) is preserved.

- [ ] **Step 5: Commit**

```bash
git add scripts/doctor.sh test.sh
git commit -m "feat(doctor): check 2b shims headroom onto PATH and verifies it resolves (issue #9)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Git Bash prerequisite + Windows status-line wiring + backslash tokens

**Files:**
- Modify: `scripts/doctor.sh` — new check 0 before check 1; check 7 token loop (lines 410-443); wiring command at line 558 and the SKILL-parity comment
- Modify: `scripts/session-probe.sh` — Git Bash env check next to the jq check
- Test: `test.sh` section 46, block "w7"

**Interfaces:**
- Consumes: `is_windows`, `win_path`, `unix_path` (Task 1).
- Produces: function `sl_hr_cmd <script-path>` → `bash "<path>"` on POSIX; `"<bash.exe>" "<C:\…\headroom-statusline.sh>"` on Windows (bash from `$CLAUDE_CODE_GIT_BASH_PATH`, else `win_path "$(command -v bash)"`). Check 0 line: `ok - Windows (Git Bash) — hooks and the status line run through it` or `FAIL - CLAUDE_CODE_GIT_BASH_PATH points at a missing file (<p>) — Git for Windows is required: hooks and the status line run through Git Bash`.

- [ ] **Step 1: Write the failing tests** — append to section 46:

```bash
# w7. Windows status-line wiring + Git Bash prerequisite
W7="$W/w7"; mkdir -p "$W7/cd" "$W7/bashdir"
printf '#!/bin/sh\nexit 0\n' > "$W7/bashdir/bash.exe"; chmod +x "$W7/bashdir/bash.exe"
S7="$W7/s.json"; printf '{}\n' > "$S7"
out=$(env -u HCAT_PYTHON DOCTOR_OS=windows DOCTOR_CYGPATH="$W/cygpath" CLAUDE_CODE_GIT_BASH_PATH='C:\Git\bin\bash.exe' \
      PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S7" DOCTOR_CLAUDE_DIR="$W7/cd" DOCTOR_VENV_DIR="$NOVENV" \
      DOCTOR_SHIM_DIR="$W7/shim" bash "$DOCTOR" --fix 2>&1)
check "w7: windows wire reports fixed" "statusLine wired to" "$out"
check_eq "w7: windows statusLine command shape" '"C:\Git\bin\bash.exe" "C:\fake\headroom-statusline.sh"' \
  "$(jq -r '.statusLine.command' "$S7")"
check "w7: doctor names Git Bash on Windows" "Windows (Git Bash)" "$out"
# re-run: check 7 must recognise the backslash token as the canonical copy (no re-wire, no FAIL)
out=$(env -u HCAT_PYTHON DOCTOR_OS=windows DOCTOR_CYGPATH="$W/cygpath" CLAUDE_CODE_GIT_BASH_PATH='C:\Git\bin\bash.exe' \
      PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S7" DOCTOR_CLAUDE_DIR="$W7/cd" DOCTOR_VENV_DIR="$NOVENV" \
      DOCTOR_SHIM_DIR="$W7/shim" bash "$DOCTOR" 2>&1)
check "w7: re-run sees the wiring as healthy" "statusLine wired (" "$out"
check_absent "w7: re-run does not FAIL the windows path" "no such file exists" "$out"
# CLAUDE_CODE_GIT_BASH_PATH pointing nowhere → FAIL
out=$(env -u HCAT_PYTHON DOCTOR_OS=windows CLAUDE_CODE_GIT_BASH_PATH="$W7/missing/bash.exe" PATH="$FENG:$STUB:/usr/bin:/bin" \
      DOCTOR_SETTINGS="$S7" DOCTOR_CLAUDE_DIR="$W7/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check "w7: broken CLAUDE_CODE_GIT_BASH_PATH is FAIL" "Git for Windows is required" "$out"
# probe: same prerequisite, one problem line
out=$(printf '{"session_id":"w7"}' | env -u HCAT_PYTHON DOCTOR_OS=windows CLAUDE_CODE_GIT_BASH_PATH="$W7/missing/bash.exe" \
      HOME="$W7" HEADROOM_STATE_DIR="$W7/state" bash "$PROBE")
check "w7: probe flags a broken Git Bash path" "Git Bash" "$out"
# POSIX wiring unchanged
S7U="$W7/su.json"; printf '{}\n' > "$S7U"
env -u HCAT_PYTHON DOCTOR_OS=unix PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S7U" DOCTOR_CLAUDE_DIR="$W7/cdu" \
  DOCTOR_VENV_DIR="$NOVENV" DOCTOR_SHIM_DIR="$W7/shim" bash "$DOCTOR" --fix >/dev/null 2>&1
check_eq "w7: posix statusLine command unchanged" "bash \"$W7/cdu/headroom-statusline.sh\"" "$(jq -r '.statusLine.command' "$S7U")"
```
Note: the stub `cygpath -w` returns `C:\fake\<basename>` and `-u` returns `/c/fake/<basename>`, so the canonical comparison in check 7 must go through `unix_path` and then match on basename+`$CLAUDE_DIR` — see Step 3 for how the token is mapped back: `unix_path` on `C:\fake\headroom-statusline.sh` yields `/c/fake/headroom-statusline.sh`, which is not `$CLAUDE_DIR/…`. To keep the fixture honest, make the stub's `-u` branch echo `"$CYGPATH_UNIX_DIR/$(basename "$2")"` and export `CYGPATH_UNIX_DIR="$W7/cd"` in the w7 env (update the stub in Task 1's fixture: `-u) echo "${CYGPATH_UNIX_DIR:-/c/fake}/$(basename "$2")";;`; the Task 1 assertion for `unix_path` stays valid because `CYGPATH_UNIX_DIR` is unset there).

- [ ] **Step 2: Run to verify it fails**

Run: `./test.sh 2>&1 | grep -E '^(FAIL|ok) - w7'`
Expected: all w7 FAIL except `posix statusLine command unchanged`.

- [ ] **Step 3: Implement**

`scripts/doctor.sh`, before `# --- 1. jq` insert:
```bash
# --- 0. platform — on Windows every hook and the status line run through Git Bash
if is_windows; then
  if [ -n "${CLAUDE_CODE_GIT_BASH_PATH:-}" ] && [ ! -f "$CLAUDE_CODE_GIT_BASH_PATH" ]; then
    say FAIL "CLAUDE_CODE_GIT_BASH_PATH points at a missing file ($CLAUDE_CODE_GIT_BASH_PATH) — Git for Windows is required: hooks and the status line run through Git Bash"
  else
    say ok "Windows (Git Bash) — hooks and the status line run through it"
  fi
fi
```
Add next to `path_hint` (Task 6 block) or just above check 7:
```bash
sl_hr_cmd() {  # sl_hr_cmd <script> — the statusLine.command to write for this platform
  local b
  if is_windows; then
    b=${CLAUDE_CODE_GIT_BASH_PATH:-}
    [ -n "$b" ] || b=$(win_path "$(command -v bash)")
    printf '"%s" "%s"' "$b" "$(win_path "$1")"
  else
    printf 'bash "%s"' "$1"
  fi
}
```
Line 558: `jq --arg hr "bash \"$sl_path\""` → `jq --arg hr "$(sl_hr_cmd "$sl_path")"`.

Check 7 token loop: change the extraction on line 443 from `grep -oE "[^\"' ]+"` to `grep -oE "[^\"']+"` ONLY for tokens inside quotes is not possible with one regex; instead pre-split: replace line 443 with
```bash
    done < <(printf '%s\n' "$sl" | grep -oE "\"[^\"]*\"|'[^']*'|[^\"' ]+" | sed -e "s/^[\"']//" -e "s/[\"']\$//")
```
(quoted spans become whole tokens, so `C:\Program Files\Git\bin\bash.exe` survives as one token; unquoted words split on spaces as before). Extend the case at lines 413-416:
```bash
      case $sl_tok in
        "~/"*headroom-statusline.sh | /*headroom-statusline.sh) ;;
        [A-Za-z]:[\\/]*headroom-statusline.sh) sl_tok=$(unix_path "$sl_tok") ;;
        *) continue ;;
      esac
```
Because `sl_tok` is now the unix form, the rest of the loop (`sl_cand=$sl_tok`, canonical comparison against `$CLAUDE_DIR/headroom-statusline.sh`, existence test) works unchanged. Also the `case $sl in *\"$sl_raw\"*)` respelling test compares `sl_raw` (unix form) against the raw command — for a Windows token that never matches, so it correctly falls into the "unquoted/nothing to rewrite" arm.

`scripts/session-probe.sh`: source the resolver lib (same loop + a `type is_windows … || is_windows() { return 1; }` fallback) and after the jq check add:
```bash
# --- 1b. Windows: hooks and the badge run through Git Bash; a stale override is an outage
if is_windows && [ -n "${CLAUDE_CODE_GIT_BASH_PATH:-}" ] && [ ! -f "$CLAUDE_CODE_GIT_BASH_PATH" ]; then
  note_error install "CLAUDE_CODE_GIT_BASH_PATH points at a missing file"
  add_problem "CLAUDE_CODE_GIT_BASH_PATH points at a missing Git Bash ($CLAUDE_CODE_GIT_BASH_PATH) — fix it in settings.json env"
fi
```

- [ ] **Step 4: Run the whole suite**

Run: `./test.sh 2>&1 | grep -E '^FAIL'; ./test.sh 2>&1 | tail -1`
Expected: no FAIL. Sections 35 F7* (tilde respelling, custom path, `.bak` sibling token) must all still pass with the new tokenizer; if `F7…headroom-statusline.sh.bak` regresses, the quoted-span token still ends in `.bak`, so the case pattern rejects it exactly as before.

- [ ] **Step 5: Commit**

```bash
git add scripts/doctor.sh scripts/session-probe.sh test.sh
git commit -m "feat(doctor): Windows status-line wiring via Git Bash + cygpath; Git Bash prerequisite check (issue #9)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: installers copy the new lib; SKILL docs disclose the shim; parity checks

**Files:**
- Modify: `skills/headroom-usage-indicator/SKILL.md` lines 95 and 174 (lib tuples) + the `HCAT_PYTHON` note at line 297
- Modify: `skills/doctor/SKILL.md` — overview paragraph (lines ~5-30), fixable list (lines 67-100), consent list (lines 122-135)
- Modify: `scripts/doctor.sh` 7c loop (line 621) — no: 7c is statusline-only; leave it. Instead check 4 (`hooks.json`) gets a sibling check that `scripts/lib/engine-resolve.sh` exists in the plugin root (partial checkout guard already exits early in Task 4 — so nothing more here).
- Test: `test.sh` — the 32j parity block (lines 860-878) gains three checks

- [ ] **Step 1: Write the failing parity checks** — after line 877 add:

```bash
check "doctor skill: consent list names the headroom shim"        "shim"                    "$(cat "$DSKILL" 2>/dev/null)"
check "doctor skill: fixable list covers headroom not on PATH"    "headroom CLI not on PATH" "$(cat "$DSKILL" 2>/dev/null)"
check_absent "doctor skill: no launcher left in the doctor docs"  "mcp-launcher"            "$(cat "$DSKILL" 2>/dev/null)"
check "installer skill: legacy installer copies engine-resolve.sh" "engine-resolve.sh"       "$(cat "$ROOT/skills/headroom-usage-indicator/SKILL.md" 2>/dev/null)"
```

- [ ] **Step 2: Run to verify it fails** — `./test.sh 2>&1 | grep -E '^FAIL'` → the four new checks (the `mcp-launcher` absence and `shim` presence at least).

- [ ] **Step 3: Edit `skills/headroom-usage-indicator/SKILL.md`**

Line 95: `for _lib in ("attribution.jq", "headroom-state.sh", "engine-resolve.sh"):`
Line 174: `for _lib in ("headroom-state.sh", "attribution.jq", "engine-resolve.sh"):`
Line 297 (`HCAT_PYTHON` note): append ` On Windows the venv interpreter is `~/.headroom-venv/Scripts/python.exe`; the resolver (`scripts/lib/engine-resolve.sh`) tries both layouts plus uv tool installs.`

- [ ] **Step 4: Edit `skills/doctor/SKILL.md`**

In the overview paragraph replace the `.mcp.json` sentence (`the bundled .mcp.json (parses and its launcher is executable exactly as spawned … --fix unquotes it in place)`) with: `the bundled .mcp.json (parses and names the bare \`headroom mcp serve\` command — since v2.8 there is no launcher script, because MCP stdio commands are spawned without a shell and Windows cannot run a .sh that way), that \`headroom\` actually resolves on PATH (check 2b — the bundled MCP is spawned by name; --fix shims the resolved CLI into ~/.local/bin and re-verifies)`. Add to the same paragraph: `On Windows the doctor also confirms it is running under Git Bash (a stale CLAUDE_CODE_GIT_BASH_PATH is FAIL) and writes the status-line command with explicit Windows paths ("C:\…\bash.exe" "C:\…\headroom-statusline.sh").`

Fixable list: replace the `quoted .mcp.json command` bullet (lines 97-100) with:
```
  - headroom CLI not on PATH (engine found, bare name unresolved) → the
    resolved `headroom` is shimmed into `~/.local/bin` (symlink; on Windows a
    copy named `headroom.exe`), then re-checked — if `~/.local/bin` is not on
    PATH the line turns `FAIL` and carries the exact one-line PATH addition for
    your shell (or the Windows user Path steps); the doctor never edits rc
    files or the registry
```
Also change the `engine missing` bullet to: `engine missing → bootstrap a venv at ~/.headroom-venv (python3, python, or py -3 — whichever works; bin/ or Scripts/ layout) + pip install "headroom-ai[all]", then shim headroom onto PATH as above`.

Consent list (line 127): replace `may rewrite the plugin's bundled .mcp.json in place to unquote its command, with its own timestamped backup;` with `may create or replace a \`headroom\` shim in \`~/.local/bin\` (symlink; \`headroom.exe\` copy on Windows);`.

- [ ] **Step 5: Run the whole suite** — `./test.sh 2>&1 | grep -E '^FAIL'; ./test.sh 2>&1 | tail -1` → no FAIL.

- [ ] **Step 6: Commit**

```bash
git add skills test.sh
git commit -m "docs(skills): disclose the headroom shim, drop the launcher, copy engine-resolve.sh in legacy installs (issue #9)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: CI — ubuntu/macos suite + windows-latest real-engine job

**Files:**
- Create: `.github/workflows/test.yml`
- Create: `scripts/ci/windows-check.sh`
- Create: `scripts/ci/spawn-probe.mjs`
- Test: `test.sh` section 46 block "w9" (shape checks: workflow parses and names the jobs; shellcheck covers `windows-check.sh`)

**Interfaces:**
- Consumes: everything above.
- Produces: required CI checks `test (ubuntu-latest)`, `test (macos-latest)`, `windows`.

- [ ] **Step 1: Write the failing shape checks** — append to section 46:

```bash
# w9. CI files exist and are well-formed
WF="$ROOT/.github/workflows/test.yml"
check "w9: workflow has a windows-latest job" "windows-latest" "$(cat "$WF" 2>/dev/null)"
check "w9: workflow runs the suite on ubuntu+macos" "macos-latest" "$(cat "$WF" 2>/dev/null)"
check "w9: windows job runs windows-check.sh" "scripts/ci/windows-check.sh" "$(cat "$WF" 2>/dev/null)"
check "w9: spawn probe exists" "child_process" "$(cat "$ROOT/scripts/ci/spawn-probe.mjs" 2>/dev/null)"
if [ -x "$ROOT/scripts/ci/windows-check.sh" ]; then echo "ok - w9: windows-check.sh executable"; PASS=$((PASS+1)); else echo "FAIL - w9: windows-check.sh executable"; FAIL=$((FAIL+1)); fi
```
Add `"$ROOT/scripts/ci/windows-check.sh"` to the shellcheck list.

- [ ] **Step 2: Run to verify it fails** — the five w9 checks FAIL.

- [ ] **Step 3: Create `scripts/ci/spawn-probe.mjs`**

```js
// spawn-probe.mjs — CI-only. Spawns an MCP stdio server WITHOUT a shell (the way
// Claude Code's MCP client does), sends `initialize`, and exits 0 only when a
// JSON-RPC result comes back. Usage: node spawn-probe.mjs <command> [args...]
// Exit: 0 handshake ok · 2 process exited early · 3 spawn error · 4 timeout
import { spawn } from "node:child_process";

const [cmd, ...args] = process.argv.slice(2);
if (!cmd) { console.error("usage: spawn-probe.mjs <command> [args...]"); process.exit(1); }

const child = spawn(cmd, args, {
  shell: false,
  stdio: ["pipe", "pipe", "inherit"],
  env: { ...process.env, HEADROOM_UPDATE_CHECK: "off", HF_HUB_OFFLINE: "1" },
});
const done = (code, msg) => { if (msg) console.error(msg); try { child.kill(); } catch {} process.exit(code); };
child.on("error", (e) => done(3, `spawn error: ${e.code || e.message}`));
child.on("exit", (code) => done(2, `server exited early (code ${code})`));
let buf = "";
child.stdout.on("data", (d) => {
  buf += d.toString();
  if (buf.includes('"result"')) { console.log("initialize ok"); done(0); }
});
const init = { jsonrpc: "2.0", id: 1, method: "initialize",
  params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "spawn-probe", version: "0" } } };
child.stdin.write(JSON.stringify(init) + "\n");
setTimeout(() => done(4, "timeout waiting for initialize result"), 20000);
```

- [ ] **Step 4: Create `scripts/ci/windows-check.sh`** (run under Git Bash on the runner)

```bash
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
printf '%s\n' "$cmd" > "$TMPD/statusline.cmd"   # consumed by the PowerShell step

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```
`chmod +x scripts/ci/windows-check.sh`.

- [ ] **Step 5: Create `.github/workflows/test.yml`**

```yaml
name: test
on:
  push: { branches: [main] }
  pull_request:
jobs:
  test:
    strategy:
      fail-fast: false
      matrix: { os: [ubuntu-latest, macos-latest] }
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - name: deps
        run: |
          if command -v apt-get >/dev/null; then sudo apt-get update -q && sudo apt-get install -y -q jq shellcheck; else brew install jq shellcheck; fi
      - run: ./test.sh
  windows:
    runs-on: windows-latest
    defaults: { run: { shell: bash } }
    env:
      VENV_DIR: ${{ github.workspace }}\\.headroom-venv
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }
      - name: real engine (venv + uv tool)
        run: |
          python -m venv "$VENV_DIR"
          "$VENV_DIR/Scripts/python.exe" -m pip install -q "headroom-ai[all]" || "$VENV_DIR/Scripts/python.exe" -m pip install -q headroom-ai
          "$VENV_DIR/Scripts/python.exe" -c "import headroom.compress; print('engine ok')"
          pip install -q uv && (uv tool install headroom-ai || echo "uv tool install failed (non-fatal)")
      - name: windows-check (required gate)
        run: VENV_DIR="$(cygpath -u "$VENV_DIR")" bash scripts/ci/windows-check.sh
      - name: MCP spawn probe (shell-less, by name) + negative control
        shell: pwsh
        run: |
          $env:PATH = "$env:VENV_DIR\Scripts;" + $env:PATH
          node scripts/ci/spawn-probe.mjs headroom mcp serve
          if ($LASTEXITCODE -ne 0) { throw "bare 'headroom mcp serve' failed to spawn/handshake ($LASTEXITCODE)" }
          node scripts/ci/spawn-probe.mjs "$PWD\scripts\session-probe.sh"
          if ($LASTEXITCODE -eq 0) { throw "negative control: a .sh spawned without a shell should NOT work" }
          Write-Host "negative control ok (exit $LASTEXITCODE)"
      - name: status line runs from PowerShell with the command doctor wrote
        shell: pwsh
        run: |
          $cmd = Get-Content (Get-ChildItem -Recurse -Filter statusline.cmd $env:TEMP | Select-Object -First 1).FullName
          Write-Host "command: $cmd"
          $json = '{"transcript_path":"","model":{"id":"claude-opus-4-8"},"session_id":"ci"}'
          $out = $json | cmd /c $cmd
          Write-Host "badge: $out"
          if (-not $out) { throw "status line printed nothing" }
      - name: full suite (informational on Windows)
        continue-on-error: true
        run: ./test.sh 2>&1 | tail -40
```
Note on the status-line step: `windows-check.sh` writes `statusline.cmd` under `mktemp -d`, which on Git Bash lives under `$TEMP`; if `Get-ChildItem` cannot find it, change `windows-check.sh` to write it to `$ROOT/statusline.cmd` instead and read `./statusline.cmd` here (and add it to `.gitignore`).

- [ ] **Step 6: Run local checks**

Run: `./test.sh 2>&1 | grep -E '^FAIL'; ./test.sh 2>&1 | tail -1; node --check scripts/ci/spawn-probe.mjs && echo probe-syntax-ok; shellcheck --severity=warning scripts/ci/windows-check.sh && echo sc-ok`
Expected: no FAIL; `probe-syntax-ok`; `sc-ok`. Also run the probe locally against the real engine as a sanity check: `node scripts/ci/spawn-probe.mjs headroom mcp serve` → `initialize ok`, exit 0; and `node scripts/ci/spawn-probe.mjs /nonexistent.sh; echo $?` → `3`.

- [ ] **Step 7: Commit and push the branch to see CI**

```bash
git add .github scripts/ci test.sh
git commit -m "ci: run the suite on ubuntu/macos and a real-engine Windows gate (issue #9)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push -u origin fix/issue-9-windows
gh run watch --exit-status   # or: gh run list --branch fix/issue-9-windows
```
Expected: three jobs green. If the Windows job fails, read the log (`gh run view --log-failed`), fix in a follow-up commit — do NOT weaken an assertion to make it pass; the assertions are the point.

---

### Task 10: README, manifests, PR, issue comment

**Files:**
- Modify: `README.md` (table rows 139-142, line 164-166 Updating, line 234 legacy appendix, lines 244+246 What's inside, new `## Windows` section after `## Updating`)
- Modify: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` → `2.8.0`
- Modify: `docs/superpowers/specs/2026-09-17-windows-support-design.md` — §4 note that the Windows required gate is `windows-check.sh`, full suite informational

- [ ] **Step 1: Write the failing docs checks** — append to section 46:

```bash
# w10. docs + manifests
check "w10: README has a Windows section"      "## Windows"           "$(cat "$ROOT/README.md")"
check "w10: README names Git Bash prerequisite" "Git for Windows"     "$(cat "$ROOT/README.md")"
check "w10: README upgrade note for the shim"   "headroom on PATH"    "$(cat "$ROOT/README.md")"
check_absent "w10: README no launcher"          "mcp-launcher"        "$(cat "$ROOT/README.md")"
check_eq "w10: plugin.json 2.8.0"      "2.8.0" "$(jq -r .version "$ROOT/.claude-plugin/plugin.json")"
check_eq "w10: marketplace.json 2.8.0" "2.8.0" "$(jq -r '.plugins[0].version // .version' "$ROOT/.claude-plugin/marketplace.json")"
```
(Confirm the marketplace.json version path with `jq . .claude-plugin/marketplace.json` first and fix the filter if it differs.)

- [ ] **Step 2: Run to verify it fails** — the six w10 checks FAIL.

- [ ] **Step 3: Edit README.md**

Table row 141 → `| headroom MCP registration | \`.mcp.json\` inside the plugin | bundled; spawns \`headroom mcp serve\` by name — the doctor makes sure \`headroom\` is on PATH |`.
Line 142 → `| headroom engine (Python) | \`~/.headroom-venv\` (or your own install: pip, pipx, uv) | the doctor bootstraps it with your consent and shims \`headroom\` into \`~/.local/bin\` |`.
After the "Updating" section's last paragraph (line 166) add:
```markdown
**Coming from v2.7.4 or earlier, run `/headroom-usage-indicator:doctor --fix` once more** — v2.8 spawns the bundled MCP by its bare name, so `headroom` must be on PATH. If the doctor bootstrapped your engine into `~/.headroom-venv`, `--fix` shims it into `~/.local/bin` and tells you the one line to add to your shell rc if that directory isn't on PATH yet.

## Windows

Works under **Git for Windows (Git Bash)** — Claude Code runs its hooks and the status line through it, so it is a hard prerequisite (PowerShell-only setups are not supported). Then:

1. `winget install jqlang.jq` and a Python 3.10+ (`winget install Python.Python.3.12`, or `uv`).
2. Install the plugin as in the Quickstart and run `/headroom-usage-indicator:doctor --fix`. The doctor finds a venv in the `Scripts\` layout, `uv tool install headroom-ai` trampolines and pip's `headroom.exe` launchers, bootstraps a venv with `py -3`/`python` if nothing is installed, shims `headroom.exe` into `%USERPROFILE%\.local\bin`, and writes the status line as `"C:\…\Git\bin\bash.exe" "C:\Users\you\.claude\headroom-statusline.sh"`.
3. If the doctor ends with *`…\.local\bin is not on PATH`*, add that directory to your user **Path** (Settings → System → About → Advanced system settings → Environment Variables) and restart Claude Code. Installing the engine with `uv tool install headroom-ai` or `pipx` instead puts `headroom` on PATH for you.

`hcat` output is UTF-8 on every platform (`PYTHONIOENCODING=utf-8`). Desktop notifications from Dangi are macOS/Linux only for now. CI runs the resolver, `hcat`, the doctor and a shell-less MCP spawn on a real `windows-latest` runner — what it cannot run is Claude Code itself; see [#9](https://github.com/Abhi902/headroom-plugin/issues/9).
```
Line 234 (legacy appendix): `You must also install the **headroom engine** yourself (→ https://github.com/headroomlabs-ai/headroom) — the plugin's \`.mcp.json\` spawns \`headroom mcp serve\` by name, so it must be on PATH — and you need \`jq\`…`.
Line 244: drop `\`mcp-launcher.sh\`` from the list; add `\`engine-resolve.sh\`` to the `scripts/lib/` list. Line 246 → `` `.mcp.json` — bundled headroom MCP server definition (`headroom mcp serve`, spawned by name). ``
Also update the FAQ/“gauge and the engine” mentions of the launcher: `grep -n launcher README.md` and reword each to "the bundled MCP is spawned by name".

- [ ] **Step 4: Bump manifests** — set `"version": "2.8.0"` in both `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`. Update the spec §4 with the CI-gate deviation (one sentence).

- [ ] **Step 5: Run the whole suite** — `./test.sh 2>&1 | grep -E '^FAIL'; ./test.sh 2>&1 | tail -1` → no FAIL.

- [ ] **Step 6: Commit, push, open the PR**

```bash
git add README.md .claude-plugin docs/superpowers/specs test.sh
git commit -m "release: v2.8.0 — Windows support (issue #9)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push
gh pr create --base main --title "feat: Windows support — bare-name MCP, shared engine resolver, Windows-aware doctor (v2.8.0, #9)" --body-file - <<'EOF'
Fixes #9.

**Why the bundled MCP died on Windows:** Claude Code runs hooks through Git Bash on Windows, so our hooks worked, but MCP stdio commands are spawned without a shell — Windows cannot run `scripts/mcp-launcher.sh` that way ("Connection closed"). `.mcp.json` has no per-platform command.

**What changed**
- `.mcp.json` spawns `headroom mcp serve` by name; the launcher is gone. New doctor check 2b makes sure `headroom` resolves: it shims the resolved CLI into `~/.local/bin` (symlink; `headroom.exe` copy on Windows), re-verifies, and FAILs with the exact PATH line if the dir isn't on PATH. It never edits rc files or the registry.
- One shared resolver (`scripts/lib/engine-resolve.sh`) replaces five drifted copies: `Scripts\python.exe` venvs, uv tool installs, PE (`MZ`) launchers with no shebang, pip --user/pipx shebangs.
- Doctor bootstrap tries `python3` / `python` / `py -3` (reversed on Windows) and handles both venv layouts.
- `hcat` sets `PYTHONIOENCODING=utf-8 PYTHONUTF8=1`.
- Status line on Windows is wired as `"C:\…\bash.exe" "C:\…\headroom-statusline.sh"` (from `CLAUDE_CODE_GIT_BASH_PATH` or `cygpath`); check 7 understands backslash paths; a stale `CLAUDE_CODE_GIT_BASH_PATH` is FAIL. Git Bash is a documented prerequisite.
- CI: `./test.sh` on ubuntu + macos; a `windows-latest` job with a REAL engine runs the resolver, hcat on non-ASCII JSON, `doctor --fix` end to end, a shell-less Node spawn of `headroom mcp serve` (+ a `.sh` negative control), and the status-line command from PowerShell.

**Upgrade note:** existing installs run `/headroom-usage-indicator:doctor --fix` once (README "Updating").

**Not verified by CI:** Claude Code itself on Windows (hooks firing, status-line spawn, the `/plugin` connected mark) — asking the reporter to test from this branch before tagging.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
```

- [ ] **Step 7: Ask the reporter to verify** — comment on #9:

```bash
gh issue comment 9 --repo Abhi902/headroom-plugin --body-file - <<'EOF'
Thanks for the detailed report — this was two bugs: the bundled MCP referenced a `.sh` launcher (MCP stdio commands are spawned without a shell, so Windows can never run it), and every engine lookup only knew the `bin/python` layout.

Fix is up as PR #<N> (branch `fix/issue-9-windows`), with a real `windows-latest` CI job. What CI can't do is run Claude Code itself, so could you try the branch on your machine?

1. Clone the branch and load it: `claude --plugin-dir <path-to-clone>` (or add the clone as a local marketplace).
2. Run `/headroom-usage-indicator:doctor --fix` and paste the output here.
3. Check `/plugin` shows the headroom MCP connected, and that `hcat <some.json>` prints a receipt.

If the status-line badge doesn't render, please paste your `statusLine.command` from `~/.claude/settings.json` — that spawn path is the one part Claude Code doesn't document for Windows. I'll tag v2.8.0 once you confirm.
EOF
```
(Replace `<N>` with the PR number `gh pr view --json number -q .number` prints.)

- [ ] **Step 8: Update memory** — in `~/.claude/projects/-Users-abhi-Desktop-neo/memory/headroom-plugin-v2.md` and `MEMORY.md`: PR number, CI status, "awaiting reporter"; tag + GH release happen only after the reporter confirms (or after a reasonable wait, with the README Windows section marked reporter-verified: no).

---

## Self-review

- **Spec coverage:** §1 resolver → T1-T4; hcat UTF-8 → T2; §2 bare command, launcher deleted, 4b shape, 2b shim/verify/FAIL snippet, README upgrade note, SKILL disclosure + parity → T5, T6, T8, T10; §3 interpreter order, `venv_bindir`, Windows status line via `CLAUDE_CODE_GIT_BASH_PATH`/cygpath, check 7 backslash tokens, Git Bash prerequisite (doctor + probe), `DOCTOR_OS`/`DOCTOR_CYGPATH` → T4, T7; §4 fixtures (Scripts layout, MZ, uv stub, bare-command 4b, shim idempotency, PATH FAIL text, interpreter fallback, Windows status-line shape, prerequisite FAIL, docs parity, shellcheck) → T1-T9; CI (ubuntu/macos suite, windows real venv/pip/uv, hcat UTF-8, doctor --fix sandbox, spawn probe + negative control, PowerShell status line, full suite informational) → T9; README Windows section, manifests, PR, reporter comment → T10. Gap check: spec §3 said "no bash resolvable → FAIL"; since the doctor and probe only ever run *under* bash, the check reduces to a broken `CLAUDE_CODE_GIT_BASH_PATH` — recorded in T7's interface, and T10 Step 4 updates the spec.
- **Placeholders:** none; every code step carries the code. The only `<N>` is the PR number substituted at runtime.
- **Type/name consistency:** `is_windows`, `venv_bindir`, `engine_python_candidates`, `resolve_engine_python`, `resolve_headroom_cli`, `win_path`, `unix_path` (T1) are the names used in T2-T9; `SHIM_DIR`, `shim_headroom`, `path_hint` (T6) match T7/T9 usage; `sl_hr_cmd` (T7) is used at doctor line 558 only; `DOCTOR_OS`, `DOCTOR_CYGPATH`, `DOCTOR_SHIM_DIR` env names are identical across tasks, tests and CI.
