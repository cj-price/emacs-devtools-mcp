# Makefile for emacs-devtools-mcp
#
# Targets:
#   all          lisp + test + lint (the CI gate)
#   lisp         byte-compile lisp/*.el with -Werror
#   test         full ERT run, every tag
#   test-fast    only :fast-tagged tests
#   test-daemon  only :daemon-tagged tests
#   test-gui     only :gui-tagged tests, under xvfb-run
#   test-mcp     end-to-end smoke against bin/emacs-devtools-mcp
#   lint         checkdoc on every lisp/*.el; zero warnings
#   clean        remove build artifacts
#   install      symlink bin/emacs-devtools-mcp into ~/.local/bin
#
# Run inside `nix-shell` so the right Emacs and tooling are on PATH.

EMACS        ?= emacs
EMACSFLAGS   = -Q --batch
LISP_DIR     = lisp
TEST_DIR     = test

LISP_SRC     = $(wildcard $(LISP_DIR)/*.el)
LISP_ELC     = $(LISP_SRC:.el=.elc)
TEST_SRC     = $(wildcard $(TEST_DIR)/*.el)

# CI / users can append extra -L paths via EXTRA_LOAD without losing the
# defaults. Inside `nix-shell`, runtime deps are on the load-path already.
EXTRA_LOAD   ?=
LOAD_FLAGS   = -L $(LISP_DIR) -L $(TEST_DIR) $(EXTRA_LOAD)

.PHONY: all lisp test test-fast test-daemon test-gui test-mcp lint clean install

all: lisp test lint

lisp: $(LISP_ELC)

$(LISP_DIR)/%.elc: $(LISP_DIR)/%.el
	$(EMACS) $(EMACSFLAGS) $(LOAD_FLAGS) \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  --funcall batch-byte-compile $<

test: lisp
	$(EMACS) $(EMACSFLAGS) $(LOAD_FLAGS) \
	  $(addprefix -l ,$(TEST_SRC)) \
	  --funcall ert-run-tests-batch-and-exit

test-fast: lisp
	$(EMACS) $(EMACSFLAGS) $(LOAD_FLAGS) \
	  $(addprefix -l ,$(TEST_SRC)) \
	  --eval '(ert-run-tests-batch-and-exit (quote (tag :fast)))'

test-daemon: lisp
	$(EMACS) $(EMACSFLAGS) $(LOAD_FLAGS) \
	  $(addprefix -l ,$(TEST_SRC)) \
	  --eval '(ert-run-tests-batch-and-exit (quote (tag :daemon)))'

test-gui: lisp
	xvfb-run -a $(EMACS) $(EMACSFLAGS) $(LOAD_FLAGS) \
	  $(addprefix -l ,$(TEST_SRC)) \
	  --eval '(ert-run-tests-batch-and-exit (quote (tag :gui)))'

test-mcp:
	$(TEST_DIR)/e2e-smoke.sh

lint:
	@for f in $(LISP_SRC); do \
	  echo "checkdoc $$f"; \
	  $(EMACS) $(EMACSFLAGS) $(LOAD_FLAGS) \
	    -l checkdoc \
	    --eval "(progn \
                      (setq checkdoc-arguments-in-order-flag t) \
                      (setq checkdoc-package-keywords-flag t) \
                      (let ((warnings 0)) \
                        (advice-add 'display-warning :before \
                                    (lambda (&rest _) (setq warnings (1+ warnings)))) \
                        (checkdoc-file \"$$f\") \
                        (when (> warnings 0) \
                          (when (get-buffer \"*Warnings*\") \
                            (princ (with-current-buffer \"*Warnings*\" (buffer-string)))) \
                          (kill-emacs 1))))" || exit 1; \
	done

clean:
	rm -f $(LISP_ELC)
	find . -name '*~' -delete

install:
	@if [ -z "$$HOME" ]; then echo "HOME unset" >&2; exit 1; fi
	@if [ ! -x $(CURDIR)/bin/emacs-devtools-mcp ]; then \
	  echo "$(CURDIR)/bin/emacs-devtools-mcp does not exist or is not executable; build it first (story 007)" >&2; \
	  exit 1; \
	fi
	@mkdir -p $$HOME/.local/bin
	@target=$$HOME/.local/bin/emacs-devtools-mcp; \
	  if [ -e $$target ] && [ ! -L $$target ]; then \
	    echo "$$target exists and is not a symlink; refusing to overwrite" >&2; \
	    exit 1; \
	  fi; \
	  if [ -L $$target ]; then \
	    current=$$(readlink $$target); \
	    if [ "$$current" != "$(CURDIR)/bin/emacs-devtools-mcp" ] && [ -z "$$FORCE" ]; then \
	      echo "$$target -> $$current; refusing to repoint without FORCE=1" >&2; \
	      exit 1; \
	    fi; \
	  fi; \
	  ln -sfn $(CURDIR)/bin/emacs-devtools-mcp $$target; \
	  echo "Installed: $$target -> $(CURDIR)/bin/emacs-devtools-mcp"
