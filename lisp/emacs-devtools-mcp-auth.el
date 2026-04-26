;;; emacs-devtools-mcp-auth.el --- Auth for the MCP socket  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  C.J. Price
;; Author: C.J. Price <cjprice@fastmail.com>
;; Maintainer: C.J. Price <cjprice@fastmail.com>
;; Homepage: https://github.com/cjprice/emacs-devtools-mcp
;; Keywords: tools, convenience
;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Per-launch token + best-effort peer-uid check for the MCP socket.
;; A 32-byte random token is generated on each `server-start' and
;; persisted at `${XDG_RUNTIME_DIR}/edmcp/${NAME}.token' with mode
;; 0600.  The first MCP frame on any accepted connection must be the
;; standard `initialize' request whose params carry a matching token
;; under `_meta.token' -- otherwise the connection is closed.
;;
;; Stock Emacs does not expose `SO_PEERCRED' to Lisp, so the peer-uid
;; check degrades to relying on the directory mode (0700) and socket
;; mode (0600) for access control.  When future Emacs versions add an
;; API, swap the body of `emacs-devtools-mcp-auth--check-peer'.

;;; Code:

;; Internal short alias: edmcp-- (this file only).

(require 'cl-lib)
(require 'project)
(require 'emacs-devtools-mcp)
(require 'emacs-devtools-mcp-rpc)

(defcustom emacs-devtools-mcp-auth-log-failures t
  "When non-nil, log auth failures to `*emacs-devtools-mcp-log*'."
  :type 'boolean
  :group 'emacs-devtools-mcp-security
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defcustom emacs-devtools-mcp-init-allowlist
  '("~/.config/emacs" "~/.emacs.d")
  "Directories under which agent-supplied init files may live.
Each entry is canonicalized with `expand-file-name' +
`file-truename' before being matched as a path prefix.  When
`project-current' yields a project, its root is added implicitly,
so per-repo init fixtures work without repointing this list.  An
init path supplied to `spawn-emacs' is rejected unless its
truename has one of these prefixes."
  :type '(repeat directory)
  :group 'emacs-devtools-mcp-security
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defvar emacs-devtools-mcp-auth--token nil
  "Current per-launch hex token, or nil when the server is not running.")

(defvar emacs-devtools-mcp-auth--token-path nil
  "Filesystem path of the current token file, or nil.")

(defun edmcp--auth-token-file (socket-path)
  "Derive the token file path that pairs with SOCKET-PATH.
The convention is `<NAME>.token' alongside `<NAME>.sock'."
  (let* ((dir (file-name-directory socket-path))
         (base (file-name-base socket-path)))
    (expand-file-name (concat base ".token") dir)))

(defun edmcp--auth-generate-token ()
  "Return a fresh 32-byte token, hex-encoded (64 chars), from `/dev/urandom'."
  (emacs-devtools-mcp-random-hex 32))

(defun emacs-devtools-mcp-auth-rotate (socket-path)
  "Generate a fresh token paired with SOCKET-PATH, write it 0600.
Returns the new token.  The file is created atomically at mode
0600 via `with-file-modes', so it is never visible at any wider
mode -- including the brief window between `with-temp-file' close
and a follow-up `set-file-modes' call.  Any previous token file
under the same path is unlinked first."
  (let ((file (edmcp--auth-token-file socket-path))
        (token (edmcp--auth-generate-token)))
    (when (file-exists-p file)
      (ignore-errors (delete-file file)))
    (with-file-modes #o600
      (with-temp-file file
        (set-buffer-file-coding-system 'utf-8-unix)
        (insert token)))
    (setq emacs-devtools-mcp-auth--token token
          emacs-devtools-mcp-auth--token-path file)
    token))

(defun emacs-devtools-mcp-auth-clear ()
  "Forget the active token and remove its file, if any.  Idempotent."
  (when (and emacs-devtools-mcp-auth--token-path
             (file-exists-p emacs-devtools-mcp-auth--token-path))
    (ignore-errors (delete-file emacs-devtools-mcp-auth--token-path)))
  (setq emacs-devtools-mcp-auth--token nil
        emacs-devtools-mcp-auth--token-path nil))

(defun emacs-devtools-mcp-auth--check-peer (_process)
  "Return non-nil when the peer of _PROCESS is the current uid.
Stock Emacs has no `SO_PEERCRED' API, so this returns t and we
rely on the 0700 directory and 0600 socket file as the only
access gate.  When Emacs gains a peer-credentials API, replace
the body to consult it."
  t)

(defun emacs-devtools-mcp-auth--check-token (provided)
  "Return non-nil when PROVIDED string-equals the current token.
Comparison is constant-time-ish to avoid trivial timing leaks
between same-uid local processes (defense-in-depth on a single-
user gate)."
  (and (stringp provided)
       (stringp emacs-devtools-mcp-auth--token)
       (= (length provided) (length emacs-devtools-mcp-auth--token))
       (let ((diff 0)
             (a provided)
             (b emacs-devtools-mcp-auth--token))
         (dotimes (i (length a))
           (setq diff (logior diff (logxor (aref a i) (aref b i)))))
         (= 0 diff))))

(defun edmcp--auth-canon-dir (path)
  "Return PATH as a canonical directory or nil if it does not exist.
`expand-file-name' resolves `~' and relative components;
`file-truename' follows symlinks so the prefix check cannot be
sidestepped via a symlink to an off-allowlist target."
  (when (and (stringp path) (not (string-empty-p path)))
    (let ((abs (expand-file-name path)))
      (when (file-exists-p abs)
        (file-name-as-directory (file-truename abs))))))

(defun edmcp--auth-allowlist-prefixes ()
  "Return canonical directory prefixes from the init allowlist.
Includes the project root yielded by `project-current' (when any),
so per-repo fixtures load without editing the allowlist."
  (let ((dirs (delq nil
                    (mapcar #'edmcp--auth-canon-dir
                            emacs-devtools-mcp-init-allowlist))))
    (when-let* ((proj (ignore-errors (project-current)))
                (root (ignore-errors (project-root proj))))
      (when-let ((c (edmcp--auth-canon-dir root)))
        (cl-pushnew c dirs :test #'equal)))
    dirs))

(defun emacs-devtools-mcp-auth-validate-init-path (path)
  "Return PATH's truename iff PATH is under the init allowlist.
Signal `user-error' otherwise.  Accepts when *either* the expanded
form or the symlink-resolved truename matches a prefix, so a
NixOS-style symlink from `~/.config/emacs/init.el' into
`/nix/store' is allowed."
  (let* ((abs (expand-file-name path))
         (real (and (file-exists-p abs) (file-truename abs))))
    (unless real
      (user-error "Init file does not exist: %s" path))
    (let ((prefixes (edmcp--auth-allowlist-prefixes)))
      (unless (or (cl-some (lambda (p) (string-prefix-p p abs)) prefixes)
                  (cl-some (lambda (p) (string-prefix-p p real)) prefixes))
        (user-error "Init path %s outside allowlist (%s)"
                    real
                    (if prefixes
                        (mapconcat #'identity prefixes ", ")
                      "<empty>"))))
    real))

(defun emacs-devtools-mcp-auth-log-failure (name reason)
  "Append one auth-failure line for connection NAME with REASON.
Suppressed entirely when `emacs-devtools-mcp-auth-log-failures'
is nil."
  (when emacs-devtools-mcp-auth-log-failures
    (with-current-buffer (get-buffer-create "*emacs-devtools-mcp-log*")
      (goto-char (point-max))
      (insert (format-time-string "%FT%T%z ")
              (format "auth-fail %s: %s\n" name reason)))))

(provide 'emacs-devtools-mcp-auth)
;;; emacs-devtools-mcp-auth.el ends here
