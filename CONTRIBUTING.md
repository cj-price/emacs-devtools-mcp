# Contributing

Issues and pull requests are welcome. A few conventions to know up front:

## Build / test

The repo expects [Nix](https://nixos.org/). Everything runs in `nix-shell`:

```sh
nix-shell --run 'make all'         # lisp + test + lint + manual
nix-shell --run 'make test-fast'   # sub-second pure tests
nix-shell --run 'make lint'        # checkdoc, zero warnings
```

CI runs `make all` against Emacs 29.1, 29.4, 30.1.

## Code style

- `lexical-binding: t` on every `.el` file.
- Docstrings on every `defun`/`defmacro`/`defcustom`/`defvar`/`defface`.
- First docstring sentence ≤ 80 chars; args in CAPS; symbols in `` `backquotes' ``.
- Byte-compile-and-checkdoc clean. The build fails on any warning.

## Naming

- Cross-file public symbols: `emacs-devtools-mcp-NAME`.
- Cross-file private symbols: `emacs-devtools-mcp--NAME`.
- File-private helpers may use the short alias `edmcp--NAME`. Document at the top
  of the file: `;; Internal short alias: edmcp-- (this file only).`
- JSON wire keys are `snake_case`. Elisp internals stay kebab-case.

## Tests

- Behavior-organized in `test/emacs-devtools-mcp-tests.el` with `;;; ___Section___`
  banners. Spawn-dependent tests in `-spawn-tests.el`; GUI in `-xvfb-tests.el`.
- Tag every test with one of `:fast`, `:daemon`, `:fresh-daemon`, `:gui`.
- Property tests (`propcheck`) for pure functions.
- "Real Emacs, real sockets" — don't mock the system under test.

## Issues

Open one at https://github.com/cjprice/emacs-devtools-mcp/issues with:

- Emacs version (`M-x emacs-version`), windowing system (X11 / Wayland / pgtk).
- A reproducer — minimal init.el or shell command sequence.
- The error you see and the error you expected.

For security issues, email cjprice@fastmail.com instead of opening a public
issue.

## Branches and pull requests

- The default branch is `main`. Day-to-day work happens on `trunk`.
- Branch off `main` for features (`feat/<short-slug>`) or `fix/<short-slug>`.
- One logical change per PR.
- Update `manual/emacs-devtools-mcp.texi` if user-visible behavior changes.
- Add an entry to `CHANGELOG` under the next version's section.
