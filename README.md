# emacs-devtools-mcp

An MCP server that gives coding agents the same kind of "open the inspector and
poke at it" loop for Emacs that
[`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp)
gives them for the browser.

**Status**: pre-alpha. Project scaffolding only.

## Quickstart

```sh
nix-shell --run 'make all'
```

`make all` runs byte-compile, ERT, checkdoc, and the texinfo build. CI does the
same on Emacs 29.1, 29.4, and 30.1.

## License

GPL-3.0-or-later. See `LICENSE`.
