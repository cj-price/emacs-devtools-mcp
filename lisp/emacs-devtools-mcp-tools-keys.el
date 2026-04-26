;;; emacs-devtools-mcp-tools-keys.el --- Keybinding tools  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  C.J. Price
;; Author: C.J. Price <cjprice@fastmail.com>
;; Maintainer: C.J. Price <cjprice@fastmail.com>
;; Homepage: https://github.com/cjprice/emacs-devtools-mcp
;; Keywords: tools, convenience
;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Five tools for inspecting and exercising Emacs keymaps:
;;   `where-is'              -- bindings for COMMAND.
;;   `lookup-key'            -- command bound to KEYS.
;;   `describe-keymap'       -- flattened bindings under a keymap or mode.
;;   `simulate-keys'         -- run a kbd-macro and capture state delta.
;;   `key-translation-trace' -- step through translation maps.
;;
;; Tools route through `emacs-devtools-mcp-spawn-call' so the same
;; code path runs on host and (eventually) subordinate Emacsen.

;;; Code:

;; Internal short alias: edmcp-- (this file only).

(require 'cl-lib)
(require 'jsonrpc)
(require 'emacs-devtools-mcp)
(require 'emacs-devtools-mcp-rpc)
(require 'emacs-devtools-mcp-server)
(require 'emacs-devtools-mcp-spawn)

(defcustom emacs-devtools-mcp-keys-page-size 100
  "Default page size for `describe-keymap'."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defcustom emacs-devtools-mcp-keys-simulate-text-cap 4096
  "Maximum bytes of buffer text returned by `simulate-keys'."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

;;;; Pure runtime helpers (run on host today, subordinate later).

(defun emacs-devtools-mcp-tools-keys--resolve-keymap (name)
  "Resolve NAME to a keymap value.
NAME may be nil (the global map), a string naming a variable
holding a keymap, or a string naming a major/minor mode.  When NAME
ends in `-mode' and the named symbol is not itself a keymap, the
function falls back to `<NAME>-map'.  Signals if no keymap is
found."
  (cond
   ((null name) (current-global-map))
   ((not (stringp name))
    (error "Keymap name must be a string, got %S" name))
   (t
    (let* ((sym (intern-soft name))
           (mode-map-sym (and (string-suffix-p "-mode" name)
                              (intern-soft (concat name "-map")))))
      (unless sym
        (error "Unknown keymap symbol: %s" name))
      (cond
       ((and (boundp sym) (keymapp (symbol-value sym)))
        (symbol-value sym))
       ((and mode-map-sym (boundp mode-map-sym)
             (keymapp (symbol-value mode-map-sym)))
        (symbol-value mode-map-sym))
       (t
        (error "Symbol is not a keymap: %s" name)))))))

(defun emacs-devtools-mcp-tools-keys--binding-name (binding)
  "Stringify BINDING for the wire.
Symbols become their name; nil yields \"undefined\"; keymaps,
byte-compiled functions, lambdas, and closures get short stable
tags; everything else falls back to `prin1-to-string'.  The
result is always a finite string (no objects, markers, or full
closure environments) so it survives the spawn round-trip."
  (cond
   ((null binding) "undefined")
   ((symbolp binding) (symbol-name binding))
   ((keymapp binding) "#<keymap>")
   ((byte-code-function-p binding) "#<bytecode>")
   ((functionp binding) "#<function>")
   (t (prin1-to-string binding))))

(defun emacs-devtools-mcp-tools-keys--where-is (command keymap-name)
  "Return key bindings for COMMAND in the resolved KEYMAP-NAME.
COMMAND is a string command name; KEYMAP-NAME is nil (global) or a
string.  Result is a list of human-readable key descriptions."
  (let* ((sym (intern-soft command))
         (map (emacs-devtools-mcp-tools-keys--resolve-keymap keymap-name)))
    (unless (and sym (fboundp sym))
      (error "Unknown command: %s" command))
    (mapcar #'key-description (where-is-internal sym map nil))))

(defun emacs-devtools-mcp-tools-keys--lookup-key (keys keymap-name accept-default)
  "Return the binding for KEYS in KEYMAP-NAME (or global when nil).
KEYS is a `kbd'-readable string.  ACCEPT-DEFAULT is a boolean
forwarded to `lookup-key'.  Result is one of:
  (:binding NAME)              -- a regular command binding,
  (:binding \"undefined\")       -- unbound (nil or 0-event prefix),
  (:prefix N)                  -- partial match consuming N events
                                  before running out (N positive).
A keymap value (the key terminates inside a prefix) is reported as
`(:keymap t)' so the wire stays JSON-clean."
  (let* ((map (emacs-devtools-mcp-tools-keys--resolve-keymap keymap-name))
         (k (kbd keys))
         (b (lookup-key map k (and accept-default t))))
    (cond
     ((or (null b) (and (integerp b) (zerop b)))
      (list :binding "undefined"))
     ((integerp b)
      (list :prefix b))
     ((keymapp b)
      (list :keymap t))
     (t
      (list :binding (emacs-devtools-mcp-tools-keys--binding-name b))))))

(defun emacs-devtools-mcp-tools-keys--flatten (map)
  "Flatten MAP into a list of (KEY-STRING . BINDING-NAME) entries.
Recurses into nested keymaps; the resulting key strings carry the
full prefix as produced by `key-description'."
  (let ((out nil))
    (cl-labels ((walk (m prefix)
                  (map-keymap
                   (lambda (event binding)
                     (let* ((seq (vconcat prefix (vector event))))
                       (cond
                        ((keymapp binding)
                         (walk binding seq))
                        ((null binding) nil)
                        (t
                         (push
                          (cons (key-description seq)
                                (emacs-devtools-mcp-tools-keys--binding-name
                                 binding))
                          out)))))
                   m)))
      (walk map []))
    (sort (nreverse out) (lambda (a b) (string< (car a) (car b))))))

(defun emacs-devtools-mcp-tools-keys--describe-keymap (name prefix)
  "Return a list of `(:keys KEY :binding NAME)' entries under NAME.
PREFIX, when non-nil, narrows the result to bindings whose
`key-description' is exactly PREFIX or begins with PREFIX followed
by a space.  This honors the natural event-sequence boundary so a
two-character control prefix returns the prefix itself plus any
sequence that extends it by an event, without spuriously matching
unrelated tokens that share a character prefix."
  (let* ((map (emacs-devtools-mcp-tools-keys--resolve-keymap name))
         (entries (emacs-devtools-mcp-tools-keys--flatten map))
         (re (and prefix (not (string-empty-p prefix))
                  (concat "\\`" (regexp-quote prefix) "\\(?: \\|\\'\\)"))))
    (mapcar (lambda (e) (list :keys (car e) :binding (cdr e)))
            (if re
                (cl-remove-if-not (lambda (e) (string-match-p re (car e)))
                                  entries)
              entries))))

(defun emacs-devtools-mcp-tools-keys--simulate (keys buffer-name)
  "Run KEYS as a kbd-macro inside BUFFER-NAME and return a state plist.
BUFFER-NAME nil uses the current buffer.  Captures the *Messages*
delta (redacted), the resulting `point', `mark', buffer size, and
a head/tail sample of buffer text capped by
`emacs-devtools-mcp-keys-simulate-text-cap'.  A `quit' or other
non-local exit during the macro is caught and returned as :error."
  (let* ((buf (if buffer-name
                  (or (get-buffer buffer-name)
                      (error "Buffer not found: %s" buffer-name))
                (current-buffer)))
         (messages-buf (get-buffer "*Messages*"))
         (msg-start (and messages-buf
                         (with-current-buffer messages-buf (point-max))))
         (kseq (kbd keys))
         (win (selected-window))
         (orig-buffer (window-buffer win))
         err)
    ;; `execute-kbd-macro' runs commands against the selected window's
    ;; buffer, not whatever `with-current-buffer' has set -- this is
    ;; load-bearing for `self-insert-command' and motion commands.
    ;; Swap the window's buffer for the duration; restore on exit.
    (unwind-protect
        (progn
          (set-window-buffer win buf)
          (with-current-buffer buf
            (let ((buffer-undo-list t))
              (condition-case oops
                  (execute-kbd-macro kseq)
                ((quit error)
                 (setq err (error-message-string oops)))))))
      (when (buffer-live-p orig-buffer)
        (set-window-buffer win orig-buffer)))
    (let* ((delta (and messages-buf msg-start
                       (with-current-buffer messages-buf
                         (buffer-substring-no-properties
                          msg-start (point-max)))))
           (redacted (emacs-devtools-mcp-redact (or delta "")))
           (cap emacs-devtools-mcp-keys-simulate-text-cap)
           (snapshot
            (with-current-buffer buf
              (let* ((sz (buffer-size))
                     (text (if (> sz cap)
                               (concat (buffer-substring-no-properties
                                        (point-min)
                                        (+ (point-min) (/ cap 2)))
                                       "\n...\n"
                                       (buffer-substring-no-properties
                                        (- (point-max) (/ cap 2))
                                        (point-max)))
                             (buffer-substring-no-properties
                              (point-min) (point-max)))))
                (list :buffer (buffer-name)
                      :point (point)
                      :mark (or (mark t) :json-false)
                      :buffer_size sz
                      :text text
                      :last_command (and last-command
                                         (symbol-name last-command))
                      :this_command (and this-command
                                         (symbol-name this-command)))))))
      (let ((base (append snapshot (list :messages redacted))))
        (if err
            (append base (list :error err))
          base)))))

(defun emacs-devtools-mcp-tools-keys--translation-trace (keys)
  "Step KEYS through Emacs's three translation maps.
Return a plist with `:input' plus per-map outputs after applying
`local-function-key-map', `key-translation-map', and
`function-key-map' in turn.  Each output is the `key-description'
of the translated sequence.  When a map's lookup yields a partial
match (prefix keymap or non-key-sequence value), the previous
sequence is preserved -- only complete translations are followed."
  (let* ((kseq (kbd keys))
         (apply-map
          (lambda (map seq)
            (let ((result (and map (lookup-key map seq))))
              (cond
               ((or (stringp result) (vectorp result)) result)
               (t seq))))))
    (let* ((after-local (funcall apply-map local-function-key-map kseq))
           (after-trans (funcall apply-map key-translation-map after-local))
           (after-func  (funcall apply-map function-key-map after-trans)))
      (list :input (key-description kseq)
            :local_function_key_map (key-description after-local)
            :key_translation_map (key-description after-trans)
            :function_key_map (key-description after-func)))))

;;;; Tool handlers.

(defun edmcp--tools-where-is (params)
  "Handler for `where-is'.  PARAMS is the validated request plist."
  (let* ((command (plist-get params :command))
         (keymap (plist-get params :keymap))
         (target (plist-get params :target)))
    (let ((bindings
           (emacs-devtools-mcp-spawn-call
            target
            `(emacs-devtools-mcp-tools-keys--where-is ,command ,keymap))))
      (list :bindings (vconcat bindings)))))

(defun edmcp--tools-lookup-key (params)
  "Handler for `lookup-key'.  PARAMS is the validated request plist."
  (let* ((keys (plist-get params :keys))
         (keymap (plist-get params :keymap))
         (accept (plist-get params :accept_default))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-keys--lookup-key
       ,keys ,keymap ,(and accept t)))))

(defun edmcp--tools-describe-keymap (params)
  "Handler for `describe-keymap'.  PARAMS is the validated request plist.
The keymap is fully walked and flattened on every fresh call (no
cursor); subsequent pages are served from the cursor store, so a
client paging through a wide keymap sees consistent ordering with
no re-walk between pages."
  (let* ((name (plist-get params :keymap))
         (prefix (plist-get params :prefix))
         (cursor (plist-get params :cursor))
         (target (plist-get params :target))
         (page-size emacs-devtools-mcp-keys-page-size)
         (items (unless cursor
                  (emacs-devtools-mcp-spawn-call
                   target
                   `(emacs-devtools-mcp-tools-keys--describe-keymap
                     ,name ,prefix))))
         (paged (emacs-devtools-mcp--paginate items page-size cursor))
         (page (nth 0 paged))
         (next (nth 1 paged))
         (out (list :bindings (vconcat page))))
    (when next (setq out (plist-put out :next_cursor next)))
    out))

(defun edmcp--tools-simulate-keys (params)
  "Handler for `simulate-keys'.  PARAMS is the validated request plist."
  (let* ((keys (plist-get params :keys))
         (buffer (plist-get params :buffer))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-keys--simulate ,keys ,buffer))))

(defun edmcp--tools-key-translation-trace (params)
  "Handler for `key-translation-trace'.  PARAMS is the validated plist."
  (let* ((keys (plist-get params :keys))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-keys--translation-trace ,keys))))

;;;; Tool definitions.

(emacs-devtools-mcp-deftool where-is
    "Return all key sequences bound to COMMAND in KEYMAP (default global)."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((command . (:type "string"))
                         (keymap  . (:type ["string" "null"]))
                         (target  . ,emacs-devtools-mcp-target-schema))
            :required ["command"])
  :handler #'edmcp--tools-where-is)

(emacs-devtools-mcp-deftool lookup-key
    "Return the command bound to KEYS in KEYMAP (default global)."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((keys           . (:type "string"))
                         (keymap         . (:type ["string" "null"]))
                         (accept_default . (:type ["boolean" "null"]))
                         (target         . ,emacs-devtools-mcp-target-schema))
            :required ["keys"])
  :handler #'edmcp--tools-lookup-key)

(emacs-devtools-mcp-deftool describe-keymap
    "List flattened bindings under KEYMAP, optionally narrowed by PREFIX."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((keymap . (:type "string"))
                         (prefix . (:type ["string" "null"]))
                         (cursor . (:type ["string" "null"]))
                         (target . ,emacs-devtools-mcp-target-schema))
            :required ["keymap"])
  :handler #'edmcp--tools-describe-keymap)

(emacs-devtools-mcp-deftool simulate-keys
    "Run KEYS as a `kbd' macro in BUFFER and return the state delta."
  :cost :slow
  :read-only nil
  :destructive t
  :idempotent nil
  :schema `(:type "object"
            :properties ((keys   . (:type "string"))
                         (buffer . (:type ["string" "null"]))
                         (target . ,emacs-devtools-mcp-target-schema))
            :required ["keys"])
  :handler #'edmcp--tools-simulate-keys)

(emacs-devtools-mcp-deftool key-translation-trace
    "Trace KEYS through the three keyboard translation maps."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((keys   . (:type "string"))
                         (target . ,emacs-devtools-mcp-target-schema))
            :required ["keys"])
  :handler #'edmcp--tools-key-translation-trace)

(provide 'emacs-devtools-mcp-tools-keys)
;;; emacs-devtools-mcp-tools-keys.el ends here
