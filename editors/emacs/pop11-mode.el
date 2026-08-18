;;; pop11-mode.el --- Major mode for Pop-11 (Poplog)  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 IoTone, Inc.
;; SPDX-License-Identifier: MIT

;; Author: IoTone <https://github.com/IoTone>
;; URL: https://github.com/IoTone/poplog
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: languages, pop11, poplog

;;; Commentary:

;; Editing support for Pop-11, the core language of Poplog: syntax,
;; font-lock, indentation, `define'-aware motion and imenu.
;;
;; Evaluation lives in `inferior-pop11.el', which provides a comint REPL
;; and the VED-equivalent load commands bound in `pop11-mode-map':
;;
;;   C-x C-e   ENTER l1     compile the current line
;;   C-c C-r   ENTER lmr    compile the region ("marked range")
;;   C-M-x     ENTER lcp    compile the enclosing procedure
;;   C-c C-c   ENTER lcp    likewise
;;   C-c C-k   ENTER load   compile the whole file
;;   C-c C-z   ENTER im     switch to the REPL ("immediate mode")
;;   C-c C-t                toggle `trace' on the word at point
;;   M-.       ENTER showlib   jump to a library definition
;;   C-c C-d h/t/r/d        HELP / TEACH / REF / doc-at-point
;;
;; With a swank connection (`M-x pop11-swank') those commands go to the
;; live session instead of a terminal, and three more become useful:
;;
;;   C-c C-i                inspect a value
;;   C-c C-s                describe a name as the session has it
;;   C-c C-a                interrupt a running evaluation
;;
;; Two things about the lexical syntax are worth knowing, because they
;; are why this file needs a `syntax-propertize-function' rather than a
;; plain syntax table:
;;
;;   * `;' is the statement separator; only a run of three, `;;;',
;;     starts a comment.  Emacs syntax tables express two-character
;;     comment openers, not three, so `;;;' is propertized by hand.
;;
;;   * `"' quotes a WORD, not a string, and its closing quote is
;;     optional: `"foo' is as valid as `"foo"'.  Marking it as a string
;;     delimiter would let one unterminated word swallow the rest of the
;;     buffer, so `"' is punctuation and font-lock recognises the word
;;     forms.  The same goes for the backquote character literals
;;     (`` `a `` and `` `a` `` are both legal).
;;
;; Only `'...'` -- the real string -- is a string in the syntax table.

;;; Code:

(require 'rx)

(defgroup pop11 nil
  "Editing support for the Pop-11 language."
  :group 'languages
  :prefix "pop11-")

(defcustom pop11-indent-offset 4
  "Number of columns a Pop-11 block body is indented.
Four matches the Poplog TEACH corpus and the system sources."
  :type 'integer
  :safe #'integerp)

(defcustom pop11-claim-dot-p 'sniff
  "How `pop11-mode' claims the contested `.p' extension.
`.p' is also Pascal, Gnuplot and OpenEdge.  With the default `sniff',
a `.p' file is opened in `pop11-mode' only when it looks like Pop-11;
otherwise `pop11-dot-p-fallback-mode' runs.  t claims `.p'
unconditionally, nil never claims it."
  :type '(choice (const :tag "Sniff the contents" sniff)
                 (const :tag "Always Pop-11" t)
                 (const :tag "Never" nil)))

(defcustom pop11-dot-p-fallback-mode
  (if (fboundp 'pascal-mode) #'pascal-mode #'fundamental-mode)
  "Mode used for a `.p' file that does not look like Pop-11."
  :type 'function)

;;;; ------------------------------------------------------------------
;;;; Syntax

(defvar pop11-mode-syntax-table
  (let ((tab (make-syntax-table)))
    (modify-syntax-entry ?_  "_"      tab)
    (modify-syntax-entry ?\\ "\\"     tab)
    ;; The one true string.
    (modify-syntax-entry ?'  "\""     tab)
    ;; Word and character literals may be left unterminated; font-lock
    ;; handles them, the syntax table must not.
    (modify-syntax-entry ?\" "."      tab)
    (modify-syntax-entry ?`  "."      tab)
    ;; /* ... */, which nests.
    (modify-syntax-entry ?/  ". 14n"  tab)
    (modify-syntax-entry ?*  ". 23n"  tab)
    ;; `;;;' is applied by `pop11-syntax-propertize'; the newline that
    ;; ends such a comment can come from the table.
    (modify-syntax-entry ?\; "."      tab)
    (modify-syntax-entry ?\n ">"      tab)
    (dolist (c '(?+ ?- ?= ?< ?> ?& ?| ?! ?: ?@ ?# ?~ ?^ ?% ?? ?$ ?,))
      (modify-syntax-entry c "." tab))
    tab)
  "Syntax table for `pop11-mode'.")

(defun pop11--mark-line-comment ()
  "Give the `;;;' just matched comment-opener syntax, unless it is quoted."
  (let ((beg (match-beginning 0)))
    (unless (nth 8 (save-excursion (syntax-ppss beg)))
      (put-text-property beg (1+ beg)
                         'syntax-table (string-to-syntax "<")))))

(defun pop11--mark-quote-char ()
  "Neutralise the quote just matched inside a character literal.
`\=`\='\=`' is the quote CHARACTER, not the start of a string; left alone it
opens a string that swallows the rest of the line -- which is how

    while i <= len and s(i) /== \=`\='\=` do

used to throw off the indentation of everything below it."
  (let ((beg (match-beginning 1)))
    (unless (nth 8 (save-excursion (syntax-ppss (match-beginning 0))))
      (put-text-property beg (1+ beg)
                         'syntax-table (string-to-syntax ".")))))

(defconst pop11--syntax-propertize
  (syntax-propertize-rules
   ("`\\(?:\\\\\\)?\\(['\"]\\)`" (0 (ignore (pop11--mark-quote-char))))
   (";;;" (0 (ignore (pop11--mark-line-comment))))))

(defun pop11-syntax-propertize (start end)
  "Apply Pop-11 syntax properties between START and END."
  (funcall pop11--syntax-propertize start end))

(defun pop11--in-string-or-comment-p (&optional pos)
  "Non-nil when POS (default point) is inside a string or comment.
`syntax-ppss' leaves point at POS and clobbers the match data; both
matter to every caller here, which scans with `re-search-forward' and
then asks this question about the match it just found.  Guard once,
here, rather than at each call site."
  (save-excursion
    (save-match-data
      (nth 8 (syntax-ppss (or pos (point)))))))

;;;; ------------------------------------------------------------------
;;;; Font lock

(defconst pop11--keywords
  '("enddefine" "procedure" "endprocedure" "if" "endif" "unless"
    "endunless" "then" "do" "else" "elseif" "elseunless" "while"
    "endwhile" "until" "enduntil" "for" "endfor" "fast_for" "endfast_for"
    "foreach" "endforeach" "forevery" "endforevery" "repeat" "endrepeat"
    "fast_repeat" "endfast_repeat" "section" "endsection" "lblock"
    "endlblock" "exload" "endexload" "defclass" "defmethod"
    "enddefmethod" "flavour" "endflavour" "vedset" "endvedset"
    "switchon" "endswitchon" "go_on" "endgo_on" "uses" "fastprocs"
    "nonsyntax" "with_nargs" "with_props" "in" "on" "by" "step" "to"
    "from" "till")
  "Pop-11 syntax words, less the declaration and control-transfer sets.")

(defconst pop11--declarations
  '("vars" "lvars" "dlvars" "dlocal" "constant" "lconstant" "global"
    "compile_mode" "syntax" "macro" "updaterof" "active" "weak")
  "Pop-11 declaration keywords.")

(defconst pop11--control
  '("quitif" "quitunless" "quitloop" "nextif" "nextunless" "nextloop"
    "return" "returnif" "returnunless" "goto" "chain" "chainfrom"
    "define")
  "Pop-11 control-transfer words.")

(defconst pop11--define-header-re
  (rx symbol-start "define" symbol-end
      (group (* (+ (in " \t"))
                (or "updaterof" "active" "macro" "syntax" "global"
                    "constant" "lconstant" "vars" "lvars" "dlvars"
                    "procedure")))
      (? (+ (in " \t")) (group ":" (+ (in alnum "_"))))
      (? (+ (in " \t")) (group (+ (not (in " \t\n(;"))))))
  "Matches a `define' header: modifiers, optional `:class', name.")

(defvar pop11-font-lock-keywords
  `((,pop11--define-header-re
     (1 font-lock-keyword-face nil t)
     (2 font-lock-type-face nil t)
     (3 font-lock-function-name-face nil t))
    ;; Declarations, and the names they introduce.
    (,(rx symbol-start
          (group (or "vars" "lvars" "dlvars" "dlocal" "constant"
                     "lconstant" "global"))
          symbol-end)
     (1 font-lock-keyword-face)
     (,(rx (* (in " \t")) (? "procedure" (+ (in " \t")))
           (group (any alpha "_") (* (in alnum "_"))))
      nil nil (1 font-lock-variable-name-face)))
    (,(regexp-opt pop11--control 'symbols) . font-lock-keyword-face)
    (,(regexp-opt pop11--keywords 'symbols) . font-lock-keyword-face)
    (,(regexp-opt pop11--declarations 'symbols) . font-lock-keyword-face)
    (,(rx symbol-start (or "true" "false" "termin" "nil" "undef")
          symbol-end)
     . font-lock-constant-face)
    ;; "word  "word"  """ -- the closing quote is optional.
    (,(rx (or "\"\"\""
              (seq "\"" (* (not (in "\" \t\n[]()"))) "\"")
              (seq "\"" (+ (in alnum "_")))))
     . font-lock-constant-face)
    ;; `c  `c`  `\n`  ``` -- likewise.
    (,(rx (or "```"
              (seq "`" (? "\\") nonl "`")
              (seq "`" (or (seq "\\" (not (in "`\n"))) (not (in "`\\\n"))))))
     . font-lock-constant-face)
    (,(rx (or (seq "#_" (or "INCLUDE" "IF" "ELSEIF" "ELSE_ERROR" "ELSE"
                            "ENDIF" "TERMIN_IF")
                   symbol-end)
              "#_<" ">_#"))
     . font-lock-preprocessor-face)
    ;; $-section$-path
    (,(rx "$-" (* (+ (in alnum "_")) "$-") (+ (in alnum "_")))
     . font-lock-type-face)
    ;; ?pattern and ??segment variables
    (,(rx (repeat 1 2 "?") (any alpha "_") (* (in alnum "_")))
     . font-lock-variable-name-face)
    (,(rx symbol-start
          (or (seq (+ digit) ":" (+ (in alnum)))
              (seq (+ digit) "." (+ digit) (? (in "esd") (? (in "+-")) (+ digit)))
              (seq (+ digit) (? (in "esd") (? (in "+-")) (+ digit))))
          symbol-end)
     . font-lock-constant-face))
  "Font-lock rules for `pop11-mode'.")

;;;; ------------------------------------------------------------------
;;;; Block structure

(defconst pop11--directive-re "^[ \t]*#_"
  "Matches a preprocessor directive line.")

(defconst pop11--openers
  '("define" "if" "unless" "while" "until" "for" "fast_for" "foreach"
    "forevery" "repeat" "fast_repeat" "lblock" "switchon"
    "go_on" "defmethod" "flavour" "vedset" "exload" "procedure")
  "Words that open a block, each closed by `end' plus the same word.

Two deliberate omissions.  `procedure' is listed but only counted when
it is not part of a typed declaration (`lvars procedure p;'), which has
no closer.  `section' is absent altogether: it does close, but the
Poplog corpus writes section bodies flush-left (see the top of
pop/lib/lib/unix_sockets.p), so indenting them would fight every file in
the tree.")

(defconst pop11--opener-re
  (concat "\\_<\\(end\\)?" (regexp-opt pop11--openers t) "\\_>"))

(defconst pop11--closer-line-re
  (concat "^[ \t]*\\(?:end" (regexp-opt pop11--openers)
          "\\|else\\|elseif\\|elseunless\\)\\_>")
  "Matches a line that begins by closing or continuing a block.")

(defun pop11--counted-opener-p ()
  "Non-nil if the `procedure' just matched really opens a block.
An anonymous procedure literal is followed immediately by `(' or `;';
every other use is a type qualifier with no closer -- `lvars procedure
p;', or a formal in a header like

    define zm_text_out(addr, procedure emit) -> next;

which would otherwise leave the whole body one step too deep.  Both
halves of the test are needed: `vars procedure (a, b, c);' is followed
by `(' and is still only a declaration."
  (and (save-excursion
         (goto-char (match-end 0))
         (skip-chars-forward " \t")
         (memq (char-after) '(?\( ?\;)))
       (save-excursion
         (goto-char (match-beginning 0))
         (skip-chars-backward " \t")
         (not (looking-back
               (rx symbol-start
                   (or "vars" "lvars" "dlvars" "dlocal" "constant"
                       "lconstant" "global")
                   symbol-end)
               (line-beginning-position))))))

(defun pop11--balance (beg end)
  "Net count of block openers minus closers between BEG and END.
Matches inside strings and comments are ignored."
  (let ((n 0))
    (save-excursion
      (goto-char beg)
      (while (re-search-forward pop11--opener-re end t)
        (unless (or (pop11--in-string-or-comment-p (match-beginning 0))
                    (and (equal (match-string 2) "procedure")
                         (not (match-beginning 1)) ; not `endprocedure'
                         (not (pop11--counted-opener-p))))
          (setq n (+ n (if (match-beginning 1) -1 1))))))
    n))

(defun pop11--line-balance ()
  "Net block balance of the current line."
  (pop11--balance (line-beginning-position) (line-end-position)))

(defun pop11--goto-previous-code-line ()
  "Move to the previous line holding code.  Return non-nil on success.
Blank lines, whole-line comments and preprocessor directives are skipped:
a directive is not part of the block structure around it (see
`pop11--directive-re')."
  (let (found)
    (while (and (not found) (zerop (forward-line -1)))
      (unless (or (looking-at-p "[ \t]*$")
                  (looking-at-p "[ \t]*;;;")
                  (looking-at-p pop11--directive-re)
                  (pop11--in-string-or-comment-p (line-beginning-position)))
        (setq found t)))
    found))

;;;; ------------------------------------------------------------------
;;;; Indentation
;;
;; Deliberately conservative.  Pop-11 statements run across lines with no
;; continuation marker, and the corpus is full of hand-aligned data --
;; `l_typespec' blocks, section export lists, argument tables.  A mode
;; that confidently re-flows those destroys files, so the rule here is:
;; indent what is structurally understood (blocks and brackets), and
;; leave a continuation line exactly where its author put it.

(defun pop11--code-eol ()
  "Position just after the last code character on this line.
A trailing `;;;' comment does not count as code."
  (save-excursion
    (let* ((bol (line-beginning-position))
           (eol (line-end-position))
           (open (nth 8 (save-excursion (syntax-ppss eol)))))
      (goto-char (if (and open (> open bol)) open eol))
      (skip-chars-backward " \t" bol)
      (point))))

(defun pop11--opens-block-p ()
  "Number of block levels this line opens (0 when it opens none)."
  (max (pop11--line-balance)
       (if (save-excursion
             (goto-char (pop11--code-eol))
             (looking-back "\\_<\\(?:then\\|do\\|else\\)" (line-beginning-position)))
           1 0)))

(defconst pop11--needs-then-re
  (concat "\\_<\\(?:if\\|unless\\|elseif\\|elseunless\\|while\\|until"
          "\\|for\\|fast_for\\|foreach\\|forevery\\)\\_>")
  "Block openers whose body only begins once `then' or `do' has been seen.")

(defun pop11--pending-header-p ()
  "Non-nil when a conditional or loop header is still awaiting its keyword.
Such a header spills its condition onto the following line, which is
therefore a continuation rather than the start of the block's body."
  (save-excursion
    (goto-char (line-beginning-position))
    (let ((end (pop11--code-eol)) last)
      (while (re-search-forward pop11--needs-then-re end t)
        (unless (pop11--in-string-or-comment-p (match-beginning 0))
          (setq last (match-end 0))))
      (and last
           (not (save-excursion
                  (goto-char last)
                  (re-search-forward "\\_<\\(?:then\\|do\\)\\_>" end t)))))))

(defconst pop11--closer-end-re
  (concat "\\_<end" (regexp-opt pop11--openers) "\\_>")
  "Matches a block-closing keyword, for testing the end of a line.")

(defun pop11--continuation-p ()
  "Non-nil when a statement is left unfinished by this line.
A line continues when it holds code, opens no block, closes none, and
ends neither in `;' nor in a closing keyword.  That last clause is
load-bearing: a procedure whose result is an expression ends

    define lconstant ndefaults();
        if zm_version fi_<= 3 then 31 else 63 endif
    enddefine;

and the middle line carries no semicolon, so without it the `enddefine'
would be read as part of the same statement and take its indentation."
  (let ((bol (line-beginning-position))
        (end (pop11--code-eol)))
    (and (> end bol)
         (not (eq (char-before end) ?\;))
         (not (save-excursion
                (goto-char end)
                (looking-back pop11--closer-end-re bol)))
         (or (pop11--pending-header-p)
             (and (>= (pop11--line-balance) 0)
                  (zerop (pop11--opens-block-p))))
         (not (looking-at-p pop11--closer-line-re)))))

(defun pop11--previous-statement ()
  "Describe the statement preceding the current line.
Returns nil when there is none, the symbol `continuation' when this line
is in the middle of one, or a cons (BASE . OPENS): the column the
statement started at, and how many blocks it leaves open.

The distinction matters because Pop-11 statements spill across lines
with no continuation marker, and the last physical line of a spilled
statement is usually indented past its own head:

    pop11_compile(stringin(
        \='uses zmachine_play; \=' <>
            \='zplay_playing -> zplaying;\='));
    true -> zmachine_ok;            ;;; belongs at the head\='s column, not 12

so the base column has to come from the head, not from the line just
above."
  (save-excursion
    (cond
     ((not (pop11--goto-previous-code-line)) nil)
     ((pop11--continuation-p) 'continuation)
     (t
      (let* ((last-eol (pop11--code-eol))
             (dangling (save-excursion
                         (goto-char last-eol)
                         (looking-back "\\_<\\(?:then\\|do\\|else\\)"
                                       (line-beginning-position))))
             (start (line-beginning-position)))
        ;; Walk back to the statement's head -- but a line that begins
        ;; by closing a block is a statement in its own right, however
        ;; unfinished the line above it looks.  Unless it is closing
        ;; inside a bracket, where the `endif' is data:
        ;;
        ;;     lconstant macro GETRESTRICT = [
        ;;         if ispair(pat) ... then ... else ... endif];
        (unless (looking-at-p pop11--closer-line-re)
          (save-excursion
            (while (and (pop11--goto-previous-code-line)
                        (pop11--continuation-p))
              (setq start (line-beginning-position)))))
        (goto-char start)
        (cons (current-indentation)
              (max (pop11--balance start last-eol) (if dangling 1 0))))))))

(defun pop11--opener-line-indent ()
  "Indentation of the line that opens the block this line closes.
Nil if no opener is found.  Walking back to the opener, rather than
subtracting a step from the line above, is what keeps a run of
`elseif'/`else'/`endif' aligned with its `if' however the intervening
bodies were laid out."
  (save-excursion
    (beginning-of-line)
    (let ((depth 0) result)
      (while (and (not result) (pop11--goto-previous-code-line))
        (setq depth (+ depth (pop11--line-balance)))
        (when (> depth 0) (setq result (current-indentation))))
      result)))

(defun pop11--bracket-indent (open)
  "Column to align to inside the bracket opened at OPEN."
  (save-excursion
    (goto-char open)
    (if (save-excursion (forward-char 1) (skip-chars-forward " \t") (eolp))
        (+ (current-indentation) pop11-indent-offset)
      (forward-char 1)
      (skip-chars-forward " \t")
      (current-column))))

(defun pop11-calculate-indent ()
  "Return the column the current line should be indented to.
Returns nil when the line continues a statement and its alignment should
be left alone."
  (save-excursion
    (beginning-of-line)
    (cond
     ;; Inside ( ) [ ] { }: a bracketed expression spilling over a line
     ;; break is a continuation like any other.  Aligning it on the
     ;; opener column reads well in Lisp but not here -- Pop-11 nests
     ;; `mkobj([% ... %])' deeply enough that it marches off the right
     ;; margin, and the corpus indents such lines by one step instead.
     ((nth 1 (syntax-ppss (point))) nil)
     ;; `#_IF'/`#_ELSE'/`#_ENDIF' are laid out inconsistently across the
     ;; corpus -- flush-left inside a procedure body in pop/lib/lib/newpop.p,
     ;; indented with the body in pop/lib/lib/crypto.p -- and they are not
     ;; part of the block structure either way.  Leave them exactly where
     ;; they are, and step over them when looking for context.
     ((looking-at-p pop11--directive-re) nil)
     ((looking-at-p pop11--closer-line-re) (or (pop11--opener-line-indent) 0))
     (t
      (let ((stmt (pop11--previous-statement)))
        (cond
         ((null stmt) 0)
         ((eq stmt 'continuation) nil)
         (t (max 0 (+ (car stmt) (* pop11-indent-offset (cdr stmt)))))))))))

(defun pop11-indent-line ()
  "Indent the current line as Pop-11."
  (interactive)
  (if (nth 8 (syntax-ppss (line-beginning-position)))
      'noindent                         ; inside /* */ or a string
    (let ((target (pop11-calculate-indent))
          (offset (- (point) (save-excursion (back-to-indentation) (point)))))
      (cond
       (target
        (indent-line-to target)
        (when (> offset 0) (forward-char offset)))
       ;; A continuation line: only help when the line is still blank,
       ;; so that pressing RET does something sensible but reindenting a
       ;; region never disturbs hand alignment.
       ((save-excursion (beginning-of-line) (looking-at-p "[ \t]*$"))
        (indent-line-to
         (let ((open (nth 1 (syntax-ppss (line-beginning-position)))))
           (if open
               (pop11--bracket-indent open)
             (save-excursion
               (if (pop11--goto-previous-code-line)
                   (current-indentation) 0))))))
       (t 'noindent)))))

;;;; ------------------------------------------------------------------
;;;; Motion: `define' ... `enddefine'

(defun pop11-beginning-of-defun (&optional arg)
  "Move backward to the start of the enclosing `define'.
ARG repeats.  Returns non-nil when a `define' was found."
  (interactive "^p")
  (let ((arg (or arg 1)) (ok t))
    (while (and ok (> arg 0))
      (setq ok (pop11--backward-defun))
      (setq arg (1- arg)))
    ok))

(defun pop11--backward-defun ()
  "Move to the `define' opening the current or preceding procedure."
  (let ((depth 0) (start (point)) found)
    (when (looking-at-p "[ \t]*\\_<define\\_>") (setq depth -1))
    (while (and (not found)
                (re-search-backward "\\_<\\(define\\|enddefine\\)\\_>" nil t))
      (unless (pop11--in-string-or-comment-p (point))
        (if (equal (match-string 1) "enddefine")
            (setq depth (1+ depth))
          (if (<= depth 0) (setq found t) (setq depth (1- depth))))))
    (if found t (goto-char start) nil)))

(defun pop11-end-of-defun ()
  "Move past the `enddefine' closing the current procedure."
  (interactive "^")
  (let ((depth 0) found)
    (when (looking-at-p "[ \t]*\\_<define\\_>")
      (re-search-forward "\\_<define\\_>" nil t))
    (while (and (not found)
                (re-search-forward "\\_<\\(define\\|enddefine\\)\\_>" nil t))
      (unless (pop11--in-string-or-comment-p (match-beginning 0))
        (if (equal (match-string 1) "define")
            (setq depth (1+ depth))
          (if (zerop depth) (setq found t) (setq depth (1- depth))))))
    (when found
      (when (looking-at "[ \t]*;") (goto-char (match-end 0)))
      t)))

(defun pop11-defun-bounds ()
  "Return (START . END) of the `define' around point, or nil.
This is the range VED's ENTER lcp would compile."
  (save-excursion
    (let ((orig (point)) start end)
      (when (pop11--backward-defun)
        (setq start (point))
        (when (pop11-end-of-defun)
          (setq end (point))
          (when (and (<= start orig) (<= orig end))
            (cons start end)))))))

;;;; ------------------------------------------------------------------
;;;; imenu

(defconst pop11--imenu-generic-expression
  `(("Procedures"
     ,(rx line-start (* (in " \t")) symbol-start "define" symbol-end
          (* (+ (in " \t"))
             (or "global" "constant" "lconstant" "vars" "lvars" "dlvars"
                 "procedure"))
          (+ (in " \t"))
          (group (+ (not (in " \t\n(;")))))
     1)
    ("Updaters"
     ,(rx line-start (* (in " \t")) symbol-start "define" symbol-end
          (+ (in " \t")) "updaterof" (+ (in " \t"))
          (group (+ (not (in " \t\n(;")))))
     1)
    ("Classes"
     ,(rx line-start (* (in " \t"))
          symbol-start (or "defclass" "defmethod") symbol-end
          (+ (in " \t")) (? ":" (* (in " \t")))
          (group (+ (not (in " \t\n(;{")))))
     1)
    ("Sections"
     ,(rx line-start (* (in " \t")) symbol-start "section" symbol-end
          (+ (in " \t")) (group (+ (not (in " \t\n;")))))
     1)))

;;;; ------------------------------------------------------------------
;;;; The language server

(defcustom pop11-lsp-program nil
  "Command that runs the Pop-11 language server, as a list.
Nil means find `tools/pop11-lsp' under the Poplog tree `pop11-root'
resolves to."
  :type '(choice (const :tag "Find it under the Poplog root" nil)
                 (repeat string))
  :group 'pop11)

(defcustom pop11-lsp-autostart nil
  "Whether every `pop11-mode' buffer should get a language server.
Off by default: a Poplog process per project is the sort of thing that
ought to be asked for.  With Eglot installed, turning it on is
all that is needed --

    (setq pop11-lsp-autostart t)

-- and `\[eglot]' starts one by hand meanwhile."
  :type 'boolean
  :group 'pop11)

(declare-function pop11-root "inferior-pop11" ())
(declare-function eglot-ensure "eglot" ())
(defvar eglot-server-programs)

(defun pop11-lsp-command (&optional _interactive)
  "Return the command line for the Pop-11 language server.
Shaped for `eglot-server-programs', which calls this with one argument."
  (or pop11-lsp-program
      (let* ((root (progn (require 'inferior-pop11) (pop11-root)))
             (launcher (and root (expand-file-name "tools/pop11-lsp" root))))
        (unless (and launcher (file-executable-p launcher))
          (user-error
           "Cannot find tools/pop11-lsp; set `pop11-lsp-program'"))
        (list launcher))))

;; Registering the program is free -- Eglot starts nothing until asked --
;; so it happens whether or not `pop11-lsp-autostart' is set.
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs '(pop11-mode . pop11-lsp-command)))

;;;; ------------------------------------------------------------------
;;;; The mode

(autoload 'run-pop11 "inferior-pop11" "Run an inferior Pop-11." t)
(autoload 'pop11-eval-line "inferior-pop11" nil t)
(autoload 'pop11-eval-region "inferior-pop11" nil t)
(autoload 'pop11-eval-defun "inferior-pop11" nil t)
(autoload 'pop11-eval-buffer "inferior-pop11" nil t)
(autoload 'pop11-load-file "inferior-pop11" nil t)
(autoload 'pop11-switch-to-repl "inferior-pop11" nil t)
(autoload 'pop11-toggle-trace "inferior-pop11" nil t)
(autoload 'pop11-find-definition "inferior-pop11" nil t)
(autoload 'pop11-doc-help "inferior-pop11" nil t)
(autoload 'pop11-doc-teach "inferior-pop11" nil t)
(autoload 'pop11-doc-ref "inferior-pop11" nil t)
(autoload 'pop11-doc-at-point "inferior-pop11" nil t)
(autoload 'pop11-swank "pop11-swank" "Start a Pop-11 session and connect." t)
(autoload 'pop11-swank-connect "pop11-swank" nil t)
(autoload 'pop11-swank-inspect "pop11-swank" nil t)
(autoload 'pop11-swank-describe "pop11-swank" nil t)
(autoload 'pop11-swank-interrupt "pop11-swank" nil t)

(defvar pop11-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-x C-e") #'pop11-eval-line)      ; ENTER l1
    (define-key map (kbd "C-c C-r") #'pop11-eval-region)    ; ENTER lmr
    (define-key map (kbd "C-M-x")   #'pop11-eval-defun)     ; ENTER lcp
    (define-key map (kbd "C-c C-c") #'pop11-eval-defun)     ; ENTER lcp
    (define-key map (kbd "C-c C-b") #'pop11-eval-buffer)
    (define-key map (kbd "C-c C-k") #'pop11-load-file)      ; ENTER load
    (define-key map (kbd "C-c C-z") #'pop11-switch-to-repl) ; ENTER im
    (define-key map (kbd "C-c C-t") #'pop11-toggle-trace)
    (define-key map (kbd "M-.")     #'pop11-find-definition); ENTER showlib
    (define-key map (kbd "C-c C-d h") #'pop11-doc-help)
    (define-key map (kbd "C-c C-d t") #'pop11-doc-teach)
    (define-key map (kbd "C-c C-d r") #'pop11-doc-ref)
    (define-key map (kbd "C-c C-d d") #'pop11-doc-at-point)
    ;; Only meaningful with a live session behind them.
    (define-key map (kbd "C-c C-i") #'pop11-swank-inspect)
    (define-key map (kbd "C-c C-s") #'pop11-swank-describe)
    (define-key map (kbd "C-c C-a") #'pop11-swank-interrupt)
    map)
  "Keymap for `pop11-mode', mapping VED's ENTER commands onto Emacs keys.")

;;;###autoload
(define-derived-mode pop11-mode prog-mode "Pop-11"
  "Major mode for editing Pop-11 source.

\\{pop11-mode-map}"
  :syntax-table pop11-mode-syntax-table
  (setq-local comment-start ";;; ")
  (setq-local comment-end "")
  (setq-local comment-start-skip ";;;+[ \t]*")
  (setq-local comment-column 40)
  (setq-local block-comment-start "/*")
  (setq-local block-comment-end "*/")
  (setq-local parse-sexp-ignore-comments t)
  (setq-local syntax-propertize-function #'pop11-syntax-propertize)
  (setq-local font-lock-defaults '(pop11-font-lock-keywords))
  (setq-local indent-line-function #'pop11-indent-line)
  (setq-local indent-tabs-mode nil)
  (setq-local beginning-of-defun-function #'pop11-beginning-of-defun)
  (setq-local end-of-defun-function #'pop11-end-of-defun)
  (setq-local imenu-generic-expression pop11--imenu-generic-expression)
  (setq-local add-log-current-defun-function #'pop11-current-defun-name)
  (when (and pop11-lsp-autostart (fboundp 'eglot-ensure))
    (eglot-ensure)))

(defun pop11-current-defun-name ()
  "Name of the `define' around point, for `add-log' and which-function."
  (save-excursion
    (when (pop11--backward-defun)
      (when (looking-at pop11--define-header-re)
        (match-string-no-properties 3)))))

;;;; ------------------------------------------------------------------
;;;; File association

(defconst pop11--sniff-re
  (rx (or ";;;"
          (seq line-start (* (in " \t")) symbol-start "define" symbol-end
               (* nonl) ";")
          "enddefine"
          (seq line-start (* (in " \t")) (? "l") "vars" symbol-end)
          "compile_mode"))
  "Content markers that identify a `.p' file as Pop-11 rather than Pascal.
Mirrors the heuristic in editors/nvim/plugin/pop11.lua.")

(defun pop11-looks-like-pop11-p ()
  "Non-nil when the first 80 lines of this buffer look like Pop-11."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (let ((limit (line-beginning-position 81)))
        (and (re-search-forward pop11--sniff-re limit t) t)))))

;;;###autoload
(defun pop11-mode-maybe ()
  "Enter `pop11-mode' when this `.p' file appears to be Pop-11.
Otherwise enter `pop11-dot-p-fallback-mode'.  See `pop11-claim-dot-p'."
  (interactive)
  (if (or (eq pop11-claim-dot-p t)
          (and pop11-claim-dot-p (pop11-looks-like-pop11-p)))
      (pop11-mode)
    (funcall pop11-dot-p-fallback-mode)))

;;;###autoload
(progn
  (add-to-list 'auto-mode-alist '("\\.pop11\\'" . pop11-mode))
  (add-to-list 'auto-mode-alist '("\\.ph\\'" . pop11-mode))
  (add-to-list 'auto-mode-alist '("\\.p\\'" . pop11-mode-maybe))
  ;; The Poplog corpus itself: HELP/TEACH/REF pages and VED libraries
  ;; carry no extension at all.
  (add-to-list 'auto-mode-alist
               '("/pop/lib/\\(?:auto\\|lib\\|ved\\)/[^/]+\\'" . pop11-mode)))

(provide 'pop11-mode)

;;; pop11-mode.el ends here
