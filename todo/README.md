# Story backlog

Topologically ordered. The number indicates the suggested implementation sequence; each story's `Dependencies` section lists which prior stories must land first. Some stories are independent and could run in parallel — see the dep graph below.

Story format (INVEST):
- **I**ndependent — minimal coupling to siblings
- **N**egotiable — acceptance criteria are open until pulled
- **V**aluable — delivers a working capability or unblocks one
- **E**stimable — `S` ≤ 1 day, `M` 1–3 days, `L` 3–5 days
- **S**mall — `L` is the cap; bigger stories must be split
- **T**estable — every AC has a check

## Phases

| Phase | Stories | Deliverable |
|---|---|---|
| 1. Scaffolding | 001–002 | Repo + CI green |
| 2. Transport | 003–008 | `ping` round-trip via Claude Code |
| 3. Cross-cutting | 009–011, 030 | Cursors, redaction, output caps, MCP client smoke |
| 4. Eval + buffer | 012–013 | Agent can read state and run elisp |
| 5. Keys | 014–015 | Agent can introspect and simulate keys |
| 6. GUI (host) | 016–018 | Agent can screenshot host frames + inspect faces |
| 7. Spawn | 019–023 | Subordinate Emacs target wired through dispatch |
| 8. Debugger | 024–025 | edebug + trace |
| 9. Init.el | 026–029 | bisect, lint, startup-profile |
| 10. Polish | 031–033 | Transient menu, manual, README |

## Dependency graph (concise)

```
001 ─┬─ 002 (CI)
     └─ 003 ─ 004 ─┬─ 005 ─┐
                   ├─ 006 ─┤
                   └─ 007  │
                           └─ 008 ─┬─ 009
                                   ├─ 010
                                   ├─ 011
                                   ├─ 014 ─ 015
                                   ├─ 016 ─ 017 ─ 018
                                   ├─ 030
                                   └─ 031
008+010+011 ─ 012 ─┬─ 024
                   └─ 025
008+009+011 ─ 013
005+006 ─ 019 ─┬─ 020 ─ 022
               ├─ 021
               ├─ 026
               ├─ 027
               └─ 028 ─ 029(+026)
021 ─ 023
013+015+018+024+025+029 ─ 032
008+031 ─ 033
```

## Index

| # | Story | Size | Phase |
|---|---|---|---|
| 001 | Project scaffolding | M | 1 |
| 002 | CI matrix | S | 1 |
| 003 | MCP newline-framed JSON-RPC connection | M | 2 |
| 004 | Unix socket server with stale-socket safety | M | 2 |
| 005 | Peer auth (SO_PEERCRED + per-launch token) | M | 2 |
| 006 | Tool registry and `deftool` macro | M | 2 |
| 007 | `bin/emacs-devtools-mcp` socat relay | S | 2 |
| 008 | Initialize / tools-list / tools-call dispatch + `ping` | M | 2 |
| 009 | Cursor store with TTL | S | 3 |
| 010 | Output redaction layer | S | 3 |
| 011 | Response size caps + `payload_too_large` | S | 3 |
| 012 | `eval-elisp` tool | M | 4 |
| 013 | Buffer / state tools (7 tools) | M | 4 |
| 014 | Read-only key tools (4 tools) | M | 5 |
| 015 | `simulate-keys` | M | 5 |
| 016 | Host screenshot backend probe (pgtk/Wayland fallback) | M | 6 |
| 017 | `screenshot-frame` tool | M | 6 |
| 018 | Frame and face tools (4 tools) | M | 6 |
| 019 | Spawn machinery (`--bg-daemon`, xvfb-run, allowlist) | L | 7 |
| 020 | Spawn lifecycle tools (4 tools) | M | 7 |
| 021 | Spawn-target dispatch routing in `deftool` | M | 7 |
| 022 | Idle reaper + `max-handles` cap | S | 7 |
| 023 | Host-vs-spawn parity test suite | M | 7 |
| 024 | edebug tools (3 tools) | M | 8 |
| 025 | trace tools (3 tools) | M | 8 |
| 026 | `init-lint` tool | S | 9 |
| 027 | `startup-profile` tool | M | 9 |
| 028 | Persistent subordinate pipe | M | 9 |
| 029 | `bisect-init` tool | M | 9 |
| 030 | Real MCP-client smoke (`make test-mcp`) | S | 3 |
| 031 | Transient dispatcher | S | 10 |
| 032 | Texinfo manual | M | 10 |
| 033 | README quickstart + transcript | S | 10 |
