;;; emacs-devtools-mcp-tests.el --- Behavior tests  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  C.J. Price
;; Author: C.J. Price <cjprice@fastmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Behavior-organized tests for `emacs-devtools-mcp'.  Section banners
;; (Server, RPC, Spawn, GUI, Keys, Eval, Init, Buffer) appear as
;; tools land.  Tag every test with one of `:fast', `:daemon',
;; `:fresh-daemon', `:gui'.

;;; Code:

(require 'ert)
(require 'emacs-devtools-mcp)

;;;; ___Scaffolding___

(ert-deftest emacs-devtools-mcp-tests/version-is-a-string ()
  "Version constant exists and is a non-empty string."
  :tags '(:fast)
  (should (stringp emacs-devtools-mcp-version))
  (should (> (length emacs-devtools-mcp-version) 0)))

(ert-deftest emacs-devtools-mcp-tests/group-is-defined ()
  "Customization group is registered with the documented subgroups."
  :tags '(:fast)
  (should (get 'emacs-devtools-mcp 'group-documentation))
  (let ((children (mapcar #'car (get 'emacs-devtools-mcp 'custom-group))))
    (dolist (sub '(emacs-devtools-mcp-server
                   emacs-devtools-mcp-spawn
                   emacs-devtools-mcp-tools
                   emacs-devtools-mcp-security))
      (should (memq sub children)))))

(provide 'emacs-devtools-mcp-tests)
;;; emacs-devtools-mcp-tests.el ends here
