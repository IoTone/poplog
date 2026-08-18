;;; pop11-swank.el --- Talk to a live Pop-11 session  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 IoTone, Inc.
;; SPDX-License-Identifier: MIT

;; Author: IoTone <https://github.com/IoTone>
;; URL: https://github.com/IoTone/poplog
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (pop11-mode "0.1.0"))
;; Keywords: languages, pop11, poplog, processes

;;; Commentary:

;; A client for the Pop-11 swank server (`pop/lib/lib/swank.p',
;; HELP * SWANK), which serves a live Poplog session over a socket.
;;
;; `M-x pop11-swank' starts a server and connects to it.  From then on
;; the `pop11-mode' send commands go over the socket rather than to a
;; comint terminal, and what comes back is structured rather than
;; scraped:
;;
;;   * output arrives WHILE the code runs, not batched at the end
;;   * a mishap opens a backtrace buffer with real frames
;;   * `M-.' and completion read the live heap, so a procedure you
;;     defined at the prompt a minute ago is as findable as one in the
;;     library
;;   * `C-c C-c' in the REPL interrupts a runaway loop
;;
;; The difference from `inferior-pop11': that talks to a terminal, and
;; everything it knows it learned by reading text off it.  This talks to
;; the session itself.  Both can be running; the send commands prefer
;; this one when it is connected.
;;
;; To hand over a session you are ALREADY using -- with everything in it
;; -- start the server from inside it instead and connect with
;; `M-x pop11-swank-connect':
;;
;;     uses swank;
;;     swank_serve(4005);
;;
;; That session then belongs to the editor: `swank_serve' blocks, so it
;; stops being a terminal you can type at.  That is the trade, and it is
;; usually the right one.

;;; Code:

(require 'json)
(require 'xref)
(require 'pop11-mode)

(declare-function pop11-root "inferior-pop11" ())

(defcustom pop11-swank-host "localhost"
  "Host running the Pop-11 swank server."
  :type 'string
  :group 'pop11)

(defcustom pop11-swank-port 4005
  "Port the Pop-11 swank server listens on.
4005 is SLIME's, since this is the same idea."
  :type 'integer
  :group 'pop11)

(defcustom pop11-swank-buffer-name "*pop11-swank*"
  "Name of the swank REPL buffer."
  :type 'string
  :group 'pop11)

(defvar pop11-swank--process nil
  "The network process, when connected.")

(defvar pop11-swank--server nil
  "The server process, when we started one ourselves.")

(defvar pop11-swank--pending ""
  "Bytes read from the server that do not yet form a whole message.")

(defvar pop11-swank--id 0)
(defvar pop11-swank--callbacks (make-hash-table :test #'eql)
  "Request id -> function called with the reply.")

(defvar pop11-swank--info nil
  "The swank/connect handshake: name, version, pid, features.")

(defvar pop11-swank--source-map (make-hash-table :test #'equal)
  "Name -> (FILE . POSITION) for definitions we compiled from a buffer.
The server cannot know these -- a procedure defined inside a file
leaves no trail back to it -- but we sent them, so we can.")

;;;; ------------------------------------------------------------------
;;;; Wire protocol

(defun pop11-swank-connected-p ()
  "Non-nil when a swank connection is live."
  (and pop11-swank--process (process-live-p pop11-swank--process)))

(defun pop11-swank--get (obj key)
  "Value of string KEY in the parsed JSON object OBJ."
  (cdr (assoc key obj)))

(defun pop11-swank--send-message (obj)
  "Frame and send OBJ, a JSON-serialisable alist."
  (let* ((json (encode-coding-string (json-encode obj) 'utf-8 t)))
    (process-send-string
     pop11-swank--process
     (concat (format "Content-Length: %d\r\n\r\n" (length json)) json))))

(defun pop11-swank-send (method params callback)
  "Send METHOD with PARAMS; call CALLBACK with the reply when it arrives."
  (unless (pop11-swank-connected-p)
    (user-error "Not connected to a Pop-11 session (M-x pop11-swank)"))
  (setq pop11-swank--id (1+ pop11-swank--id))
  (when callback
    (puthash pop11-swank--id callback pop11-swank--callbacks))
  (pop11-swank--send-message
   `(("jsonrpc" . "2.0") ("id" . ,pop11-swank--id)
     ("method" . ,method) ("params" . ,(or params #s(hash-table))))))

(defun pop11-swank-call (method params &optional timeout)
  "Send METHOD with PARAMS, wait up to TIMEOUT seconds, return the result.
Used by the commands that have nothing to do until the answer comes --
`M-.\=', completion, describe -- where waiting is what the user meant."
  (let ((done nil) (reply nil)
        (deadline (+ (float-time) (or timeout 30))))
    (pop11-swank-send method params
                      (lambda (msg) (setq reply msg done t)))
    (while (and (not done) (< (float-time) deadline)
                (pop11-swank-connected-p))
      (accept-process-output pop11-swank--process 0.05))
    (unless done (user-error "Pop-11: no answer to %s" method))
    (pop11-swank--get reply "result")))

(defun pop11-swank--filter (_proc chunk)
  "Accumulate CHUNK and dispatch every whole message in it."
  (setq pop11-swank--pending (concat pop11-swank--pending chunk))
  (let (done)
    (while (not done)
      (let ((split (string-match "\r\n\r\n" pop11-swank--pending)))
        (if (not split)
            (setq done t)
          (let* ((headers (substring pop11-swank--pending 0 split))
                 (body-start (+ split 4))
                 (len (and (string-match "Content-Length: *\\([0-9]+\\)" headers)
                           (string-to-number (match-string 1 headers)))))
            (cond
             ((null len)                ; unusable frame: drop the headers
              (setq pop11-swank--pending
                    (substring pop11-swank--pending body-start)))
             ((< (- (length pop11-swank--pending) body-start) len)
              (setq done t))            ; body still arriving
             (t
              (let ((body (substring pop11-swank--pending
                                     body-start (+ body-start len))))
                (setq pop11-swank--pending
                      (substring pop11-swank--pending (+ body-start len)))
                (pop11-swank--dispatch
                 (let ((json-object-type 'alist)
                       (json-array-type 'list)
                       (json-key-type 'string))
                   (json-read-from-string
                    (decode-coding-string body 'utf-8 t)))))))))))))

(defun pop11-swank--dispatch (msg)
  "Route one parsed message MSG: a reply to us, or a notification."
  (let ((id (pop11-swank--get msg "id"))
        (method (pop11-swank--get msg "method")))
    (cond
     ((equal method "swank/output")
      (pop11-swank--output (pop11-swank--get msg "params")))
     (id
      (let ((cb (gethash id pop11-swank--callbacks)))
        (remhash id pop11-swank--callbacks)
        (when cb (funcall cb msg)))))))

(defun pop11-swank--sentinel (_proc event)
  "Report EVENT and forget the connection it ended."
  (pop11-swank--log (format ";;; connection %s" (string-trim event)))
  (setq pop11-swank--process nil
        pop11-swank--info nil))

;;;; ------------------------------------------------------------------
;;;; The REPL buffer

(defvar-local pop11-swank--input-start nil
  "Where the current input begins, just after the prompt.")

(defvar pop11-swank--history nil)
(defvar-local pop11-swank--history-pos nil)

(defun pop11-swank--buffer ()
  "The swank REPL buffer, created if it does not exist yet."
  (or (get-buffer pop11-swank-buffer-name)
      (with-current-buffer (get-buffer-create pop11-swank-buffer-name)
        (pop11-swank-mode)
        (current-buffer))))

(defun pop11-swank--at-end (text &optional face)
  "Insert TEXT before the input area, in FACE."
  (with-current-buffer (pop11-swank--buffer)
    (let ((inhibit-read-only t)
          (at-input (and pop11-swank--input-start
                         (>= (point) pop11-swank--input-start))))
      (save-excursion
        (goto-char (or pop11-swank--input-start (point-max)))
        (when pop11-swank--input-start
          (goto-char (line-beginning-position)))
        (let ((start (point)))
          (insert text)
          (when face (put-text-property start (point) 'face face))
          (put-text-property start (point) 'read-only t)
          (when pop11-swank--input-start
            (setq pop11-swank--input-start
                  (+ pop11-swank--input-start (- (point) start))))))
      (when at-input (goto-char (point-max))))
    (let ((win (get-buffer-window (current-buffer) t)))
      (when win (set-window-point win (point-max))))))

(defun pop11-swank--log (text)
  "Insert TEXT into the REPL as a comment line of our own."
  (pop11-swank--at-end (concat text "\n") 'font-lock-comment-face))

(defun pop11-swank--output (params)
  "Show a swank/output notification.
PARAMS carries its `text\=' and which `stream\=' it came from."
  (pop11-swank--at-end
   (pop11-swank--get params "text")
   (when (equal (pop11-swank--get params "stream") "err")
     'font-lock-warning-face)))

(defun pop11-swank--prompt ()
  "Start a fresh input area at the end of the REPL buffer."
  (with-current-buffer (pop11-swank--buffer)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (let ((start (point)))
        (insert ": ")
        (put-text-property start (point) 'face 'minibuffer-prompt)
        (put-text-property start (point) 'read-only t)
        (put-text-property start (point) 'rear-nonsticky t))
      (setq pop11-swank--input-start (point-max))
      (goto-char (point-max)))))

(defun pop11-swank-repl-send ()
  "Send the input after the prompt to the session."
  (interactive)
  (let ((code (string-trim
               (buffer-substring-no-properties
                (or pop11-swank--input-start (point-max)) (point-max)))))
    (if (string-empty-p code)
        (pop11-swank--prompt)
      (push code pop11-swank--history)
      (setq pop11-swank--history-pos nil)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert "\n")
        (put-text-property pop11-swank--input-start (point) 'read-only t))
      (setq pop11-swank--input-start nil)
      (pop11-swank-eval code nil))))

(defun pop11-swank--history-move (delta)
  "Replace the current input with the entry DELTA back in the history."
  (let* ((n (length pop11-swank--history))
         (pos (cond ((null pop11-swank--history-pos) (if (> delta 0) 0 nil))
                    (t (+ pop11-swank--history-pos delta)))))
    (when (and pos (>= pos 0) (< pos n))
      (setq pop11-swank--history-pos pos)
      (let ((inhibit-read-only t))
        (delete-region pop11-swank--input-start (point-max))
        (goto-char (point-max))
        (insert (nth pos pop11-swank--history))))))

(defun pop11-swank-history-previous ()
  "Recall the previous input."
  (interactive) (pop11-swank--history-move 1))

(defun pop11-swank-history-next ()
  "Recall the next input."
  (interactive) (pop11-swank--history-move -1))

(defvar pop11-swank-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")     #'pop11-swank-repl-send)
    (define-key map (kbd "M-p")     #'pop11-swank-history-previous)
    (define-key map (kbd "M-n")     #'pop11-swank-history-next)
    (define-key map (kbd "C-c C-c") #'pop11-swank-interrupt)
    (define-key map (kbd "C-c C-i") #'pop11-swank-inspect)
    (define-key map (kbd "C-c C-t") #'pop11-swank-toggle-trace)
    (define-key map (kbd "C-c C-q") #'pop11-swank-quit)
    (define-key map (kbd "M-.")     #'pop11-swank-find-definition)
    map)
  "Keymap for `pop11-swank-mode'.")

(define-derived-mode pop11-swank-mode pop11-mode "Pop-11/swank"
  "REPL buffer for a live Pop-11 session reached over a socket.

\\{pop11-swank-mode-map}"
  (setq-local indent-line-function #'pop11-indent-line)
  (add-hook 'completion-at-point-functions
            #'pop11-swank-completion-at-point nil t))

;;;; ------------------------------------------------------------------
;;;; Evaluation

(defun pop11-swank-eval (code &optional what)
  "Evaluate CODE in the session, describing it as WHAT."
  (pop11-swank-send
   "swank/eval" `(("code" . ,code))
   (lambda (msg)
     (let* ((r (pop11-swank--get msg "result"))
            (err (pop11-swank--get msg "error")))
       (cond
        (err (pop11-swank--log (format ";;; protocol error: %s"
                                       (pop11-swank--get err "message"))))
        ((eq (pop11-swank--get r "ok") t)
         (dolist (v (pop11-swank--get r "values"))
           (pop11-swank--at-end (format "%s\n" v) 'font-lock-constant-face))
         (when what (message "Pop-11: %s" what)))
        ((pop11-swank--get r "refused")
         (pop11-swank--log
          (format ";;; refused: %s" (pop11-swank--get r "refused"))))
        ((eq (pop11-swank--get r "interrupted") t)
         (pop11-swank--log ";;; interrupted"))
        (t (pop11-swank--mishap (pop11-swank--get r "mishap"))))
       (pop11-swank--prompt)))))

(defun pop11-swank-eval-expression (code)
  "Read CODE from the minibuffer and evaluate it in the session."
  (interactive "sPop-11: ")
  (pop11-swank-eval code "sent"))

(defun pop11-swank-interrupt ()
  "Interrupt the running evaluation.
Nothing can arrive on the socket while the session is inside the user's
loop, so this signals the process instead -- which the engine notices at
the next `I_CHECK' planted in the running code."
  (interactive)
  (let ((pid (and pop11-swank--info (pop11-swank--get pop11-swank--info "pid"))))
    (unless pid (user-error "No session to interrupt"))
    (signal-process pid 'SIGINT)
    (message "Pop-11: interrupted %d" pid)))

;;;; ------------------------------------------------------------------
;;;; Backtraces

(defvar pop11-swank--mishap-buffer "*pop11-mishap*")

(defun pop11-swank--mishap (m)
  "Show mishap M -- message, culprits and frames -- in its own buffer."
  (pop11-swank--at-end
   (format ";;; MISHAP - %s\n" (pop11-swank--get m "message"))
   'font-lock-warning-face)
  (let ((buf (get-buffer-create pop11-swank--mishap-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "%s\n" (pop11-swank--get m "message"))
                            'face 'font-lock-warning-face))
        (let ((culprits (pop11-swank--get m "culprits")))
          (when culprits
            (insert "\nInvolving:\n")
            (dolist (c culprits) (insert (format "  %s\n" c)))))
        (insert "\nFrames:\n")
        (let ((i 0))
          (dolist (f (pop11-swank--get m "frames"))
            (setq i (1+ i))
            (insert (propertize (format "  %2d  %s\n" i f)
                                'pop11-frame f))))
        (goto-char (point-min)))
      (pop11-mishap-mode))
    (display-buffer buf)))

(defun pop11-mishap-visit-frame ()
  "Describe the procedure named by the frame at point."
  (interactive)
  (let ((name (get-text-property (point) 'pop11-frame)))
    (unless name (user-error "No frame here"))
    (pop11-swank-find-definition name)))

(defvar pop11-mishap-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'pop11-mishap-visit-frame)
    (define-key map (kbd "n")   #'next-line)
    (define-key map (kbd "p")   #'previous-line)
    map)
  "Keymap for `pop11-mishap-mode'.")

(define-derived-mode pop11-mishap-mode special-mode "Pop-11 mishap"
  "A Pop-11 mishap: its message, culprits and the frames that were live.

\\{pop11-mishap-mode-map}")

;;;; ------------------------------------------------------------------
;;;; Inspector

(defvar pop11-swank--inspector-buffer "*pop11-inspector*")
(defvar pop11-swank--inspector-stack nil
  "Handles visited, so `l' can go back up the object graph.")

(defun pop11-swank-inspect (expr)
  "Inspect the value of EXPR in the session."
  (interactive
   (list (read-string "Inspect: "
                      (or (and (use-region-p)
                               (buffer-substring-no-properties
                                (region-beginning) (region-end)))
                          (thing-at-point 'symbol t)))))
  (setq pop11-swank--inspector-stack nil)
  (pop11-swank--inspector-show
   (pop11-swank-call "swank/inspect" `(("expr" . ,expr)))))

(defun pop11-swank--inspect-handle (handle)
  "Show the value the session is holding under HANDLE."
  (pop11-swank--inspector-show
   (pop11-swank-call "swank/inspect" `(("handle" . ,handle)))))

(defun pop11-swank--inspector-show (r)
  "Render one swank/inspect result R in the inspector buffer."
  (unless (eq (pop11-swank--get r "ok") t)
    (user-error "Pop-11: %s" (or (pop11-swank--get r "error") "cannot inspect")))
  (let ((buf (get-buffer-create pop11-swank--inspector-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "%s\n" (pop11-swank--get r "class"))
                            'face 'font-lock-type-face))
        (insert (format "%s\n" (pop11-swank--get r "printed")))
        (when (pop11-swank--get r "pdprops")
          (insert (format "\nprocedure %s, %s argument(s)\n"
                          (pop11-swank--get r "pdprops")
                          (pop11-swank--get r "nargs"))))
        (let ((parts (pop11-swank--get r "parts")))
          (if (null parts)
              (insert "\nNo parts.\n")
            (insert "\nParts:\n")
            (dolist (p parts)
              (insert (propertize
                       (format "  %2s  %-12s %s\n"
                               (pop11-swank--get p "index")
                               (pop11-swank--get p "class")
                               (pop11-swank--get p "printed"))
                       'pop11-handle (pop11-swank--get p "handle"))))))
        ;; Field NAMES are not recoverable from a Pop-11 class key --
        ;; class_spec gives types, not names -- so parts are indexed.
        (goto-char (point-min)))
      (pop11-inspector-mode)
      (push (pop11-swank--get r "handle") pop11-swank--inspector-stack))
    (display-buffer buf)))

(defun pop11-inspector-drill ()
  "Inspect the part at point."
  (interactive)
  (let ((h (get-text-property (point) 'pop11-handle)))
    (unless h (user-error "No part here"))
    (pop11-swank--inspect-handle h)))

(defun pop11-inspector-back ()
  "Go back to the value inspected before this one."
  (interactive)
  (pop pop11-swank--inspector-stack)      ; the one on screen
  (let ((previous (pop pop11-swank--inspector-stack)))
    (unless previous (user-error "At the top"))
    (pop11-swank--inspect-handle previous)))

(defvar pop11-inspector-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'pop11-inspector-drill)
    (define-key map (kbd "l")   #'pop11-inspector-back)
    (define-key map (kbd "n")   #'next-line)
    (define-key map (kbd "p")   #'previous-line)
    map)
  "Keymap for `pop11-inspector-mode'.")

(define-derived-mode pop11-inspector-mode special-mode "Pop-11 inspector"
  "A live Pop-11 value: its class, its printing and its parts.

\\{pop11-inspector-mode-map}")

;;;; ------------------------------------------------------------------
;;;; Names: definitions, documentation, completion, tracing

(defun pop11-swank-remember-definitions (code file position)
  "Note where CODE came from: FILE, at POSITION.
Every `define\=' it contains is recorded under its own name.
The server cannot know this -- a procedure defined inside a file leaves
no trail back to it -- but we are the ones who sent it."
  (when file
    (let ((start 0))
      (while (string-match
              (concat "^[ \t]*define\\_>\\(?:[ \t]+\\(?:updaterof\\|active\\|"
                      "macro\\|syntax\\|global\\|constant\\|lconstant\\|vars\\|"
                      "lvars\\|dlvars\\|procedure\\)\\)*[ \t]+"
                      "\\([^ \t\n(;]+\\)")
              code start)
        (setq start (match-end 0))
        (puthash (match-string 1 code) (cons file position)
                 pop11-swank--source-map)))))

(defun pop11-swank-find-definition (name)
  "Visit the definition of NAME, asking the live session where it is."
  (interactive (list (read-string "Find definition: "
                                  (thing-at-point 'symbol t))))
  (let* ((d (pop11-swank-call "swank/describe" `(("name" . ,name))))
         (remembered (gethash name pop11-swank--source-map))
         (file (or (car remembered) (pop11-swank--get d "sourceFile"))))
    (cond
     (file
      (xref-push-marker-stack)
      (find-file file)
      (if (and remembered (cdr remembered))
          (goto-char (min (cdr remembered) (point-max)))
        (goto-char (point-min))
        (re-search-forward (format "^[ \t]*define\\_>.*\\_<%s\\_>"
                                   (regexp-quote name))
                           nil t)
        (beginning-of-line)))
     ((eq (pop11-swank--get d "defined") t)
      (message "Pop-11: %s is %s, defined in this session but not in a file"
               name (pop11-swank--get d "identprops")))
     (t (user-error "Pop-11: %s is not defined" name)))))

(defun pop11-swank-describe (name)
  "Report what NAME is bound to in the live session."
  (interactive (list (read-string "Describe: " (thing-at-point 'symbol t))))
  (let ((d (pop11-swank-call "swank/describe" `(("name" . ,name)))))
    (if (not (eq (pop11-swank--get d "defined") t))
        (message "Pop-11: %s is not defined" name)
      (message "%s: %s%s%s" name
               (pop11-swank--get d "identprops")
               (if (eq (pop11-swank--get d "isProcedure") t)
                   (format ", procedure %s of %s argument(s)"
                           (pop11-swank--get d "pdprops")
                           (pop11-swank--get d "nargs"))
                 (format " = %s" (pop11-swank--get d "value")))
               (if (pop11-swank--get d "sourceFile")
                   (format " [%s]" (pop11-swank--get d "sourceFile")) "")))))

(defun pop11-swank-completion-at-point ()
  "Complete the word at point from the session's live dictionary."
  (when (pop11-swank-connected-p)
    (let ((bounds (bounds-of-thing-at-point 'symbol)))
      (when bounds
        (list (car bounds) (cdr bounds)
              (completion-table-dynamic
               (lambda (prefix)
                 (pop11-swank--get
                  (pop11-swank-call "swank/complete" `(("prefix" . ,prefix)))
                  "items")))
              :exclusive 'no)))))

(defvar pop11-swank--traced nil)

(defun pop11-swank-toggle-trace (name)
  "Toggle `trace' on NAME in the live session."
  (interactive (list (read-string "Trace: " (thing-at-point 'symbol t))))
  (let ((off (member name pop11-swank--traced)))
    (pop11-swank-call "swank/trace"
                      (if off
                          `(("name" . ,name) ("untrace" . t))
                        `(("name" . ,name))))
    (if off
        (progn (setq pop11-swank--traced (delete name pop11-swank--traced))
               (message "Pop-11: untraced %s" name))
      (push name pop11-swank--traced)
      (message "Pop-11: traced %s" name))))

;;;; ------------------------------------------------------------------
;;;; Connecting

;;;###autoload
(defun pop11-swank-connect (&optional host port)
  "Connect to a Pop-11 swank server already listening on HOST and PORT."
  (interactive
   (when current-prefix-arg
     (list (read-string "Host: " pop11-swank-host)
           (read-number "Port: " pop11-swank-port))))
  (when (pop11-swank-connected-p) (pop11-swank-quit))
  (setq pop11-swank--pending ""
        pop11-swank--id 0)
  (clrhash pop11-swank--callbacks)
  (setq pop11-swank--process
        (make-network-process
         :name "pop11-swank"
         :host (or host pop11-swank-host)
         :service (or port pop11-swank-port)
         :coding 'binary          ; Content-Length counts bytes
         :filter #'pop11-swank--filter
         :sentinel #'pop11-swank--sentinel
         :noquery t))
  (setq pop11-swank--info (pop11-swank-call "swank/connect" nil))
  (with-current-buffer (pop11-swank--buffer)
    (let ((inhibit-read-only t)) (erase-buffer)))
  (pop11-swank--log
   (format ";;; %s %s, Poplog %s, pid %s"
           (pop11-swank--get pop11-swank--info "name")
           (pop11-swank--get pop11-swank--info "version")
           (pop11-swank--get pop11-swank--info "poplogVersion")
           (pop11-swank--get pop11-swank--info "pid")))
  (pop11-swank--prompt)
  (pop-to-buffer (pop11-swank--buffer))
  pop11-swank--info)

;;;###autoload
(defun pop11-swank ()
  "Start a Pop-11 swank server and connect to it."
  (interactive)
  (let* ((root (pop11-swank--root))
         (launcher (expand-file-name "tools/pop11-swank" root)))
    (unless (file-executable-p launcher)
      (user-error "Cannot find tools/pop11-swank under %s" root))
    (setq pop11-swank--server
          (start-process "pop11-swank-server" (get-buffer-create
                                               "*pop11-swank-server*")
                         launcher "--port" (number-to-string pop11-swank-port)))
    (set-process-query-on-exit-flag pop11-swank--server nil)
    ;; The server prints one line when the socket is bound; wait for it
    ;; rather than guessing at a sleep.
    (let ((deadline (+ (float-time) 30)) (ready nil))
      (while (and (not ready) (< (float-time) deadline))
        (accept-process-output pop11-swank--server 0.1)
        (with-current-buffer "*pop11-swank-server*"
          (goto-char (point-min))
          (setq ready (re-search-forward "swank: listening" nil t))))
      (unless ready (user-error "Pop-11: the swank server did not start")))
    (pop11-swank-connect)))

(defun pop11-swank--root ()
  "Return the Poplog tree to launch a server from."
  (require 'inferior-pop11)
  (or (pop11-root) (user-error "Cannot find Poplog")))

(defun pop11-swank-quit ()
  "Disconnect, and stop the server if we started it."
  (interactive)
  (when (pop11-swank-connected-p)
    (ignore-errors (pop11-swank-call "swank/stop" nil 2))
    (delete-process pop11-swank--process))
  (setq pop11-swank--process nil pop11-swank--info nil)
  (when (and pop11-swank--server (process-live-p pop11-swank--server))
    (delete-process pop11-swank--server))
  (setq pop11-swank--server nil)
  (message "Pop-11: disconnected"))

(provide 'pop11-swank)

;;; pop11-swank.el ends here
