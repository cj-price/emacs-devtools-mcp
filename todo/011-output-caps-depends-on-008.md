# 011 — Response size caps and `payload_too_large`

**As** the host Emacs user
**I want** every tool response capped at a configurable byte limit
**So that** an agent can't accidentally pull a 50 MB buffer back through the socket and stall my Emacs.

## INVEST
- **I**: cross-cutting middleware; doesn't pin to any tool but every tool feeds through it.
- **N**: default cap negotiable; the structured error shape is fixed.
- **V**: protects host responsiveness and the agent's context window.
- **E**: S.
- **S**: ~70 lines + tests.
- **T**: byte-count assertion is trivial.

## Dependencies
- 008-initialize-list-call-ping-depends-on-004-006

## Acceptance criteria
- [ ] Defcustom `emacs-devtools-mcp-max-response-bytes` (default 262144 / 256 KiB).
- [ ] Defcustom `emacs-devtools-mcp-print-level` (default 8) and `emacs-devtools-mcp-print-length` (default 200) applied around server-side `prin1` of any user-supplied data.
- [ ] After serializing a tool reply, if the JSON body exceeds the cap, the reply is replaced with a JSON-RPC success response carrying `{content: [{type: "text", text: "..."}], isError: true, _meta: {error_code: "payload_too_large", actual_bytes: N, limit_bytes: M}}`.
- [ ] `buffer-substring` (013) and `list-messages` (013) accept a `max_bytes` param that defaults to the global cap and can lower (never raise) it.
- [ ] When a tool truncates due to its local `max_bytes`, the response includes `truncated: true` and `next_offset` (if applicable) so a follow-up call can continue.
- [ ] `screenshot-frame` (017) is exempt from the global cap because it has its own pixel cap; the JSON envelope still counts.
- [ ] All caps documented in commentary and in the manual once the relevant tools land.

## Files touched
- `lisp/emacs-devtools-mcp-rpc.el` (cap + envelope helpers)
- `lisp/emacs-devtools-mcp-server.el` (apply cap in dispatch)
- `test/emacs-devtools-mcp-tests.el` (Caps section)

## Test plan
- A tool returning a 300 KiB string under the default cap → reply has `payload_too_large` envelope.
- A tool returning under-cap → reply unchanged.
- `print-level` cap: a deeply nested cons returns truncated `prin1` instead of a stack overflow.
- `print-length` cap: a 10000-element list returns first 200 + `...`.
- Local `max_bytes` lower than global: respected.
- Local `max_bytes` higher than global: clamped to global, no error signaled.
