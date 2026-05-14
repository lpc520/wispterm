# AI Chat Inline Images — Design

Date: 2026-05-14
Status: Draft

## Goal

Let the AI Agent chat panel display local and remote images inline, on both
the native Phantty UI and the remote web mirror. The motivating workflow is
the agent capturing a screenshot via PowerShell and showing it back to the
user without forcing them to leave the terminal.

## Scope

In scope:

- Parse markdown image syntax `![alt](source)` inside `ai_chat.Message.content`.
- Resolve sources of three kinds: Windows absolute paths, `http(s)://` URLs,
  and `data:image/...;base64,...` URIs.
- Render images inline in the local AI-chat panel using the existing GL
  pipeline (`renderer/image_renderer.zig`), fit-to-width with a 400px height
  cap. Click opens a fullscreen overlay; click / Esc / scroll dismisses.
- Mirror the same rendering on the web AI-chat panel (which became plain HTML
  in commit `5dc644e`), reading a sidecar attachment payload over the relay.
- Render the same markdown subset on web that the local renderer supports
  today: fences, tables, headings, lists, horizontal rules, basic inline
  (bold / italic / inline code), plus images.

Out of scope (v1):

- User-initiated image uploads from the web side.
- Image annotation, cropping, editing, save-as, copy-to-clipboard menu.
- Animated GIF playback (first frame only).
- SVG rendering.
- Pinch / wheel zoom or pan inside the fullscreen overlay.
- Relative paths, UNC paths, `file://` URLs.
- Image references in tool-call arguments or tool results (only message
  content is scanned).
- Binary WebSocket frames in the relay (stays JSON + base64).
- Persistent on-disk attachment cache (memory only; per session).

## Background

`commit 5dc644e` ("fix: separate remote AI chat input") changed the web
AI-chat surface from an xterm-rendered text grid into a plain HTML container
(`<div class="ai-chat-remote">` → `<pre class="ai-chat-transcript">` +
`<textarea>` + Send button). It also stopped broadcasting the local user's
draft input in the remote snapshot. This design assumes that baseline. Image
support is added by:

1. Extending the local AI-chat markdown parser/renderer with an `image`
   block kind.
2. Introducing a content-addressed attachment cache shared between the
   renderer and the relay serializer.
3. Rewriting outbound snapshots so the relay carries `id://<hash>` instead
   of real filesystem paths, plus a sidecar payload of newly-introduced
   attachment bytes.
4. Replacing `aiTranscript.textContent = snapshot` on the web with a small
   markdown-to-DOM renderer that mirrors the local Zig parser's subset.

## Architecture

```
┌──── ai_chat.Message.content (raw markdown text) ─────────┐
│ "screenshot saved to:                                    │
│  ![Desktop](C:\Users\xzg\Desktop\screenshot.png)         │
│  see annotation in panel 2."                             │
└──┬───────────────────────────────────────────────────────┘
   │ on message append/update, scan ![..](..) once
   ▼
┌──────────────────────────────────────────────────────────┐
│ image_attachments.zig                       (new module) │
│  - resolve source: Win abs path | http(s) | data:        │
│  - decode to RGBA via existing image_decoder.zig         │
│  - compute sha1 → 16-byte hex ID                         │
│  - bounded in-memory cache (~64 MiB LRU)                 │
│  - public API:                                           │
│      ensureFromPath(path) → Attachment{id,w,h,bytes_png} │
│      ensureFromUrl(url)  → Attachment{...}               │
│      ensureFromDataUri(s) → Attachment{...}              │
│      getById(id) → ?Attachment                           │
└──┬──────────────────────────┬────────────────────────────┘
   │                          │
   ▼ (local render)           ▼ (remote serialization)
┌─────────────────────────┐  ┌──────────────────────────────┐
│ ai_chat_renderer.zig    │  │ AppWindow.zig AI-chat        │
│ - markdown line parser  │  │ snapshot serializer:         │
│   gains an `image` kind │  │  - replace ![alt](src) with  │
│ - reserves a fit-to-    │  │    ![alt](id://<hash>) so    │
│   width box (capped     │  │    real paths don't leave    │
│   400px tall), blits    │  │  - emit sidecar field        │
│   via image_renderer    │  │    "attachments":[{id,mime,  │
│ - hit-test → fullscreen │  │      w,h,b64}, ...] for IDs  │
│   overlay (new tiny     │  │    not yet seen by this      │
│   module)               │  │    remote connection         │
└─────────────────────────┘  └──────────┬───────────────────┘
                                         │ relay (pass-through)
                                         ▼
                            ┌──────────────────────────────┐
                            │ remote/src/client/           │
                            │   ai_chat_markdown.ts  (new) │
                            │   ai_chat_attachments.ts(new)│
                            │ - per-connection blob cache  │
                            │   Map<id, BlobURL>           │
                            │ - markdown→DOM renderer for  │
                            │   {fence, table, heading,    │
                            │    list, rule, bold/italic/  │
                            │    code, image}              │
                            │ - on ![](id://h), look up    │
                            │   blob URL → <img>           │
                            │ - <img> click → fullscreen   │
                            │   overlay                    │
                            └──────────────────────────────┘
```

### Invariants

- Original Windows paths and arbitrary URLs never appear in relay payloads.
  Outbound snapshots only carry `id://<hash>` references.
- Attachment IDs are content-addressed (sha1 of the decoded RGBA buffer,
  truncated to 16 bytes → 32 hex chars). Identical pixels share storage.
- Each remote connection tracks which IDs it has already received; an ID
  is sent over the relay exactly once per connection (until the web
  explicitly requests retransmission).
- The local attachment cache is the single source of truth. The renderer
  never re-decodes from disk per paint, and the relay never re-fetches.
- The web markdown renderer is a deliberate subset, not full CommonMark —
  it matches whatever subset the local Zig renderer supports today, so the
  two views stay visually consistent and scope stays bounded.

## Image syntax contract

Recognized at line granularity (matches the existing markdown parser's
`prepareMarkdownLine`):

```
![alt text](<source>)
```

`<source>` must be one of:

| Form | Example | Detection |
|---|---|---|
| Windows absolute path | `C:\Users\xzg\Desktop\s.png` | matches `^[A-Za-z]:[\\/]` |
| HTTP/HTTPS URL | `https://example.com/x.png` | matches `^https?://` |
| Data URI | `data:image/png;base64,iVBORw0K...` | matches `^data:image/` |
| Internal ID (relay-side only) | `id://a3f5b8c1...` | matches `^id://[0-9a-f]+`; only valid in inbound snapshots on the web |

Anything else inside `()` is treated as plain text — the parser emits the
original line unchanged. Mixed inline text + image on the same line is
rendered as plain text (image must be on its own line) — matches CommonMark's
block-image convention and keeps layout simple.

Allowed image formats are whatever `image_decoder.zig` accepts: PNG, JPEG,
GIF (first frame only), WebP, BMP.

### Limits

- Decoded dimensions: reject if `width * height > 8192 * 8192` (≈64 MP).
- Encoded relay payload per attachment: reject if `> 16 MiB` after
  re-encoding for transport.
- Cache budget: ~64 MiB total, LRU eviction by ID.

### ID lifecycle

1. Renderer encounters `![alt](C:\...\s.png)` → calls
   `image_attachments.ensureFromPath`.
2. The cache reads the file, decodes once via `image_decoder`, computes sha1
   over the decoded RGBA buffer → ID `a3f5b8c1...`. Stores
   `{id, mime, w, h, encoded_bytes, decoded_rgba, gl_texture}`.
3. The parsed AST holds a reference `image{ id, alt }` — not the original
   path. The path is still present in raw `Message.content` text, but
   parsed consumers see only the ID.
4. The relay serializer rewrites the snapshot's `![alt](C:\...)` to
   `![alt](id://a3f5b8c1...)`. If the per-connection state has not yet
   seen this ID, the sidecar `attachments` array carries the encoded bytes.
5. Web side caches the blob URL by ID. Subsequent references reuse it.

### Error states

| Failure | Local render | Web render |
|---|---|---|
| File not found / no permission | Inline placeholder tile, "image not found: `…\s.png`" (path tail only) | `<span class="ai-chat-img-error">image unavailable</span>` (scrubbed) |
| Decode error / unsupported format | "could not decode image" tile | Same scrubbed message |
| HTTP fetch failure | "fetch failed: <status>" tile | Same scrubbed message |
| Oversize (>64 MP or >16 MiB) | "image too large to display" tile | Same |
| ID referenced in snapshot but missing from this connection's cache | (n/a — local always has it) | "loading…" placeholder; web sends `request-attachments` over the relay |

Failures are cached too (keyed by source → synthetic `err://<hash>` ID) so
we don't retry on every paint. A new message bumps a session epoch which
clears the error cache, supporting natural "edit and retry" flows.

### HTTP fetching

Synchronous-with-timeout on the AI-chat thread would stall the renderer, so
the local side dispatches asynchronously (reusing the HTTP plumbing from
`remote_client.zig`), shows a "loading…" tile, and triggers a chat re-render
via the existing `notifyRebuild` signal when the fetch completes. The web
side never fetches `http(s)://` directly — it always waits for the local
side to resolve the bytes and ship them through the relay. This sidesteps
CORS and credential issues in the browser.

## Local rendering integration

### Markdown parser extension

`renderMarkdownContent` (`ai_chat_renderer.zig:847`) currently steps
line-by-line, returning a vertical cursor. Add one branch alongside the
existing `fence` / `rule` / `table` / `text` cases:

```
.image => {
    const att = image_attachments.getById(prepared.image_id) orelse fallback_error_tile;
    const box_h = computeImageBoxHeight(att, max_w);   // fit-to-width, capped at 400px
    image_renderer.blit(att.texture, x, current_top, box_w, box_h, window_height);
    record_hit_rect(prepared.image_id, x, current_top, box_w, box_h);
    current_top += box_h + IMAGE_VERTICAL_GAP;
}
```

`prepareMarkdownLine` is extended to recognize a single-image line and
return `.image` with the resolved ID.

### Box sizing

- `box_w = min(image.natural_w, max_w)`
- `box_h = box_w * image.natural_h / image.natural_w`
- If `box_h > 400`: scale `box_h = 400`, recompute `box_w` from aspect
  ratio, center horizontally within `max_w`.

### Texture lifecycle

`image_renderer.zig` already manages GL textures for terminal-side Kitty
Graphics. Reuse: when `ensureFromX` first inserts an attachment, it also
uploads a GL texture and stores the handle on the attachment record. LRU
eviction releases the texture in the same step it frees the bytes.

### Hit-testing and fullscreen

Each rendered image records its rect into a per-message
`image_hit_rects: []ImageHit` list during `renderMessageBubble`. The
existing mouse-click handler in `ai_chat.zig` (which already handles
header / copy / approval clicks) gets one more branch: if the click lands
inside any `ImageHit`, dispatch `ai_chat.showFullscreenImage(id)`. The
fullscreen overlay is a new tiny module (`renderer/image_fullscreen.zig`) —
borderless backdrop + centered image scaled to fit the window, dismissed on
click / Esc / scroll. No keyboard zoom controls in v1.

### Scrolling and async loading

Image boxes participate in scroll measurement the same way text bubbles do.
Scrolling past an image doesn't unload its texture (LRU is global, not
viewport-driven). When `ensureFromUrl` returns "in-flight", the renderer
draws a 1-line "loading…" tile; on completion, `notifyRebuild` schedules a
re-render.

## Relay protocol & snapshot serialization

### Current state

`buildAiChatTabState` (`AppWindow.zig:1305`) emits:

```json
{"id":"...","kind":"ai_chat","readOnly":false,"cols":120,"rows":30,
 "cursorX":0,"cursorY":0,"snapshot":"<text>","x":0,"y":0,"w":1,"h":1}
```

`<text>` comes from `session.allocRemoteSnapshot(allocator)`. We extend
along two axes: rewrite the snapshot text, add a sidecar.

### Snapshot text rewrite

`allocRemoteSnapshot` post-processes each message's content: every
`![alt](<source>)` whose source matches Windows path / `http(s)://` /
`data:` is replaced with `![alt](id://<hash>)`. The in-memory
`Message.content` is unchanged — only the serialized form is rewritten.
This keeps copy-from-local working with real paths.

### Sidecar field

The AI-chat surface JSON gains one optional field:

```json
"attachments": [
  {
    "id": "a3f5b8c1d2e4...",
    "mime": "image/png",
    "w": 1920,
    "h": 1080,
    "b64": "iVBORw0KGgoAAAANSUhEUg..."
  }
]
```

Empty / omitted when no new attachments. The field is per-frame, not
cumulative — the web keeps its own cache.

### Per-connection state

`remote_client.zig` gains
`sent_attachment_ids: std.AutoHashMapUnmanaged([16]u8, void)`. Keys are the
raw 16-byte attachment ID (not its 32-char hex form). Before emitting a
snapshot:

1. Walk attachments referenced in the snapshot text.
2. For any ID not in `sent_attachment_ids`, append it to the sidecar and
   mark it sent.
3. On reconnect / fresh remote, state resets — all IDs re-ship on first
   snapshot.

Eviction in the local cache does **not** invalidate `sent_attachment_ids`.
The web's own LRU may drop a blob; when that happens, the web sends a
retransmission request (below).

### Re-encoding for transport

The local cache holds decoded RGBA + the original encoded bytes
side-by-side. Transport ships the original encoded form when it's
web-safe (PNG / JPEG / GIF / WebP). BMP is re-encoded to PNG via
stb_image_write (already vendored). Encoded payloads exceeding the 16 MiB
per-attachment limit are rejected at decode time (rendered as the
"image too large" tile) — we do not downscale-to-fit in v1. If the
combined new-attachments payload would exceed 16 MiB across one frame,
remaining attachments are deferred to subsequent frames in FIFO order.

Base64 in JSON (not binary frames), because the Cloudflare relay worker
is currently a JSON pass-through and we want to avoid touching it.

### Web → local retransmission

When the web sees an `id://` reference for an ID missing from its cache,
it sends:

```json
{"type":"ai_chat_request_attachments","surfaceId":"...","ids":["..."]}
```

Handled as a sibling of `handleRemoteAiInputRequest`. The local clears
those IDs from `sent_attachment_ids` and triggers `g_force_rebuild` so
the next snapshot reships them.

### worker.ts

Expected to need no changes — Cloudflare worker is a transparent
passthrough of `output` / `input-bytes` / `notice`. The new attachment
payload travels inside the existing snapshot message; the new
"request retransmission" travels alongside existing input messages.
Verify during implementation; if `worker.ts` validates payload shape, add
the new type.

### Rate watchdog

If a single message-update would broadcast >32 MiB cumulative sidecar
bytes within 60 seconds, log a warning. No hard rate limiting in v1.

## Testing strategy

### Unit tests (Zig, `zig build test`)

- `image_attachments.zig`
  - `ensureFromPath` decodes a known PNG → deterministic ID, correct w/h
  - Same file appended twice → single cache entry, same ID
  - Identical content via different paths → same ID
  - Non-existent file → returns error attachment with stable error ID
  - Oversize image rejected
  - LRU eviction: fill past 64 MiB, oldest dropped, re-`ensure` re-decodes
- `ai_chat.zig`
  - `allocRemoteSnapshot` rewrites `![](C:\…\s.png)` → `![](id://<hex>)`
  - `allocRemoteSnapshot` leaves non-image markdown untouched
  - Existing test `ai chat remote snapshot omits local draft input` still passes
- `remote_client.zig`
  - First snapshot emits sidecar; second snapshot referencing same IDs emits empty sidecar
  - Fresh connection re-emits all visible IDs
  - `request-attachments` clears IDs from sent set and forces inclusion in next frame

### Integration / fixture tests (Zig)

- Round-trip: feed an AI message containing `![](fixture/red.png)` →
  `allocRemoteSnapshot` produces snapshot + sidecar → parse both back →
  reconstructed attachment matches original bytes.
- Async fetch path: stubbed HTTP client returns bytes after a delay →
  first paint shows "loading…" tile, `notifyRebuild` fires, second paint
  resolves the ID.

### Web tests (`cd remote && npm run test:client`)

- `ai_chat_markdown.test.ts`
  - Parse snapshot with one `![](id://abc)` → DOM has one `<img>` with the
    right `data-img-id`
  - Parse code fence / table / heading / list / rule / bold / italic /
    inline-code — structure matches local renderer's behavior on the same input
  - Unknown ID renders "loading…" placeholder, doesn't throw
- `ai_chat_attachments.test.ts`
  - Sidecar ingest creates blob URL, second `<img>` for same ID reuses cache
  - Cache eviction drops a blob URL; next reference triggers
    `request-attachments` message
- Existing `mobile_canvas` / `mobile_layout` tests must still pass —
  AI-chat panel layout changes don't intersect with terminal pan logic.

### Manual smoke tests

1. Launch Phantty, open AI Agent tab, ask the agent to take a screenshot
   and embed it as `![](C:\…\s.png)`. Verify inline render, click →
   fullscreen, Esc dismisses.
2. Same flow with a `data:image/png;base64,...` URI typed into a user
   message.
3. Same flow with `https://httpbin.org/image/png` — verify async loading
   placeholder, then resolved image.
4. Open the remote web mirror, repeat (1) — verify image appears at the
   same position, click → fullscreen, no Windows path visible in DevTools.
5. Hard-reload the web tab while a chat with 3 images is visible — verify
   all three re-stream on reconnect.
6. Send 30 screenshots in succession via agent → no UI stall, cache stays
   bounded, oldest eventually evicts.
7. Send a 10000×10000 PNG → graceful "image too large" tile, no crash.

### Performance budget

- 1080p PNG decode + upload + cache in < 50 ms on the dev box.
- Re-painting a chat with 10 visible images stays within the existing
  AI-chat frame budget (no perceptible drop from text-only baseline).
- Relay payload for a fresh connection viewing 5 screenshots: ≤ 10 MiB
  total over the first 2 seconds.

## File map

New files:

- `src/image_attachments.zig` — content-addressed attachment cache and
  source resolution.
- `src/renderer/image_fullscreen.zig` — overlay renderer for click-to-zoom.
- `remote/src/client/ai_chat_markdown.ts` — markdown→DOM renderer (subset
  matching local).
- `remote/src/client/ai_chat_attachments.ts` — per-connection blob cache,
  retransmission requests.

Modified files (concentrated change surface):

- `src/ai_chat.zig` — `Message` parsing extracts attachment IDs;
  `allocRemoteSnapshot` rewrites paths; new `showFullscreenImage` and
  click-hit dispatch.
- `src/renderer/ai_chat_renderer.zig` — new `.image` branch in
  `renderMarkdownContent`; hit-rect recording.
- `src/AppWindow.zig` — `buildAiChatTabState` emits the `attachments`
  sidecar.
- `src/remote_client.zig` — `sent_attachment_ids` per-connection state and
  retransmission handling.
- `remote/src/client/surfaces.ts` — replace
  `aiTranscript.textContent = snapshot` with the new markdown renderer;
  inject the attachment cache.
- `remote/src/client/types.ts` — `LayoutSurface.attachments?: Attachment[]`
  field.
- `remote/src/client/styles/console.css` — image / fullscreen styles.

## Risks and open questions

- **Re-render frequency vs. async fetch.** If many `http(s)://` URLs are
  in flight, each completion fires `notifyRebuild`. Risk of paint thrash.
  Mitigation: coalesce rebuild signals via the existing scheduler (likely
  already done) — verify during implementation.
- **GL texture upload thread.** `image_renderer.zig` texture uploads must
  happen on the GL thread. `ensureFromX` may be called from the AI-chat
  worker thread. We will need to queue uploads on a render-thread mailbox
  rather than blocking. Verify the existing image-renderer pattern for
  Kitty Graphics handles this; if not, this becomes a small additional task.
- **Selection / copy.** Selecting text across an inline image: the
  existing AI-chat copy path operates on raw `Message.content`, which
  still contains the original `![alt](path)` markdown — so copy semantics
  are preserved by accident. Verify in manual smoke test.
- **Code-fence rendering on web.** The local renderer's table layout is
  non-trivial; matching its visual output exactly on the web is best-effort.
  We will match structure (table → `<table>`, fences → `<pre><code>`) but
  not pixel-perfect alignment.
