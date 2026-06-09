# emacs-devtools-mcp

[![CI](https://github.com/cj-price/emacs-devtools-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/cj-price/emacs-devtools-mcp/actions/workflows/ci.yml)

A [Model Context Protocol](https://modelcontextprotocol.io) server that runs
*inside* Emacs and lets a coding agent introspect the running session: frames,
windows, buffers, faces, keymaps, hooks, advice, the message log, the
*Warnings* buffer, and your `init.el`. The same loop
[`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp)
gives an agent for the browser, but for Emacs.

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

## Installing

You need: Emacs ≥30.1, `socat`, and `jq`. Everything except
`screenshot_frame` works in a TTY or headless daemon; only the screenshot
tool needs a graphical Emacs build (for `x-export-frames`). `xvfb-run`
lets you run `make test-gui` and lets `spawn_emacs` start a screenshot-
capable subordinate daemon via `display_mode: "xvfb-run"`. The repo ships
a `shell.nix` that pins all of those.

```sh
git clone https://github.com/cj-price/emacs-devtools-mcp.git
cd emacs-devtools-mcp
nix-shell --run 'make all'   # byte-compile + ERT + checkdoc
```

To make the server part of your Emacs:

```elisp
(add-to-list 'load-path "/path/to/emacs-devtools-mcp/lisp")
(require 'emacs-devtools-mcp)
(require 'emacs-devtools-mcp-server)
(emacs-devtools-mcp-server-start)   ;; binds the Unix socket
;; (emacs-devtools-mcp-server-stop) to shut it down.
```

### Verify it works

End-to-end smoke against a fresh subordinate Emacs (no host attach
required) — should end with `summary: PASS=N FAIL=0`:

```sh
nix-shell --run 'make test-mcp'
```

### Wire it into your agent

The relay (`bin/emacs-devtools-mcp`) is a standard MCP stdio server, so
any MCP-compatible client works (Claude Code, Codex, Cline, Continue,
Goose, …). For Claude Code, copy `.mcp.json.example` and point it at the
absolute path of `bin/emacs-devtools-mcp`:

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

Other clients use the same `command` + `env` shape under their own
configuration key.

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
| `spawn_emacs` | Start an `emacs -Q --bg-daemon` subordinate; optionally load an init file under the allowlist. `display_mode` is one of `"host-inherit"` (default; daemon inherits the host's `DISPLAY` and `WAYLAND_DISPLAY` — typically what an interactive Emacs has, headless under TTY hosts; on a Wayland host the X11 `DISPLAY` is dropped — `WAYLAND_DISPLAY` kept — so a `--with-pgtk` build uses Wayland rather than a crash-prone X11 frame that pops the "pure-GTK under X" warning), `"none"` (scrubs both for a guaranteed-headless spawn even when the host has a display), or `"xvfb-run"` (wraps the launch in `xvfb-run -a` so `screenshot_frame` works against the spawn). Returns `{handle, server_name, pid, display_mode, idle_seconds, expires_at, attached}`. |
| `attach_emacs` | Register a daemon you started yourself, by `server_name`. |
| `list_handles` | Paginated active-handle listing with `idle_seconds` + `expires_at`. |
| `kill_spawn` | Kill a daemon by handle and forget it. Named `kill_spawn` (not `kill_emacs`) so it cannot be misread as a request to terminate the host. |

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
| `screenshot_frame` | Export FRAME as a base64 PNG MCP image content block via `x-export-frames` (graphical Emacs builds only; errors on builds where the probe fails). |
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

Every user-facing knob is a `defcustom` under the parent
`emacs-devtools-mcp` group or one of its four subgroups: `-server`,
`-spawn`, `-tools`, `-security`. The ones you are most likely to touch:

| Variable | Default | Purpose |
|---|---|---|
| `emacs-devtools-mcp-server-name` | `"default"` | Socket name segment under `${XDG_RUNTIME_DIR}/edmcp/`. |
| `emacs-devtools-mcp-init-allowlist` | `~/.config/emacs`, `~/.emacs.d`, project root | Paths agents may pass to `bisect_init` / `init_lint` / `startup_profile` / `spawn_emacs`. |
| `emacs-devtools-mcp-max-response-bytes` | `262144` | Global hard cap on per-call payload (text). |
| `emacs-devtools-mcp-max-image-response-bytes` | `8388608` | Cap for responses that include an MCP `image` block. |
| `emacs-devtools-mcp-screenshot-max-pixels` | `2560×1600` | Refuse oversize frames. |
| `emacs-devtools-mcp-spawn-idle-timeout` | `1800` | Reaper kills idle handles after this many seconds. |
| `emacs-devtools-mcp-spawn-max-handles` | `4` | Cap on simultaneous subordinate daemons. |
| `emacs-devtools-mcp-spawn-default-display-mode` | `host-inherit` | Default `display_mode` when `spawn_emacs` omits the field. |
| `emacs-devtools-mcp-spawn-xvfb-run-program` | `xvfb-run` | Path to `xvfb-run`; used for `display_mode: "xvfb-run"` spawns. |
| `emacs-devtools-mcp-slow-tool-timeout` | `25` | `with-timeout` cap for `:slow` tools. |
| `emacs-devtools-mcp-bisect-max-probes` | `32` | Hard cap on `bisect_init` iterations. |
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

## License

GPL-3.0-or-later. Full text in `LICENSE`.
