# emacs-devtools-mcp

An MCP server that gives coding agents the same kind of "open the inspector and poke at it" loop for Emacs that `chrome-devtools-mcp` gives them for the browser. Used to debug `~/.config/emacs/init.el`, verify GUI rendering, and check that keybinds resolve to the intended commands.

**Quality bar**: the magit-grade conventions that pay rent on a single-developer Elisp package — `lexical-binding`, byte-compile-and-checkdoc-clean, real-process tests. **Not** the conventions that exist because magit serves hundreds of thousands of users (full GPLv3-per-file boilerplate, AUTHORS file, CODE_OF_CONDUCT pre-contributors, `NEWS` scaffolding for a v0.1.0, texinfo manual). The README is the load-bearing doc; agents are the user-facing surface.

## Architecture

Agents speak newline-delimited JSON-RPC over stdio to `bin/emacs-devtools-mcp` (a POSIX-sh `socat` relay), which forwards to a Unix socket served by the host Emacs. The host can spawn subordinate `emacs -Q --bg-daemon=NAME` instances via `make-process`.

- Pure Elisp server runs **inside** the user's Emacs (no external runtime).
- Relay socket lives at `${XDG_RUNTIME_DIR}/edmcp/${NAME}.sock` (mode `0600`). **Hard-fails if `XDG_RUNTIME_DIR` is unset; never falls back to `/tmp`.**
- Peer auth: per-launch token in the first MCP frame, written to a 0600 sibling token file; relay reads + injects. In the absence of `SO_PEERCRED` from Lisp, the access boundary is the 0700 dir + 0600 socket/token files (filesystem-permission same-uid restriction); `emacs-devtools-mcp-auth--check-peer` is a stub awaiting a peer-cred API.
- Every tool accepts an optional `target`: **always an object** — `{"host": true}` (default — the user's running Emacs) or `{"spawn": "<handle>"}` (subordinate Emacs from `emacs-devtools-mcp-spawn`). Never a string form.

## MCP framing — important

MCP stdio is **newline-delimited JSON** per spec, not Content-Length-framed. `jsonrpc.el`'s built-in `jsonrpc-process-connection` uses Content-Length (LSP-style) and is therefore **wrong** for MCP. We subclass the abstract `jsonrpc-connection` and supply newline framing while keeping its dispatch / continuation / events-buffer machinery. This is non-negotiable; do not try to "just use" `jsonrpc-process-connection`.

## Layout

`lisp/` holds the package (server, rpc, auth, spawn, plus `tools-<domain>.el` per tool group); `bin/emacs-devtools-mcp` is the relay; `test/` holds the single ERT file plus `e2e-smoke.sh`.

Notably **absent** (deliberately): `manual/`, `AUTHORS.md`, `CODE_OF_CONDUCT.md`, `NEWS`. License text lives once in `LICENSE`; per-file headers carry only the SPDX line. The README is the single user-facing doc.

## Naming

- Cross-file public symbols: `emacs-devtools-mcp-NAME`.
- Cross-file private symbols: `emacs-devtools-mcp--NAME` (full prefix preserved for grep-ability).
- **Subsystem-private helpers** (called only within their own `lisp/<file>.el`): allowed short alias `edmcp--NAME`. Document at the top of the file: `;; Internal short alias: edmcp-- (this file only).`

This is **looser** than magit's policy on purpose. Magit stacks at most two segments (`magit-section-`); ours stacks four. `emacs-devtools-mcp-tools-keys-key-translation-trace` (51 chars) is hostile; `edmcp--key-translation-trace` for an internal helper is not. The full prefix returns at every cross-file boundary, so grep across the package still finds everything.

JSON wire keys: **`snake_case`** (`server_name`, `with_properties`, `print_level`, `max_bytes`, `next_cursor`). Elisp internals stay kebab-case; the macro maps.

## File header

Mirror an existing file's header. Full GPLv3 boilerplate lives once in `LICENSE`; per-file headers carry only the SPDX line.

## Docstrings (checkdoc-clean, mandatory)

Every `defun`/`defmacro`/`defcustom`/`defvar`/`defface`. First line: complete sentence ≤80 chars. Args in CAPS, symbols in `` `backquotes' ``. `make lint` enforces.

## Customization

Every user-facing knob: `defcustom` with `:group`, `:type`, `:package-version '(emacs-devtools-mcp . "0.1.0")`. Group hierarchy in `emacs-devtools-mcp.el`: parent `emacs-devtools-mcp` → subgroups `-server`, `-spawn`, `-tools`, `-security`. The README's table lists current values; `M-x customize-group RET emacs-devtools-mcp RET` is authoritative.

## User entry points

The two `;;;###autoload` symbols are `emacs-devtools-mcp-server-start` and `emacs-devtools-mcp-server-stop`. There is no keymap and no menu — agents drive the package, not interactive users.

## Tool registration

Define every tool with the package's macro:

```elisp
(emacs-devtools-mcp-deftool eval-elisp
  "Evaluate FORM in TARGET and return the printed value."
  :cost :slow
  :read-only nil
  :destructive t
  :idempotent nil
  :schema `(:type "object"
            :properties ((form         . (:type "string"))
                         (print_level  . (:type ["integer" "null"]))
                         (print_length . (:type ["integer" "null"]))
                         (target       . ,emacs-devtools-mcp-target-schema))
            :required ["form"])
  :handler #'emacs-devtools-mcp-tools-eval--elisp)
```

**Schema is a backquoted form, not a quoted datum.** The macro expands `:schema ,schema` (unquoted), so the schema value is *evaluated* at definition time. Use a backquote (`` ` ``) to splice constants like `,emacs-devtools-mcp-target-schema` (the canonical host/spawn `:oneOf`). A bare `'(:type "object")` is acceptable for trivial schemas, but production tools should backquote and reuse the `target-schema` constant for the `:target` field. **Do not** write the schema as raw `(:type "object" …)` — that becomes a function call at expansion.

**Schema array convention**: every JSON array — values of `:required`, `:enum`, `:oneOf`, multi-valued `:type` — must be written as an Elisp **vector** (`["a" "b"]`), not a list. `json-serialize` only treats vectors as JSON arrays; lists are interpreted as alists (objects) and fail to encode for arrays-of-strings. The validator coerces both forms via `edmcp--as-list`, so reading is uniform.

The macro:
- Registers `name → record` in the central tool table.
- Validates incoming params against `:schema` (JSON Schema subset).
- Emits MCP `readOnlyHint`/`destructiveHint`/`idempotentHint` in `tools/list`.
- Wraps the handler in `condition-case` → error envelope.
- For `:cost :slow`: wraps body in `(while-no-input (with-timeout (T (...)) ...))` so user keystrokes preempt.

A handler **must** end with `(emacs-devtools-mcp-spawn-call target form)` — never branch on `target`. One code path for host vs spawn.

Handler return values must be `read`-equivalent to their `prin1` form (no buffer/marker/window objects). The spawn path round-trips through `prin1`/`read`; host must obey the same contract. Enforced at compile time where feasible.

## Concurrency

Cooperative single-threaded dispatch. Every tool tagged `:fast` (≤100 ms target) or `:slow`. `:slow` runs inside `while-no-input` + `with-timeout` so user keystrokes preempt them, and the timeout (default `emacs-devtools-mcp-slow-tool-timeout`) bounds the call. Concurrency follows from the host being single-threaded: jsonrpc.el's filter parses every newline-framed frame, dispatch runs one tool body to completion before draining the next, and `:fast` requests can interleave only at `accept-process-output` yield points inside a `:slow` body. There is no explicit "busy" envelope — a second request issued while a `:slow` tool is mid-flight queues until the slow tool returns or its timeout fires.

`make-thread` is **not** used. Cooperative threads only yield at I/O points and don't make `(while t)` cancellable; they're a trap, not a solution.

## Pagination

**Cursor-based**, MCP-native pattern. Tools producing collections accept an optional `cursor` (opaque string) and return `next_cursor` when more results exist. Server holds cursor state in a hash table keyed by random 16-byte hex token; entries TTL'd at 5 min.

Text/binary tools (`buffer-substring`, `screenshot-frame`) take a `max_bytes` and return `truncated: true` + `next_offset` when capped. Global hard cap `emacs-devtools-mcp-max-response-bytes` (256 KiB default) returns a structured `payload_too_large` error.

## Error envelope

- **Protocol failures**: JSON-RPC `error` object with codes `-32601` (unknown tool or method), `-32602` (schema-invalid args; also a malformed `form` string in `eval_elisp`/`capture_backtrace`, whose parse runs host-side *before* dispatch), `-32000` (slow-tool timeout/interruption).
- **Tool execution failures** (handler signal, buffer not found, payload too large; also parse failures of strings consumed *inside* a routed tool body, like `ert_run`'s selector and `bisect_init`'s predicate): success response with `isError: true` + MCP content blocks. **Never** invent custom codes in the JSON-RPC `-32600..-32603` range.
- Errors signaled by the *evaluated form* in `eval_elisp`/`capture_backtrace` are not failures of the tool: they come back as data (`:error` key in the JSON body, `isError: false`). The tool ran; the form's failure is its result.
- `print-level` and `print-length` capped server-side so error data can't explode.
- Output redaction: regex strip lines matching `auth-source-`/`epg-`/`tramp-` (configurable) before sending any *Messages*/backtrace surface.

## Spawn / handle lifecycle

- `--bg-daemon=NAME` is the default. `display_mode: "xvfb-run"` uses `--fg-daemon` because `xvfb-run` tears down its private X display when its child exits, and `--bg-daemon`'s self-fork would trigger that immediately. Sync modes (`host-inherit`, `none`) fork-exit so they use `call-process`; the `xvfb-run` mode keeps the launcher resident under `make-process`.
- `make-process` / `call-process` with **explicit argv list** everywhere. Never `start-process-shell-command`. `server_name` validated against `[A-Za-z0-9_-]+`.
- `spawn_emacs`'s `display_mode` is an enum (default `host-inherit`): `host-inherit` inherits the host's `DISPLAY` (and `WAYLAND_DISPLAY`), except on a Wayland host it drops the X11 `DISPLAY` (keeping `WAYLAND_DISPLAY`) so a `--with-pgtk` build uses Wayland rather than opening a crash-prone XWayland frame that pops the "pure-GTK under X" warning (`x-export-frames` screenshots work on the Wayland frame); `none` scrubs `DISPLAY`/`WAYLAND_DISPLAY` from the child's env via bare-name sentinel entries — necessary because Emacs's `call-process` otherwise re-injects `DISPLAY` from the parent's X session — so the daemon is guaranteed-headless even when the host has a display; `xvfb-run` wraps the launch so the spawn gets its own X display and `screenshot_frame` works against it. The valid symbols live in the `emacs-devtools-mcp-spawn-display-modes` defconst, which the JSON schema's `:enum` and `:default` are derived from at deftool time so the wire contract cannot drift from the validator. Handle records carry `:display-mode` (and the wrapper `:proc` for `xvfb-run`); kill SIGTERMs the wrapper when present. An exit sentinel on the wrapper evicts the handle if the wrapper crashes out-of-band (Xvfb OOM, display-number exhaustion), so a phantom record never sits in the registry for the 30-minute reaper to find.
- Init paths from agent are validated against `emacs-devtools-mcp-init-allowlist`: `expand-file-name` + `file-truename` then prefix-match.
- Idle timeout (default 30 min); `max-handles` cap (default 4); reaper runs on a timer and on `kill-emacs-hook`. `list-handles` includes `idle_seconds` + `expires_at`.
- `init-lint`, `startup-profile`, and `bisect-init` each run their probe in a fresh `emacs -Q --batch` subprocess (no daemon attach, no persistent client). `bisect-init` is capped at `emacs-devtools-mcp-bisect-max-probes` (default 32) iterations and each probe at `emacs-devtools-mcp-init-batch-timeout` seconds (default 30).

## Screenshots

Host Emacs build is probed lazily on the first `screenshot-frame` call. The probe looks for *any* graphical frame (selected first, then `frame-list` — the `emacs --daemon` + GUI-client topology can dispatch with the dumb terminal frame selected) and runs a trial `x-export-frames nil 'png` on it. Valid PNG bytes cache `'x-export-frames` in `emacs-devtools-mcp-tools-gui--host-backend` for the lifetime of the host; a failed probe returns a structured error but is **not** cached, so a GUI frame opened later is picked up on the next call. Frames whose pixel area exceeds `emacs-devtools-mcp-screenshot-max-pixels` are refused before encoding.

`screenshot-frame` returns the standard MCP `image` content block (`{type: "image", data, mimeType}`) — no custom envelope, no width/height sidecar.

## Build / test contract

See the Makefile header for target definitions. CI: Emacs 30.1. `make all` + `make test-mcp` on every push. Build fails on any byte-compile or checkdoc warning.

## Tests

- **One** behavior-organized file: `test/emacs-devtools-mcp-tests.el` with `;;; ___Section___` banners (Server, RPC, Spawn, GUI, Keys, Eval, Init, Buffer). End-to-end MCP-protocol coverage lives in `test/e2e-smoke.sh`, run via `make test-mcp`.
- ERT tag selectors mandatory: `:fast`, `:daemon`, `:fresh-daemon`, `:gui`. `make test-{fast,daemon,gui}` filter on these. Pure-logic tests must be `:fast`.
- Property-style testing: the RPC encode/decode round-trip has a seeded `cl-random` generative test (random frame chunking); color-contrast math, the schema validator, and redaction are covered example-based. `propcheck` is not in the dep set yet; the seeded test is framed as "stand-in for a propcheck generative test" so it swaps cleanly when propcheck lands, and the example-based areas are the natural candidates to generalize then.
- **"No mocks" — narrow form**: don't mock the system under test (Emacs, emacsclient, sockets, file system). Auxiliary stubbing with `cl-letf` (e.g., faking `read-passwd`, `current-time`, `random`) is fine — magit does this. Real git, real Emacs.
- **Daemon fixture**: shared subordinate Emacs cached in a `defvar` across `:daemon` tests; per-test isolation via `emacsclient --eval`-driven reset; `:fresh-daemon` tests opt out for clean `-Q` spawns.

## Reuse, don't reinvent

Prefer built-in Emacs APIs (`jsonrpc.el`'s abstract `jsonrpc-connection` class, `x-export-frames`, `where-is-internal`/`lookup-key`/`key-binding`/`execute-kbd-macro`, `profiler-start`/`profiler-report-cpu` under `unwind-protect`) and nixpkgs CLIs (`xvfb-run`, `socat`, `jq`) over custom replacements.

## Security

`emacs-devtools-mcp-tools-eval` is intentionally unsandboxed — this is a developer tool for the user's own Emacs session.

What's defended:
- Socket: 0600 mode, in `${XDG_RUNTIME_DIR}/edmcp/`, hard-fail without `XDG_RUNTIME_DIR`.
- Peer: per-launch token in first frame; access boundary is the 0700 dir + 0600 socket/token files (no `SO_PEERCRED` from Lisp).
- Stale socket: verified `S_ISSOCK` + same-uid + non-symlink before bind.
- Subprocess: `make-process` argv lists everywhere; `[A-Za-z0-9_-]+` validation on `server_name`.
- Reader injection: every `read` of untrusted text (subordinate `emacsclient --eval` replies, `bisect_init` predicate and init-file scan, `startup_profile` probe output, `ert_run` selector) is pre-scanned against the shared `emacs-devtools-mcp-unsafe-reader-re` and rejected on `#.` (read-time eval — Emacs has no documented switch to inhibit it), `#@` (reader skip), or `#N=`/`#N#` labels (shared-structure ~2^N print amplifier). One constant, so the rejected set cannot drift between read sites. The agent-supplied `form` in the eval tools is deliberately *not* scanned (unsandboxed by design), but note it is `read` host-side even when targeting a spawn — spawn targeting is routing, not isolation.
- Init paths: allowlist-checked.
- Output: redaction layer strips `auth-source-`/`epg-`/`tramp-` lines from *Messages*/backtraces.
- Resource caps: `with-timeout` on every `:slow` handler; `max-response-bytes`; `screenshot-max-pixels`; `unwind-protect` around `profiler-start`.

What's not defended (deliberate):
- `eval-elisp` itself (developer tool, by design).
- Multi-tenant access (single-user only).
- Networked transport (local stdio only).
