#lang racket/base

;; racket/cli/common.rkt — shared scaffolding for the `odysseus-*` CLIs.
;;
;; Faithful port of scripts/_lib/cli.py. Each CLI imports a few helpers so it
;; doesn't redefine the same emit / fail / version / repo-root pattern:
;;
;;   (require "common.rkt")
;;   (emit (hasheq 'ok #t) #:pretty? pretty?)
;;
;; --pretty, --version, repo-root resolution, and clean exit on errors /
;; Ctrl-C are handled centrally (see `run`).

(require json
         racket/runtime-path
         racket/port)

(provide version
         repo-root
         emit
         fail
         run
         pretty-from-args?)

;; Bumped centrally; every odysseus-* CLI reports this (mirrors cli.py VERSION).
(define version "0.1.0")

;; This file lives at <repo>/racket/cli/common.rkt, so the repo root is two
;; directories up from this file's directory. define-runtime-path resolves
;; correctly both when run from source and from a `raco exe` binary.
(define-runtime-path here-dir ".")
(define repo-root (simplify-path (build-path here-dir 'up 'up)))

;; ---- JSON output -----------------------------------------------------------

;; Racket's write-json has no indent option, so we hand-roll a 2-space
;; pretty-printer over jsexpr values. Scalars and empty containers defer to
;; write-json for correct escaping.
(define (write-json-pretty x out ind)
  (cond
    [(and (hash? x) (positive? (hash-count x)))
     (write-string "{\n" out)
     (define ind2 (+ ind 2))
     (let loop ([ps (hash->list x)])
       (define p (car ps))
       (write-string (make-string ind2 #\space) out)
       (write-json (symbol->string (car p)) out)
       (write-string ": " out)
       (write-json-pretty (cdr p) out ind2)
       (cond [(null? (cdr ps)) (write-string "\n" out)]
             [else (write-string ",\n" out) (loop (cdr ps))]))
     (write-string (make-string ind #\space) out)
     (write-string "}" out)]
    [(and (list? x) (pair? x))
     (write-string "[\n" out)
     (define ind2 (+ ind 2))
     (let loop ([xs x])
       (write-string (make-string ind2 #\space) out)
       (write-json-pretty (car xs) out ind2)
       (cond [(null? (cdr xs)) (write-string "\n" out)]
             [else (write-string ",\n" out) (loop (cdr xs))]))
     (write-string (make-string ind #\space) out)
     (write-string "]" out)]
    [else (write-json x out)]))

;; Write JSON to stdout. Pretty-print when --pretty was passed or stdout is a
;; TTY (matches cli.py emit()).
(define (emit obj #:pretty? [pretty? #f])
  (define out (current-output-port))
  (if (or pretty? (terminal-port? out))
      (write-json-pretty obj out 0)
      (write-json obj out))
  (newline out))

;; Print an error to stderr and exit non-zero. Doesn't return.
(define (fail msg #:code [code 1])
  (eprintf "error: ~a\n" msg)
  (exit code))

;; ---- arg helpers + dispatch ------------------------------------------------

;; --pretty may appear before or after the subcommand (like argparse parents).
(define (pretty-from-args? args)
  (and (member "--pretty" args) #t))

;; Wrap a thunk with the same exit semantics as cli.py run(): intercept
;; --version/-V up front, map Ctrl-C to 130, and turn uncaught errors into a
;; friendly stderr line + exit 1.
(define (run prog thunk)
  (define args (vector->list (current-command-line-arguments)))
  (when (or (member "--version" args) (member "-V" args))
    (printf "~a ~a\n" prog version)
    (exit 0))
  (with-handlers ([exn:break? (lambda (_) (eprintf "interrupted\n") (exit 130))]
                  [exn:fail?  (lambda (e) (fail (exn-message e)))])
    (thunk)
    (exit 0)))
