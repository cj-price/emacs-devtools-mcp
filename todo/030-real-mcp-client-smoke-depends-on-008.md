# 030 — Real MCP-client smoke (`make test-mcp`)

**As** the project
**I want** a CI-runnable target that spins up the real `bin/emacs-devtools-mcp` relay and drives it from an off-the-shelf MCP client
**So that** "we follow the spec" is verified end-to-end, not just by our own tests.

## INVEST
- **I**: depends on the dispatch landing (008); the relay (007) is implicitly exercised.
- **N**: client choice — `mcp-cli` vs Node `@modelcontextprotocol/sdk` — open. Pick `@modelcontextprotocol/sdk` (more closely tracks the spec; pin a version in shell.nix).
- **V**: this is the "if Claude Code can't talk to us, none of this works" check.
- **E**: S (~half day).
- **S**: ~80 lines (mostly Makefile + a tiny Node script).
- **T**: pass/fail boolean from the script, plus stderr on failure.

## Dependencies
- 008-initialize-list-call-ping-depends-on-004-006

## Acceptance criteria
- [ ] `Makefile` target `test-mcp`: launches a host Emacs in `--bg-daemon`, waits for the socket, runs the smoke script, tears down.
- [ ] Smoke script (`test/mcp-client/smoke.mjs`) uses `@modelcontextprotocol/sdk`'s `StdioClientTransport` to launch `bin/emacs-devtools-mcp` and:
  1. Calls `initialize` and asserts `protocolVersion`, `capabilities.tools`, `serverInfo.name`.
  2. Calls `tools/list` and asserts `ping` is present with expected annotations.
  3. Calls `tools/call ping` and asserts `pong` content.
  4. Calls `tools/call unknown_tool` and asserts JSON-RPC error code `-32601`.
  5. Calls `tools/call ping {bad_arg: 1}` and asserts JSON-RPC error code `-32602`.
- [ ] Exits non-zero on any assertion failure with a clear message.
- [ ] `shell.nix` includes Node + the SDK pinned via a `package.json` in `test/mcp-client/`.
- [ ] CI workflow (002) gains a `make test-mcp` step.
- [ ] Test sets a unique `EDMCP_SERVER_NAME` per run so parallel CI jobs don't collide.

## Files touched
- `Makefile`
- `test/mcp-client/package.json`
- `test/mcp-client/smoke.mjs`
- `shell.nix` (add Node)
- `.github/workflows/ci.yml` (extend)

## Test plan
- Local: `nix-shell --run 'make test-mcp'` exits 0.
- Tamper test: temporarily rename `ping` to `pingX` in the registry → smoke fails on assertion 2 with a useful message.
- Tamper test: temporarily make `tools/call` return `200` instead of `-32601` for unknown methods → smoke fails on assertion 4.
- CI: matrix run on Emacs 29.1 / 29.4 / 30.1, all green.
