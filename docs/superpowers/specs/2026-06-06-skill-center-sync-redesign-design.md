# Skill Center Redesign — 本地中心 + 分发/拉取 (Sync)

**Date:** 2026-06-06
**Status:** Approved design, pending implementation plan
**Branch:** `worktree-feat-skill-center`
**Supersedes the *direction* of:** `2026-06-06-skill-center-design.md` (the
read-only N-server matrix). The scan / cache / threading / source-enumeration
foundation from that spec is **kept and reused**; only the comparison model and
the UI change, and file transfer (previously out of scope) becomes core.

## Why redesign

The shipped v1 renders a `skills × servers` matrix with a modal-reference-hash
cell state (`✓ / ≠ / ✗ / ?`). In real use it reads as "意义不明":

1. **Indistinguishable columns** — every remote column header truncates to
   `ss` (`ssh:<name>` → 2 chars), so a matrix built to compare servers can't
   tell its servers apart.
2. **Mostly noise** — most remote columns are entirely `?` (offline, or no
   `sha256sum`/`shasum`). A 9×8 grid where ~75% of cells mean "couldn't check".
3. **2-D grid carrying 1-D information** — when each skill exists on only one
   reachable server, the modal reference *is* that server, so `≠` never appears;
   the matrix degenerates into a "local-xor-remote" presence map.
4. **No action possible** — preview / push / pull / sync were all deferred, so
   seeing a divergence leads nowhere. This is the real source of "看了没用".
5. **Doesn't scale** — one column per server overflows past ~4–5 machines.

### What the user actually wants

> 本地作为一个 SKILL 中心，分发给不同服务器，也可以从服务器把技能下载到本地
> 管理。同步时同名技能要先对比差异再决定保存。hash 不是重点。
>
> 核心面板展示本地的 SKILL，选择一台服务器：点本地的可以上传，点远程的可以
> 下载；本地和远程都能查看对比；下载/上传覆盖时给一个"是否覆盖"提示即可。
> 「哪些 skill 发给哪台」不持久化，每次临时选。

So the panel is **not** a passive cross-server status board. It is a
**local-hub distribution tool**: one server at a time, local on the left, the
selected server on the right, with upload / download / diff and an overwrite
confirm. Hash is demoted from the product to an internal "same / differ" signal.

## Goal

A two-pane Skill Center where **local is the hub**:

- **Left** = all local skills (the hub library); **right** = the **one**
  currently-selected server's skills; a server picker in the header.
- Rows are **aligned by `(provider, name)`** so each row shows local status and
  remote status side by side.
- **Upload** (local → selected server) and **download** (selected server →
  local) a skill, off the UI thread.
- Same-name skills can be **diffed** before acting.
- Overwriting an existing, differing copy shows a **confirm** ("覆盖？"); a
  matching copy is a no-op; an absent target transfers directly.
- The "which skill → which server" relationship is **not persisted**; targets
  are chosen ad-hoc each time.

Hash stays only as the cheap per-row drift flag ("same / differ / unknown").

## What is reused vs replaced

| Component | Disposition |
|---|---|
| `src/skill_scan.zig` (scan one host → rows + agg_hash) | **Reuse unchanged.** |
| `runScan` + source enumeration in `AppWindow.zig` (local + WSL + SSH) | **Reuse.** Still scan **all** known servers so switching the selected server is instant from the in-memory result set. |
| `src/skill_inventory_cache.zig` (persist `[]ServerScan`) | **Reuse.** Seeds the panel for instant open. |
| `skill_center.zig` `Session` / `ScanWork` threading (mutex + generation) | **Reuse**, extended with a transfer worker of the same shape. |
| `skill_inventory.zig` `ServerScan` type | **Keep** (cache + scan depend on it). |
| `skill_inventory.zig` modal `Matrix` / `buildMatrix` / `CellState` | **Replace** with pairwise pairing (below). Modal-reference logic is wrong for a local-vs-one-server comparison. |
| `renderer/skill_center_renderer.zig` (N-column grid) | **Rewrite** as a two-column aligned list + header picker + overlays. |
| `src/scp.zig` `sshExec` / `transfer` / `sshWriteFile`; `remote_file.localPosixExec` / `sshExecCapture` | **Reuse** as transfer primitives. |

## Architecture & components

Keeps the project's pure / impure split.

### Pure modules (unit-tested)

**`src/skill_pairing.zig`** — the new comparison heart (replaces the modal
matrix).

```zig
pub const Relation = enum {
    same,         // present both sides, agg_hash equal
    differ,       // present both sides, agg_hash differ (both hashable)
    local_only,   // present locally, absent on the server
    remote_only,  // absent locally, present on the server
    unknown,      // present both sides but one side has null hash (can't tell)
};

pub const PairRow = struct {
    provider: Provider,
    name: []const u8,        // borrowed from the underlying ServerScan rows
    local_rel_path: ?[]const u8,
    remote_rel_path: ?[]const u8,
    relation: Relation,
};

/// Align one local scan against one server scan into a sorted, deduped list.
/// `remote_reachable=false` makes every both-present/remote-present row `unknown`
/// instead of asserting a diff. Pure; borrows from the inputs (no ownership).
pub fn pair(
    allocator: std.mem.Allocator,
    local: inv.ServerScan,
    remote: inv.ServerScan,
    remote_reachable: bool,
) ![]PairRow;
```

Sort: provider then name, stable, deterministic. Union of names; each side's
presence + `agg_hash` decides `relation`. This is a direct pairwise compare —
no modal reference, no cross-server aggregation.

**`src/skill_transfer_cmd.zig`** — pure builders for the shell strings used by
the transfer runner, so the dangerous parts (quoting, paths) are testable
without I/O:

- `tarCreateCmd(root_rel, skill_dir, tmp)` → `tar -czf '<tmp>' -C "$HOME/<root>" '<skill_dir>'`
- `tarExtractCmd(root_rel, dir, tmp)` → stage-then-swap: `mkdir -p "$HOME/<root>" && rm -rf '<stage>' && tar -xzf '<tmp>' -C '<stage_parent>' && rm -rf "$HOME/<root>/<dir>" && mv '<stage>' "$HOME/<root>/<dir>"` (extract into a sibling `<dir>.wisptmp`, then atomic swap; a failed extract never touches the live skill)
- All names single-quote-escaped (mirrors `previewCommand` / `scp.appendShellQuote`).

**`src/skill_diff.zig`** — a minimal pure line diff for the SKILL.md preview
(LCS → added / removed / context spans). Used to render the compare view. Only
the primary `SKILL.md` is diffed in this version (whole-directory drift is still
flagged by `agg_hash`; see Out of scope).

### Impure orchestration

**`src/skill_transfer.zig`** — runs a transfer off the UI thread using only
existing primitives, via a temp-file tar dance (avoids needing new bidirectional
ssh-stream plumbing):

- **Upload (local → server):**
  1. local `tar -czf <localtmp> -C ~/<root> <skill_dir>` via `remote_file.localPosixExec`
  2. `scp.transfer(localtmp → user@host:<remotetmp>)`
  3. remote `sshExec` runs `tarExtractCmd` (stage into `<dir>.wisptmp`, atomic
     swap onto `~/<root>/<dir>`, `rm -f <remotetmp>`)
  4. clean up `localtmp`
- **Download (server → local):**
  1. remote `sshExec`: `tar -czf <remotetmp> -C ~/<root> <skill_dir>`
  2. `scp.transfer(user@host:<remotetmp> → localtmp)`
  3. local runs `tarExtractCmd` via `localPosixExec` (stage + atomic swap onto
     `~/<root>/<dir>`)
  4. clean up both temps
- The atomic swap **is** the clean-replace: a fresh extract fully replaces the
  target skill dir, and a failed extract leaves the live skill untouched. There
  is no separate destructive `rm` before a successful extract.
- Result enum `{ ok, failed, cancelled }`; runs on a worker thread mirroring the
  scan worker; on success it triggers a rescan of the affected server so the
  pairing refreshes.

Prompt-style single-file skills (`.codex/prompts/*.md`) use the same tar path
(tar of a single file), so one code path covers both formats.

### UI / model

**`skill_center.zig` `PanelModel`** gains:

- `sel_server: usize` — index of the selected server **among remote servers**
  (local is always the left pane, never a selectable target).
- `pairing: ?[]PairRow` — rebuilt from `servers[local]` vs `servers[sel_server]`
  whenever the scan result or `sel_server` changes.
- `overlay: union(enum) { none, confirm: ConfirmState, diff: DiffState, busy: []const u8 }`
  for the overwrite confirm, the compare view, and a transfer-in-progress note.
- `sel_row`, `scroll` stay; `sel_col` is dropped (only two fixed columns).

**`renderer/skill_center_renderer.zig`** rewritten:

```
┌ Skill Center   本地 ⇆ web-1   [s 换服务器]   本地 9 · 远程 4 ───────────┐
│                                   本地     web-1                          │
│  ──────────────────────────────────────────────────────────────────────  │
│    cla homologo                    —        ✓     仅远程 → 可下载         │
│  ▸ cla roundtable                  ✓        ≠     不同 → 可对比/覆盖      │
│    cla jcvi-sync                   ✓        —     仅本地 → 可上传         │
│    cod release                     ✓        ?     远程无法校验            │
│  ──────────────────────────────────────────────────────────────────────  │
│  ✓ 存在   ≠ 内容不同   — 不存在   ? 无法校验                              │
│  [⏎]预览/对比   [u]上传→web-1   [d]从 web-1 下载   [s]换服务器           │
└──────────────────────────────────────────────────────────────────────────┘
```

- Two fixed status columns: **本地** and the **selected server name** (real
  name, not `ss`).
- Per-row glyphs from `Relation`: local col `✓`/`—`; remote col
  `✓`(same) / `≠`(differ) / `—`(absent) / `?`(unknown). A trailing hint string
  states the available action.
- Header shows `本地 ⇆ <server>` and counts; legend + action keys pinned bottom.
- Reuses the existing `ai_history_renderer.DrawContext` seam (no new AppWindow
  draw wiring), same as today.

**Overlays:**

- **Diff** (`⏎` on a both-present row): fetch local + remote `SKILL.md`
  (`previewCommand` already builds the `cat`), run `skill_diff`, render
  added/removed lines in the preview band. One-side rows just preview that
  side's content.
- **Confirm** (`u`/`d` that would overwrite a differing target): a small modal
  `<server> 已有 <skill>（内容不同），覆盖？  [v 查看 diff] [⏎ 覆盖] [esc 取消]`.
  Reuse the app's existing confirm/overlay pattern if one exists in the file
  explorer remote-op path; otherwise a minimal inline confirm bar.
- **Busy**: a transient `上传中… / 下载中…` line while the transfer worker runs.

### Keys

| Key | Action |
|---|---|
| `↑ ↓` | move row selection |
| `s` | open server picker / cycle selected server |
| `u` | upload selected skill → selected server (confirm if differing target) |
| `d` | download selected skill ← selected server (confirm if differing local) |
| `⏎` | preview / diff the selected row |
| `r` | rescan |
| `esc` | close overlay / panel |

## Data flow

1. Open panel → seed from cache (instant), then background `runScan` over **all**
   sources; header shows `Scanning… N/M`.
2. Build `pairing` from local vs the selected server (default = first remote).
3. `s` re-points `sel_server` and rebuilds the pairing from the already-scanned
   in-memory results — **no new scan** needed to switch servers.
4. `u`/`d`:
   - target absent → transfer immediately.
   - target present & `same` → no-op, toast "已一致".
   - target present & `differ`/`unknown` → confirm overlay → on confirm,
     transfer with clean-replace.
5. Transfer runs on a worker; on `ok`, rescan that one server and rebuild the
   pairing so the row flips to `same`.

## Error handling

- **Selected server offline**: its rows render `?`; `u` still allowed (will fail
  → toast "无法连接 <server>"); `d` disabled (nothing to read).
- **No hash tool on a side**: that row is `unknown` (`?`); transfer treats it as
  overwrite (always confirm before clobbering).
- **Transfer failure** (auth, tar missing, disk): worker returns `failed`; a
  toast surfaces the failing step and no partial state is left behind. Because a
  bare `tar -xzf` over a live skill dir can leave it half-written if the
  transfer dies mid-extract, the runner always **stages then swaps**: extract
  into a sibling temp dir (`<name>.wisptmp/`), and only on a clean exit do
  `rm -rf <name> && mv <name>.wisptmp <name>`. A failed extract leaves the live
  skill untouched and just removes the temp dir. This is the concrete meaning of
  `clean_dir`/clean-replace above.
- **No POSIX locally** (Windows w/o WSL): upload/download disabled with a clear
  note; inventory still shows local via the existing local-exec path.
- **Stale generation**: scan + transfer workers both honor the generation
  counter; late results from a superseded action are discarded.

## Testing

- **`skill_pairing`**: union/sort/dedup; every `Relation` (same / differ /
  local_only / remote_only / unknown); `remote_reachable=false` ⇒ all-`unknown`;
  null-hash on either side ⇒ `unknown` not `differ`.
- **`skill_transfer_cmd`**: tar create/extract command shape; quote-escaping of
  hostile skill names; the extract command stages into `<dir>.wisptmp` and swaps
  with `mv` (never extracts straight over the live dir).
- **`skill_diff`**: identical inputs ⇒ no diff; add-only / remove-only /
  interleaved; empty file vs non-empty.
- **`skill_center` model**: `sel_server` switch rebuilds pairing without a
  rescan; overwrite-decision logic (absent⇒direct, same⇒no-op,
  differ⇒confirm); selection clamping when pairing shrinks.
- **renderer**: glyph mapping per `Relation`; two-column layout capacity /
  scroll clamp (reuse existing helper tests).
- **transfer runner**: drive with a fake exec/transfer seam (like the scan fake)
  to assert the upload/download step ordering and the rescan-on-success.

## Out of scope (later specs)

- Persisted per-server assignment / "应有清单" (explicitly chosen: ad-hoc only).
- Per-file diff for non-`SKILL.md` files (whole-dir drift still flagged by hash).
- Three-way / conflict merge — v1 is overwrite-with-confirm only.
- WSL-distro transfer targets (SSH + local only first).
- Bulk "整机对齐" (push all local skills to one server) — natural follow-up once
  single-skill transfer is proven.
- Project-level (`<project>/.claude/skills/`) and plugin skills.
