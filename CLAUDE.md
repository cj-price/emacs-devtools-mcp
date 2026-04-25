# emacs-devtools-mcp

An MCP server that gives coding agents the same kind of "open the inspector and poke at it" loop for Emacs that `chrome-devtools-mcp` gives them for the browser. Used to debug `~/.config/emacs/init.el`, verify GUI rendering, and check that keybinds resolve to the intended commands.

**Quality bar**: the magit-grade conventions that pay rent on a single-developer Elisp package — `lexical-binding`, byte-compile-and-checkdoc-clean, transient dispatcher, real-process tests, texinfo manual once tools stabilize. **Not** the conventions that exist because magit serves hundreds of thousands of users (full GPLv3-per-file boilerplate, AUTHORS file, CODE_OF_CONDUCT pre-contributors, `NEWS` scaffolding for a v0.1.0).

## Architecture

```
agent ──stdio──▶ bin/emacs-devtools-mcp ──unix socket──▶ Host Emacs (loads this package)
   newline-delimited JSON-RPC                                     │
   per MCP stdio spec                                             └─ make-process argv list ──▶ subordinate Emacs
                                                                     emacs -Q --bg-daemon=NAME
                                                                     (optionally `xvfb-run --auto-servernum`)
```

- Pure Elisp server runs **inside** the user's Emacs (no external runtime).
- `bin/emacs-devtools-mcp` is a POSIX-sh `socat` relay between Claude Code's stdio MCP transport and a Unix socket at `${XDG_RUNTIME_DIR}/edmcp/${NAME}.sock` (mode `0600`). **Hard-fails if `XDG_RUNTIME_DIR` is unset; never falls back to `/tmp`.**
- Peer auth: `SO_PEERCRED` uid match + per-launch token in the first MCP frame. Token written to a 0600 sibling file at `${XDG_RUNTIME_DIR}/edmcp/${NAME}.token`; relay reads + injects.
- Every tool accepts an optional `target`: **always an object** — `{"host": true}` (default — the user's running Emacs) or `{"spawn": "<handle>"}` (subordinate Emacs from `emacs-devtools-mcp-spawn`). Never a string form.

## MCP framing — important

MCP stdio is **newline-delimited JSON** per spec, not Content-Length-framed. `jsonrpc.el`'s built-in `jsonrpc-process-connection` uses Content-Length (LSP-style) and is therefore **wrong** for MCP. We subclass the abstract `jsonrpc-connection` and supply newline framing while keeping its dispatch / continuation / events-buffer machinery. This is non-negotiable; do not try to "just use" `jsonrpc-process-connection`.

## Layout

```
lisp/
  emacs-devtools-mcp.el              ;;;###autoload entry, defgroup, transient dispatcher
  emacs-devtools-mcp-server.el       newline JSON-RPC over Unix socket; tool registry; cursor store
  emacs-devtools-mcp-rpc.el          JSON encode/decode; error envelope; redaction layer
  emacs-devtools-mcp-auth.el         SO_PEERCRED check; per-launch token; init-path allowlist
  emacs-devtools-mcp-spawn.el        spawn/attach/kill subordinate Emacs; idle reaper
  emacs-devtools-mcp-tools-gui.el    screenshots (pgtk/Wayland fallback), frame tree, faces, contrast
  emacs-devtools-mcp-tools-keys.el   where-is, lookup, simulate, translation trace
  emacs-devtools-mcp-tools-eval.el   eval, edebug, capture-backtrace, trace
  emacs-devtools-mcp-tools-init.el   bisect, init-lint, startup-profile
  emacs-devtools-mcp-tools-buffer.el buffer state, list-messages, list-warnings, ert
bin/emacs-devtools-mcp               POSIX sh + socat stdio↔socket relay
manual/emacs-devtools-mcp.texi       texinfo source — drafted alongside tools, not before
test/
  emacs-devtools-mcp-tests.el        behavior-organized; the bulk
  emacs-devtools-mcp-spawn-tests.el  :daemon / :fresh-daemon
  emacs-devtools-mcp-xvfb-tests.el   :gui
shell.nix                            emacs 30, xvfb-run, socat, gnumake, texinfo, grim, jq, rg, fd
Makefile                             all | lisp | test | test-fast | test-daemon | test-gui | test-mcp | lint | manual | clean | install
.github/workflows/ci.yml             matrix: emacs 29.1 / 29.4 / 30.1
CHANGELOG  CONTRIBUTING.md  LICENSE  README.md
```

Notably **absent** (deliberately): `manual/AUTHORS.md`, `CODE_OF_CONDUCT.md`, `NEWS`. License text lives once in `LICENSE`; per-file headers carry only the SPDX line.

## Naming

- Cross-file public symbols: `emacs-devtools-mcp-NAME`.
- Cross-file private symbols: `emacs-devtools-mcp--NAME` (full prefix preserved for grep-ability).
- **Subsystem-private helpers** (called only within their own `lisp/<file>.el`): allowed short alias `edmcp--NAME`. Document at the top of the file: `;; Internal short alias: edmcp-- (this file only).`

This is **looser** than magit's policy on purpose. Magit stacks at most two segments (`magit-section-`); ours stacks four. `emacs-devtools-mcp-tools-keys-key-translation-trace` (51 chars) is hostile; `edmcp--key-translation-trace` for an internal helper is not. The full prefix returns at every cross-file boundary, so grep across the package still finds everything.

JSON wire keys: **`snake_case`** (`server_name`, `with_properties`, `print_level`, `max_bytes`, `next_cursor`). Elisp internals stay kebab-case; the macro maps.

## File header

```elisp
;;; FILENAME --- ONE-LINE DESCRIPTION  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  C.J. Price
;; Author: C.J. Price <cjprice@fastmail.com>
;; Maintainer: C.J. Price <cjprice@fastmail.com>
;; Homepage: https://github.com/cjprice/emacs-devtools-mcp
;; Keywords: tools, convenience
;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (compat "30.1") (transient "0.6.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; <one paragraph: what this file does>

;;; Code:
(require 'cl-lib)
;; ...
(provide 'FEATURE)
;;; FILENAME ends here
```

The full GPLv3 boilerplate lives **once** in `LICENSE`. The SPDX line carries the same legal information per-file.

## Docstrings (checkdoc-clean, mandatory)

Every `defun`/`defmacro`/`defcustom`/`defvar`/`defface`. First line: complete sentence ≤80 chars. Args in CAPS, symbols in `` `backquotes' ``. `make lint` enforces.

## Customization

Every user-facing knob: `defcustom` with `:group`, `:type`, `:package-version '(emacs-devtools-mcp . "0.1.0")`. Group hierarchy in `emacs-devtools-mcp.el`: parent `emacs-devtools-mcp` → subgroups `-server`, `-spawn`, `-tools`, `-security`.

Key defcustoms: `emacs-devtools-mcp-max-response-bytes` (256 KiB), `screenshot-max-pixels` (1920×1080), `spawn-idle-timeout` (1800 s), `max-handles` (4), `slow-tool-timeout` (25 s), `init-allowlist` (~/.config/emacs, ~/.emacs.d, project root), `redact-extra-regexps`.

## Keymaps & menus

`defvar-keymap` (Emacs 29+). User entry point is `M-x emacs-devtools-mcp` — a `transient-define-prefix` with start/stop, list/kill handles, run tests, customize. Autoload cookies on the dispatcher and `emacs-devtools-mcp-{start,stop}` only; **not** every tool. Magit doesn't autoload its entire surface either.

## Tool registration

Define every tool with the package's macro:

```elisp
(emacs-devtools-mcp-deftool eval-elisp
  "Evaluate FORM in TARGET and return the printed value."
  :cost :slow
  :read-only nil
  :destructive t
  :idempotent nil
  :schema '(:type "object"
            :properties ((form         . (:type "string"))
                         (print_level  . (:type ("integer" "null")))
                         (print_length . (:type ("integer" "null")))
                         (target       . (:oneOf ((:type "object" :properties ((host  . (:const t))))
                                                  (:type "object" :properties ((spawn . (:type "string"))))))))
            :required ("form"))
  :handler #'emacs-devtools-mcp-tools-eval--elisp)
```

The macro:
- Registers `name → record` in the central tool table.
- Validates incoming params against `:schema` (JSON Schema subset).
- Emits MCP `readOnlyHint`/`destructiveHint`/`idempotentHint` in `tools/list`.
- Wraps the handler in `condition-case` → error envelope.
- For `:cost :slow`: wraps body in `(while-no-input (with-timeout (T (...)) ...))` so user keystrokes preempt.
- Generates an interactive `;;;###autoload` wrapper **only** when explicitly requested (`:interactive t`).

A handler **must** end with `(emacs-devtools-mcp-spawn-call target form)` — never branch on `target`. One code path for host vs spawn.

Handler return values must be `read`-equivalent to their `prin1` form (no buffer/marker/window objects). The spawn path round-trips through `prin1`/`read`; host must obey the same contract. Enforced at compile time where feasible.

## Concurrency

Single in-flight slot. Every tool tagged `:fast` (≤100 ms target) or `:slow`. `:slow` runs inside `while-no-input` + `with-timeout`. Second `:slow` request while one is in flight returns a `busy` error envelope. `:fast` requests can interleave during a `:slow` tool's I/O yields (`accept-process-output`).

`make-thread` is **not** used. Cooperative threads only yield at I/O points and don't make `(while t)` cancellable; they're a trap, not a solution.

## Pagination

**Cursor-based**, MCP-native pattern. Tools producing collections accept an optional `cursor` (opaque string) and return `next_cursor` when more results exist. Server holds cursor state in `emacs-devtools-mcp-server--cursors`, keyed by random 16-byte hex token; entries TTL'd at 5 min.

Text/binary tools (`buffer-substring`, `screenshot-frame`) take a `max_bytes` and return `truncated: true` + `next_offset` when capped. Global hard cap `emacs-devtools-mcp-max-response-bytes` (256 KiB default) returns a structured `payload_too_large` error.

## Error envelope

- **Protocol failures** (unknown tool, schema-invalid args): JSON-RPC `error` object with codes `-32601` (method not found), `-32602` (invalid params).
- **Tool execution failures** (eval signal, buffer not found, payload too large): success response with `isError: true` + MCP content blocks. **Never** invent custom codes in the JSON-RPC `-32600..-32603` range.
- `print-level` and `print-length` capped server-side so error data can't explode.
- Output redaction: regex strip lines matching `auth-source-`/`epg-`/`tramp-` (configurable) before sending any *Messages*/backtrace surface.

## Spawn / handle lifecycle

- `--bg-daemon=NAME` (not `--fg-daemon`; the latter blocks `make-process`).
- `make-process` with **explicit argv list** everywhere. Never `start-process-shell-command`. `server_name` validated against `[A-Za-z0-9_-]+`.
- `xvfb-run --auto-servernum --server-args="-nolisten tcp -nolisten unix"` + private `XAUTHORITY` per spawn.
- Init paths from agent are validated against `emacs-devtools-mcp-init-allowlist`: `expand-file-name` + `file-truename` then prefix-match.
- Idle timeout (default 30 min); `max-handles` cap (default 4); reaper runs on a timer and on `kill-emacs-hook`. `list-handles` includes `idle_seconds` + `expires_at`.
- `emacsclient --eval` results parsed under `(let ((read-eval nil)) (read ...))` to neutralize `#.` reader-macro injection.
- `bisect-init` holds a persistent pipe to the subordinate's server socket (not one `emacsclient` per probe) to amortize the ~20-50 ms fork-cost across dozens of calls.

## Screenshots — Wayland / pgtk fallback

Host Emacs build is detected at server-start. A probe creates a hidden test frame and tries `x-export-frames`; if it returns valid PNG bytes the host path uses it. Otherwise (or if probe fails on pgtk in some configurations) falls back to **`grim -g <frame-bounds>`** on Wayland or `xwd | convert` on X11, cropped to `frame-position` + `frame-pixel-{width,height}`. Backend cached in `emacs-devtools-mcp-tools-gui--host-backend`. Spawn target always uses `x-export-frames` (the Xvfb daemon is X11).

`screenshot-frame` returns an MCP `image` content block (`{type: "image", data, mimeType}`) — not a custom envelope.

## Build / test contract

```
make all            lisp + test + lint + manual
make lisp           byte-compile -Werror; zero warnings
make test           full ert run, all tags
make test-fast      :fast tag only — sub-second, pre-commit-friendly
make test-daemon    :daemon tag — shared subordinate Emacs fixture
make test-gui       :gui tag — under xvfb-run -a
make test-mcp       end-to-end MCP smoke from a real client
make lint           checkdoc-file every lisp/*.el; zero warnings
make manual         makeinfo manual/emacs-devtools-mcp.texi
```

CI matrix: Emacs 29.1, 29.4, 30.1. `make all` + `make test-mcp` on every push. Build fails on any byte-compile or checkdoc warning.

## Tests

- **One** behavior-organized file: `test/emacs-devtools-mcp-tests.el` with `;;; ___Section___` banners (Server, RPC, Spawn, GUI, Keys, Eval, Init, Buffer). Magit's pattern. Cross-cutting tests live alongside the behavior they cover.
- Slow / spawn-dependent: `emacs-devtools-mcp-spawn-tests.el`. GUI: `emacs-devtools-mcp-xvfb-tests.el`.
- ERT tag selectors mandatory: `:fast`, `:daemon`, `:fresh-daemon`, `:gui`. Pure-logic tests must be `:fast`.
- Property tests for pure functions (color-contrast math, RPC encode/decode round-trip, schema validator, redaction) using `propcheck` (test-only `Package-Requires`).
- **"No mocks" — narrow form**: don't mock the system under test (Emacs, emacsclient, sockets, file system). Auxiliary stubbing with `cl-letf` (e.g., faking `read-passwd`, `current-time`, `random`) is fine — magit does this. Real git, real Emacs.
- **Daemon fixture**: shared subordinate Emacs cached in a `defvar` across `:daemon` tests; per-test isolation via `emacsclient --eval`-driven reset; `:fresh-daemon` tests opt out for clean `-Q` spawns.
- **Required test classes**:
  - RPC encode/decode round-trip (property)
  - `condition-case` at dispatch boundary for every signal type (`error`/`user-error`/`quit`/`wrong-type-argument`/`throw`)
  - Schema validator negative cases (wrong type, missing required, extra unknown, `oneOf` discrimination)
  - Socket lifecycle: bind on stale socket file, double-start, `kill-emacs-hook` cleanup, mode-0600 enforcement
  - Spawn lifecycle: kill-during-call, bad init path, attach-to-nonexistent, list-handles after external kill
  - `make-frame-on-display` failure modes (DISPLAY unset, Xvfb dead) → structured error
  - Color-contrast: symmetry, identity, bounds, AA/AAA threshold boundaries
  - `simulate-keys` undo isolation across tests
  - Tool registry: duplicate name rejection, schema/handler arity match, `tools/list` matches registry
  - Bisect convergence on a known-bad single-line init.el; bisect against an init that hangs (timeout, not deadlock)
  - Host vs spawn parity: `eval-elisp`, `simulate-keys`, `face-at`, `buffer-substring` produce equal results across both targets

## Reuse, don't reinvent

- `jsonrpc.el` abstract `jsonrpc-connection` class — keep dispatch/continuation; replace framing only.
- `x-export-frames` (built in) — primary screenshot path.
- `where-is-internal`, `lookup-key`, `key-binding`, `execute-kbd-macro` — keybinding tools.
- `profiler-start` / `profiler-report-cpu` — startup profile (always under `unwind-protect`).
- `transient` — menus.
- `compat 30.1` — cross-version shims; floor Emacs 29.1.
- `propcheck` — test-only property generation.
- `xvfb-run`, `socat`, `grim` — nixpkgs.

## Security

`emacs-devtools-mcp-tools-eval` is intentionally unsandboxed — this is a developer tool for the user's own Emacs session.

What's defended:
- Socket: 0600 mode, in `${XDG_RUNTIME_DIR}/edmcp/`, hard-fail without `XDG_RUNTIME_DIR`.
- Peer: `SO_PEERCRED` uid check + per-launch token in first frame.
- Stale socket: verified `S_ISSOCK` + same-uid + non-symlink before bind.
- Subprocess: `make-process` argv lists everywhere; `[A-Za-z0-9_-]+` validation on `server_name`.
- Reader injection: `(let ((read-eval nil)) (read ...))` around every parse of subordinate output.
- Init paths: allowlist-checked.
- Output: redaction layer strips `auth-source-`/`epg-`/`tramp-` lines from *Messages*/backtraces.
- Resource caps: `with-timeout` on every `:slow` handler; `max-response-bytes`; `screenshot-max-pixels`; `unwind-protect` around `profiler-start`.

What's not defended (deliberate):
- `eval-elisp` itself (developer tool, by design).
- Multi-tenant access (single-user only).
- Networked transport (local stdio only).

## Future / out of scope

- Extracting `emacs-devtools-mcp-server.el` + `-rpc.el` into a standalone `mcp-server.el` package once the API stabilizes (v0.2 candidate; tracked, not built).
- Windows / non-Unix sockets.
- A statically-linked Go/Rust replacement for the `socat` relay.
- Sandboxing `eval-elisp`.
- Networked transport (HTTP/SSE).
