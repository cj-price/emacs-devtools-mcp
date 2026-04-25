# 017 — `screenshot-frame` tool

**As** an agent verifying a UI change
**I want** to capture a PNG of a frame and have it returned as an MCP `image` content block
**So that** I can "look at" the result of my change and report back to the user.

## INVEST
- **I**: depends on the probe (016) for backend selection.
- **N**: pixel cap default (1920×1080) negotiable; format set list (PNG only initially) negotiable.
- **V**: the marquee tool — the demo the README leads with.
- **E**: M (~1.5 days).
- **S**: ~150 lines + tests.
- **T**: produced PNG decoded and asserted via `image-size` and magic bytes.

## Dependencies
- 016-pgtk-screenshot-probe-depends-on-008

## Acceptance criteria
- [ ] Tool: `screenshot-frame` (`:fast`, read-only).
- [ ] Schema: `frame` (string | null — frame name; defaults to selected), `format` (enum `["png"]`, default `"png"`), `target` (host or spawn — host-only until 021).
- [ ] Defcustom `emacs-devtools-mcp-screenshot-max-pixels` as `(WIDTH . HEIGHT)`, default `(1920 . 1080)`. Larger captures are downscaled (preserving aspect) before encode.
- [ ] Backend dispatch:
  - `:x-export` → `(x-export-frames FRAME 'png)`; bytes returned directly.
  - `:grim` → `make-process` with argv `(grim "-g" "<x>,<y> <w>x<h>" "-")` reading from stdout. `<x>,<y>,<w>,<h>` from `frame-position` + `frame-pixel-width/height`.
  - `:xwd-convert` → `make-process` chain `xwd -id ID | convert xwd:- png:-`; ID from `frame-parameter FRAME 'window-id`.
  - `:unsupported` → return error envelope with `screenshot_unsupported` and the reason from the probe log.
- [ ] Returned MCP content block uses `{type: "image", data: <base64>, mimeType: "image/png"}`.
- [ ] Downscale path uses `create-image` + `image-transforms-p` if available; else falls back to ImageMagick on the bytes.
- [ ] On failure during capture (process exit nonzero, malformed bytes), returns `isError: true` with stderr captured from the subprocess (redacted via 010).
- [ ] Bytes are decoded once at the boundary; they never sit in *Messages*.

## Files touched
- `lisp/emacs-devtools-mcp-tools-gui.el` (extend with the tool)
- `test/emacs-devtools-mcp-tests.el` (GUI section)
- `test/emacs-devtools-mcp-xvfb-tests.el` (the round-trip)

## Test plan
- ERT `:fast`: with a pinned `:x-export` backend and stubbed `x-export-frames` returning a known PNG, tool returns the bytes base64-encoded.
- ERT `:fast`: with backend `:unsupported`, tool returns `screenshot_unsupported`.
- ERT `:fast`: 4000×4000 stub PNG → downscaled to 1920×1080 (or below).
- ERT `:gui` (under xvfb-run): spawn a daemon, capture its frame, decode base64, assert PNG magic bytes and `image-size` returns non-zero, assert non-zero pixel variance (not a blank canvas).
- ERT `:gui`: nonexistent frame name → `frame_not_found`.
