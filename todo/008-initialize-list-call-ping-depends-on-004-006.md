# 008 — Initialize / tools-list / tools-call dispatch + `ping`

**As** an MCP client
**I want** to perform `initialize`, `tools/list`, and `tools/call ping`
**So that** I have a verifiable end-to-end round-trip before any real tool is built.

## INVEST
- **I**: depends on 004 (socket) + 006 (registry); first story producing user-visible behavior.
- **N**: `ping` payload shape open.
- **V**: first story an agent could actually call.
- **E**: M (~1 day).
- **S**: glue + one trivial tool.
- **T**: end-to-end round-trip is a single ERT.

## Dependencies
- 004-unix-socket-server-depends-on-003
- 005-peer-auth-token-depends-on-004
- 006-tool-registry-and-deftool-depends-on-003
- 007-relay-script-depends-on-004

## Acceptance criteria
- [ ] Server dispatches MCP methods: `initialize`, `tools/list`, `tools/call`. Unknown methods return JSON-RPC `-32601`.
- [ ] `initialize` reply contains `protocolVersion` (latest MCP supported), `capabilities: {tools: {}}`, `serverInfo: {name, version}`.
- [ ] `tools/list` reads from registry; emits `name`, `description`, `inputSchema`, plus annotations (`readOnlyHint`/`destructiveHint`/`idempotentHint`).
- [ ] `tools/call` validates against `inputSchema` (006), invokes handler, returns content blocks.
- [ ] `ping` tool (`:cost :fast`, read-only, idempotent): no params, returns `{content: [{type: "text", text: "pong"}]}`.
- [ ] Tool execution failures returned as `{content: [...], isError: true}`; protocol failures as JSON-RPC error.
- [ ] Concurrency: a `:fast` tool dispatched while no `:slow` is in flight runs immediately. `:slow` while in flight returns `busy` (-32001).
- [ ] All tests in the Server section pass.

## Files touched
- `lisp/emacs-devtools-mcp-server.el` (dispatcher methods)
- `lisp/emacs-devtools-mcp-rpc.el` (error envelope helpers)
- `test/emacs-devtools-mcp-tests.el`

## Test plan
- ERT (`:daemon`): start server, connect a client, run `initialize` → reply asserted.
- ERT: `tools/list` includes `ping` with the expected annotations.
- ERT: `tools/call ping` → content block `pong`.
- ERT: `tools/call unknown_tool` → `-32601`.
- ERT: schema-violating `tools/call` → `-32602` with field path.
- ERT: simulate a `:slow` in-flight + a second `:slow` request → second returns `busy`.
