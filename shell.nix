{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    emacs31
    xvfb-run
    xorg-server
    socat
    gnumake
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
    echo ""
    echo "Targets:  make all | lisp | test | lint | clean"
  '';
}
