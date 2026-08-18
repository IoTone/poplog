;;; inferior-pop11.el --- Run Pop-11 as an Emacs subprocess  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 IoTone, Inc.
;; SPDX-License-Identifier: MIT

;; Author: IoTone <https://github.com/IoTone>
;; URL: https://github.com/IoTone/poplog
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (pop11-mode "0.1.0"))
;; Keywords: languages, pop11, poplog, processes

;;; Commentary:

;; A comint REPL for Pop-11, plus the editing commands that talk to it.
;; `M-x run-pop11' starts one; `pop11-mode' buffers send code to it with
;; the bindings listed in pop11-mode.el, which are named after the VED
;; ENTER commands they replace.
;;
;; Three details of the Poplog listener shape this file.
;;
;; 1. The prompt is written with a raw write(2) on the input device's own
;;    descriptor (pop/src/devio.p), and both prompt and banner are gated
;;    on that device being a terminal.  Over a pipe you get neither.
;;
;; 2. Worse, a mishap chains to `setpop', and setpop_reset calls
;;    `sysexit()' outright when stdin is not a terminal
;;    (pop/src/setpop_reset.p).  One typo would kill the session.
;;
;;    So the process MUST run on a pty -- see `process-connection-type'
;;    in `run-pop11'.  On a pty the same mishap instead flushes pending
;;    input, prints `Setpop', and returns to the prompt.
;;
;; 3. That input flush means a chunk which mishaps part-way through
;;    discards its own remainder.  Nothing can be done about it from out
;;    here; it is why `pop11--check-complete' refuses to send code that
;;    is structurally unfinished, which would otherwise leave the
;;    itemiser wedged.  The MCP server does the same thing for the same
;;    reason (pop/mcp/pop11_mcp.p, `incomplete_code').

;;; Code:

(require 'cl-lib)
(require 'comint)
(require 'grep)
(require 'seq)
(require 'xref)
(require 'pop11-mode)
(require 'pop11-swank)

(defcustom pop11-repl-buffer-name "*pop11*"
  "Name of the buffer running the inferior Pop-11 process."
  :type 'string
  :group 'pop11)

(defcustom pop11-program nil
  "Command used to start Pop-11, as a list of program and arguments.
Nil means work it out from `pop11-root'."
  :type '(choice (const :tag "Derive from the Poplog root" nil)
                 (repeat string))
  :group 'pop11)

(defcustom pop11-root nil
  "Poplog root directory.
Nil means discover one; see `pop11-root' for the search order."
  :type '(choice (const :tag "Discover" nil) directory)
  :group 'pop11)

(defcustom pop11-echo-sends 12
  "How many lines of sent code to echo into the REPL buffer.
The listener does not echo what Emacs sends it, so without this the
transcript is a column of bare prompts.  Longer sends are summarised in
one line instead.  Nil switches echoing off."
  :type '(choice (const :tag "Never echo" nil) integer)
  :group 'pop11)

(defcustom pop11-unwrap-output t
  "Whether to switch off Poplog's automatic line wrapping in the REPL.
Poplog wraps all output at `poplinewidth' (70 columns) and hard-breaks
at `poplinemax' (78), which splits long values and mishap messages
mid-word.  Emacs does its own wrapping, so the default turns Poplog's
off, exactly as the MCP server does."
  :type 'boolean
  :group 'pop11)

(defvar pop11--load-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory this file was loaded from, used to find the Poplog checkout.")

;;;; ------------------------------------------------------------------
;;;; Finding Poplog

(defun pop11--root-from-config ()
  "Poplog root recorded by the pop11 skill installer, if any."
  (let ((cfg (expand-file-name "~/.cache/pop11-skill/config.json")))
    (when (file-readable-p cfg)
      (with-temp-buffer
        (insert-file-contents cfg)
        (goto-char (point-min))
        (when (re-search-forward "\"root\"[ \t]*:[ \t]*\"\\([^\"]+\\)\"" nil t)
          (match-string 1))))))

(defun pop11--enclosing-root (dir)
  "Nearest ancestor of DIR that appears to be a Poplog tree."
  (when dir
    (locate-dominating-file
     dir (lambda (d) (and (file-exists-p (expand-file-name "poplog" d))
                          (file-directory-p (expand-file-name "pop" d)))))))

(defun pop11-root ()
  "Return the Poplog root directory, or nil if none can be found.
Tries, in order: `pop11-root'; $POPLOG_ROOT; a Poplog tree enclosing the
current buffer; the checkout this file was loaded from; the root the
pop11 skill installer recorded; $usepop.

Editing inside a checkout beats the installed tarball deliberately: a
checkout has the full `pop11' startup image and the sources you are
looking at, and is almost always the tree you meant."
  (or pop11-root
      (seq-find
       (lambda (d) (and d (file-exists-p (expand-file-name "poplog" d))))
       (list (getenv "POPLOG_ROOT")
             (pop11--enclosing-root default-directory)
             (expand-file-name "../.." pop11--load-directory)
             (pop11--root-from-config)
             (getenv "usepop")))))

(defun pop11-program ()
  "Return the command line for Pop-11, as a list of program and arguments.
The `pop11' engine name is preferred: the wrapper script expands it via
$pop_pop11 into the fully loaded startup image.  A tarball install ships
only `basepop11' -- the bare core system, still a perfectly good
listener -- so fall back to that."
  (or pop11-program
      (let ((root (pop11-root)))
        (unless root
          (user-error
           "Cannot find Poplog: set `pop11-root' or $POPLOG_ROOT"))
        (let ((wrapper (expand-file-name "poplog" root))
              (full (expand-file-name "target/pop/pop11" root))
              (base (expand-file-name "target/pop/basepop11" root)))
          (list wrapper (if (file-exists-p full) full base))))))

;;;; ------------------------------------------------------------------
;;;; The process

(defvar pop11--traced nil
  "Words currently traced, so `pop11-toggle-trace' can untrace them.")

(defun pop11-process (&optional no-error)
  "Return the live inferior Pop-11 process, or nil.
Signals unless NO-ERROR."
  (let* ((buf (get-buffer pop11-repl-buffer-name))
         (proc (and buf (get-buffer-process buf))))
    (cond ((and proc (process-live-p proc)) proc)
          (no-error nil)
          (t (user-error "No Pop-11 session; start one with M-x run-pop11")))))

(defvar inferior-pop11-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-d h") #'pop11-doc-help)
    (define-key map (kbd "C-c C-d t") #'pop11-doc-teach)
    (define-key map (kbd "C-c C-d r") #'pop11-doc-ref)
    (define-key map (kbd "C-c C-d d") #'pop11-doc-at-point)
    (define-key map (kbd "C-c C-t")   #'pop11-toggle-trace)
    (define-key map (kbd "M-.")       #'pop11-find-definition)
    map)
  "Keymap for `inferior-pop11-mode'.")

(define-derived-mode inferior-pop11-mode comint-mode "Inferior Pop-11"
  "Major mode for the buffer running an inferior Pop-11 listener.

\\{inferior-pop11-mode-map}"
  :syntax-table pop11-mode-syntax-table
  ;; `: ' is `popprompt' (pop/src/miscio.p); `? ' is
  ;; `pop_readline_prompt', which `readline' dlocals over it.
  (setq-local comint-prompt-regexp "^\\(?:: \\|? \\)")
  (setq-local comint-prompt-read-only nil)
  (setq-local comint-input-sender-no-newline nil)
  (setq-local comint-process-echoes nil)
  (setq-local syntax-propertize-function #'pop11-syntax-propertize)
  (setq-local font-lock-defaults '(pop11-font-lock-keywords))
  (setq-local comment-start ";;; ")
  (setq-local indent-line-function #'pop11-indent-line))

;;;###autoload
(defun run-pop11 (&optional prompt)
  "Run an inferior Pop-11 listener in `pop11-repl-buffer-name'.
With a prefix argument, PROMPT for the command line to use."
  (interactive "P")
  (let* ((cmd (if prompt
                  (split-string-and-unquote
                   (read-string "Run Pop-11: "
                                (mapconcat #'identity (pop11-program) " ")))
                (pop11-program)))
         (buf (get-buffer-create pop11-repl-buffer-name)))
    (unless (comint-check-proc buf)
      ;; A pty, not a pipe.  Without one there is no prompt, and any
      ;; mishap exits the process outright -- see the commentary.
      (let ((process-connection-type t))
        (apply #'make-comint-in-buffer
               "pop11" buf (car cmd) nil (cdr cmd)))
      (with-current-buffer buf
        (inferior-pop11-mode)
        (when pop11-unwrap-output
          (comint-send-string
           (get-buffer-process buf)
           "false ->> poplinemax -> poplinewidth;\n"))))
    (pop-to-buffer buf)))

;;;; ------------------------------------------------------------------
;;;; Sending code

(defun pop11--check-complete (code)
  "Signal if CODE is structurally unfinished.
An unterminated string, comment or bracket would leave the listener's
itemiser mid-token, and every later chunk would be read as part of it."
  (with-temp-buffer
    (let ((inhibit-message t))
      (insert code)
      (pop11-mode)
      (syntax-propertize (point-max))
      (let ((state (parse-partial-sexp (point-min) (point-max))))
        (cond ((nth 3 state) (user-error "Pop-11: unterminated string"))
              ((nth 4 state) (user-error "Pop-11: unterminated comment"))
              ((> (nth 0 state) 0) (user-error "Pop-11: unclosed bracket"))
              ((< (nth 0 state) 0) (user-error "Pop-11: stray closing bracket")))))))

(defun pop11--send (code &optional what position)
  "Send CODE to Pop-11, describing it as WHAT.
Over the swank connection when there is one -- so output streams, values
come back as values and a mishap opens a backtrace -- and otherwise down
the comint terminal.  POSITION, when given, is where in this buffer the
code came from, which is what lets \[pop11-find-definition] come back to
a definition the session has no file for."
  (let ((trimmed (string-trim code)))
    (when (string-empty-p trimmed)
      (user-error "Nothing to send"))
    (pop11--check-complete trimmed)
    (if (pop11-swank-connected-p)
        (progn
          (pop11-swank-remember-definitions
           trimmed (buffer-file-name) position)
          (pop11-swank-eval trimmed what))
      (let ((proc (pop11-process)))
        (pop11--echo trimmed what)
        (comint-send-string proc (concat trimmed "\n"))
        (when what (message "Pop-11: sent %s" what))))))

(defun pop11--echo (code what)
  "Show CODE, described as WHAT, in the REPL buffer before sending it.
Inserted before the process mark so the listener's own output still
lands after it."
  (when pop11-echo-sends
    (let* ((lines (1+ (cl-count ?\n code)))
           (text (if (<= lines pop11-echo-sends)
                     code
                   (format ";;; [%d lines%s]" lines
                           (if what (format ": %s" what) "")))))
      (with-current-buffer pop11-repl-buffer-name
        (let ((proc (get-buffer-process (current-buffer))))
          (save-excursion
            (goto-char (process-mark proc))
            (insert-before-markers (concat text "\n"))))))))

(defun pop11-eval-line ()
  "Compile the current line.  VED's ENTER l1."
  (interactive)
  (pop11--send (buffer-substring-no-properties
                (line-beginning-position) (line-end-position))
               "line"))

(defun pop11-eval-region (start end)
  "Compile the region between START and END.  VED's ENTER lmr."
  (interactive "r")
  (pop11--send (buffer-substring-no-properties start end) "region"))

(defun pop11-eval-defun ()
  "Compile the `define' around point.  VED's ENTER lcp."
  (interactive)
  (let ((bounds (pop11-defun-bounds)))
    (unless bounds
      (user-error "Point is not inside a define ... enddefine"))
    (pop11--send (buffer-substring-no-properties (car bounds) (cdr bounds))
                 (or (pop11-current-defun-name) "procedure")
                 (car bounds))))

(defun pop11-eval-buffer ()
  "Compile the whole buffer, without saving it."
  (interactive)
  (pop11--send (buffer-substring-no-properties (point-min) (point-max))
               "buffer"))

(defun pop11-load-file (&optional file)
  "Compile FILE, by default the file this buffer is visiting.
VED's ENTER load.  Unlike \\[pop11-eval-buffer] this compiles what is on
disk, so mishaps carry a real filename and line number."
  (interactive)
  (let ((file (or file
                  (buffer-file-name)
                  (user-error "Buffer is not visiting a file"))))
    (when (and (buffer-modified-p) (equal file (buffer-file-name))
               (y-or-n-p (format "Save %s first? " (buffer-name))))
      (save-buffer))
    (pop11--send (format "pop11_compile('%s');" (expand-file-name file))
                 (file-name-nondirectory file))))

(defun pop11-switch-to-repl ()
  "Switch to the Pop-11 session, starting a listener if needed.
VED's ENTER im.  Prefers the swank connection when there is one."
  (interactive)
  (cond
   ((pop11-swank-connected-p) (pop-to-buffer pop11-swank-buffer-name))
   ((pop11-process t) (pop-to-buffer pop11-repl-buffer-name))
   (t (run-pop11))))

;;;; ------------------------------------------------------------------
;;;; Tracing

(defun pop11-toggle-trace (word)
  "Toggle `trace' on WORD, by default the identifier at point."
  (interactive
   (list (read-string "Trace: " (thing-at-point 'symbol t))))
  (if (pop11-swank-connected-p)
      (pop11-swank-toggle-trace word)
    (if (member word pop11--traced)
        (progn (pop11--send (format "untrace %s;" word))
               (setq pop11--traced (delete word pop11--traced))
               (message "Pop-11: untraced %s" word))
      (pop11--send (format "trace %s;" word))
      (push word pop11--traced)
      (message "Pop-11: traced %s" word))))

;;;; ------------------------------------------------------------------
;;;; Documentation: HELP, TEACH, REF

(defconst pop11--doc-sections '("help" "teach" "ref" "doc")
  "Poplog documentation directories, in the order HELP searches them.")

(defun pop11--doc-file (name &optional section)
  "Find the documentation file for NAME, optionally only in SECTION."
  (let ((root (pop11-root)))
    (when root
      (seq-some
       (lambda (sec)
         (let ((f (expand-file-name (format "pop/%s/%s" sec name) root)))
           (and (file-readable-p f) (not (file-directory-p f)) f)))
       (if section (list section) pop11--doc-sections)))))

(defun pop11--show-doc (name section)
  "Display the SECTION documentation for NAME."
  (let ((file (pop11--doc-file name section)))
    (unless file
      (user-error "No %s file for %s" (or section "documentation") name))
    (let ((buf (get-buffer-create (format "*pop11 %s: %s*"
                                          (or section "doc") name))))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert-file-contents file)
          (goto-char (point-min)))
        (setq buffer-file-name nil)
        (special-mode)
        (setq-local header-line-format file))
      (pop-to-buffer buf))))

(defun pop11--read-doc-name (section)
  "Read a documentation topic for SECTION, defaulting to the word at point."
  (list (read-string (format "%s for: " (upcase section))
                     (thing-at-point 'symbol t))))

(defun pop11-doc-help (name)
  "Show the HELP page for NAME."
  (interactive (pop11--read-doc-name "help"))
  (pop11--show-doc name "help"))

(defun pop11-doc-teach (name)
  "Show the TEACH file for NAME."
  (interactive (pop11--read-doc-name "teach"))
  (pop11--show-doc name "teach"))

(defun pop11-doc-ref (name)
  "Show the REF page for NAME."
  (interactive (pop11--read-doc-name "ref"))
  (pop11--show-doc name "ref"))

(defun pop11-doc-at-point ()
  "Show documentation for the identifier at point, from any section."
  (interactive)
  (let* ((name (or (thing-at-point 'symbol t)
                   (user-error "No identifier at point")))
         (file (pop11--doc-file name)))
    (unless file (user-error "No documentation for %s" name))
    (pop11--show-doc name (nth 1 (nreverse (split-string
                                            (file-name-directory file)
                                            "/" t))))))

;;;; ------------------------------------------------------------------
;;;; M-. : the library source for a name.  VED's ENTER showlib.

(defconst pop11--library-dirs
  '("pop/lib/auto" "pop/lib/lib" "pop/lib/ved" "pop/lib/data"
    "pop/lib/pwm" "local/auto")
  "Directories searched for an autoloadable library file.")

(defun pop11--library-file (name)
  "Path of the library file defining NAME, if there is one."
  (let ((root (pop11-root)))
    (when root
      (seq-some
       (lambda (dir)
         (let ((f (expand-file-name (format "%s/%s.p" dir name) root)))
           (and (file-readable-p f) f)))
       pop11--library-dirs))))

(defun pop11-find-definition (name)
  "Visit the definition of NAME.  VED's ENTER showlib.

An autoloadable library is a file named after the identifier, so that
lookup is exact.  For anything else -- a procedure defined inside a
larger file -- fall back to searching the tree for its `define'."
  (interactive (list (read-string "Find definition: "
                                  (thing-at-point 'symbol t))))
  (let ((file (and (not (pop11-swank-connected-p))
                   (pop11--library-file name))))
    (cond
     ((pop11-swank-connected-p) (pop11-swank-find-definition name))
     (file
      (xref-push-marker-stack)
      (find-file file)
      (goto-char (point-min))
      (re-search-forward (format "^[ \t]*define\\_>.*\\_<%s\\_>"
                                 (regexp-quote name))
                         nil t)
      (beginning-of-line))
     ((pop11-root)
      (let ((default-directory (pop11-root)))
        (grep (format "grep -rn --include=*.p -e %s ."
                      (shell-quote-argument
                       (format "^[ \t]*define[^;]*\\<%s\\>" name))))))
     (t (user-error "Cannot find Poplog to search")))))

(provide 'inferior-pop11)

;;; inferior-pop11.el ends here
