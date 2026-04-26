# emacs-devtools-mcp

A [Model Context Protocol](https://modelcontextprotocol.io) server that runs
*inside* Emacs and lets a coding agent introspect the running session: frames,
windows, buffers, faces, keymaps, hooks, advice, the message log, the
*Warnings* buffer, and your `init.el`. The same loop
[`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp)
gives an agent for the browser, but for Emacs.

**Status**: 0.1.0 — feature-complete for the v1 tool surface (36 tools across
8 categories). Pre-release; no public API stability guarantees yet. Tested on
Emacs 29.1, 29.4, and 30.1.

## What you can ask an agent to do

- *"My modeline shows the wrong color for unsaved buffers — verify it."*
  Agent calls `screenshot_frame`, `face-at`, `color_contrast`.
- *"My init.el started taking 4 seconds to load yesterday. Find the culprit."*
  Agent calls `bisect_init` or `startup_profile`.
- *"Why is `C-c C-c` running the wrong command in this buffer?"*
  Agent calls `lookup_key`, `where_is`, `key_translation_trace`.
- *"Reproduce this bug, capture the backtrace, and tell me which advice
  swallowed the error."* Agent calls `eval_elisp` and `capture_backtrace`.
- *"Run the package's ERT suite and summarize."* Agent calls `ert_run`.

## How it works

```
agent ──stdio──▶ bin/emacs-devtools-mcp ──unix socket──▶ Host Emacs (this package)
   newline-delimited JSON-RPC         │
   per the MCP stdio spec             └─ make-process argv list ──▶ subordinate Emacs
                                          emacs -Q --bg-daemon=NAME
                                          (optional: under `xvfb-run`)
```

- Pure-Elisp server runs inside the user's Emacs — no external runtime.
- `bin/emacs-devtools-mcp` is a small POSIX-sh script that uses `socat` to
  relay between the agent's stdio MCP transport and a Unix-domain socket at
  `${XDG_RUNTIME_DIR}/edmcp/${NAME}.sock` (mode `0600`).
- Peer auth: `SO_PEERCRED` uid match plus a per-launch token stored in a
  sibling `0600` file; the relay reads it and injects it into the first MCP
  frame's `params._meta.token`.
- Every tool accepts an optional `target` object: `{"host": true}` (default —
  your running Emacs) or `{"spawn": "<handle>"}` (a subordinate `emacs -Q`
  daemon spawned by `spawn_emacs`).

## Installing

You need: Emacs ≥29.1, `socat`, `jq`, and (for headless / GUI tests) `xvfb-run`
and `grim`. The repo ships a `shell.nix` that pins all of those.

```sh
git clone https://github.com/cjprice/emacs-devtools-mcp.git
cd emacs-devtools-mcp
nix-shell --run 'make all'   # byte-compile + ERT + checkdoc + manual
```

To make the server part of your Emacs:

```elisp
(add-to-list 'load-path "/path/to/emacs-devtools-mcp/lisp")
(require 'emacs-devtools-mcp)
(require 'emacs-devtools-mcp-server)
(emacs-devtools-mcp-server-start)   ;; binds the Unix socket
;; (emacs-devtools-mcp-server-stop) to shut it down.
```

To register the agent transport with Claude Code, copy `.mcp.json.example` and
point it at the absolute path of `bin/emacs-devtools-mcp`:

```json
{
  "mcpServers": {
    "emacs-devtools": {
      "command": "/abs/path/to/emacs-devtools-mcp/bin/emacs-devtools-mcp",
      "env": { "EDMCP_NAME": "default" }
    }
  }
}
```

## Tool catalog

All tools accept an optional `target` (`{"host": true}` default or
`{"spawn": "<handle>"}`). List-shaped tools take an optional `cursor` and
return `next_cursor` when more results remain. JSON keys are `snake_case`.

### Server / smoke

| Tool | Description |
|---|---|
| `ping` | Echo back `pong` plus an optional message. Useful for the agent's first call. |

### Spawn

| Tool | Description |
|---|---|
| `spawn_emacs` | Start an `emacs -Q --bg-daemon` subordinate; optionally load an init file under the allowlist. Returns `{handle, server_name, pid, expires_at}`. |
| `attach_emacs` | Register a daemon you started yourself, by `server_name`. |
| `list_handles` | Paginated active-handle listing with `idle_seconds` + `expires_at`. |
| `kill_emacs` | Kill a daemon by handle and forget it. |

### Eval / debug

| Tool | Description |
|---|---|
| `eval_elisp` | Evaluate FORM in `target` and return its printed value plus the *Messages* delta and any error. |
| `edebug_instrument` / `edebug_uninstrument` | Mark a function for `edebug` stepping; restore. |
| `capture_backtrace` | Evaluate FORM and return the backtrace at signal time, tail-truncated and redacted. |
| `trace_function` / `untrace_function` / `trace_log` | `trace-function-foreground` round-trip, with paginated log readout. |

### Buffer / state

| Tool | Description |
|---|---|
| `list_buffers` | Optionally filtered by regex. |
| `buffer_state` | Point/mark/mode/file metadata for a buffer. |
| `buffer_substring` | Up to `max_bytes` of a buffer between `start` and `end`; sets `truncated: true` and `next_offset` when capped. |
| `list_messages` | Last N lines of *Messages*, redacted. |
| `list_warnings` | Paragraph-split contents of *Warnings*. |
| `ert_run` | Run ERT for a selector; return summary. |
| `describe_hooks` | All bound hooks, or contents of one. |

### Keys

| Tool | Description |
|---|---|
| `where_is` | All key sequences bound to a command in a keymap. |
| `lookup_key` | Command bound to a key sequence. |
| `describe_keymap` | Flattened binding listing under a keymap, optionally narrowed by prefix. |
| `simulate_keys` | Run a `kbd` macro and return point/mark/buffer-diff/messages delta. |
| `key_translation_trace` | Trace through the three keyboard translation maps. |

### GUI

| Tool | Description |
|---|---|
| `screenshot_frame` | Export FRAME as a base64 PNG MCP image content block. Pgtk/Wayland fallback to `grim`. |
| `get_frame_tree` | frames → windows → buffer metadata. |
| `face_at` | Face at a 1-based line + 0-based column in a buffer. |
| `describe_face` | Inheritance-resolved attributes plus docstring. |
| `list_faces` | Alphabetical face listing, optionally filtered. |
| `color_contrast` | WCAG contrast ratio between two colors. |

### Init / startup

| Tool | Description |
|---|---|
| `init_lint` | Byte-compile FILE in `emacs -Q --batch`; return diagnostics. Allowlist-checked; output redacted. |
| `startup_profile` | CPU-profile FILE; return elapsed seconds plus the top 50 hotspot frames (redacted). |
| `bisect_init` | Binary-search FILE for the form that triggers a predicate; returns `{culprit_form, line_start, line_end, probes, load_failed_probes}`. |

## Configuration

Every user-facing knob is a `defcustom` under one of four groups:
`emacs-devtools-mcp` (parent), `-server`, `-spawn`, `-tools`, `-security`. The
ones you are most likely to touch:

| Variable | Default | Purpose |
|---|---|---|
| `emacs-devtools-mcp-server-name` | `"default"` | Socket name segment under `${XDG_RUNTIME_DIR}/edmcp/`. |
| `emacs-devtools-mcp-init-allowlist` | `~/.config/emacs`, `~/.emacs.d`, project root | Paths agents may pass to `bisect_init` / `init_lint` / `startup_profile` / `spawn_emacs`. |
| `emacs-devtools-mcp-max-response-bytes` | `262144` | Global hard cap on per-call payload. |
| `emacs-devtools-mcp-screenshot-max-pixels` | `1920×1080` | Refuse oversize frames. |
| `emacs-devtools-mcp-spawn-idle-timeout` | `1800` | Reaper kills idle handles after this many seconds. |
| `emacs-devtools-mcp-spawn-max-handles` | `4` | Cap on simultaneous subordinate daemons. |
| `emacs-devtools-mcp-slow-tool-timeout` | `25` | `with-timeout` cap for `:slow` tools. |
| `emacs-devtools-mcp-bisect-max-probes` | `12` | Hard cap on `bisect_init` iterations. |
| `emacs-devtools-mcp-init-batch-timeout` | `30` | Per-probe timeout in `emacs --batch`. |
| `emacs-devtools-mcp-redact-extra-regexps` | `nil` | Additional patterns to scrub from any *Messages* / backtrace output. |

`M-x customize-group RET emacs-devtools-mcp RET` walks the full set.

## Security model

This is a developer tool for your own Emacs session. It is intentionally **not
sandboxed** — `eval_elisp` runs Lisp with your full user privileges, and
`bisect_init` / `startup_profile` execute arbitrary code from your real
`init.el` in subordinate `emacs -Q --batch` subprocesses that inherit your
`$HOME`. Treat it accordingly: only register it with agents you trust to act
on your behalf, and review what they're about to do before approving
destructive tool calls.

What is defended:

- **Transport**. Unix-domain socket at `${XDG_RUNTIME_DIR}/edmcp/`, mode
  `0600`. Hard-fails if `XDG_RUNTIME_DIR` is unset — never falls back to
  `/tmp`. Stale socket files are verified `S_ISSOCK` + same-uid + non-symlink
  before re-bind.
- **Peer auth**. `SO_PEERCRED` uid check on every accept, plus a per-launch
  random token in the first MCP frame.
- **Subprocess hygiene**. `make-process` with explicit argv lists everywhere
  (no shell). `server_name` validated against `[A-Za-z0-9_-]+`. Reader-macro
  injection (`#.`, `#@`) refused everywhere subordinate output is parsed,
  even before `read` ever runs.
- **Init paths**. Allowlist-checked via `expand-file-name` + `file-truename`
  + prefix match, against `emacs-devtools-mcp-init-allowlist`.
- **Output**. Redaction layer scrubs lines mentioning `auth-source-`, `epg-`,
  and `tramp-` (plus `redact-extra-regexps`) from any *Messages* / backtrace /
  profiler-frame surface before it leaves the host.
- **Resource caps**. `with-timeout` on every `:slow` handler;
  `max-response-bytes`; `screenshot-max-pixels`; `unwind-protect` around
  `profiler-start`.

What is *not* defended (deliberate, single-user developer tool):

- The contents of `eval_elisp` / `simulate_keys` / `capture_backtrace`. They
  are general-purpose execution by design.
- Multi-tenant access. The relay rejects any peer whose uid is not yours.
- Networked transport. Local stdio + Unix socket only.

## Development

```
make all          lisp + test + lint + manual
make lisp         byte-compile -Werror; zero warnings
make test         full ERT, all tags
make test-fast    :fast tag only — sub-second, pre-commit-friendly
make test-daemon  :daemon tag — shared subordinate fixture
make test-gui     :gui tag — under xvfb-run -a
make test-mcp     end-to-end MCP smoke from a real client
make lint         checkdoc-file every lisp/*.el; zero warnings
make manual       makeinfo manual/emacs-devtools-mcp.texi
```

CI: GitHub Actions matrix on Emacs 29.1, 29.4, 30.1. `make all` and
`make test-mcp` on every push. Build fails on any byte-compile or checkdoc
warning.

## Contributing

See `CONTRIBUTING.md` for issue/PR norms. Conventions for the codebase live
in `CLAUDE.md` (it doubles as the agent-facing rulebook and the human-facing
style guide).

## License

GPL-3.0-or-later. Full text in `LICENSE`.
