;;; test-e2e.el --- Tests for editors/emacs  -*- lexical-binding: t; -*-

;; Run from the repository root:
;;
;;     emacs -Q --batch -l tools/emacs/test-e2e.el
;;
;; Unit tests for the syntax table, indentation, motion and the
;; structural precheck, plus a live end-to-end test that starts a real
;; Poplog listener over a pty and drives it exactly as an editing buffer
;; would.  The live test is skipped when no engine can be found, so the
;; unit tests still run on a machine with no build.
;;
;; The corpus test is the one that matters most: it reindents a slice of
;; pop/lib/lib and asserts both that indentation is IDEMPOTENT (a second
;; pass changes nothing) and that it leaves most of the tree alone.
;; Those files are hand-formatted, some of them since the 1980s, so
;; agreeing with all of them is not the goal -- not damaging them is.

(require 'ert)

(defconst pop11-test-root
  (expand-file-name "../.." (file-name-directory load-file-name)))

(add-to-list 'load-path (expand-file-name "editors/emacs" pop11-test-root))
(require 'pop11-mode)
(require 'inferior-pop11)

(defmacro pop11-test-with (text &rest body)
  "Run BODY in a `pop11-mode' buffer holding TEXT."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (pop11-mode)
     (syntax-propertize (point-max))
     (goto-char (point-min))
     ,@body))

(defun pop11-test-face-at (pos)
  "Whether POS is in a string (`s'), a comment (`c') or code (nil)."
  (let ((ppss (syntax-ppss pos)))
    (cond ((nth 3 ppss) 's) ((nth 4 ppss) 'c))))

;;;; ------------------------------------------------------------------
;;;; Syntax

(ert-deftest pop11-syntax-semicolon-is-not-a-comment ()
  "A lone `;' separates statements; only `;;;' starts a comment."
  (pop11-test-with "npr(1); npr(2);\n"
    (should-not (pop11-test-face-at 9))))

(ert-deftest pop11-syntax-triple-semicolon-comments ()
  (pop11-test-with "npr(1);   ;;; and this is prose\n"
    (should (eq 'c (pop11-test-face-at 20)))))

(ert-deftest pop11-syntax-string ()
  (pop11-test-with "npr('hello');\n"
    (should (eq 's (pop11-test-face-at 8)))))

(ert-deftest pop11-syntax-word-quote-does-not-open-a-string ()
  "`\"' quotes a WORD and its closing quote is optional, so it must not
be a string delimiter -- one bare \"foo would swallow the whole file."
  (pop11-test-with "\"alpha and then some code;\nnpr(1);\n"
    (should-not (pop11-test-face-at 30))))

(ert-deftest pop11-syntax-quote-character-literal ()
  "`'` is the quote CHARACTER, not the start of a string."
  (pop11-test-with "while s(i) /== `'` do i + 1 -> i endwhile;\n"
    (should-not (pop11-test-face-at 25))
    (should (= 0 (car (syntax-ppss (point-max)))))))

(ert-deftest pop11-syntax-block-comments-nest ()
  (pop11-test-with "/* outer /* inner */ still outer */ npr(1);\n"
    (should (eq 'c (pop11-test-face-at 25)))
    (should-not (pop11-test-face-at 38))))

;;;; ------------------------------------------------------------------
;;;; Indentation

(defun pop11-test-reindents-to-itself (text)
  "Non-nil when reindenting TEXT reproduces TEXT exactly."
  (pop11-test-with text
    (indent-region (point-min) (point-max))
    (equal text (buffer-string))))

(ert-deftest pop11-indent-define-body ()
  (should (pop11-test-reindents-to-itself
           "define foo(x);\n    lvars x;\n    npr(x);\nenddefine;\n")))

(ert-deftest pop11-indent-if-else-chain ()
  (should (pop11-test-reindents-to-itself
           (concat "define lconstant hexval(c) -> v;\n"
                   "    if digit(c) then c - `0` -> v\n"
                   "    elseif c >= `a` and c <= `f` then c - `a` + 10 -> v\n"
                   "    else jerror('bad hex digit')\n"
                   "    endif\n"
                   "enddefine;\n"))))

(ert-deftest pop11-indent-nested-loop ()
  (should (pop11-test-reindents-to-itself
           (concat "define scan(l);\n"
                   "    for x in l do\n"
                   "        if x > 0 then\n"
                   "            npr(x);\n"
                   "        endif;\n"
                   "    endfor;\n"
                   "enddefine;\n"))))

(ert-deftest pop11-indent-procedure-as-parameter-type ()
  "`procedure' before an identifier is a type, not a block opener."
  (should (pop11-test-reindents-to-itself
           (concat "define zm_text_out(addr, procedure emit) -> next;\n"
                   "    lvars addr, next;\n"
                   "    emit(addr) -> next;\n"
                   "enddefine;\n"))))

(ert-deftest pop11-indent-anonymous-procedure ()
  "`procedure(' does open a block."
  (should (pop11-test-reindents-to-itself
           (concat "define guard();\n"
                   "    dlocal interrupt = procedure();\n"
                   "        false -> ok;\n"
                   "    endprocedure;\n"
                   "enddefine;\n"))))

(ert-deftest pop11-indent-multiline-condition ()
  "A condition that has not reached its `then' is a continuation, so the
line carrying the rest of it keeps the author's alignment."
  (should (pop11-test-reindents-to-itself
           (concat "define f(c, i, s, len);\n"
                   "    if c == `;` and i + 2 <= len\n"
                   "    and s(i+1) == `;` then\n"
                   "        npr(1);\n"
                   "    endif;\n"
                   "enddefine;\n"))))

(ert-deftest pop11-indent-statement-head-not-last-line ()
  "The base column comes from the head of a spilled statement, not from
its last physical line."
  (should (pop11-test-reindents-to-itself
           (concat "define load_it();\n"
                   "    pop11_compile(stringin(\n"
                   "        'uses zmachine_play; '\n"
                   "            <> 'zplay_turn -> zturn;'));\n"
                   "    true -> ok;\n"
                   "enddefine;\n"))))

(ert-deftest pop11-indent-expression-body-terminates-statement ()
  "A body line ending in `endif' ends its statement even with no `;',
so the `enddefine' below it does not inherit its indentation."
  (should (pop11-test-reindents-to-itself
           (concat "define lconstant ndefaults();\n"
                   "    if zm_version fi_<= 3 then 31 else 63 endif\n"
                   "enddefine;\n"
                   "\n"
                   "define lconstant entry_size();\n"
                   "    9\n"
                   "enddefine;\n"))))

(ert-deftest pop11-indent-section-body-is-flush-left ()
  "The corpus writes section bodies flush-left."
  (should (pop11-test-reindents-to-itself
           (concat "section $-zmachine =>\n"
                   "        zm_obj_addr zm_obj_count\n"
                   "    ;\n"
                   "\n"
                   "define zm_obj_addr(obj);\n"
                   "    obj\n"
                   "enddefine;\n"))))

(ert-deftest pop11-indent-leaves-continuations-alone ()
  "An indent pass must not re-flow hand-aligned continuation lines."
  (should (pop11-test-reindents-to-itself
           (concat "define f();\n"
                   "    lvars   addr, next, zl,\n"
                   "            alpha  = 0,\n"
                   "            abbrev = false;\n"
                   "enddefine;\n"))))

(ert-deftest pop11-indent-blank-continuation-line-gets-a-hint ()
  "TAB on a fresh line inside a continuation still offers something."
  (pop11-test-with "define f();\n    lvars a,\n            b,\n"
    (goto-char (point-max))
    (pop11-indent-line)
    (should (= 12 (current-indentation)))))

;;;; ------------------------------------------------------------------
;;;; Motion

(ert-deftest pop11-motion-defun-bounds ()
  (pop11-test-with
      "npr(0);\ndefine foo(x);\n    npr(x);\nenddefine;\nnpr(1);\n"
    (goto-char (point-min))
    (forward-line 2)
    (let ((b (pop11-defun-bounds)))
      (should b)
      (should (string= (buffer-substring-no-properties (car b) (cdr b))
                       "define foo(x);\n    npr(x);\nenddefine;")))))

(ert-deftest pop11-motion-defun-bounds-nil-outside ()
  (pop11-test-with
      "define foo(x);\n    npr(x);\nenddefine;\nnpr(1);\n"
    (goto-char (point-max))
    (should-not (pop11-defun-bounds))))

(ert-deftest pop11-motion-nested-define ()
  (pop11-test-with
      (concat "define outer();\n"
              "    define inner();\n"
              "        npr(1);\n"
              "    enddefine;\n"
              "    inner();\n"
              "enddefine;\n")
    (goto-char (point-min))
    (forward-line 2)                    ; inside `inner'
    (let ((b (pop11-defun-bounds)))
      (should (string-prefix-p
               "define inner"
               (string-trim (buffer-substring-no-properties
                             (car b) (cdr b))))))))

(ert-deftest pop11-motion-current-defun-name ()
  (pop11-test-with "define lconstant zm_obj_addr(obj);\n    obj\nenddefine;\n"
    (goto-char (point-min))
    (forward-line 1)
    (should (string= "zm_obj_addr" (pop11-current-defun-name)))))

;;;; ------------------------------------------------------------------
;;;; File association

(ert-deftest pop11-sniff-accepts-pop11 ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "pop/lib/lib/json.p" pop11-test-root))
    (should (pop11-looks-like-pop11-p))))

(ert-deftest pop11-sniff-rejects-pascal ()
  (with-temp-buffer
    (insert "program Hello;\nbegin\n  writeln('hi')\nend.\n")
    (should-not (pop11-looks-like-pop11-p))))

;;;; ------------------------------------------------------------------
;;;; Structural precheck

(ert-deftest pop11-precheck-rejects-unterminated-string ()
  (should-error (pop11--check-complete "npr('oops);") :type 'user-error))

(ert-deftest pop11-precheck-rejects-unclosed-bracket ()
  (should-error (pop11--check-complete "npr((1);") :type 'user-error))

(ert-deftest pop11-precheck-rejects-unterminated-comment ()
  (should-error (pop11--check-complete "/* forever") :type 'user-error))

(ert-deftest pop11-precheck-accepts-quote-character ()
  "The precheck must not be fooled by the quote character literal."
  (should-not (pop11--check-complete "if c == `'` then npr(1) endif;")))

(ert-deftest pop11-precheck-allows-unfinished-define ()
  "A `define' with no `enddefine' yet is fine: the listener simply waits
for the rest, which is how one builds a procedure interactively."
  (should-not (pop11--check-complete "define f();")))

;;;; ------------------------------------------------------------------
;;;; Corpus: idempotence and fidelity

(ert-deftest pop11-corpus-indent-is-idempotent ()
  (let ((files (seq-take
                (directory-files
                 (expand-file-name "pop/lib/lib" pop11-test-root) t "\\.p\\'")
                120))
        (unstable '()))
    (should (> (length files) 20))
    (dolist (f files)
      (with-temp-buffer
        (insert-file-contents f)
        (pop11-mode)
        (indent-region (point-min) (point-max))
        (let ((once (buffer-string)))
          (indent-region (point-min) (point-max))
          (unless (string= once (buffer-string))
            (push (file-name-nondirectory f) unstable)))))
    (should (null unstable))))

(ert-deftest pop11-corpus-indent-is-conservative ()
  "At least half the library must reindent byte-for-byte unchanged."
  (let ((files (seq-take
                (directory-files
                 (expand-file-name "pop/lib/lib" pop11-test-root) t "\\.p\\'")
                120))
        (clean 0) (total 0))
    (dolist (f files)
      (with-temp-buffer
        (insert-file-contents f)
        (pop11-mode)
        (let ((before (buffer-string)))
          (indent-region (point-min) (point-max))
          (setq total (1+ total))
          (when (string= before (buffer-string)) (setq clean (1+ clean))))))
    (message "corpus: %d/%d files reindent unchanged" clean total)
    (should (>= clean (/ total 2)))))

;;;; ------------------------------------------------------------------
;;;; Live listener

(defun pop11-test-wait (regexp &optional seconds)
  "Wait for REGEXP to appear in the REPL buffer.  Return non-nil if seen."
  (let ((deadline (+ (float-time) (or seconds 30))) found)
    (while (and (not found) (< (float-time) deadline))
      (accept-process-output nil 0.2)
      (with-current-buffer pop11-repl-buffer-name
        (save-excursion
          (goto-char (point-min))
          (when (re-search-forward regexp nil t) (setq found t)))))
    found))

(defun pop11-test-engine-available-p ()
  (let ((pop11-root pop11-test-root))
    (ignore-errors (file-executable-p (car (pop11-program))))))

(ert-deftest pop11-live-listener ()
  (skip-unless (pop11-test-engine-available-p))
  (let ((pop11-root pop11-test-root))
    (unwind-protect
        (progn
          (run-pop11)
          (should (pop11-test-wait "Sussex Poplog"))
          (should (pop11-test-wait "^: "))

          ;; A procedure sent from a source buffer, then called.
          (with-temp-buffer
            (pop11-mode)
            (insert "define fact(n);\n"
                    "    if n <= 1 then 1 else n * fact(n-1) endif\n"
                    "enddefine;\n")
            (goto-char (point-min))
            (forward-line 1)
            (pop11-eval-defun))
          (with-temp-buffer (insert "fact(10) =>") (pop11-eval-line))
          (should (pop11-test-wait "\\*\\* 3628800"))

          ;; What was sent is visible in the transcript.  It lands just
          ;; after a `: ' prompt rather than at column 0, because the
          ;; prompt carries no newline -- exactly where typed input
          ;; would have appeared.
          (with-current-buffer pop11-repl-buffer-name
            (goto-char (point-min))
            (should (re-search-forward "define fact(n);\n" nil t)))

          ;; A mishap must be survivable.  Over a pipe the engine would
          ;; call sysexit() here (pop/src/setpop_reset.p); the pty is
          ;; what makes it recoverable.
          (with-temp-buffer (insert "hd(3);") (pop11-eval-line))
          (should (pop11-test-wait ";;; MISHAP - LIST NEEDED"))
          (should (pop11-test-wait "^Setpop"))
          (with-temp-buffer (insert "1 + 1 =>") (pop11-eval-line))
          (should (pop11-test-wait "\\*\\* 2"))

          ;; Poplog's own wrapping is off, so a 90-column value arrives
          ;; on one line for Emacs to wrap.
          (with-temp-buffer
            (insert "consstring(repeat 90 times `x` endrepeat, 90) =>")
            (pop11-eval-line))
          (should (pop11-test-wait "x\\{90\\}")))
      (when (pop11-process t) (kill-process (pop11-process))))))

;;;; ------------------------------------------------------------------

(let ((ert-batch-backtrace-right-margin 200))
  (ert-run-tests-batch-and-exit))

;;; test-e2e.el ends here
