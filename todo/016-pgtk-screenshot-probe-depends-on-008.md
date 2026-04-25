# 016 — Host screenshot backend probe

**As** the package
**I want** to detect at server-start time whether `x-export-frames` produces valid PNG bytes on the host (pgtk vs x11), and pick a fallback if not
**So that** `screenshot-frame` can ship without forcing every user to debug their windowing system first.

## INVEST
- **I**: probe is independent — no caller depends on it until 017 lands.
- **N**: which fallback (`grim` for Wayland, `xwd | convert` for X11) is selectable; defcustom.
- **V**: makes the host screenshot path actually work for the user (who is on pgtk/Wayland).
- **E**: M (~1 day).
- **S**: ~100 lines + tests.
- **T**: probe result is observable in a defvar; backend-specific code paths each unit-tested.

## Dependencies
- 008-initialize-list-call-ping-depends-on-004-006

## Acceptance criteria
- [ ] On first call (or eagerly at server start), the package creates a hidden 1×1 frame, calls `(x-export-frames nil 'png)`, and inspects the result. A multibyte unibyte string starting with `\x89PNG` → backend `:x-export`. Anything else → fall through.
- [ ] If `:x-export` failed and `(getenv "WAYLAND_DISPLAY")` is set and `grim` is on `exec-path` → backend `:grim`.
- [ ] Else if `(getenv "DISPLAY")` is set and `xwd` and `convert` (ImageMagick) are on `exec-path` → backend `:xwd-convert`.
- [ ] Else → backend `:unsupported`; `screenshot-frame` will return a structured error envelope.
- [ ] Result cached in `emacs-devtools-mcp-tools-gui--host-backend`; cache invalidatable via `emacs-devtools-mcp-tools-gui-reset-host-backend`.
- [ ] Defcustom `emacs-devtools-mcp-tools-gui-host-backend` (default `'auto`) lets the user pin a backend explicitly. `'auto` runs the probe.
- [ ] Probe never deletes a user-visible frame; uses `make-frame` with `(visibility . nil)` and tears down with `delete-frame`.
- [ ] Logs the chosen backend at info level once, not every call.

## Files touched
- `lisp/emacs-devtools-mcp-tools-gui.el` (new — probe lives here)
- `test/emacs-devtools-mcp-tests.el` (GUI section, `:fast` for the probe-logic tests; `:gui` for the actual probe)

## Test plan
- Mocked: `x-export-frames` returns valid PNG bytes → backend `:x-export`.
- Mocked: `x-export-frames` returns `nil` + `WAYLAND_DISPLAY` set + grim on path → `:grim`.
- Mocked: `x-export-frames` errors + only X11 env → `:xwd-convert`.
- Mocked: nothing available → `:unsupported`.
- Pinned defcustom value bypasses the probe.
- `:gui` test (under xvfb-run): real probe selects `:x-export`.
- Reset function clears cache.
