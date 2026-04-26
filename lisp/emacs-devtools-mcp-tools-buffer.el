;;; emacs-devtools-mcp-tools-buffer.el --- Buffer-state introspection  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  C.J. Price
;; Author: C.J. Price <cjprice@fastmail.com>
;; Maintainer: C.J. Price <cjprice@fastmail.com>
;; Homepage: https://github.com/cjprice/emacs-devtools-mcp
;; Keywords: tools, convenience
;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Read-only buffer introspection plus `ert-run' and `describe-hooks'.
;; Tools route through `emacs-devtools-mcp-spawn-call' so the same
;; code paths run on host and (eventually) subordinate Emacsen.
;; Pagination uses the cursor store from
;; `emacs-devtools-mcp-server.el'; redaction is applied to any
;; *Messages*-derived surface.

;;; Code:

;; Internal short alias: edmcp-- (this file only).

(require 'cl-lib)
(require 'ert)
(require 'jsonrpc)
(require 'emacs-devtools-mcp)
(require 'emacs-devtools-mcp-rpc)
(require 'emacs-devtools-mcp-server)
(require 'emacs-devtools-mcp-spawn)

(defcustom emacs-devtools-mcp-buffer-list-page-size 50
  "Default page size for `list-buffers' / `list-messages' / `list-warnings'."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defcustom emacs-devtools-mcp-buffer-substring-default-max-bytes (* 64 1024)
  "Default per-call byte cap for `buffer-substring' when client omits `max_bytes'."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

;;;; Pure runtime helpers (run on host today, subordinate later).

(defun emacs-devtools-mcp-tools-buffer--snapshot-list (filter)
  "Return a list of buffer plists, optionally narrowed by regex FILTER.
Plist keys: :name, :file, :mode, :size, :modified.  Buffers whose
names start with a space (internal) are skipped unless FILTER
explicitly matches them."
  (let ((re (and filter (not (string-empty-p filter)) filter))
        (out nil))
    (dolist (b (buffer-list))
      (let ((n (buffer-name b)))
        (when (and n
                   (or re (not (string-prefix-p " " n)))
                   (or (null re) (string-match-p re n)))
          (with-current-buffer b
            (push (list :name n
                        :file (or buffer-file-name :json-false)
                        :mode (symbol-name major-mode)
                        :size (buffer-size)
                        :modified (if (buffer-modified-p) t :json-false))
                  out)))))
    (nreverse out)))

(defun emacs-devtools-mcp-tools-buffer--state (name)
  "Return a buffer-state plist for buffer NAME, or signal if it does not exist."
  (let ((b (get-buffer name)))
    (unless b
      (error "Buffer not found: %s" name))
    (with-current-buffer b
      (list :name (buffer-name)
            :file (or buffer-file-name :json-false)
            :mode (symbol-name major-mode)
            :size (buffer-size)
            :modified (if (buffer-modified-p) t :json-false)
            :read_only (if buffer-read-only t :json-false)
            :point (point)
            :mark (or (mark t) :json-false)
            :line (line-number-at-pos)
            :column (current-column)
            :point_min (point-min)
            :point_max (point-max)
            :narrowed (if (or (/= (point-min) 1)
                              (/= (point-max) (1+ (buffer-size))))
                          t
                        :json-false)))))

(defun emacs-devtools-mcp-tools-buffer--substring
    (name start end with-properties max-bytes)
  "Return part of buffer NAME between START and END.
WITH-PROPERTIES non-nil keeps text properties as a structured
list; nil yields a plain string.  Output is capped to MAX-BYTES;
result plist carries :text and, when truncated, :truncated t
plus :next_offset."
  (let ((b (get-buffer name)))
    (unless b
      (error "Buffer not found: %s" name))
    (with-current-buffer b
      (let* ((pmin (point-min))
             (pmax (point-max))
             (s0 (max pmin (or start pmin)))
             (e0 (min pmax (or end pmax))))
        (when (> s0 e0)
          (error "Invalid range: start %d > end %d" s0 e0))
        (let* ((raw (if with-properties
                        (buffer-substring s0 e0)
                      (buffer-substring-no-properties s0 e0)))
               (bytes (string-bytes raw))
               (truncated (> bytes max-bytes)))
          (if (not truncated)
              (list :text raw :truncated :json-false)
            (let* ((acc nil)
                   (acc-bytes 0)
                   (i 0)
                   (len (length raw))
                   (next-offset s0))
              (while (and (< i len) (< acc-bytes max-bytes))
                (let* ((ch (aref raw i))
                       (cb (string-bytes (string ch))))
                  (when (> (+ acc-bytes cb) max-bytes)
                    (setq i len))
                  (when (< i len)
                    (push ch acc)
                    (setq acc-bytes (+ acc-bytes cb)
                          next-offset (1+ next-offset)
                          i (1+ i)))))
              (list :text (concat (nreverse acc))
                    :truncated t
                    :next_offset next-offset))))))))

(defun emacs-devtools-mcp-tools-buffer--messages-tail (n)
  "Return the last N lines of the *Messages* buffer, redacted.
N defaults to `emacs-devtools-mcp-buffer-list-page-size' when nil."
  (let ((buf (get-buffer "*Messages*"))
        (cap (or n emacs-devtools-mcp-buffer-list-page-size)))
    (if (not buf)
        '()
      (with-current-buffer buf
        (let* ((all (buffer-substring-no-properties (point-min) (point-max)))
               (lines (split-string all "\n"))
               (non-empty (cl-remove-if #'string-empty-p lines))
               (tail (last non-empty cap))
               (kept (split-string
                      (emacs-devtools-mcp-redact
                       (mapconcat #'identity tail "\n"))
                      "\n")))
          (cl-remove-if #'string-empty-p kept))))))

(defun emacs-devtools-mcp-tools-buffer--warnings-list ()
  "Return the *Warnings* buffer contents as one string per warning paragraph."
  (let ((buf (get-buffer "*Warnings*")))
    (if (not buf)
        '()
      (with-current-buffer buf
        (let* ((all (buffer-substring-no-properties (point-min) (point-max)))
               (paras (split-string all "\n\n" t "[ \t\n]+")))
          paras)))))

(defun emacs-devtools-mcp-tools-buffer--ert-run (selector)
  "Run ERT for SELECTOR (string or t) and return a plist summary.
SELECTOR strings are resolved via `intern-soft' so callers can
only reach existing tests; the literal \"t\" runs every loaded
test (use it sparingly -- the slow-tool timeout still applies)."
  (let* ((sel (cond
               ((null selector) t)
               ((and (stringp selector) (string= selector "t")) t)
               ((stringp selector)
                (or (intern-soft selector)
                    (error "Unknown ert selector: %s" selector)))
               (t selector)))
         (stats (ert-run-tests sel (lambda (&rest _)) nil))
         (passed (ert-stats-completed-expected stats))
         (failed (ert-stats-completed-unexpected stats))
         (skipped (ert-stats-skipped stats))
         (total (ert-stats-total stats)))
    (list :total total
          :passed passed
          :failed failed
          :skipped skipped
          :ok (if (zerop failed) t :json-false))))

(defun emacs-devtools-mcp-tools-buffer--describe-hooks (hook)
  "Describe HOOK or, when HOOK is nil, return a list of all bound hook symbols.
A bound hook is any symbol whose name ends in `-hook' that is
fboundp or whose value is a list."
  (cond
   ((null hook)
    (let (hooks)
      (mapatoms
       (lambda (s)
         (let ((n (symbol-name s)))
           (when (and (string-suffix-p "-hook" n)
                      (boundp s)
                      (listp (symbol-value s)))
             (push n hooks)))))
      (sort hooks #'string<)))
   (t
    (let* ((sym (if (stringp hook) (intern-soft hook) hook)))
      (unless (and sym (boundp sym))
        (error "Unbound hook: %s" hook))
      (list :name (symbol-name sym)
            :functions
            (mapcar (lambda (f)
                      (cond
                       ((symbolp f) (symbol-name f))
                       ((byte-code-function-p f) "#<bytecode>")
                       ((functionp f) (format "%S" f))
                       (t (format "%S" f))))
                    (symbol-value sym)))))))

;;;; Tool handlers.

(defun edmcp--tools-list-buffers (params)
  "Handler for `list-buffers'.  PARAMS is the validated request plist."
  (let* ((filter (plist-get params :filter))
         (cursor (plist-get params :cursor))
         (target (plist-get params :target))
         (page-size emacs-devtools-mcp-buffer-list-page-size)
         (items (unless cursor
                  (emacs-devtools-mcp-spawn-call
                   target
                   `(emacs-devtools-mcp-tools-buffer--snapshot-list
                     ,filter))))
         (paged (emacs-devtools-mcp--paginate items page-size cursor))
         (page (nth 0 paged))
         (next (nth 1 paged))
         (out (list :buffers (vconcat page))))
    (when next (setq out (plist-put out :next_cursor next)))
    out))

(defun edmcp--tools-buffer-state (params)
  "Handler for `buffer-state'.  PARAMS is the validated request plist."
  (let* ((name (plist-get params :buffer))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-buffer--state ,name))))

(defun edmcp--tools-buffer-substring (params)
  "Handler for `buffer-substring'.  PARAMS is the validated request plist."
  (let* ((name (plist-get params :buffer))
         (start (plist-get params :start))
         (end (plist-get params :end))
         (with-props (eq (plist-get params :with_properties) t))
         (max-bytes (or (plist-get params :max_bytes)
                        emacs-devtools-mcp-buffer-substring-default-max-bytes))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-buffer--substring
       ,name ,start ,end ,with-props ,max-bytes))))

(defun edmcp--tools-list-messages (params)
  "Handler for `list-messages'.  PARAMS is the validated request plist."
  (let* ((n (plist-get params :n))
         (cursor (plist-get params :cursor))
         (target (plist-get params :target))
         (page-size emacs-devtools-mcp-buffer-list-page-size)
         (items (unless cursor
                  (emacs-devtools-mcp-spawn-call
                   target
                   `(emacs-devtools-mcp-tools-buffer--messages-tail ,n))))
         (paged (emacs-devtools-mcp--paginate items page-size cursor))
         (page (nth 0 paged))
         (next (nth 1 paged))
         (out (list :messages (vconcat page))))
    (when next (setq out (plist-put out :next_cursor next)))
    out))

(defun edmcp--tools-list-warnings (params)
  "Handler for `list-warnings'.  PARAMS is the validated request plist."
  (let* ((cursor (plist-get params :cursor))
         (target (plist-get params :target))
         (page-size emacs-devtools-mcp-buffer-list-page-size)
         (items (unless cursor
                  (emacs-devtools-mcp-spawn-call
                   target
                   `(emacs-devtools-mcp-tools-buffer--warnings-list))))
         (paged (emacs-devtools-mcp--paginate items page-size cursor))
         (page (nth 0 paged))
         (next (nth 1 paged))
         (out (list :warnings (vconcat page))))
    (when next (setq out (plist-put out :next_cursor next)))
    out))

(defun edmcp--tools-ert-run (params)
  "Handler for `ert-run'.  PARAMS is the validated request plist."
  (let* ((selector (plist-get params :selector))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-buffer--ert-run ,selector))))

(defun edmcp--tools-describe-hooks (params)
  "Handler for `describe-hooks'.  PARAMS is the validated request plist."
  (let* ((hook (plist-get params :hook))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-buffer--describe-hooks ,hook))))

;;;; Tool definitions.

(emacs-devtools-mcp-deftool list-buffers
    "List live buffers, optionally narrowed by regex FILTER."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((filter . (:type ["string" "null"]))
                         (cursor . (:type ["string" "null"]))
                         (target . ,emacs-devtools-mcp-target-schema)))
  :handler #'edmcp--tools-list-buffers)

(emacs-devtools-mcp-deftool buffer-state
    "Return point/mark/mode/file metadata for BUFFER."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((buffer . (:type "string"))
                         (target . ,emacs-devtools-mcp-target-schema))
            :required ["buffer"])
  :handler #'edmcp--tools-buffer-state)

(emacs-devtools-mcp-deftool buffer-substring
    "Return up to MAX_BYTES of BUFFER between START and END.
Sets `truncated: true' + `next_offset' when the cap is hit."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((buffer          . (:type "string"))
                         (start           . (:type ["integer" "null"]))
                         (end             . (:type ["integer" "null"]))
                         (with_properties . (:type ["boolean" "null"]))
                         (max_bytes       . (:type ["integer" "null"]))
                         (target          . ,emacs-devtools-mcp-target-schema))
            :required ["buffer"])
  :handler #'edmcp--tools-buffer-substring)

(emacs-devtools-mcp-deftool list-messages
    "Return the last N lines of *Messages* (default page size), redacted."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((n      . (:type ["integer" "null"]))
                         (cursor . (:type ["string" "null"]))
                         (target . ,emacs-devtools-mcp-target-schema)))
  :handler #'edmcp--tools-list-messages)

(emacs-devtools-mcp-deftool list-warnings
    "Return the contents of the *Warnings* buffer, paragraph-split."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((cursor . (:type ["string" "null"]))
                         (target . ,emacs-devtools-mcp-target-schema)))
  :handler #'edmcp--tools-list-warnings)

(emacs-devtools-mcp-deftool ert-run
    "Run ERT for SELECTOR (default: all tests) and return a summary plist."
  :cost :slow
  :read-only nil
  :destructive t
  :idempotent nil
  :schema `(:type "object"
            :properties ((selector . (:type ["string" "null"]))
                         (target   . ,emacs-devtools-mcp-target-schema)))
  :handler #'edmcp--tools-ert-run)

(emacs-devtools-mcp-deftool describe-hooks
    "List all bound hooks, or the contents of a specific HOOK."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((hook   . (:type ["string" "null"]))
                         (target . ,emacs-devtools-mcp-target-schema)))
  :handler #'edmcp--tools-describe-hooks)

(provide 'emacs-devtools-mcp-tools-buffer)
;;; emacs-devtools-mcp-tools-buffer.el ends here
