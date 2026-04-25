# 007 — `bin/emacs-devtools-mcp` socat relay

**As** Claude Code (or any stdio MCP client)
**I want** to launch a single binary that forwards my stdio to the host Emacs's socket and injects the auth token in the `initialize` frame
**So that** I don't need to know about Emacs sockets or tokens.

## INVEST
- **I**: standalone POSIX shell script; only contract is "stdin → socket, socket → stdout".
- **N**: shell vs Go later (out of scope; today: sh + socat).
- **V**: nothing reaches the server without this.
- **E**: S (~half day).
- **S**: one ~80-line script.
- **T**: integration-tested via 008 / 030.

## Dependencies
- 004-unix-socket-server-depends-on-003

## Acceptance criteria
- [ ] `bin/emacs-devtools-mcp` is a POSIX `/bin/sh` script (no bashisms).
- [ ] Reads `EDMCP_SERVER_NAME` env var (default `default`).
- [ ] Errors and exits 1 if `XDG_RUNTIME_DIR` is unset, with a message naming the variable.
- [ ] Verifies `${XDG_RUNTIME_DIR}/edmcp/${NAME}.sock` is a socket (`[ -S "$SOCK" ]`); errors with "host Emacs is not running. Start with M-x emacs-devtools-mcp-start".
- [ ] Reads `${XDG_RUNTIME_DIR}/edmcp/${NAME}.token`; errors if missing or non-0600.
- [ ] On the first incoming line (the `initialize` request), parses with `jq` to inject `_meta.token`. (Use `jq -c` so output is single-line.) Subsequent lines pass through unchanged.
- [ ] Connects to the socket via `socat - UNIX-CONNECT:$SOCK`. No `EXEC` / shell fan-out.
- [ ] Exits 0 on clean disconnect; non-zero on socket error or jq parse failure.
- [ ] Executable bit set; `make install` (story 001) symlinks into `~/.local/bin` if requested.
- [ ] Documented in `--help`.

## Files touched
- `bin/emacs-devtools-mcp`

## Test plan
- Run with `XDG_RUNTIME_DIR` unset → exit 1, helpful message.
- Run with no host Emacs → exit 1, helpful message.
- Pipe a sample `initialize` JSON in → output to a netcat-listener shows the token injected.
- Confirm no auth state leaks to stderr beyond high-level error categories.
