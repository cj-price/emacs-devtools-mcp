;;; emacs-devtools-mcp.el --- Devtools MCP server for Emacs  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  C.J. Price
;; Author: C.J. Price <cjprice@fastmail.com>
;; Maintainer: C.J. Price <cjprice@fastmail.com>
;; Homepage: https://github.com/cjprice/emacs-devtools-mcp
;; Keywords: tools, convenience
;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (transient "0.6.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Entry point for the emacs-devtools-mcp package.  Defines the
;; customization group and version constant.  Tool registration,
;; transport, and dispatcher live in sibling files and are loaded as
;; their respective stories land.

;;; Code:

(defconst emacs-devtools-mcp-version "0.1.0"
  "Current version of the `emacs-devtools-mcp' package.")

(defgroup emacs-devtools-mcp nil
  "Devtools MCP server for Emacs."
  :group 'tools
  :prefix "emacs-devtools-mcp-"
  :link '(url-link :tag "Homepage"
                   "https://github.com/cjprice/emacs-devtools-mcp"))

(defgroup emacs-devtools-mcp-server nil
  "Transport, dispatch, and lifecycle for the MCP server."
  :group 'emacs-devtools-mcp
  :prefix "emacs-devtools-mcp-")

(defgroup emacs-devtools-mcp-spawn nil
  "Subordinate Emacs lifecycle for the spawn target."
  :group 'emacs-devtools-mcp
  :prefix "emacs-devtools-mcp-spawn-")

(defgroup emacs-devtools-mcp-tools nil
  "Per-category tool defaults."
  :group 'emacs-devtools-mcp
  :prefix "emacs-devtools-mcp-")

(defgroup emacs-devtools-mcp-security nil
  "Authentication, redaction, and allowlist policy."
  :group 'emacs-devtools-mcp
  :prefix "emacs-devtools-mcp-")

;; Auto-load the tool subsystems whose code is unconditional (no
;; external runtime deps).  Tool subsystems that hit X11 / spawn
;; gates load lazily as their stories land.
(eval-after-load 'emacs-devtools-mcp-server
  '(progn
     (require 'emacs-devtools-mcp-tools-eval)
     (require 'emacs-devtools-mcp-tools-buffer)
     (require 'emacs-devtools-mcp-tools-keys)
     (require 'emacs-devtools-mcp-tools-gui)
     (require 'emacs-devtools-mcp-tools-spawn)
     (require 'emacs-devtools-mcp-tools-init)))

(provide 'emacs-devtools-mcp)
;;; emacs-devtools-mcp.el ends here
