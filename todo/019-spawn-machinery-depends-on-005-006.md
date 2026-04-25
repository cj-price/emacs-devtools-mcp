# 019 — Spawn machinery (subordinate Emacs lifecycle)

**As** an agent (or the package itself)
**I want** to start, attach to, and tear down a subordinate Emacs daemon — optionally headless under `xvfb-run` — and dispatch elisp into it via emacsclient
**So that** I can run experiments without polluting the user's live Emacs and so headless / CI flows have a path.

## INVEST
- **I**: depends on auth (so a per-handle token can be propagated if needed) and the registry (so `target.spawn` shape is known); routing of *all* tools into spawn lands in 021.
- **N**: idle-timeout default and max-handles cap negotiable (defcustom).
- **V**: gates Phase 7 — every spawn-target tool depends on this.
- **E**: L (~3–4 days; this is the biggest piece in the project after the registry).
- **S**: borderline — `:cost` wrapping, allowlist, xvfb hardening, idle reaper hooks, emacsclient dispatch, return-value reading. If it grows past ~400 lines, split out idle reaper into 022 and routing into 021 (already planned).
- **T**: each piece has its own ERT; the integration is exercised by 021's parity tests.

## Dependencies
- 005-peer-auth-token-depends-on-004
- 006-tool-registry-and-deftool-depends-on-003

## Acceptance criteria
- [ ] `(emacs-devtools-mcp-spawn-start &key init headless name)` returns a handle struct `(:handle :server-name :pid :headless :init :created-at :last-used-at)`.
- [ ] Server name validated against regex `\\`[A-Za-z0-9_-]+\\`'`; refused otherwise.
- [ ] Init path validated against `emacs-devtools-mcp-init-allowlist` defcustom (default `(~/.config/emacs ~/.emacs.d <project-root>)`); rejected otherwise. Allowlist entries are `expand-file-name` + `file-truename`d; comparison is prefix-match on the truenamed path.
- [ ] `make-process` argv list:
  - GUI host: `(emacs --bg-daemon=NAME [-l INIT or -Q])`.
  - Headless: `(xvfb-run --auto-servernum --server-args="-nolisten tcp -nolisten unix" -- emacs --bg-daemon=NAME [...])` with private `XAUTHORITY=$XDG_RUNTIME_DIR/edmcp/<NAME>.xauth`.
- [ ] `(emacs-devtools-mcp-spawn-attach SERVER-NAME)`: registers an existing daemon as a handle; same allowlist check is N/A here.
- [ ] `(emacs-devtools-mcp-spawn-call HANDLE FORM)`: serializes `FORM` via `prin1-to-string`, runs `emacsclient -s SERVER-NAME --eval STRING`, reads stdout via `(let ((read-eval nil)) (read FROM-STRING))`. Updates `last-used-at`.
- [ ] `(emacs-devtools-mcp-spawn-kill HANDLE)`: `emacsclient -s NAME --eval '(kill-emacs)'`; on no-response after 2 s, `make-process` `kill -TERM`; after 5 s, `kill -KILL`. Frees `XAUTHORITY` file.
- [ ] `(emacs-devtools-mcp-spawn-list)`: returns the live handles.
- [ ] `kill-emacs-hook` on the host calls `spawn-kill` for every handle.
- [ ] Defcustom `emacs-devtools-mcp-spawn-emacs-binary` (default `"emacs"`); resolved via `executable-find` once at start.
- [ ] All `make-process` calls use `:command (list ...)` argv form; never `:command "shell-string"`.
- [ ] Stderr from spawn captured into a per-handle buffer `* edmcp-spawn:NAME *` for diagnosis.

## Files touched
- `lisp/emacs-devtools-mcp-spawn.el` (new)
- `lisp/emacs-devtools-mcp-auth.el` (extend with allowlist if not already)
- `test/emacs-devtools-mcp-spawn-tests.el` (new)

## Test plan
- ERT `:fresh-daemon`: spawn `-Q` daemon, `spawn-call '(emacs-version)'` → returns version string.
- ERT `:fresh-daemon`: spawn `-Q` daemon, kill it, attempt `spawn-call` → `handle_dead` error.
- ERT `:fresh-daemon`: server-name with `;` → refused at validation.
- ERT `:fresh-daemon`: init outside allowlist → refused.
- ERT `:fresh-daemon`: subordinate prints `#.(delete-file "/tmp/x")` → `read` refuses (read-eval bound to nil); file not deleted.
- ERT `:gui`: headless spawn under xvfb-run produces a frame; `XAUTHORITY` is in the per-handle dir; deleted on `spawn-kill`.
- ERT `:fresh-daemon`: `kill-emacs-hook` simulation kills outstanding handles.
