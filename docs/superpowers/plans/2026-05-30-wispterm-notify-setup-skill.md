# wispterm-notify-setup Skill — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `plugins/skills/wispterm-notify-setup/` skill that idempotently installs an agent-agnostic notify script and wires Claude Code `Stop`/`Notification` hooks plus Codex `config.toml` `notify`, so finishes/confirmations surface inside WispTerm (OSC 777 toast + BEL bell badge).

**Architecture:** A bundled installer script (`install-wispterm-notify.sh`) copies a runtime notify program (`wispterm-notify.sh`) to `~/.config/wispterm/`, then idempotently merges Claude Code's `settings.json` (via python3, jq fallback, manual last resort) and prepends Codex's `config.toml` `notify`. The notify program is agent-agnostic: it reads Claude Code's event JSON from stdin OR Codex's event JSON from the last argv, builds a sanitized title/body, discovers the agent's tty (Linux `/proc`, macOS `ps`), and writes OSC 777 + BEL. A `WISPTERM_NOTIFY_TTY` env override makes the emit path unit-testable. `SKILL.md` + `agents/openai.yaml` expose it to Claude Code and Codex.

**Tech Stack:** POSIX `sh`, `python3`/`jq` (config merge), the repo's `plugins/skills/` convention.

**Spec:** `docs/superpowers/specs/2026-05-30-wispterm-notify-setup-skill-design.md`

**Branch:** `feat/wispterm-notify-setup-skill` (already created off `main`; spec committed at `c627637`).

**Platform:** Unix only (Linux/WSL + macOS). Windows is out of scope.

---

## File Structure

| File | Responsibility |
|---|---|
| `plugins/skills/wispterm-notify-setup/scripts/wispterm-notify.sh` | Runtime notify program: payload routing (CC stdin / Codex last-argv), title/body mapping, sanitization, tty discovery (+`WISPTERM_NOTIFY_TTY` override), emit OSC 777 + BEL. |
| `plugins/skills/wispterm-notify-setup/scripts/install-wispterm-notify.sh` | Idempotent installer: copy notify program to `~/.config/wispterm/`, merge CC `settings.json` hooks, prepend Codex `config.toml` `notify`, report changes. |
| `plugins/skills/wispterm-notify-setup/scripts/test-install.sh` | Pure-`sh` test harness (temp `HOME` + `WISPTERM_NOTIFY_TTY`): emit/parse/sanitize + installer idempotency/merge/no-clobber. |
| `plugins/skills/wispterm-notify-setup/SKILL.md` | Skill doc: name/description + Workflow (run installer → report → verify). |
| `plugins/skills/wispterm-notify-setup/agents/openai.yaml` | Codex interface. |

---

## Task 1: Notify program + emit/parse/sanitize tests

**Files:**
- Create: `plugins/skills/wispterm-notify-setup/scripts/wispterm-notify.sh`
- Create: `plugins/skills/wispterm-notify-setup/scripts/test-install.sh`

- [ ] **Step 1: Write the failing tests** — create `scripts/test-install.sh`:

```sh
#!/usr/bin/env sh
# Test harness for wispterm-notify-setup. Pure POSIX sh. Exits non-zero on any failure.
set -u
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NOTIFY="$HERE/wispterm-notify.sh"
INSTALL="$HERE/install-wispterm-notify.sh"
FAILS=0
ESC="$(printf '\033')"
BEL="$(printf '\007')"

ok()   { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; FAILS=$((FAILS+1)); }
assert_contains() { # file needle desc
  if LC_ALL=C grep -qF -- "$2" "$1"; then ok "$3"; else fail "$3 (missing: $2)"; fi
}
assert_not_contains() {
  if LC_ALL=C grep -qF -- "$2" "$1"; then fail "$3 (unexpected: $2)"; else ok "$3"; fi
}

# ---- notify: Claude Code Notification on stdin ----
t="$(mktemp)"
printf '%s' '{"hook_event_name":"Notification","title":"WispTerm","message":"hi"}' \
  | WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY"
assert_contains "$t" "${ESC}]777;notify;WispTerm;hi${BEL}" "CC Notification -> OSC777 title+body"
assert_contains "$t" "$BEL" "CC Notification -> emits BEL"

# ---- notify: Claude Code Stop on stdin ----
t="$(mktemp)"
printf '%s' '{"hook_event_name":"Stop"}' | WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY"
assert_contains "$t" "${ESC}]777;notify;Claude Code;" "CC Stop -> OSC777 Claude Code title"

# ---- notify: Codex event as LAST argv ----
t="$(mktemp)"
WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY" '{"type":"agent-turn-complete","last-assistant-message":"done deal"}'
assert_contains "$t" "${ESC}]777;notify;Codex;done deal${BEL}" "Codex argv -> OSC777 Codex/body"

# ---- notify: sanitization (strip ';' delimiter from title and body) ----
t="$(mktemp)"
printf '%s' '{"hook_event_name":"Notification","title":"a;b","message":"x;y"}' \
  | WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY"
assert_contains "$t" "${ESC}]777;notify;ab;xy${BEL}" "sanitize strips ';' from title and body"

# ---- notify: empty payload -> no output, exit 0 ----
t="$(mktemp)"
printf '' | WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY"; rc=$?
[ "$rc" -eq 0 ] && ok "empty payload exits 0" || fail "empty payload exit code ($rc)"
[ ! -s "$t" ] && ok "empty payload writes nothing" || fail "empty payload wrote output"

printf '\n%s test(s) failed\n' "$FAILS"
[ "$FAILS" -eq 0 ]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `sh plugins/skills/wispterm-notify-setup/scripts/test-install.sh; echo "rc=$?"`
Expected: FAIL — `wispterm-notify.sh` doesn't exist yet, so every notify assertion fails and `rc` is non-zero (the `sh "$NOTIFY"` calls error, files stay empty).

- [ ] **Step 3: Write the notify program** — create `scripts/wispterm-notify.sh`:

```sh
#!/usr/bin/env sh
# wispterm-notify.sh — agent-agnostic notifier. Reads a Claude Code hook event
# from stdin OR a Codex event JSON as the last argv, builds a sanitized
# title/body, finds the agent's terminal, and writes OSC 777 + BEL so WispTerm
# shows a desktop notification (toast on macOS w/ OSC support) and/or bell badge.
# Always exits 0; never blocks the agent.

# --- 1. Collect payload: Codex passes event JSON as the LAST argv; Claude Code
#        pipes it on stdin. ---
payload=""
if [ "$#" -gt 0 ]; then
  for a in "$@"; do payload="$a"; done   # last argument
elif [ ! -t 0 ]; then
  payload="$(cat)"
fi
[ -z "$payload" ] && exit 0

# --- 2. Title/body. Use jq when available; otherwise a safe generic default. ---
title="Claude Code"
body="Notification"
if command -v jq >/dev/null 2>&1; then
  ev="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)"
  if [ "$ev" = "Stop" ]; then
    title="Claude Code"; body="完成，轮到你了"
  elif [ "$ev" = "Notification" ]; then
    title="$(printf '%s' "$payload" | jq -r '.title // "Claude Code"' 2>/dev/null)"
    body="$(printf '%s' "$payload" | jq -r '.message // .notification_type // "需要你确认"' 2>/dev/null)"
  else
    typ="$(printf '%s' "$payload" | jq -r '.type // empty' 2>/dev/null)"
    if [ -n "$typ" ]; then
      title="Codex"
      body="$(printf '%s' "$payload" | jq -r '."last-assistant-message" // .type // "Turn complete"' 2>/dev/null)"
    fi
  fi
fi

# --- 3. Sanitize: strip ESC/BEL/CR/LF and ';' (OSC 777 field delimiter); truncate. ---
sanitize() { printf '%s' "$1" | tr -d '\033\007\r\n;' | cut -c1-"$2"; }
title="$(sanitize "$title" 256)"
body="$(sanitize "$body" 1024)"

# --- 4. Find the terminal. Hooks have no controlling tty (/dev/tty = ENXIO), so
#        walk the parent chain to the agent process's tty. Test override wins. ---
notify_tty=""
if [ -n "${WISPTERM_NOTIFY_TTY:-}" ]; then
  notify_tty="$WISPTERM_NOTIFY_TTY"
else
  os="$(uname -s 2>/dev/null || echo unknown)"
  pid=$$
  i=0
  while [ "$i" -lt 12 ]; do
    case "$os" in
      Linux)
        for fd in 1 0 2; do
          t="$(readlink "/proc/$pid/fd/$fd" 2>/dev/null)" || continue
          case "$t" in /dev/pts/*) notify_tty="$t"; break ;; esac
        done
        [ -n "$notify_tty" ] && break
        pid="$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
        ;;
      Darwin)
        t="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')"
        case "$t" in ttys*) notify_tty="/dev/$t"; break ;; esac
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
        ;;
      *) break ;;
    esac
    [ -z "$pid" ] && break
    [ "$pid" = 0 ] && break
    i=$((i + 1))
  done
fi
[ -z "$notify_tty" ] && exit 0

# --- 5. Emit one OSC 777 (title+body) + BEL. Only OSC 777 (not OSC 9) to avoid
#        double-notifying terminals that support both. ---
{
  printf '\033]777;notify;%s;%s\007' "$title" "$body"
  printf '\a'
} >"$notify_tty" 2>/dev/null || true
exit 0
```

- [ ] **Step 4: Make scripts executable and run the tests**

Run:
```
chmod +x plugins/skills/wispterm-notify-setup/scripts/wispterm-notify.sh plugins/skills/wispterm-notify-setup/scripts/test-install.sh
sh plugins/skills/wispterm-notify-setup/scripts/test-install.sh; echo "rc=$?"
```
Expected: all `ok` lines for the notify tests, `0 test(s) failed`, `rc=0`.

> Note: these parse tests require `jq` (the notify program degrades to a generic title/body without it). If `jq` is absent on the dev box, install it (`apt-get install -y jq` / `brew install jq`) before running. Control-char stripping (ESC/BEL/CR/LF) is covered by the `tr -d` in the program and verified by inspection; this shell test asserts `;`-stripping.

- [ ] **Step 5: Commit**

```bash
git add plugins/skills/wispterm-notify-setup/scripts/wispterm-notify.sh plugins/skills/wispterm-notify-setup/scripts/test-install.sh
git commit -m "feat(skill): wispterm-notify.sh agent-agnostic notifier + emit/parse tests

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Installer — install program + Claude Code settings.json merge

**Files:**
- Create: `plugins/skills/wispterm-notify-setup/scripts/install-wispterm-notify.sh`
- Modify: `plugins/skills/wispterm-notify-setup/scripts/test-install.sh` (append installer tests)

- [ ] **Step 1: Append failing installer tests** — add to the END of `test-install.sh`, BEFORE the final `printf '\n%s test(s) failed...'` / `[ "$FAILS" -eq 0 ]` lines (move those two lines to stay last):

```sh

# ================= installer: Claude Code settings.json =================
# Run installer against a throwaway HOME with a pre-existing PreToolUse hook.
FAKE="$(mktemp -d)"
mkdir -p "$FAKE/.claude"
cat > "$FAKE/.claude/settings.json" <<'JSON'
{ "model": "opus", "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/existing/rtk.sh" } ] } ] } }
JSON
HOME="$FAKE" sh "$INSTALL" >/dev/null 2>&1

CC="$FAKE/.claude/settings.json"
DEST="$FAKE/.config/wispterm/wispterm-notify.sh"
[ -x "$DEST" ] && ok "installer copied notify program (executable)" || fail "notify program not installed at $DEST"
# Valid JSON?
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CC" 2>/dev/null \
    && ok "settings.json is valid JSON after merge" || fail "settings.json invalid JSON"
fi
assert_contains "$CC" '/existing/rtk.sh' "preserved pre-existing PreToolUse hook"
assert_contains "$CC" "$DEST" "wired notify command into settings.json"
# Both events present?
if command -v python3 >/dev/null 2>&1; then
  python3 - "$CC" "$DEST" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1])); dest=sys.argv[2]
def has(ev):
    return any(h.get("command")==dest for e in cfg.get("hooks",{}).get(ev,[]) for h in e.get("hooks",[]))
import os
sys.exit(0 if has("Stop") and has("Notification") else 1)
PY
  [ $? -eq 0 ] && ok "Stop and Notification both wired" || fail "Stop/Notification not both wired"
fi

# Idempotency: run again, assert the command appears exactly once across hooks.
HOME="$FAKE" sh "$INSTALL" >/dev/null 2>&1
if command -v python3 >/dev/null 2>&1; then
  python3 - "$CC" "$DEST" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1])); dest=sys.argv[2]
n=sum(1 for ev in ("Stop","Notification") for e in cfg["hooks"].get(ev,[]) for h in e.get("hooks",[]) if h.get("command")==dest)
sys.exit(0 if n==2 else 1)  # exactly one per event, not duplicated
PY
  [ $? -eq 0 ] && ok "re-run is idempotent (no duplicate CC hooks)" || fail "CC hooks duplicated on re-run"
fi
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `sh plugins/skills/wispterm-notify-setup/scripts/test-install.sh; echo "rc=$?"`
Expected: notify tests still `ok`; installer tests FAIL (`install-wispterm-notify.sh` missing → nothing installed/merged), `rc` non-zero.

- [ ] **Step 3: Write the installer (program install + CC merge)** — create `scripts/install-wispterm-notify.sh`:

```sh
#!/usr/bin/env sh
# install-wispterm-notify.sh — idempotently install the WispTerm notify program
# and wire Claude Code Stop/Notification hooks. (Codex wiring added in Task 3.)
# Unix only (Linux/WSL + macOS). Backs up before editing; only adds, never deletes.
set -eu

SRC_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NOTIFY_SRC="$SRC_DIR/wispterm-notify.sh"
DEST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wispterm"
DEST="$DEST_DIR/wispterm-notify.sh"

# --- 1. Install the notify program ---
mkdir -p "$DEST_DIR"
cp "$NOTIFY_SRC" "$DEST"
chmod +x "$DEST"
echo "notify program -> $DEST"

# --- 2. Wire Claude Code settings.json (idempotent merge) ---
CC_DIR="$HOME/.claude"
CC="$CC_DIR/settings.json"
mkdir -p "$CC_DIR"
[ -f "$CC" ] || printf '{}\n' >"$CC"
cp "$CC" "$CC.bak"

if command -v python3 >/dev/null 2>&1; then
  DEST="$DEST" python3 - "$CC" <<'PY'
import json, os, sys
path = sys.argv[1]; dest = os.environ["DEST"]
try:
    with open(path) as f: cfg = json.load(f)
except Exception:
    cfg = {}
if not isinstance(cfg, dict): cfg = {}
hooks = cfg.setdefault("hooks", {})
def ensure(ev):
    arr = hooks.setdefault(ev, [])
    for entry in arr:
        for h in entry.get("hooks", []):
            if h.get("type") == "command" and h.get("command") == dest:
                return "present"
    arr.append({"hooks": [{"type": "command", "command": dest}]})
    return "added"
s = ensure("Stop"); n = ensure("Notification")
with open(path, "w") as f:
    json.dump(cfg, f, indent=2); f.write("\n")
print(f"claude: Stop {s}, Notification {n}")
PY
elif command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq --arg d "$DEST" '
    .hooks //= {} | .hooks.Stop //= [] | .hooks.Notification //= []
    | (if any(.hooks.Stop[]?.hooks[]?; .type=="command" and .command==$d)
        then . else .hooks.Stop += [{"hooks":[{"type":"command","command":$d}]}] end)
    | (if any(.hooks.Notification[]?.hooks[]?; .type=="command" and .command==$d)
        then . else .hooks.Notification += [{"hooks":[{"type":"command","command":$d}]}] end)
  ' "$CC" >"$tmp" && mv "$tmp" "$CC"
  echo "claude: hooks merged via jq"
else
  echo "WARN: no python3 or jq found. Add to $CC manually:"
  echo "  hooks.Stop[]   -> { \"hooks\": [ { \"type\": \"command\", \"command\": \"$DEST\" } ] }"
  echo "  hooks.Notification[] -> (same)"
fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```
chmod +x plugins/skills/wispterm-notify-setup/scripts/install-wispterm-notify.sh
sh plugins/skills/wispterm-notify-setup/scripts/test-install.sh; echo "rc=$?"
```
Expected: all `ok` (notify + CC installer + idempotency), `0 test(s) failed`, `rc=0`.

- [ ] **Step 5: Commit**

```bash
git add plugins/skills/wispterm-notify-setup/scripts/install-wispterm-notify.sh plugins/skills/wispterm-notify-setup/scripts/test-install.sh
git commit -m "feat(skill): installer installs notify program + idempotent CC settings.json merge

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Installer — Codex config.toml notify (prepend, no-clobber)

**Files:**
- Modify: `plugins/skills/wispterm-notify-setup/scripts/install-wispterm-notify.sh` (append the Codex step before nothing — it's the last step)
- Modify: `plugins/skills/wispterm-notify-setup/scripts/test-install.sh` (append Codex tests)

- [ ] **Step 1: Verify the Codex `notify` contract (no code yet)**

On a machine with a working `codex`, confirm: (a) `notify` is a top-level `config.toml` array `notify = ["prog", ...]`; (b) Codex appends the event JSON as the **last** argv when invoking the program; (c) `~` is NOT expanded (absolute path required); (d) which event types fire (e.g. `agent-turn-complete`). Sources: `codex` docs / `~/.codex` docs / a smoke test. The notify program (Task 1) already takes the LAST argv and parses it as JSON, so it is robust to extra configured args. If the contract differs materially, note it on the PR and adjust. **Do not block the rest of this task** — the implementation below matches the documented contract.

- [ ] **Step 2: Append failing Codex tests** — add to `test-install.sh` (again, keep the final two summary lines last):

```sh

# ================= installer: Codex config.toml =================
# Case A: no prior notify -> added, top-level (before any [section]).
FAKE2="$(mktemp -d)"
mkdir -p "$FAKE2/.claude" "$FAKE2/.codex"
printf '{}\n' > "$FAKE2/.claude/settings.json"
cat > "$FAKE2/.codex/config.toml" <<'TOML'
model = "gpt-5"

[history]
persistence = "save-all"
TOML
HOME="$FAKE2" sh "$INSTALL" >/dev/null 2>&1
CODEX="$FAKE2/.codex/config.toml"
DEST2="$FAKE2/.config/wispterm/wispterm-notify.sh"
assert_contains "$CODEX" "notify = [\"$DEST2\"]" "codex: notify added"
# top-level: the notify line must appear before the first [section]
firstsec="$(grep -n '^\[' "$CODEX" | head -1 | cut -d: -f1)"
notifyln="$(grep -n '^notify' "$CODEX" | head -1 | cut -d: -f1)"
[ -n "$notifyln" ] && [ -n "$firstsec" ] && [ "$notifyln" -lt "$firstsec" ] \
  && ok "codex: notify is top-level (before [section])" || fail "codex: notify not top-level"
# idempotent re-run: still exactly one notify line
HOME="$FAKE2" sh "$INSTALL" >/dev/null 2>&1
[ "$(grep -c '^notify' "$CODEX")" -eq 1 ] && ok "codex: idempotent (one notify line)" || fail "codex: notify duplicated"

# Case B: pre-existing DIFFERENT notify -> left untouched + warning.
FAKE3="$(mktemp -d)"
mkdir -p "$FAKE3/.claude" "$FAKE3/.codex"
printf '{}\n' > "$FAKE3/.claude/settings.json"
printf 'notify = ["/some/other/notifier.sh"]\n' > "$FAKE3/.codex/config.toml"
out="$(HOME="$FAKE3" sh "$INSTALL" 2>&1)"
assert_contains "$FAKE3/.codex/config.toml" '/some/other/notifier.sh' "codex: existing notify preserved"
assert_not_contains "$FAKE3/.codex/config.toml" 'wispterm-notify.sh' "codex: did not clobber existing notify"
printf '%s' "$out" | grep -qi 'warn' && ok "codex: warned about existing notify" || fail "codex: no warning on conflict"
```

- [ ] **Step 3: Run to verify the new tests fail**

Run: `sh plugins/skills/wispterm-notify-setup/scripts/test-install.sh; echo "rc=$?"`
Expected: prior tests `ok`; Codex tests FAIL (installer doesn't touch `config.toml` yet), `rc` non-zero.

- [ ] **Step 4: Add the Codex step to the installer** — append to the END of `install-wispterm-notify.sh`:

```sh

# --- 3. Wire Codex config.toml `notify` (idempotent, top-level, no-clobber) ---
CODEX_DIR="$HOME/.codex"
CODEX="$CODEX_DIR/config.toml"
mkdir -p "$CODEX_DIR"
[ -f "$CODEX" ] || : >"$CODEX"
cp "$CODEX" "$CODEX.bak"

# A top-level bare key appended after a [section] would bind to that section,
# so we PREPEND the notify line to keep it top-level.
existing="$(grep -nE '^[[:space:]]*notify[[:space:]]*=' "$CODEX" | head -1 || true)"
if [ -z "$existing" ]; then
  tmp="$(mktemp)"
  printf 'notify = ["%s"]\n' "$DEST" >"$tmp"
  cat "$CODEX" >>"$tmp"
  mv "$tmp" "$CODEX"
  echo "codex: notify added -> $DEST"
elif printf '%s' "$existing" | grep -qF "$DEST"; then
  echo "codex: notify already set to wispterm-notify"
else
  echo "WARN: codex already has a different notify (left untouched): ${existing#*:}"
fi

echo
echo "Verify in WispTerm:"
echo "  echo '{\"hook_event_name\":\"Notification\",\"title\":\"WispTerm\",\"message\":\"setup ok\"}' | $DEST"
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `sh plugins/skills/wispterm-notify-setup/scripts/test-install.sh; echo "rc=$?"`
Expected: all `ok` (notify + CC + Codex + idempotency + no-clobber), `0 test(s) failed`, `rc=0`.

- [ ] **Step 6: Commit**

```bash
git add plugins/skills/wispterm-notify-setup/scripts/install-wispterm-notify.sh plugins/skills/wispterm-notify-setup/scripts/test-install.sh
git commit -m "feat(skill): installer wires Codex config.toml notify (top-level prepend, no-clobber)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: SKILL.md + Codex interface

**Files:**
- Create: `plugins/skills/wispterm-notify-setup/SKILL.md`
- Create: `plugins/skills/wispterm-notify-setup/agents/openai.yaml`

- [ ] **Step 1: Create `SKILL.md`**

```markdown
---
name: wispterm-notify-setup
description: Use when the user wants to install, repair, or re-apply WispTerm notification reminders (Claude Code Stop + Notification, and Codex turn-complete) on this Unix machine, so finishes and confirmation prompts surface inside WispTerm. Linux/WSL + macOS only.
---

# WispTerm Notify Setup

## Overview

Install a small notifier that makes Claude Code and Codex surface a WispTerm
notification (OSC 777 toast + terminal bell badge) when a turn finishes or a
confirmation is needed. The notifier is agent-agnostic and the installer is
idempotent — safe to re-run. Unix only (Linux/WSL + macOS); Windows is not yet
supported.

## Workflow

1. Run the bundled installer:

   ```bash
   sh "$(dirname "$0")/scripts/install-wispterm-notify.sh"
   ```

   (Invoke the `scripts/install-wispterm-notify.sh` that ships with this skill —
   under `~/.claude/skills/wispterm-notify-setup/` or
   `~/.codex/skills/wispterm-notify-setup/`.)

2. Relay what it changed: the notify program path (`~/.config/wispterm/wispterm-notify.sh`),
   which Claude Code hooks were added vs already present, and whether Codex's
   `notify` was added, already set, or left untouched (a pre-existing different
   `notify` is never overwritten).

3. Verify — run the printed test command and ask the user to confirm they saw a
   bell badge / toast in WispTerm:

   ```bash
   echo '{"hook_event_name":"Notification","title":"WispTerm","message":"setup ok"}' \
     | ~/.config/wispterm/wispterm-notify.sh
   ```

## Notes

- **Where it shows:** only when Claude Code / Codex run *inside* WispTerm. The
  rich OSC 777 toast needs a WispTerm build with OSC 9/777 support; older builds
  still get the bell badge from the BEL.
- **Idempotent:** re-running won't duplicate hooks; existing hooks and a
  pre-existing Codex `notify` are preserved.
- **Backups:** `settings.json.bak` / `config.toml.bak` are written before edits.
- **Dependencies:** prefers `python3` for the JSON merge, falls back to `jq`,
  then to printing a manual snippet.
```

- [ ] **Step 2: Create `agents/openai.yaml`**

```yaml
interface:
  display_name: "WispTerm Notify Setup"
  short_description: "Install WispTerm notify hooks for Claude Code + Codex"
  default_prompt: "Use $wispterm-notify-setup to install WispTerm Stop/Notification reminders on this machine."
```

- [ ] **Step 3: Sanity-check the skill files**

Run:
```
test -f plugins/skills/wispterm-notify-setup/SKILL.md && head -3 plugins/skills/wispterm-notify-setup/SKILL.md
test -f plugins/skills/wispterm-notify-setup/agents/openai.yaml && cat plugins/skills/wispterm-notify-setup/agents/openai.yaml
```
Expected: SKILL.md frontmatter shows `name: wispterm-notify-setup`; the yaml prints the interface block. (Mirrors the existing `plugins/skills/inspect-computer-config` layout.)

- [ ] **Step 4: Commit**

```bash
git add plugins/skills/wispterm-notify-setup/SKILL.md plugins/skills/wispterm-notify-setup/agents/openai.yaml
git commit -m "feat(skill): SKILL.md + Codex agents/openai.yaml for wispterm-notify-setup

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Full test run + manual verification + finish

**Files:** none (verification only)

- [ ] **Step 1: Run the full skill test harness**

Run: `sh plugins/skills/wispterm-notify-setup/scripts/test-install.sh; echo "rc=$?"`
Expected: every line `ok`, `0 test(s) failed`, `rc=0`.

- [ ] **Step 2: Confirm the Zig suites are unaffected**

This skill adds no Zig code, but confirm nothing in the repo broke:
Run: `zig build test 2>&1 | tail -3; echo "rc=$?"`
Expected: `rc=0`.

- [ ] **Step 3: Real end-to-end manual check** (inside WispTerm)

```bash
sh plugins/skills/wispterm-notify-setup/scripts/install-wispterm-notify.sh
echo '{"hook_event_name":"Notification","title":"WispTerm","message":"setup ok"}' | ~/.config/wispterm/wispterm-notify.sh
```
- [ ] Confirm a bell badge (and, on a WispTerm with OSC support, a toast) appears.
- [ ] Trigger a real Claude Code `Stop` (finish a turn) and confirm the notification.
- [ ] If Codex is available, confirm a turn-complete fires the notifier (per the Step-1 contract check in Task 3).

- [ ] **Step 4: Finish**

Use `superpowers:finishing-a-development-branch` to push and open the PR for `feat/wispterm-notify-setup-skill`.

---

## Self-Review

**Spec coverage:**
- §3.1 Unix Linux/WSL+macOS, OS-branched tty → Task 1 notify `uname` branch. ✅
- §3.2 OSC 777 + BEL, no OSC 9 → Task 1 emit. ✅
- §3.3 CC stdin + Codex argv, agent-agnostic → Task 1 payload routing + Task 1/3 tests. ✅
- §3.4 location `plugins/skills/wispterm-notify-setup/` → all tasks. ✅
- §3.5 shared path `~/.config/wispterm/wispterm-notify.sh` → Task 2 installer. ✅
- §3.6 idempotent, backups, no-clobber → Task 2 (CC) + Task 3 (Codex) + tests. ✅
- §4.1 title/body table, sanitize, `WISPTERM_NOTIFY_TTY` seam → Task 1 + tests. ✅
- §4.2 installer 3 steps + python3/jq/manual + report/verify → Task 2 + Task 3. ✅
- §4.3 SKILL.md + openai.yaml → Task 4. ✅
- §5 tests (idempotency/emit/sanitize via temp HOME + tty override) → Task 1/2/3 test-install.sh; Task 5 full run. ✅
- §6 scope (no Windows, no uninstall, no script-side rate-limit, no OSC 9) → respected. ✅
- §4.2 Codex-contract verification flag → Task 3 Step 1. ✅

**Placeholder scan:** none — every script and test is given in full with exact paths and run commands.

**Consistency:** the notify program install path `~/.config/wispterm/wispterm-notify.sh` (`$DEST`) is identical across the notify tests, installer, CC merge, Codex line, SKILL.md, and verify command. The `WISPTERM_NOTIFY_TTY` override name matches between `wispterm-notify.sh` and `test-install.sh`. The OSC string `\033]777;notify;<title>;<body>\007` is identical in the emit code and the test assertions.

**Known limitation (documented):** the Codex top-level-`notify` detection uses a `^\s*notify\s*=` grep, which could false-match a `notify` key inside a `[section]`; Codex's `notify` is documented top-level, and the no-clobber warning bounds the risk. Acceptable for v1.
