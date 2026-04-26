{ pkgs ? import <nixpkgs> {} }:

let
  # Emacs 30.x with the package's runtime deps pre-installed, so `make lisp`
  # and `make test` find `transient` without M-x package-install.
  emacsWithDeps = pkgs.emacs30.pkgs.withPackages (epkgs: with epkgs; [
    transient
  ]);
in

pkgs.mkShell {
  buildInputs = with pkgs; [
    # Emacs itself + the package's Package-Requires deps.
    # Must be a graphical build — `x-export-frames` (screenshots) needs a
    # frame, which the -nox build cannot create even under Xvfb.
    emacsWithDeps

    # Headless display for GUI tests in CI and for spawn-target tools that
    # render frames without taking over the user's screen.
    xvfb-run
    xorg.xorgserver

    # stdio <-> Unix-socket relay used by bin/emacs-devtools-mcp.
    socat

    # Build / docs.
    gnumake
    texinfo

    # Project tooling matching ~/.claude/CLAUDE.md preferences.
    jq
    ripgrep
    fd
    gawk
    gnused
    curl
    git
  ];

  shellHook = ''
    echo "emacs-devtools-mcp dev shell"
    echo "  emacs:     $(emacs --version | head -1)"
    echo "  emacsclient: $(emacsclient --version | head -1)"
    echo "  xvfb-run:  $(xvfb-run --help 2>&1 | head -1)"
    echo "  socat:     $(socat -V 2>&1 | head -1)"
    echo "  make:      $(make --version | head -1)"
    echo "  makeinfo:  $(makeinfo --version | head -1)"
    echo ""
    echo "Targets:  make all | lisp | test | lint | manual | clean"
  '';
}
