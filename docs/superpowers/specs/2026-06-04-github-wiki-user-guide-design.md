# WispTerm GitHub Wiki — Bilingual User Guide

**Date:** 2026-06-04
**Status:** Design (approved structure, pending spec review)

## Goal

Create a comprehensive, end-user-facing **usage guide** ("使用方法") for WispTerm,
published as the project's **GitHub Wiki** (the `wispterm.wiki.git` repository).
The wiki is **bilingual** (English + 简体中文) and covers every major feature so a
new user can install the app and learn each capability without reading source.

This wiki is distinct from the existing `docs/` site (the GitHub Pages landing +
reference site at `phantty.cc-remote.app`). The wiki is the walkthrough-style
"how do I use X" companion; it reuses and re-narrates content from the existing
`docs/*.md` and the READMEs rather than duplicating the reference site verbatim.

## Non-Goals

- Not replacing or restructuring the existing `docs/` Pages site.
- Not documenting internal architecture, build internals, or contributor
  workflow (those stay in `docs/development.md` / `docs/architecture.md` /
  `AGENTS.md`).
- Not auto-syncing wiki content from `docs/` — this is a one-time authored set
  that we maintain by hand going forward.

## Decisions (from brainstorming)

1. **Location:** GitHub Wiki tab → the separate `wispterm.wiki.git` repo.
2. **Language:** Bilingual using **Approach A** — every topic is two independent
   single-language pages (`<Topic>.md` English, `<Topic>-zh.md` 中文), with a
   top-of-page `English | 中文` switch link, and a single `_Sidebar.md` split
   into an **English** section and a **中文** section.
3. **Coverage:** Comprehensive — all 14 topic pages below.
4. **Delivery:** Prepare everything locally first in a staging directory, the
   user reviews, then push to `wispterm.wiki.git`.

## Architecture / Layout

### Staging directory

All wiki files are authored under a flat staging directory in the main repo:

```
wiki/
  Home.md                 Home-zh.md
  Installation.md         Installation-zh.md
  Getting-Started.md      Getting-Started-zh.md
  Tabs-Splits-Panels.md   Tabs-Splits-Panels-zh.md
  Configuration.md        Configuration-zh.md
  Themes-Appearance.md    Themes-Appearance-zh.md
  Keyboard-Shortcuts.md   Keyboard-Shortcuts-zh.md
  File-Explorer.md        File-Explorer-zh.md
  SSH-Remote-Development.md   SSH-Remote-Development-zh.md
  AI-Copilot.md           AI-Copilot-zh.md
  Browser-Jupyter-Panel.md    Browser-Jupyter-Panel-zh.md
  Inline-Images.md        Inline-Images-zh.md
  Remote-Access.md        Remote-Access-zh.md
  FAQ.md                  FAQ-zh.md
  _Sidebar.md
  _Footer.md
```

The directory is **flat** because GitHub Wiki stores all pages at the repo root;
the staging filenames are exactly the wiki page slugs, so publishing is a plain
file copy + commit into `wispterm.wiki.git`.

A short `wiki/README.md` (not a wiki page — excluded when copying, or simply left
behind) records "this is the staging source for the GitHub Wiki; copy `*.md`
except this file into `wispterm.wiki.git` and push."

### Page conventions

Every content page follows the same skeleton so the two languages stay parallel:

```markdown
# <Page Title>

*English | [中文](<Topic>-zh)*    <!-- zh page mirrors: *[English](<Topic>) | 中文* -->

> One-sentence summary of what this page covers.

## <Sections...>

---
*See also: [[Related Page]] · [[Another Page]]*
```

- **Page-name slugs** are ASCII with hyphens (no spaces, no unicode) so links are
  stable on GitHub. The Chinese page is the same slug + `-zh`; the human-readable
  Chinese title lives in the `# H1` only.
- **Internal links** use GitHub wiki link syntax `[[Page-Slug]]` or
  `[[Display text|Page-Slug]]`. The language-switch link uses the bare slug.
- **Platform callouts:** WispTerm ships for Windows + macOS (Linux WIP). Where a
  feature or path differs, show both inline (e.g. `Ctrl+,` / `Cmd+,`) and note
  Windows-only features (embedded WebView2 browser panel) explicitly.

### Sidebar (`_Sidebar.md`)

```markdown
**English**
- [[Home]]
- [[Installation]]
- [[Getting Started|Getting-Started]]
- ... (all 14, English slugs)

**中文**
- [[首页|Home-zh]]
- [[安装|Installation-zh]]
- ... (all 14, -zh slugs, Chinese display text)
```

### Footer (`_Footer.md`)

Single line: project name + link back to the repo and the docs site
(`phantty.cc-remote.app`), shown on every page.

## Page Content Outline (14 topics × 2 languages)

Each entry lists the page's scope and its primary source material in-repo.

1. **Home** — What WispTerm is (Zig + libghostty-vt terminal workspace for remote
   dev + AI agent workflows), platform support note (Win/macOS shipped, Linux
   WIP), a feature-at-a-glance list, and a "start here" path (Installation →
   Getting Started). *Source:* `README.md` intro + Features.

2. **Installation** — Windows (download/run `wispterm.exe`), macOS (Apple Silicon
   vs Intel `.app`, launching, CLI-flag-needs-binary-path note), and build-from-
   source pointers. *Source:* `README.md` Building/Usage; link to
   `docs/development.md` for deep build.

3. **Getting Started** — First launch, the AI-setup-on-first-launch form, basic
   terminal use, the command center (`Ctrl+Shift+P`), opening tabs/sessions
   (`Ctrl+Shift+T` session launcher), `--version`/`--show-config-path`/
   `--list-fonts`/`--list-themes` discovery flags. *Source:* `README.md` Usage,
   `docs/ai-agent.md`.

4. **Tabs, Splits & Panels** — Tabs vs splits, split right/down, focus
   left/right/up/down + focus previous/next, equalize, focus panel by number
   (`Cmd/Ctrl+1-9`), Alt+drag panel swap, focus-follows-mouse, Quake drop-down
   mode (`toggle_quake`, default off per recent change — verify shipped default),
   close confirm for running TUIs. *Source:* `README.md` Features, `keybind`
   actions in `docs/configuration.md`, memory notes (panel focus-by-number,
   panel swap, quake default).

5. **Configuration** — Config file resolution order + platform paths, `open_config`
   (`Ctrl+,`/`Cmd+,`), CLI override rules, `config-file` includes, an annotated
   example config, and the full key table. *Source:* `docs/configuration.md`
   (lift the resolution order, example, and key table; restate for users).

6. **Themes & Appearance** — Selecting a theme (453 built-in, `--list-themes`,
   theme gallery link), fonts (`font-family`/`font-style`/`font-size`,
   `--list-fonts`, per-glyph fallback / CJK note), cursor style, background image
   (modes + opacity table), custom GLSL shader. *Source:* `docs/configuration.md`
   + `docs/media.md` (Background Image section).

7. **Keyboard Shortcuts** — Default app-level chords (table of common ones),
   `keybind = trigger=action` syntax, `global:` prefix, `keybind = clear`, the
   full action list, modal/overlay-local keys caveat, remap examples. *Source:*
   `docs/configuration.md` Keyboard Shortcuts section + `README.md` shortcuts.

8. **File Explorer & Previews** — Toggle (`Ctrl+Shift+Alt+E`), environment-aware
   browsing (local/WSL/SSH), preview panel (Ctrl/Cmd+click `.md/.txt/.csv/.tsv/
   image`; double-click in explorer), what each preview type does, SSH remote
   file download (`Ctrl+Shift`-click), resizing/scroll/zoom, the SSH-metadata
   requirement. *Source:* `docs/file-explorer.md`.

9. **SSH & Remote Development** — Launching SSH profile sessions, why profile
   sessions (vs typing `ssh` in a shell) unlock preview/download/cwd, OSC 7 cwd
   reporting setup snippets (bash/zsh/fish) for drag-drop uploads,
   `ssh-legacy-algorithms`, SSH loopback port forwarding for web apps + the
   browser panel/`url-open-mode` interaction. *Source:* `docs/file-explorer.md`
   (SSH cwd + loopback), `docs/configuration.md` (`url-open-mode`).

10. **AI Copilot & Agent** — The big one. Covers: opening Copilot (`Ctrl+Shift+T`
    → Copilot), AI profiles & Settings, on-disk profile location, protocols
    (chat_completions / responses / anthropic) + their base-URL/auth rules,
    DeepSeek defaults + `DEEPSEEK_API_KEY`, reasoning block display, the
    in-context Copilot sidebar (`Ctrl+Shift+A`, per-tab, terminal snapshot,
    exclusive right slot, Esc behavior), Sessions browser + Resume, per-conversation
    working directory (`/cwd`) + `ai-agent-working-dir`, tool-permission levels
    (`/permission ask|auto|full`), local slash commands list, custom slash
    commands (`commands/*.md`), Agent skills (`$skill-name`, `skills/<name>/
    SKILL.md`), skill distillation (`/distill` · `/沉淀`), Markdown export
    (full vs clean), and `wispterm_docs` self-help. *Source:* `docs/ai-agent.md`
    + memory (working dir #150, permission 3-level, /loop+/watch if shipped).

11. **Browser & Jupyter Panel** — Embedded WebView2 browser panel (Windows;
    `Toggle Browser`, Ctrl/Cmd+click URLs, URL bar, resize), `url-open-mode`
    embedded vs system-browser, SSH loopback tunnels. Jupyter: connect to a remote
    Jupyter (paste URL+token, side/full modes, auto-detect). **Verify shipped
    state during writing** — Jupyter (PR #151) and macOS WKWebView may be
    unmerged; only document what is in a released build, or clearly mark as
    "available on Windows" / "coming soon" if not yet shipped. *Source:*
    `docs/file-explorer.md` (browser panel) + Jupyter memory note (gate on merge).

12. **Inline Images (Kitty Graphics)** — Why/when (remote shells emit images),
    `tools/imgcat.py` and `tools/pdfcat.py` usage + examples, dependency notes
    (Pillow/ImageMagick; pdftoppm/mutool), "runs on the remote machine, not the
    Windows host" caveat. *Source:* `docs/media.md` (Remote Image Viewing).

13. **Remote Access (Sharing a Session)** — Opt-in Cloudflare relay (disabled by
    default), the `remote-*` config keys, how the session key is generated/shown
    (status pill, Copy Remote Key), multi-instance key suffixing, the
    "remote mirrors local size on phones" behavior, security framing (off by
    default, separate from relay admin login). *Source:* `docs/configuration.md`
    (remote keys) + `docs/faq.md` (remote mirror).

14. **FAQ & Troubleshooting** — Windows elevation (admin shell), running elevated,
    remote-mirrors-local-size, plus a few cross-cutting "where is my config /
    how do I hot-reload / why no Linux build yet" entries that point into the
    relevant pages. *Source:* `docs/faq.md` + `README.md` Linux WIP note.

## Content Sourcing & Accuracy

- Re-narrate for a **user audience** (task-first: "to do X, press Y"), not the
  reference tone of `docs/`. Lift facts (paths, key tables, defaults) verbatim
  where precision matters; rewrite prose.
- Every keybind, config key, default value, and path must match the current
  source (`docs/configuration.md`, `src/keybind.zig`) at writing time — no
  invented options.
- Where a feature's shipped status is uncertain (Jupyter, macOS WKWebView,
  `/loop`+`/watch`, Quake default), confirm against `main` / latest release
  before documenting; gate or label anything not yet released.
- Chinese pages are real translations (faithful, idiomatic), not machine-literal;
  keep command names, config keys, and code blocks identical to the English page.

## Testing / Verification

This is a documentation deliverable, so verification is:

1. **Link integrity:** every `[[...]]` and `English|中文` switch resolves to an
   existing staging file/slug; sidebar lists all 28 pages.
2. **Parity:** each English page has a `-zh` counterpart with the same section
   structure and the same code/config blocks.
3. **Fact check:** spot-check config keys, defaults, and keybinds against
   `docs/configuration.md` / source.
4. **Local render:** preview a couple of pages (any Markdown renderer) to confirm
   tables and wiki-links look right before publishing.
5. **Publish step (separate, user-gated):** copy staged `*.md` (except
   `wiki/README.md`) into `wispterm.wiki.git` and push. Requires the Wiki to be
   enabled in repo Settings and local push access; surface that prerequisite to
   the user rather than assuming it.

## Open Questions / Risks

- **Wiki enablement:** the `wispterm.wiki.git` repo only exists once Wiki is
  enabled and at least one page created in repo Settings. Flag to user at publish
  time; do not auto-create.
- **Staging dir longevity:** keep `wiki/` in the main repo as the maintained
  source of truth (recommended, so future edits are reviewable via PR), vs delete
  after publishing. Default: **keep it.** Confirm with user.
- **Shipped-feature gating** for Jupyter / macOS WebView / `/loop` etc. resolved
  during writing by checking `main`.
