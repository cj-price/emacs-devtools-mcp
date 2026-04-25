# 003 — MCP newline-framed JSON-RPC connection

**As** the server
**I want** a `jsonrpc-connection` subclass that frames messages as line-delimited JSON per the MCP stdio spec
**So that** Claude Code (and any spec-compliant client) can talk to us without tweaks.

`jsonrpc.el`'s built-in `jsonrpc-process-connection` uses Content-Length headers (LSP-style). MCP uses `<json>\n`. We keep the abstract dispatch/continuation/events-buffer machinery; we replace the framing only.

## INVEST
- **I**: pure framing; nothing here knows about tools, sockets, or auth.
- **N**: subclass name and slot layout open; framing semantics fixed by spec.
- **V**: every tool-call ever made depends on this being correct.
- **E**: M (~1–2 days, mostly tests).
- **S**: one new file.
- **T**: property tests over framing edge cases.

## Dependencies
- 001-project-scaffolding

## Acceptance criteria
- [ ] `lisp/emacs-devtools-mcp-rpc.el` defines `emacs-devtools-mcp-rpc-connection` extending `jsonrpc-connection`.
- [ ] Implements `jsonrpc-connection-send` to write `<json>\n` (UTF-8, no embedded newlines per MCP §stdio).
- [ ] Process filter accumulates bytes, splits on `\n`, parses each line, calls `jsonrpc-connection-receive`.
- [ ] Refuses to send a message whose JSON encoding contains an embedded `\n` (server bug, fail loudly).
- [ ] Partial reads tolerated (filter buffers until LF arrives).
- [ ] Multiple messages in a single chunk all dispatched.
- [ ] Empty lines (`\n\n`) tolerated and ignored.
- [ ] Property test: encode N random envelopes, concatenate at random chunk boundaries, decoder reconstructs them all.
- [ ] All tests tagged `:fast`.

## Files touched
- `lisp/emacs-devtools-mcp-rpc.el`
- `test/emacs-devtools-mcp-tests.el` (RPC section)

## Test plan
- ERT: round-trip a notification, a request, a response.
- ERT: partial read across `\n` boundary.
- ERT: two messages in one chunk → both dispatched, both decoded equal.
- ERT: a 1 MiB JSON object → encoded once, decoded once, equal.
- ERT property (propcheck): random message + random chunking → no loss.
- ERT negative: message with embedded `\n` → signals encoder error before write.
