# 005 — Peer auth (SO_PEERCRED + per-launch token)

**As** the host Emacs
**I want** to verify that the connecting peer is the same uid AND presents a per-launch token in its first frame
**So that** another local process running as my user (compromised npm postinstall, native messaging host, etc.) cannot reach `eval-elisp`.

## INVEST
- **I**: layered on 004; doesn't touch tool surface.
- **N**: token length, frame name, file path open. SO_PEERCRED check fixed.
- **V**: closes the only realistic local-attacker surface for this socket.
- **E**: M (~1 day).
- **S**: small additions to server file + a tiny auth file.
- **T**: every reject path is unit-testable.

## Dependencies
- 004-unix-socket-server-depends-on-003

## Acceptance criteria
- [ ] `lisp/emacs-devtools-mcp-auth.el` provides `emacs-devtools-mcp-auth--check-peer` (uid match) and `-check-token`.
- [ ] On `server-start`, generate a 32-byte random token; write to `${XDG_RUNTIME_DIR}/edmcp/${NAME}.token` with mode 0600.
- [ ] On accept, read `SO_PEERCRED` (via `network-process-peer-credentials` if available, else best-effort with documented degradation) and reject if uid ≠ current.
- [ ] First MCP frame from a new connection MUST be the MCP `initialize` request whose params include `_meta.token` matching the file. Reject (and close) otherwise.
- [ ] Token rotated on every `server-start`; old token file unlinked.
- [ ] All failure paths log to a `*emacs-devtools-mcp-log*` buffer (suppressible via defcustom).
- [ ] Reject paths return a JSON-RPC error and close the socket; do not leak details.

## Files touched
- `lisp/emacs-devtools-mcp-auth.el`
- `lisp/emacs-devtools-mcp-server.el` (wire auth into accept)
- `test/emacs-devtools-mcp-tests.el` (Auth section)

## Test plan
- Connect with mismatched token → server closes with error.
- Connect, send a non-`initialize` first frame → close with error.
- Connect, send `initialize` without `_meta.token` → close.
- Token file is mode 0600 and removed on stop.
- Restart server → new token; old connection rejected with stale token.
