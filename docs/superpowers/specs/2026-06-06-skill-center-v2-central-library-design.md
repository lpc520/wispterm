# Skill Center v2 — Central Library + (machine × software) targets

**Date:** 2026-06-06
**Status:** Approved design, pending implementation plan
**Branch:** `worktree-feat-skill-center`
**Supersedes the *model* of:** `2026-06-06-skill-center-sync-redesign-design.md`
(the local-`~/.claude` ⇆ remote, provider-locked, machine-to-machine model).
The tar transfer, line diff, scan/cache/threading, and confirm-overlay
machinery built for that model are **reused**; the data model and the
target-selection UI change.

## Why this supersedes v1.5

The shipped redesign treats the **local machine's** `~/.claude/skills` /
`~/.codex/skills` as the hub and syncs them to a server's matching dir —
**provider-locked** (claude↔claude, codex↔codex), machine-to-machine. The user
clarified the real intent:

> wispterm 是中心。一个 SKILL 我自己决定同步到哪个目标，目标 = 机器（本地 /
> 某服务器）× 软件（Claude Code / Codex）。同一个 skill 可以装到 claude 也可以
> 装到 codex —— 由我选，不是锁死。

So:

1. The **center is a wispterm-managed library** (its own directory), **not** the
   local machine's claude/codex dirs.
2. **`local` is just another target**, peer to remote servers.
3. The destination **software (claude / codex) is a per-deploy choice**, not an
   intrinsic lock. A skill is provider-agnostic in the library; where it lands is
   chosen at deploy time.

This is feasible because `~/.claude/skills` and `~/.codex/skills` use the **same
SKILL.md directory format** — deploying a library skill to either is a plain
copy into a different root.

## Goal

A Skill Center where:

- **The library** (`<config>/skills/`) is the source of truth — a flat list of
  the user's skills, each a `<name>/` dir with a `SKILL.md` (+ any files).
- A **target** = a machine (`local` or a saved SSH profile) × a software root
  (`.claude/skills` or `.codex/skills`).
- **Deploy** (`d`): copy a library skill to a target, chosen via a popup picker
  (machine → software); overwrite of a differing same-name skill asks first
  (with a diff option).
- **Import** (`i`): pull a skill from a target into the library (picker → list
  the target's skills → choose), same overwrite-confirm.
- **Preview** (`⏎`): show the selected library skill's SKILL.md.
- The library is populated **by import** (your existing `~/.claude/skills` enter
  the library via "import from local · Claude Code").

Hash stays the internal "same / differ / unknown" drift signal (computed
identically on the library and every target so they compare correctly). No
persisted skill→target assignment — targets are chosen ad-hoc each action.

## Storage

- Library root: `dirs.pathInConfigDir(allocator, "skills")` → `<config>/skills/`.
  Created on first use. Each immediate subdir with a `SKILL.md` is one library
  skill (mirrors the `.claude/skills` layout, so the existing `skill_scan`
  `skill_md` logic applies unchanged to the library root).

## Locations & targets

A **location** is "where a skill set lives + how to run shell there":

```zig
const Exec = union(enum) { local, wsl: []const u8, ssh: SshConnection };
const Location = struct {
    exec: Exec,
    root_expr: []const u8, // shell-ready root, e.g. "\"$HOME\"/.claude/skills"
                           // or a single-quoted absolute "<config>/skills"
    label: []const u8,     // display
};
```

- **Library location:** `exec = .local`, `root_expr = '<config>/skills'`
  (absolute, single-quoted).
- **Target software → `root_expr` (under `$HOME` on the target machine):**
  `claude` → `"$HOME"/.claude/skills`, `codex` → `"$HOME"/.codex/skills`.
  (Codex prompts `.codex/prompts` is a *different* flat-`.md* format — **out of
  scope for v2**.)
- **Target machine → `exec`:** `local` (this host), or `ssh:<profile>`
  (`overlays.aiHistorySshConnection`). WSL deferred.

Since the library is **always local**, every operation is **local ⇆ target**,
where the target is local or remote. There is no remote↔remote transfer.

## Scan

Generalize the scan to "list + hash the skills under one location's root":

- `skill_scan.buildLocationScanCommand(allocator, root_expr) []u8` — emits the
  same `find … | sha256sum` per-skill line format as today
  (`name \t rel \t hash`), but rooted at an arbitrary `root_expr` instead of the
  hardcoded `$HOME/<target>` list. The **same hash recipe** as the existing
  `skill_md` block, so a library skill and a target skill with identical content
  hash equal (this is what makes `same`/`differ` correct across library↔target).
- The center scan runs this with the library `root_expr` via `localPosixExec`.
- A target scan runs it with the software `root_expr` via the machine's exec
  (`localPosixExec` / `sshExecCapture`).
- `parseScanOutput` reuses the existing parser (provider field becomes a fixed
  label — see note). Rows carry `{ name, rel_path, agg_hash }`.

> Provider note: library skills are provider-agnostic, so the `provider` column
> of the existing scan output is dropped from the v2 line format (or emitted as a
> constant and ignored). `SkillRow` loses `provider` (or keeps it unused). The
> v2 model keys skills by **name** alone within a single location.

## Operations

### Deploy (library → target)

1. User selects a library skill, presses `d`.
2. Popup picker: pick **machine** (local / each SSH profile), then **software**
   (Claude Code / Codex). Yields a target `Location`.
3. Compare: hash the library skill vs the target's same-name skill (a quick
   targeted scan or a single hash of that one skill).
   - target absent → copy directly.
   - target present & equal hash → no-op toast "already in sync".
   - target present & differs → **confirm** ("overwrite? [v] diff / [⏎] / [esc]").
4. On proceed: tar the library skill dir, place it at the target root with the
   stage-then-swap (atomic, no corruption on failure).

### Import (target → library)

1. User presses `i`.
2. Popup picker → target `Location`.
3. Scan the target; show its skills in a transient overlay list, marking which
   are already in the library (same / differs / new).
4. User selects one (or more); for each: overwrite-confirm if the library
   already has a differing same-name skill; then tar target→library.

### Preview (`⏎`)

`cat` the selected **library** skill's SKILL.md via `localPosixExec` and show it
in the markdown preview (reuse `markdown_preview_panel.open`). (Compare-diff is
surfaced at overwrite-confirm time via `skill_diff`.)

## Transfer (generalized)

The library is always the local side; the target is local or remote.

- **`skill_transfer_cmd`** (pure) takes an explicit `root_expr` instead of a
  provider-derived `$HOME/<root>`:
  - `tarCreateCmd(allocator, root_expr, item, tmp)` → `tar -czf '<tmp>' -C <root_expr> '<item>'`
  - `tarExtractCmd(allocator, root_expr, item, tmp)` → stage-then-swap under
    `D=<root_expr>` (unchanged logic; root is now a passed expression).
- **`skill_transfer`** (impure) generalizes `upload`/`download` into:
  - `deploy(ops, src_root_expr, dst_root_expr, dst_is_local, name)` and
    `importSkill(ops, src_root_expr, dst_root_expr, src_is_local, name)` — or a
    single `transfer(ops, from, to, name)` where `from`/`to` each carry
    `{ root_expr, is_local }`.
  - **local → local** (deploy to a local target, or import from a local target):
    `localExec tarCreate(src_root…)` then `localExec tarExtract(dst_root…)` — no
    `copy` hop.
  - **local ⇆ remote:** local tar create + `copy` (scp) + remote extract (or the
    reverse), exactly today's dance.
  - Reuses the exit-checked `localPosixExecOk`, `sshExecCapture`, `scp.transfer`.

## UI

- **`skill_center.zig` PanelModel** holds: the **library skill list**
  (`[]LibrarySkill { name, rel_path, agg_hash }`), `sel_row`, `scroll`, and
  overlay state: `none | picker(PickerState) | import_list(ImportState) |
  confirm(ConfirmState) | busy`.
- **`renderer/skill_center_renderer.zig`** renders a **single-column library
  list** (name + a subtle "in N targets" is *not* tracked in v2 — keep it a
  clean list), header `Skill Center · Library N`, an action legend
  (`[⏎] preview  [d] deploy  [i] import  [r] rescan`), and the overlays:
  - **Picker overlay:** two steps — a machine list, then a software list.
  - **Import-list overlay:** the chosen target's skills with a per-row
    new/same/differs marker.
  - **Confirm bar:** the existing overwrite-confirm.
- **Keys** (`input.zig`): `↑/↓` move; `d` deploy (open picker); `i` import (open
  picker); `⏎` preview (or, inside an overlay, confirm/select); `esc` close
  overlay; `r` rescan library. The picker uses `↑/↓` + `⏎` to choose, `esc` to
  back out.
- All strings via **i18n** (`sc_*` keys; add picker/import keys). No hardcoded
  locale text — this was a bug in v1.5.

## Reuse vs change

| Component | v2 disposition |
|---|---|
| `skill_diff.zig` | **Reuse unchanged.** |
| tar dance (`skill_transfer*`) | **Generalize** to explicit roots + local↔local case; tar/scp primitives unchanged. |
| confirm overlay, busy, Session/scan threading, cache | **Reuse** (cache now keyed by location). |
| `skill_scan` | **Generalize** to scan one location by `root_expr`; drop provider from the line format. |
| `skill_pairing` | **Repurpose** for the import-list compare (library vs one target by name) or fold into a small name-compare; the v1.5 two-column "local-vs-server" usage is removed. |
| renderer | **Rewrite** to library list + picker/import/confirm overlays. |
| `AppWindow.zig` skill-center wiring | **Rewrite** the source enumeration (library + picker-driven target) and the deploy/import drivers; transfer worker generalized. |
| provider-scoping invariant | **Removed** — destination software is a choice, not a lock. |

## Error handling

- Target machine offline: deploy → toast "can't connect to <machine>"; import →
  same. Library is local so it's always reachable.
- No POSIX locally (Windows w/o WSL): library + local targets disabled with a
  clear note; SSH targets still work for deploy/import via the remote side, but
  the library (local) side needs local POSIX — so on such hosts the panel is
  inventory-only. (Same constraint as v1.5.)
- Transfer failure: stage-then-swap leaves the live target/library skill intact;
  toast surfaces the failing step (exit-checked local + remote exec).

## Testing

- **`skill_transfer_cmd`**: tar create/extract with arbitrary `root_expr`
  (absolute library path *and* `$HOME`-relative target); quote-escaping; stage-
  then-swap shape.
- **`skill_transfer`**: deploy/import for both local→local (no copy) and
  local↔remote (copy hop) via fakes — assert the step ordering per case.
- **`skill_scan`**: `buildLocationScanCommand` shape for an absolute root and a
  `$HOME` root; parser tolerance.
- **`skill_diff`**: unchanged.
- **model**: picker state machine (machine→software→target), overwrite decision
  (absent→direct, same→noop, differ→confirm), import-list new/same/differs
  marking, selection clamping.
- **renderer**: library list, picker rendering, glyph/marker mapping.

## Out of scope (later)

- Codex prompts (`.codex/prompts`, flat `.md`) as a target software.
- WSL-distro targets.
- Remote↔remote transfer.
- Persisted deploy targets / "deploy to all" bulk.
- Editing skills in place / creating skills in the panel (library populated by
  import for v2).
- A per-library-skill "deployed to which targets" status matrix (intentionally
  omitted to avoid the v1 noise).
