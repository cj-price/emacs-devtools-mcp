# 006 — Tool registry and `deftool` macro

**As** the package developer
**I want** an `emacs-devtools-mcp-deftool` macro that registers a tool with name, schema, annotations, cost, and handler
**So that** every tool file looks the same and schema validation / annotations / `:slow` wrapping happen in one place.

## INVEST
- **I**: doesn't depend on socket or auth; only the RPC connection class for error envelope shape.
- **N**: keyword names open; one rule fixed: handler must end with `(emacs-devtools-mcp-spawn-call ...)` (enforced in 021).
- **V**: every tool from 008 onwards uses this; bad design here ripples everywhere.
- **E**: M (~1.5 days).
- **S**: macro + JSON Schema validator subset + tests.
- **T**: macro expansion and validator are pure functions, easy to test.

## Dependencies
- 003-mcp-newline-framing-depends-on-001

## Acceptance criteria
- [ ] Macro signature: `(emacs-devtools-mcp-deftool NAME DOCSTRING &key cost read-only destructive idempotent schema handler interactive)`.
- [ ] Registers `name → record` in `emacs-devtools-mcp--tool-registry` (a hash, keyed by snake_case JSON name).
- [ ] Schema validator subset supports: `:type` (string|number|integer|boolean|object|array|null, including type unions), `:properties`, `:required`, `:enum`, `:const`, `:oneOf`, nested schemas. No `$ref`, no `format` validation.
- [ ] Validation produces JSON-RPC `-32602 invalid_params` with a path to the failing field.
- [ ] `:cost :slow` wraps the handler body in `(while-no-input (with-timeout (T (jsonrpc-error :code -32000 :message "timeout") (...))))` — T from `emacs-devtools-mcp-slow-tool-timeout` defcustom (default 25 s).
- [ ] `:read-only` / `:destructive` / `:idempotent` recorded; surfaced as MCP annotations in 008's `tools/list`.
- [ ] Duplicate registration signals an error at macro expansion time (or load time).
- [ ] `:interactive t` generates a `;;;###autoload` interactive wrapper; default off.
- [ ] Every defined tool's macro expansion compiles `-Werror` clean and passes checkdoc.

## Files touched
- `lisp/emacs-devtools-mcp-server.el` (or split into `-registry.el` if it grows)
- `test/emacs-devtools-mcp-tests.el` (Registry section)

## Test plan
- Register a `ping` tool; `gethash` returns the expected record.
- Schema validator: 20+ negative cases (wrong type, missing required, extra unknown, `oneOf` discrimination, nested object).
- Schema validator: positive cases for all supported keywords.
- Duplicate name → signal.
- `:slow` tool wrapped in `while-no-input` (assert by mocking `with-timeout`).
- Annotations appear in a synthesized `tools/list` reply.
