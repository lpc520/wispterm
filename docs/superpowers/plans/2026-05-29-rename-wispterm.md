# Rename Phantty → WispTerm Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Note on style:** This is a mechanical rename, not feature work. Steps are "transform → verify build/tests green → grep-audit → commit" rather than test-first TDD. The existing test suite is the safety net; do not delete or weaken tests, only let the rename update their assertion strings.

**Goal:** Rename the project Phantty → WispTerm across code, build, packaging, website, docs, and bundled skills; replace the app icon with the user-supplied `wispterm.png`; update the README intro — without migrating user config and without touching historical records or protected external references.

**Architecture:** A shared case-aware replacement helper (`/tmp/rename_wispterm.py`) applies `PHANTTY→WISPTERM`, `Phantty→WispTerm`, `phantty→wispterm` to a given list of text files, while protecting the literals `arya-s/phantty` (upstream fork) and `phantty.cc-remote.app` (kept domain). A Pillow icon script regenerates `.png/.ico/.icns` from the new artwork. All code+build identifiers are renamed in one atomic task (a half-renamed build can't compile); packaging, docs-content, and skills follow as separate build-green tasks. Each task verifies `zig build test` and audits with grep before committing.

**Tech Stack:** Zig (`zig build test`), Python 3 + Pillow 11.1 (icons + rename helper), git.

---

## Setup (do once, before Task A)

These create throwaway scripts in `/tmp` (not committed) used by later tasks.

- [ ] **Step S1: Create the rename helper** `/tmp/rename_wispterm.py`

```python
#!/usr/bin/env python3
"""Case-aware Phantty->WispTerm rename for a list of text files.
Protects external/kept literals. Skips binary (non-UTF-8) files.
Usage: rename_wispterm.py <file> [<file> ...]"""
import sys

PROTECT = {
    "arya-s/phantty": "\x00ARYAFORK\x00",
    "phantty.cc-remote.app": "\x00KEPTDOMAIN\x00",
}

def transform(text: str) -> str:
    for lit, sent in PROTECT.items():
        text = text.replace(lit, sent)
    text = text.replace("PHANTTY", "WISPTERM")
    text = text.replace("Phantty", "WispTerm")
    text = text.replace("phantty", "wispterm")
    for lit, sent in PROTECT.items():
        text = text.replace(sent, lit)
    return text

changed = 0
for path in sys.argv[1:]:
    try:
        with open(path, "rb") as f:
            raw = f.read()
        text = raw.decode("utf-8")
    except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
        continue  # binary/dir/missing -> skip
    new = transform(text)
    if new != text:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new)
        print("changed", path)
        changed += 1
print(f"[rename] {changed} file(s) changed")
```

- [ ] **Step S2: Create the icon generator** `/tmp/gen_icons.py`

```python
#!/usr/bin/env python3
"""Generate WispTerm icon assets from the root wispterm.png."""
from PIL import Image

SRC = "wispterm.png"
im = Image.open(SRC).convert("RGBA")
w, h = im.size
s = min(w, h)
left, top = (w - s) // 2, (h - s) // 2
master = im.crop((left, top, left + s, top + s))  # center-cropped square

# 256x256 RGBA PNGs
png = master.resize((256, 256), Image.LANCZOS)
png.save("assets/wispterm.png")
png.save("docs/assets/wispterm.png")

# Multi-size .ico
master.save("assets/wispterm.ico", format="ICO",
            sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])

# .icns (Pillow writes up to a 1024 entry, upscaling as needed)
master.save("assets/wispterm.icns", format="ICNS")

print("icons written: assets/wispterm.png, docs/assets/wispterm.png, "
      "assets/wispterm.ico, assets/wispterm.icns")
```

- [ ] **Step S3: Sanity-check the helper protects the right literals**

Run:
```bash
printf 'xuzhougeng/phantty arya-s/phantty Phantty PHANTTY phantty phantty.cc-remote.app' > /tmp/rn_probe.txt
python3 /tmp/rename_wispterm.py /tmp/rn_probe.txt && cat /tmp/rn_probe.txt
```
Expected output line:
`xuzhougeng/wispterm arya-s/phantty WispTerm WISPTERM wispterm phantty.cc-remote.app`
(only `xuzhougeng/phantty` and the bare casings changed; `arya-s/phantty` and the domain intact.)

---

## Task A: Rename all code + build + icons (atomic green-build task)

Renames everything the Zig build/compiler resolves, so the build goes from green (Phantty) to green (WispTerm) in one commit. This is the large, behavior-critical task.

**Files:**
- Generate/rename: `assets/wispterm.{png,ico,icns}`, `docs/assets/wispterm.png`, `assets/wispterm.rc`, `src/wispterm_docs.zig`; delete `assets/phantty.aseprite`; commit root `wispterm.png`.
- Modify (hand-checked): `build.zig`, `build.zig.zon`, `src/app_metadata.zig`, `src/platform/dirs.zig`, `src/update_check.zig`, `src/skill_update.zig`, `src/renderer/overlays.zig`.
- Modify (bulk via helper): all of `src/**` and `tests/**`.

- [ ] **Step A1: Generate icons and stage the source**

Run from repo root:
```bash
python3 /tmp/gen_icons.py
git add wispterm.png
```
Expected: prints the four written paths; `assets/wispterm.png`, `assets/wispterm.icns`, `assets/wispterm.ico`, `docs/assets/wispterm.png` now exist.

- [ ] **Step A2: Rename tracked files with git mv**

```bash
git mv assets/phantty.rc assets/wispterm.rc
git mv src/phantty_docs.zig src/wispterm_docs.zig
git rm assets/phantty.aseprite
git rm assets/phantty.png assets/phantty.ico assets/phantty.icns docs/assets/phantty.png
git add assets/wispterm.png assets/wispterm.ico assets/wispterm.icns docs/assets/wispterm.png
```
(The old binary icon files are removed; the new ones from A1 are added. `git mv` of `.rc`/`.zig` preserves history.)

- [ ] **Step A3: Fix the `.rc` icon reference**

`assets/wispterm.rc` currently contains `1 ICON "phantty.ico"`. Replace its entire contents with:
```
1 ICON "wispterm.ico"
```

- [ ] **Step A4: Run the rename helper over all code + build files**

```bash
cd /home/xzg/project/phantty
python3 /tmp/rename_wispterm.py build.zig build.zig.zon $(git ls-files 'src/*' 'tests/*')
```
Expected: prints `changed ...` lines for every file containing the name (including `src/wispterm_docs.zig`, `build.zig`, `build.zig.zon`, `src/app_metadata.zig`, `src/platform/dirs.zig`, `src/update_check.zig`, `src/skill_update.zig`, `src/renderer/overlays.zig`, and many more) and a final `[rename] N file(s) changed`.

This converts, among others:
- `app_metadata.name` `"Phantty"` → `"WispTerm"`.
- `dirs.zig` `app_dir_name`/`portable_config_basename` and all test path assertions and `/tmp/phantty-test-config` → `/tmp/wispterm-test-config`.
- all `xuzhougeng/phantty` → `xuzhougeng/wispterm` in update/skill/overlays (+ their test fixtures).
- `build.zig` macOS metadata (`Phantty.app`, `Phantty`, `com.phantty.terminal`, icon paths → `assets/wispterm.icns`/`.rc`), exe `.name "phantty"` → `"wispterm"`, test-step names `phantty-*` → `wispterm-*`, embed-import names `phantty_doc_*` → `wispterm_doc_*` (matched on both sides by `src/wispterm_docs.zig`), and build.zig's own assertion strings.
- `build.zig.zon` `.name = .phantty` → `.name = .wispterm`.
- every `@import("phantty_docs.zig")` → `@import("wispterm_docs.zig")`.

- [ ] **Step A5: Build — handle the `build.zig.zon` fingerprint if Zig rejects it**

Run:
```bash
zig build test 2>&1 | tail -25
```
- If it builds and tests pass: continue to A6.
- If Zig errors that the `.fingerprint` is invalid/does not match the package name, it prints the correct value (e.g. `note: the correct fingerprint is 0x...`). Edit `build.zig.zon` and set `.fingerprint = 0x<that value>,`, then re-run `zig build test 2>&1 | tail -25`.

Expected after this step: build succeeds; only the pre-existing `[config] (warn)` lines appear; all tests pass.

- [ ] **Step A6: Verify the behavior-critical changes by eye**

Run:
```bash
grep -n 'wispterm' src/app_metadata.zig
grep -n 'app_dir_name\|portable_config_basename' src/platform/dirs.zig
grep -rn 'xuzhougeng/' src/update_check.zig src/skill_update.zig src/renderer/overlays.zig
grep -n 'executable_name\|bundle_identifier\|bundle_dir\|wispterm.icns\|wispterm.rc' build.zig
grep -n '\.name = ' build.zig.zon
```
Confirm: display name `"WispTerm"`; `app_dir_name = "wispterm"`, `portable_config_basename = "wispterm.conf"`; all GitHub URLs are `xuzhougeng/wispterm`; macOS `WispTerm.app`/`WispTerm`/`com.wispterm.terminal`/`assets/wispterm.icns`; `.name = .wispterm`. No `phantty` remains in these files.

- [ ] **Step A7: Confirm no stray phantty in code/build (and protected literals intact)**

```bash
grep -rni 'phantty' build.zig build.zig.zon $(git ls-files 'src/*' 'tests/*') ; echo "exit=$?"
```
Expected: no matches (`exit=1`). If any remain, they are real misses — fix them (re-run the helper on the file or hand-edit) and re-verify.

- [ ] **Step A8: Cross-compile baseline (Windows target)**

```bash
zig build test-full -Dtarget=x86_64-windows-gnu 2>&1 | tail -15
```
Expected: matches the known-green baseline (497/499: 1 known Windows-API failure, 1 skip). No NEW failures introduced by the rename.

- [ ] **Step A9: Commit**

```bash
git add -A
git commit -m "refactor: rename code+build+icons Phantty -> WispTerm

- app name, config dir (wispterm, no migration), package name, binary, macOS bundle
- own GitHub repo URLs xuzhougeng/phantty -> xuzhougeng/wispterm
- regenerate icon assets (png/ico/icns) from new wispterm.png
- rename src/phantty_docs.zig -> src/wispterm_docs.zig"
```

---

## Task B: Packaging, CI/release, tools, remote/ website

No effect on `zig build test`; verify the build still configures and scripts are name-consistent. **Coupling note:** the release workflows in `.github/workflows/` produce asset names like `phantty-windows-portable-<tag>.zip` and `phantty-macos-<arch>-<tag>.dmg`. Task A already renamed the asset-name matcher (`src/platform/update_package.zig` / `src/update_check.zig`) to expect `wispterm-...`, so these workflows MUST be renamed to match or auto-update/skill flows would mismatch released assets. `tools/test-windows-release-assets.mjs` validates these names.

**Files:**
- Rename: `packaging/windows/Install-Phantty.ps1` → `Install-WispTerm.ps1`; `packaging/macos/Phantty.entitlements` → `WispTerm.entitlements`.
- Modify (bulk via helper): all of `packaging/**`, `.github/**`, `tools/**`, `debug/**`, `pkg/opengl/build.zig`, and `remote/**` (excluding `remote/node_modules`, which is untracked/ignored — `git ls-files` already omits it).

- [ ] **Step B1: Rename packaging files**

```bash
git mv packaging/windows/Install-Phantty.ps1 packaging/windows/Install-WispTerm.ps1
git mv packaging/macos/Phantty.entitlements packaging/macos/WispTerm.entitlements
```

- [ ] **Step B2: Run the helper over packaging, CI, tools, debug, pkg comment, remote**

```bash
cd /home/xzg/project/phantty
python3 /tmp/rename_wispterm.py pkg/opengl/build.zig \
  $(git ls-files 'packaging/*' '.github/*' 'tools/*' 'debug/*' 'remote/*')
```
Expected: `changed ...` lines for the packaging scripts, `.github/workflows/*.yml` (release asset names `phantty-*` → `wispterm-*`) and `.github/ISSUE_TEMPLATE/*`, `tools/*` (incl. `test-windows-release-assets.mjs`, `kitty_graphics.py`), `debug/*.ps1`, `pkg/opengl/build.zig` (a code comment), and remote website/app files. (Any `phantty.cc-remote.app` occurrences are left intact by the helper.)

- [ ] **Step B3: Verify release asset names now match the matcher**

```bash
grep -rn 'windows-portable\|macos-' .github/workflows/*.yml | grep -i wispterm | head
grep -rn 'wispterm-windows-portable\|matchesAssetName' src/platform/update_package.zig | head
```
Expected: the workflows now emit `wispterm-windows-portable-*` / `wispterm-macos-*`, consistent with the renamed matcher in `update_package.zig`. No `phantty-` asset names remain in the workflows.

- [ ] **Step B4: Audit packaging/CI/tools/debug/pkg/remote**

```bash
grep -rni 'phantty' pkg/opengl/build.zig \
  $(git ls-files 'packaging/*' '.github/*' 'tools/*' 'debug/*' 'remote/*') \
  | grep -vi 'phantty.cc-remote.app' ; echo "exit=$?"
```
Expected: no matches except (filtered-out) the kept domain. Any other stray `phantty` → fix it.

Then confirm the build still configures:
```bash
zig build --help >/dev/null 2>&1 && echo "build config OK"
```
Expected: `build config OK`.

- [ ] **Step B5: Commit**

```bash
git add -A
git commit -m "refactor: rename packaging, CI/release, tools, remote Phantty -> WispTerm"
```

---

## Task C: Docs + top-level prose (README intro verbatim)

Docs `.md` files are embedded by path (e.g. `docs/faq.md`), so editing their content does not affect the build. Excludes historical records.

**Files:**
- Modify (bulk via helper): `README.md`, `AGENTS.md`, `CONTRIBUTING.md`, `TODO.md`, `Makefile`, and `docs/**` EXCEPT `docs/superpowers/**` and `docs/CNAME`.
- Hand-edit: `README.md` intro paragraph.

- [ ] **Step C1: Run the helper over docs + top-level prose (excluding history)**

```bash
cd /home/xzg/project/phantty
python3 /tmp/rename_wispterm.py README.md AGENTS.md CONTRIBUTING.md TODO.md Makefile \
  $(git ls-files 'docs/*' | grep -v '^docs/superpowers/' | grep -v '^docs/CNAME$')
```
Expected: `changed ...` lines for these files. `docs/CNAME` is not in the list; `docs/superpowers/*` (this spec/plan + historical) is excluded.

- [ ] **Step C2: Replace the README intro paragraph by hand**

In `README.md`, the current opening description paragraph (after the title) begins with `A terminal written in Zig, powered by ...` (now partially rewritten by the helper to start with `WispTerm`/`A terminal written in Zig`). Replace that entire opening description paragraph with exactly:

```markdown
**WispTerm**, formerly Phantty, is a cross-platform terminal workspace for remote development and AI agent workflows. It is written in Zig and powered by libghostty-vt for terminal emulation.
```

Leave the existing fork-attribution note block (the `> [!NOTE]` mentioning `arya-s/phantty`) in place — confirm its `arya-s/phantty` link is unchanged.

- [ ] **Step C3: Verify CNAME, domain, and fork link are intact**

```bash
cat docs/CNAME
grep -rn 'arya-s/phantty' README.md
grep -rn 'phantty.cc-remote.app' $(git ls-files 'docs/*' | grep -v '^docs/superpowers/') README.md 2>/dev/null
```
Expected: `docs/CNAME` still reads `phantty.cc-remote.app`; the README fork note still links `arya-s/phantty`; any domain references are still `phantty.cc-remote.app`.

- [ ] **Step C4: Audit docs (history excluded) for stray non-protected phantty**

```bash
grep -rni 'phantty' README.md AGENTS.md CONTRIBUTING.md TODO.md Makefile \
  $(git ls-files 'docs/*' | grep -v '^docs/superpowers/' | grep -v '^docs/CNAME$') \
  | grep -vi 'arya-s/phantty' | grep -vi 'phantty.cc-remote.app' ; echo "exit=$?"
```
Expected: no matches except intentional ones (e.g. the literal word "Phantty" in "formerly Phantty" in the README intro is intended — confirm any matches are that or the fork note). The `formerly Phantty` mention is expected and correct.

- [ ] **Step C5: Confirm build still green (docs are embedded)**

```bash
zig build test 2>&1 | tail -6
```
Expected: build succeeds, tests pass.

- [ ] **Step C6: Commit**

```bash
git add -A
git commit -m "docs: rename Phantty -> WispTerm in README/docs/website; new README intro"
```

---

## Task D: Bundled skills + final repo-wide audit

**Files:**
- Rename: `plugins/skills/phantty-diagnostics/` → `plugins/skills/wispterm-diagnostics/` and its script `collect_phantty_diagnostics.ps1` → `collect_wispterm_diagnostics.ps1`.
- Modify (bulk via helper): all of `plugins/**`.

- [ ] **Step D1: Rename the skill dir and script**

```bash
git mv plugins/skills/phantty-diagnostics plugins/skills/wispterm-diagnostics
git mv plugins/skills/wispterm-diagnostics/scripts/collect_phantty_diagnostics.ps1 \
       plugins/skills/wispterm-diagnostics/scripts/collect_wispterm_diagnostics.ps1
```

- [ ] **Step D2: Run the helper over plugins**

```bash
cd /home/xzg/project/phantty
python3 /tmp/rename_wispterm.py $(git ls-files 'plugins/*')
```
Expected: `changed ...` lines for the skill's `SKILL.md`, the renamed script, and any `agents/openai.yaml` referencing the name.

- [ ] **Step D3: Audit plugins**

```bash
grep -rni 'phantty' $(git ls-files 'plugins/*') ; echo "exit=$?"
```
Expected: no matches (`exit=1`).

- [ ] **Step D4: Final repo-wide audit**

```bash
cd /home/xzg/project/phantty
git ls-files | grep -i phantty   # any remaining tracked FILENAMES with phantty
echo "--- content (excluding history + protected literals) ---"
grep -rniI 'phantty' $(git ls-files \
  | grep -vE '^(plans/|release-notes/|docs/superpowers/)' ) \
  | grep -vi 'arya-s/phantty' | grep -vi 'phantty.cc-remote.app' \
  | grep -vi 'formerly phantty'
echo "exit=$?"
```
Expected:
- No tracked filenames contain `phantty` (the first command prints nothing).
- The content audit prints nothing except possibly intentional mentions you accept. Historical dirs (`plans/`, `release-notes/`, `docs/superpowers/`) are intentionally excluded and keep their old text. The protected literals and the `formerly Phantty` README line are filtered out.
- Any genuine stray (a real file that should have been renamed but slipped through scope) → fix it: run the helper on it (or `git mv`), re-audit, and amend/extend this commit.

- [ ] **Step D5: Full verification**

```bash
zig build test 2>&1 | tail -6
zig build test-full -Dtarget=x86_64-windows-gnu 2>&1 | tail -10
```
Expected: native tests pass; Windows-target matches the 497/499 baseline (no new failures).

- [ ] **Step D6: Commit**

```bash
git add -A
git commit -m "skills: rename phantty-diagnostics -> wispterm-diagnostics; finalize WispTerm rename"
```

---

## Done criteria

- `zig build test` green; `test-full -Dtarget=x86_64-windows-gnu` at the 497/499 baseline.
- No tracked filename contains `phantty`.
- No `phantty` in tracked content except: historical dirs (`plans/`, `release-notes/`, `docs/superpowers/`), the protected literals `arya-s/phantty` and `phantty.cc-remote.app`, and the README's `formerly Phantty`.
- App reports name "WispTerm", uses `~/.config/wispterm` (etc.), and the new icon; auto-update/skill-download point at `xuzhougeng/wispterm`.
- `docs/CNAME` unchanged (`phantty.cc-remote.app`).
