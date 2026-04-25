# 009 — Cursor store with TTL

**As** a tool author
**I want** a server-side cursor store I can write iterator state into and hand back as an opaque token
**So that** list-shaped tools paginate MCP-natively without each tool reinventing pagination.

## INVEST
- **I**: utility; nothing depends on it until 013/014/etc. land.
- **N**: token format (16-byte hex) negotiable; TTL value defcustom.
- **V**: prerequisite for paginated `list-*` tools.
- **E**: S.
- **S**: ~80 lines + tests.
- **T**: pure data structure with TTL — easy.

## Dependencies
- 008-initialize-list-call-ping-depends-on-004-006

## Acceptance criteria
- [ ] `emacs-devtools-mcp-server--cursors` is a hash keyed by 16-byte hex token (32 chars).
- [ ] API: `(server-cursor-put STATE)` returns a token; `(server-cursor-get TOKEN)` returns state or nil; `(server-cursor-drop TOKEN)`.
- [ ] Each entry stores STATE + creation timestamp.
- [ ] A timer (default every 60 s, defcustom) drops entries older than `emacs-devtools-mcp-cursor-ttl` (default 300 s).
- [ ] Tokens are cryptographically random (use `nonce-bytes` or `secure-hash` over good entropy; document choice).
- [ ] Get-after-drop returns nil and logs at debug level.
- [ ] Cursor returned in `tools/call` reply when the iterator has more; absent otherwise.
- [ ] `next_cursor` propagation pattern documented in commentary for tool authors.

## Files touched
- `lisp/emacs-devtools-mcp-server.el` (cursor-* defuns)
- `test/emacs-devtools-mcp-tests.el` (Cursors section)

## Test plan
- Put → get returns the stored value.
- Put 100 entries → all retrievable.
- Token uniqueness across 10k puts.
- TTL: put, advance time (`cl-letf` `current-time`), reaper drops it.
- Get-after-drop returns nil, no error.
