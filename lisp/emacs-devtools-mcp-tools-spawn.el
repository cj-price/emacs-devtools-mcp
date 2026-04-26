;;; emacs-devtools-mcp-tools-spawn.el --- Spawn lifecycle tools  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  C.J. Price
;; Author: C.J. Price <cjprice@fastmail.com>
;; Maintainer: C.J. Price <cjprice@fastmail.com>
;; Homepage: https://github.com/cjprice/emacs-devtools-mcp
;; Keywords: tools, convenience
;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The four lifecycle tools that manage subordinate Emacs daemons:
;; `spawn-emacs', `attach-emacs', `kill-emacs', `list-handles'.  Each
;; is a thin wrapper around `emacs-devtools-mcp-spawn-*' that converts
;; the exception-throwing Elisp API into JSON-Schema-shaped requests
;; and `:isError'-tagged responses.
;;
;; These tools do not themselves accept a `target' parameter -- they
;; *are* the spawn-target plumbing.  All other tools route through
;; `emacs-devtools-mcp-spawn-call' once a handle exists.

;;; Code:

;; Internal short alias: edmcp-- (this file only).

(require 'cl-lib)
(require 'jsonrpc)
(require 'emacs-devtools-mcp)
(require 'emacs-devtools-mcp-rpc)
(require 'emacs-devtools-mcp-server)
(require 'emacs-devtools-mcp-spawn)

(defcustom emacs-devtools-mcp-handles-page-size 50
  "Number of handles per `list-handles' page.
Cursor-based pagination breaks larger result sets into pages of
this size.  Each page returns a `next_cursor' when more handles
remain."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defun edmcp--tools-spawn-spawn (params)
  "Handler for `spawn-emacs'.  PARAMS is the validated request plist."
  (let* ((init (plist-get params :init))
         (headless-raw (plist-get params :headless))
         (headless (and headless-raw (not (eq headless-raw :json-false))))
         (rec (apply #'emacs-devtools-mcp-spawn-spawn
                     (append (when init (list :init init))
                             (when headless (list :headless t))))))
    (edmcp--spawn-record-public rec)))

(defun edmcp--tools-spawn-attach (params)
  "Handler for `attach-emacs'.  PARAMS is the validated request plist."
  (let* ((sn (plist-get params :server_name))
         (rec (emacs-devtools-mcp-spawn-attach sn)))
    (edmcp--spawn-record-public rec)))

(defun edmcp--tools-spawn-kill (params)
  "Handler for `kill-emacs'.  PARAMS is the validated request plist.
Idempotent: a second call against an already-killed handle still
returns ok rather than signaling, matching the
`idempotentHint' annotation."
  (let* ((handle (plist-get params :handle))
         (already-gone
          (null (gethash handle emacs-devtools-mcp-spawn--handles))))
    (unless already-gone
      (emacs-devtools-mcp-spawn-kill handle))
    (list :ok t :handle handle :already_gone (if already-gone t :json-false))))

(defun edmcp--tools-spawn-list (params)
  "Handler for `list-handles'.  PARAMS is the validated request plist."
  (let* ((cursor (plist-get params :cursor))
         (all (and (null cursor) (emacs-devtools-mcp-spawn-list)))
         (paged (emacs-devtools-mcp--paginate
                 all emacs-devtools-mcp-handles-page-size cursor))
         (page (car paged))
         (next (cadr paged))
         (out (list :handles (vconcat page))))
    (when next
      (setq out (plist-put out :next_cursor next)))
    out))

(emacs-devtools-mcp-deftool spawn-emacs
    "Spawn a subordinate Emacs daemon and return its handle.
Optional INIT is a path to an init file that must lie under
`emacs-devtools-mcp-init-allowlist'.  Optional HEADLESS is
reserved for Xvfb-backed mode and is currently rejected.
The server name is auto-generated as `edmcp-spawn-<HANDLE>'
and is not caller-controllable -- this prevents an agent from
colliding with a daemon owned by the user, which the reaper
would later kill."
  :cost :slow
  :read-only nil
  :destructive t
  :idempotent nil
  :schema `(:type "object"
            :properties ((init     . (:type ["string" "null"]))
                         (headless . (:type ["boolean" "null"]))))
  :handler #'edmcp--tools-spawn-spawn)

(emacs-devtools-mcp-deftool attach-emacs
    "Register an externally-started Emacs daemon by SERVER_NAME.
Probes the daemon before recording the handle; signals when no
daemon answers at the given name."
  :cost :fast
  :read-only nil
  :destructive t
  :idempotent nil
  :schema `(:type "object"
            :properties ((server_name . (:type "string")))
            :required ["server_name"])
  :handler #'edmcp--tools-spawn-attach)

(emacs-devtools-mcp-deftool kill-emacs
    "Kill the daemon at HANDLE and forget the handle."
  :cost :fast
  :read-only nil
  :destructive t
  :idempotent t
  :schema `(:type "object"
            :properties ((handle . (:type "string")))
            :required ["handle"])
  :handler #'edmcp--tools-spawn-kill)

(emacs-devtools-mcp-deftool list-handles
    "List active subordinate Emacs handles.
Optional CURSOR continues a previous page."
  :cost :fast
  :read-only t
  :destructive nil
  :idempotent t
  :schema `(:type "object"
            :properties ((cursor . (:type ["string" "null"]))))
  :handler #'edmcp--tools-spawn-list)

(provide 'emacs-devtools-mcp-tools-spawn)
;;; emacs-devtools-mcp-tools-spawn.el ends here
