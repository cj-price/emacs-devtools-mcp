# 004 — Unix socket server with stale-socket safety

**As** the host Emacs
**I want** to listen on a Unix-domain socket at `${XDG_RUNTIME_DIR}/edmcp/${NAME}.sock`
**So that** the relay (and only legitimate local processes) can reach the dispatcher.

## INVEST
- **I**: depends on 003 for the connection class but not on auth or the registry.
- **N**: socket subdir name (`edmcp`) is open; XDG path is fixed.
- **V**: without this, tools can't be reached.
- **E**: M (~1 day).
- **S**: ~120 lines of Elisp + tests.
- **T**: stale-socket conditions are deterministic and testable.

## Dependencies
- 003-mcp-newline-framing-depends-on-001

## Acceptance criteria
- [ ] `lisp/emacs-devtools-mcp-server.el` exposes `emacs-devtools-mcp-server-start` / `-stop`.
- [ ] Server creates `${XDG_RUNTIME_DIR}/edmcp/` with mode 0700 if missing.
- [ ] **Hard-fails** if `XDG_RUNTIME_DIR` is unset. Never falls back to `/tmp`.
- [ ] Socket name is `defcustom emacs-devtools-mcp-server-name` (default `"default"`); supports multiple Emacsen on same user.
- [ ] On bind: if path exists, verify it is a socket (`S_ISSOCK`), owned by current uid, and not a symlink (`file-symlink-p` nil + `file-attributes` matches). Refuse otherwise. Otherwise unlink and bind.
- [ ] Socket created with mode 0600.
- [ ] On accept, instantiates an `emacs-devtools-mcp-rpc-connection` over the accepted process.
- [ ] `kill-emacs-hook` removes the socket file.
- [ ] `emacs-devtools-mcp-server-stop` is idempotent.
- [ ] Tests tagged `:fast` (no real subprocess) and `:daemon` where a real client is needed.

## Files touched
- `lisp/emacs-devtools-mcp-server.el`
- `test/emacs-devtools-mcp-tests.el` (Server section)

## Test plan
- Start server twice → second `start` is a no-op (or returns existing).
- Pre-create a regular file at the socket path → start refuses.
- Pre-create a symlink at the socket path → start refuses.
- Stale socket left from prior crash (real socket, our uid) → start unlinks and rebinds.
- `XDG_RUNTIME_DIR` unset → start signals user-error.
- `kill-emacs-hook` removes the file (verify via `file-exists-p` after a child process triggers `kill-emacs`).
