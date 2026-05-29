# Built-in "Update Skills" Feature — Design

**Date:** 2026-05-29
**Status:** Approved (design), pending implementation plan

## Goal

Add a built-in feature to phantty that downloads the latest skills from the main
repository (`xuzhougeng/phantty`, `main` branch, `plugins/skills/` directory) and
installs them into the user config directory `<config>/plugins/skills`. Users get
new/updated skills **without updating the main program**.

Out of scope (YAGNI): version negotiation, incremental diffing, signature
verification, authenticated GitHub API, configurable source repo. Each run simply
fetches the latest and overwrites same-name skills.

## Behavior summary

- Source: `xuzhougeng/phantty` `main` branch, `plugins/skills/` directory only.
- Install target: `<config>/plugins/skills` (via `platform_dirs.pluginSkillsDir`).
- Overwrite policy: replace same-name skill directories; leave other local skills
  untouched (merge, not full mirror).
- Two entry points, both routed to one orchestration function: an AI-chat slash
  command and a Command Palette action.
- Download runs on a background thread; the UI never blocks.
- On any failure, local skills are left unchanged.

## Download mechanism: Git Trees API + raw downloads

1. One API call: `GET https://api.github.com/repos/xuzhougeng/phantty/git/trees/main?recursive=1`
   (user-agent `phantty`, same client config as `update_check.zig`).
2. Filter the tree entries to paths starting with `plugins/skills/` and
   `type == "blob"`.
3. Download each file from `https://raw.githubusercontent.com/xuzhougeng/phantty/main/<path>`.
   Raw downloads are not subject to the unauthenticated API rate limit, so only the
   single tree call counts against it.

Rationale: pulls only skill files (not the whole repo), one API call total, reuses
the existing JSON-parsing style and atomic-download helper. The repo tarball
approach was rejected (downloads vendor/shaders too); the Contents API recursion
approach was rejected (many rate-limited calls, most complex logic).

## New module: `src/skill_update.zig`

Pure-logic module, peer to `update_check.zig` / `skill_registry.zig`. Single
responsibility, independently testable. No networking in the pure functions.

Constants:

- `skills_tree_api_url = "https://api.github.com/repos/xuzhougeng/phantty/git/trees/main?recursive=1"`
- `raw_base = "https://raw.githubusercontent.com/xuzhougeng/phantty/main/"`
- `skills_prefix = "plugins/skills/"`

Pure functions (all unit-testable by feeding strings):

- `parseSkillPaths(allocator, tree_json) -> [][]u8` — parse the trees response,
  return owned paths where `path` starts with `skills_prefix` and `type == "blob"`.
  Mirrors the JSON parsing style in `update_check.zig` (`jsonString` helpers).
- `rawUrlForPath(allocator, path) -> []u8` — `raw_base ++ path`.
- `installPathForPath(allocator, config_skills_dir, path) -> []u8` — map remote
  `plugins/skills/<skill>/<file...>` to `<config_skills_dir>/<skill>/<file...>`
  (strip the `plugins/skills/` prefix, join under the config skills dir).
- `skillNamesFromPaths(allocator, paths) -> [][]u8` — deduplicated set of top-level
  skill directory names (the first path segment after the prefix). Used both to
  clear same-name targets before install and for the "(N skills)" status message.

A `State` enum local to this module:

```
pub const State = enum { idle, downloading, done, failed };
```

(Independent from `update_check.State` — clearer semantics, avoids coupling to the
program-update flow.)

## Orchestration (background thread, in `App.zig`)

Reuses the async skeleton of the existing program-update download (the
`pending_download_update` pattern). Add a `pending_skill_update` field carrying the
`skill_update.State` plus a small result (count, message buffer).

Flow on the worker thread:

1. `client.fetch` GET the trees API. Non-200 / network error → `failed`.
2. `parseSkillPaths` → file path list. Empty list → `done` with count 0 (nothing to
   pull; treated as success, not an error).
3. Compute the set of top-level skill names (`skillNamesFromPaths`).
4. Stage into a temp dir `<config>/plugins/skills/.update-tmp/`: for each file,
   download with the atomic pattern (write `.part`, then rename) into the matching
   path under the temp dir.
5. After all files succeed, for each remote skill name: delete the existing
   `<config>/plugins/skills/<name>` directory, then rename the temp dir's `<name>`
   into place (per-skill atomic replace).
6. On any failure before step 5 completes for a given skill: remove the temp dir,
   set `failed`, leave local skills unchanged.
7. On success: remove the temp dir, trigger a skill rescan by invalidating cached
   skill suggestions (reuse the `/reload-skills` path's `freeSkillSuggestions()`),
   set `done` with the installed skill count.

Reuse: extract `update_install.downloadAsset`'s atomic single-file download into a
shared helper usable for both program updates and skill files (or call it directly
with absolute paths).

## Entry points

Both converge on the same orchestration function.

### Slash command (`/update-skills`)

- `ai_chat_composer.zig`: add `update_skills` to the `SlashCommand` enum; add
  `{ .command = "/update-skills", .description = "download latest skills from GitHub" }`
  to `slash_command_entries`; ensure `parseSlashCommand` recognizes it.
- `ai_chat.zig` dispatch (around line 1352): special-case `update_skills` — kick off
  the background update and append a tool message reflecting the status text.

### Command Palette ("Update Skills")

- `command_center_state.zig`: add `update_skills` to `CommandAction`; add
  `{ .title = "Update Skills", .detail = "Download the latest skills from GitHub", .shortcut = "", .action = .update_skills }`
  to `command_entries`.
- `src/renderer/overlays.zig` (the `CommandAction` switch, ~line 467): add a branch
  that calls the same orchestration function.

## Status reporting

Status text surfaced via the `pending_skill_update` state, polled on the main thread
(same model as the existing update download):

- `downloading` → `"Updating skills..."`
- `done` → `"Skills updated (N skills)"` (or `"Skills already up to date"` when N==0)
- `failed` → `"Skill update failed"`

The UI never blocks; all network/disk work happens on the worker thread.

## Error handling

- Network error / HTTP non-200 → `failed`, local unchanged.
- JSON parse failure → `failed`.
- Any single-file download failure → roll back via the temp dir; local old skills
  remain intact.
- Offline → friendly status message, no crash.

## Testing

Run natively with `zig build test` (per project baseline).

- `parseSkillPaths`: feed a fixed trees JSON sample; assert the filtered path set
  (excludes non-`plugins/skills/` paths and `type == "tree"` entries).
- `installPathForPath` / `rawUrlForPath`: path-mapping and URL-join assertions.
- `skillNamesFromPaths`: dedup + top-level name extraction.

Network/thread orchestration is not unit-tested (consistent with the existing
program-update flow); validated manually.
