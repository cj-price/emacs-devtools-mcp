# 015 — `simulate-keys` tool

**As** an agent
**I want** to feed a key sequence to a buffer and observe what changed
**So that** I can verify "does this binding actually do what I think?" or reproduce a bug step-by-step.

## INVEST
- **I**: depends only on the read-only key tools landing first so the surrounding category is consistent.
- **N**: `buffer_diff` shape (full text vs unified-diff vs region) open; pick unified-diff to keep cap-friendly.
- **V**: closes the agent's interactive-debug loop — no more "ask the user to press the key for me".
- **E**: M (~1 day).
- **S**: ~120 lines + tests.
- **T**: deterministic given a fixture buffer + key sequence.

## Dependencies
- 014-key-tools-depends-on-008

## Acceptance criteria
- [ ] Tool: `simulate-keys` (`:cost :slow`, destructive, not read-only, not idempotent).
- [ ] Schema: `keys` (string, required, kbd syntax), `buffer` (string, optional — defaults to current buffer), `target` (host-only until 021).
- [ ] Refuses to run sequences whose first event is bound to `keyboard-quit` or `save-buffers-kill-terminal`. Configurable via defcustom `emacs-devtools-mcp-simulate-keys-blocklist`.
- [ ] Wraps `execute-kbd-macro` inside `with-current-buffer` and `save-excursion` semantics where possible. Errors during execution are caught into `isError: true` envelope, NOT propagated as protocol error.
- [ ] Returns `{last_command, this_command, point, mark, buffer_diff (unified-diff against pre-state, capped), messages_delta (redacted), duration_ms}`.
- [ ] Defcustom `emacs-devtools-mcp-simulate-keys-confirm-destructive` (default nil): when t, the tool prompts the user via `y-or-n-p` before executing. Documented as the "throw an emergency brake" knob.
- [ ] Output flows through 010 redaction and 011 caps.

## Files touched
- `lisp/emacs-devtools-mcp-tools-keys.el` (extend)
- `test/emacs-devtools-mcp-tests.el` (Keys section)

## Test plan
- ERT: in a fixture buffer with `"abc"`, simulate `"C-e"` → point at end-of-line, no buffer diff.
- ERT: simulate `"C-d"` at start of `"abc"` → buffer diff shows `-abc / +bc`.
- ERT: simulate `"C-x C-c"` → refused (blocklist).
- ERT: simulate a sequence that signals `(error "boom")` → `isError: true` with `error_message`, NOT a protocol error.
- ERT: simulate a long-running command → preempts under `while-no-input` (006).
- ERT: confirm-destructive flag t + a destructive sequence → assertion verifies `y-or-n-p` was called (cl-letf stub).
