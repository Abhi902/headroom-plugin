# Windows support for headroom-usage-indicator (v2.8.0) — design

Fixes GitHub issue #9 (Windows: bundled MCP launcher fails; engine paths, UTF-8,
status-line wiring all Unix-only).

## Problem

- Claude Code runs `type: command` hooks through Git Bash on Windows, so the
  five hooks in `hooks/hooks.json` work there. MCP stdio commands are spawned
  directly, without a shell, and Windows cannot execute a `.sh` file that way,
  so `.mcp.json` → `scripts/mcp-launcher.sh` dies at spawn ("Connection closed").
  `.mcp.json` has no per-platform `command`.
- Engine resolution in `bin/hcat`, `scripts/doctor.sh`, `scripts/hcat-gate.sh`,
  `scripts/session-probe.sh`, `scripts/mcp-launcher.sh` only tries `bin/python`
  and `bin/headroom`. Windows venvs use `Scripts\python.exe`; uv/pip on Windows
  ship `headroom.exe` PE trampolines with no sibling python and no shebang, so
  every fallback misses and hcat silently drops to TOON-lite. The five copies
  have already drifted (gate/probe never try the shebang interpreter).
- `doctor.sh --fix` bootstraps with `python3 -m venv` and `$VENV/bin/pip`;
  on Windows the interpreter is `python`/`py -3` and pip lives under `Scripts\`.
- hcat runs the engine without `PYTHONIOENCODING=utf-8`; non-ASCII output
  crashes on Windows' default code page.
- Doctor wires `statusLine.command` as `bash "/c/Users/..."`. How Claude Code
  spawns the status line on Windows is undocumented; a Git-Bash-style path only
  resolves inside bash.

## Decisions (approved 2026-09-17)

1. **MCP: bare command + PATH shim.** `.mcp.json` becomes
   `{"command":"headroom","args":["mcp","serve"]}` (env unchanged).
   `scripts/mcp-launcher.sh` is deleted. Doctor ensures `headroom` resolves on
   PATH: shim the resolved CLI, re-verify, FAIL with the exact PATH snippet if
   it still does not resolve. Doctor does not edit shell rc files or the
   Windows registry.
2. **One shared engine resolver** (`scripts/lib/engine-resolve.sh`) replaces
   the five hand-rolled copies.
3. **Git Bash is a documented Windows prerequisite.** Without it Claude Code
   runs hooks under PowerShell and none of ours can work. PowerShell-only
   installs are out of scope.
4. **Verification:** unit fixtures on macOS simulate every Windows layout; the
   issue reporter verifies on real Windows from the PR branch before the tag.

## Section 1 — shared engine resolver

New file `scripts/lib/engine-resolve.sh` (sourced, never executed):

- `is_windows` — true when `$OSTYPE` matches `msys*|cygwin*` or `uname -s`
  matches `MINGW*|MSYS*|CYGWIN*`. Tests override with `DOCTOR_OS=windows|unix`.
- `resolve_engine_python` — prints the first candidate that exists and is
  executable (callers decide whether to also verify `import headroom.compress`,
  as today):
  1. `$HCAT_PYTHON` if set — authoritative, no fallback (unchanged contract).
  2. sibling `python` then `python.exe` of `headroom` on PATH.
  3. shebang interpreter of that `headroom` script — skipped when its first
     two bytes are `MZ` (PE trampoline: uv tool shims, pip Windows launchers).
  4. `$(uv tool dir)/headroom-ai/bin/python` then `.../Scripts/python.exe`
     (only when `uv` is on PATH; helps uv users on every OS).
  5. `$VENV_DIR/bin/python` then `$VENV_DIR/Scripts/python.exe`
     (`VENV_DIR=${DOCTOR_VENV_DIR:-$HOME/.headroom-venv}`).
- `resolve_headroom_cli` — same order, for the CLI: `$HCAT_PYTHON`'s directory
  `headroom`/`headroom.exe` (authoritative when set) → `command -v headroom` →
  uv tool dir `bin/headroom`/`Scripts/headroom.exe` → venv `bin/headroom`/
  `Scripts/headroom.exe`.
- `venv_bindir <venv>` — prints `bin` or `Scripts`, whichever exists.

Consumers: `bin/hcat`, `scripts/doctor.sh`, `scripts/hcat-gate.sh`,
`scripts/session-probe.sh`. Each sources it with the existing pattern
(`$here/lib/engine-resolve.sh`, then flat sibling `$here/engine-resolve.sh` for
legacy flat installs), and keeps a minimal inline fallback (HCAT_PYTHON →
venv in both layouts) so a partial legacy copy degrades instead of breaking.
The legacy installer in `skills/headroom-usage-indicator/SKILL.md` and the
doctor's lib-provisioning (check 7c) add the new file to the copied set.

`bin/hcat` exec line: `PYTHONIOENCODING=utf-8 PYTHONUTF8=1` alongside the
existing `HF_HUB_OFFLINE=1 HEADROOM_UPDATE_CHECK=off`.

## Section 2 — bare `headroom` MCP + shim

- `.mcp.json`: `"command": "headroom", "args": ["mcp", "serve"]`; env keeps
  `HEADROOM_UPDATE_CHECK=off`, `HF_HUB_OFFLINE=1`.
- Delete `scripts/mcp-launcher.sh`; update README/SKILL.md references.
- Doctor check 4b owns only the file's shape: `.mcp.json` parses and names
  server `headroom` with a bare `command` (no path separators, no
  `${CLAUDE_PLUGIN_ROOT}`, no quotes); anything else is FAIL (a stale cache
  copy of an older release). Whether that bare name resolves is check 2b's
  job, so a PATH problem is reported exactly once.
- New check 2b "headroom CLI on PATH", after engine resolution:
  - engine resolved AND `command -v headroom` resolves → ok.
  - engine resolved, CLI not on PATH → `fixable`. `--fix`: shim
    `resolve_headroom_cli` result to `SHIM_DIR/headroom` (Unix: `ln -sf`;
    Windows: `cp` of `headroom.exe`, name `headroom.exe`).
    `SHIM_DIR=${DOCTOR_SHIM_DIR:-$HOME/.local/bin}`, created if missing.
    Then re-run `command -v headroom`: resolves → `fixed`; still not →
    `FAIL "headroom shimmed to <path> but <dir> is not on PATH — add it:
    <snippet>"` where snippet is `echo 'export PATH="$HOME/.local/bin:$PATH"'
    >> ~/.zshrc` (or `.bashrc` by `$SHELL`), or on Windows: Settings → System →
    About → Advanced → Environment Variables → User `Path` → add
    `%USERPROFILE%\.local\bin`, then restart Claude Code.
  - no engine → `skip` (check 2 already reports the engine as fixable).
  - The venv bootstrap runs the same shim+verify step right after install.
  - Output note on the ok line: PATH is verified in the Bash tool's
    environment, the closest available proxy for Claude Code's MCP spawn env.
- Block 9 (ambient all-clear) unchanged: a FAIL from 2b blocks it, as any FAIL.
- README: "Upgrading from ≤2.7.4 with a doctor-bootstrapped venv" note — run
  `/headroom-usage-indicator:doctor --fix` once; the bundled MCP now needs
  `headroom` on PATH. SKILL.md (doctor) consent list and fixable list disclose
  the shim and the `~/.local/bin` write; parity checks in test.sh pin both.

## Section 3 — Windows-aware bootstrap and status line

- Bootstrap interpreter order: Unix `python3`, `python`, `py -3`; Windows
  `py -3`, `python`, `python3` (Store alias stub last). First one whose
  `-m venv "$VENV_DIR"` succeeds wins; then `bindir=$(venv_bindir "$VENV_DIR")`
  and `$VENV_DIR/$bindir/pip`, `.../python` (`python.exe` on Windows). The
  half-venv cleanup and the FAIL hint keep their current behaviour; the hint
  names the interpreter that was tried.
- Status-line wiring (check 7 init-wire and re-copy paths): on Windows the
  written command is `"<bash.exe>" "<script>"` with both as Windows paths:
  bash from `$CLAUDE_CODE_GIT_BASH_PATH` if set, else `cygpath -w "$(command -v
  bash)"`; script `cygpath -w "$CLAUDE_DIR/headroom-statusline.sh"`. Unix
  unchanged. Check 7's token extractor accepts `\`-separated paths and
  `.sh` tokens inside Windows quoting when matching `headroom-statusline.sh`.
- Doctor and probe: when `is_windows` and no bash is resolvable, or
  `CLAUDE_CODE_GIT_BASH_PATH` points at a missing file → FAIL "Git for Windows
  (Git Bash) is required on Windows: hooks and the status line run through it".
- `DOCTOR_OS` override (`windows`|`unix`) forces `is_windows` for tests;
  `DOCTOR_CYGPATH` override lets tests stub `cygpath` (fixture prints
  `C:\...`).

## Section 4 — tests, docs, release

test.sh additions (TDD: each fixture red first):
- resolver: `Scripts/python.exe` venv layout found; `MZ` trampoline skips
  shebang and falls through; stub `uv` → `uv tool dir` layout found; order
  preserved (HCAT_PYTHON authoritative; PATH sibling beats venv).
- hcat: exec env carries `PYTHONIOENCODING=utf-8` (fixture python echoes env).
- 4b: bare command ok; path-style command → FAIL; `command -v` miss → FAIL.
- 2b: fixable when engine found but CLI off PATH; `--fix` creates shim
  (symlink on unix; copy named `headroom.exe` under `DOCTOR_OS=windows`);
  idempotent second run; unresolved → FAIL text carries the PATH snippet.
- bootstrap: stub PATH with only `python` (no `python3`) → bootstrap succeeds;
  `Scripts/` layout venv fixture → pip/python resolved from `Scripts/`.
- status line: `DOCTOR_OS=windows` + stub cygpath → written command shape
  `"C:\...\bash.exe" "C:\...\headroom-statusline.sh"`; check 7 recognises it.
- prerequisite: `DOCTOR_OS=windows` with no bash resolvable → FAIL line.
- docs parity: SKILL.md lists the shim mutation; README has no
  `mcp-launcher.sh` reference.
- shellcheck `--severity=warning` clean.

Docs: README "Windows" section (Git Bash required; jq via `winget install
jqlang.jq`; `uv tool install "headroom-ai[all]"` or `pipx` recommended because
they manage PATH; status-line command shape; the `/plugin` MCP shows connected
once `headroom` is on PATH), issue #9 link, upgrade note (Section 2).
`plugin.json` + `marketplace.json` → 2.8.0.

Release: PR → comment on #9 asking the reporter to test from the branch
(clone + `/plugin marketplace add <local path>` or `--plugin-dir`) → tag
v2.8.0 + GH release after their confirmation (or after a reasonable wait if
they do not respond, with the Windows section marked "reporter-verified: no").

## Out of scope

PowerShell-only Windows (no Git Bash); editing shell rc files or the Windows
registry; desktop notifications on Windows (Dangi silently skips, as today);
the plugin-namespaced MCP tool prefix follow-up already tracked in memory.
