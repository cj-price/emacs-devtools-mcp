# 021 — Spawn-target dispatch routing in `deftool`

**As** the package developer
**I want** `deftool` to recognize a `target` param and dispatch the handler to host or spawn transparently
**So that** every existing tool (`eval-elisp`, `simulate-keys`, `face-at`, `buffer-substring`, etc.) works against either target without per-tool code.

## INVEST
- **I**: depends on the registry (006) and spawn lib (019).
- **N**: contract that handlers must end with `(emacs-devtools-mcp-spawn-call target form)` is fixed; the macro enforces this. The macro-time enforcement check shape is open.
- **V**: this is the unification — without it, every tool would branch on target by hand.
- **E**: M (~2 days).
- **S**: ~150 lines (mostly macro changes + tests).
- **T**: dispatch table is small; parity tests in 023 are the integration check.

## Dependencies
- 019-spawn-machinery-depends-on-005-006
- 006-tool-registry-and-deftool-depends-on-003

## Acceptance criteria
- [ ] `deftool` (006) accepts an implicit `target` schema member when the handler signature includes a `target` arg; macro-time error if a tool author declares `target` but the handler ignores it.
- [ ] At dispatch time, `target = {host: t}` → `funcall HANDLER ARGS-WITHOUT-TARGET` in the host process.
- [ ] `target = {spawn: HANDLE-ID}` → handle is looked up in the registry; on miss, JSON-RPC error `-32602` with field `target.spawn` and value `handle_not_found`.
- [ ] On hit, the handler's body is serialized via `prin1-to-string` and dispatched via `(emacs-devtools-mcp-spawn-call HANDLE FORM)`.
- [ ] Macro-time check (best-effort): the handler's body must end with a single expression. A handler that side-effects on the host before the spawn call is rejected with a helpful error.
- [ ] Return value contract: handler returns a value `read`-equivalent to its `prin1` form (no buffer/marker/window/process objects). Documented in commentary.
- [ ] When `target` is omitted, defaults to `{host: t}`.
- [ ] `:slow` wrapping (006) wraps the entire dispatch including the spawn call's `make-process` + `read`.

## Files touched
- `lisp/emacs-devtools-mcp-server.el` (or `-registry.el`) — extend `deftool`
- `lisp/emacs-devtools-mcp-spawn.el` — `spawn-call` already exists from 019; this story consumes it.
- `test/emacs-devtools-mcp-tests.el` (Registry/Dispatch section)

## Test plan
- ERT: tool with default `target` runs in host.
- ERT: tool with `{host: t}` runs in host.
- ERT `:fresh-daemon`: tool with `{spawn: ID}` runs in spawn; verify by side-effect (e.g., `(emacs-pid)` differs from host).
- ERT: tool with `{spawn: "bogus"}` → `-32602`, `handle_not_found`.
- ERT (macro expansion): a tool author writing pre-spawn host side-effects → byte-compile error.
- ERT: a handler that returns a buffer object → spawn-side `prin1` produces an opaque `#<buffer>` string; host-side `read` errors → tool returns `non_serializable_return` envelope.
