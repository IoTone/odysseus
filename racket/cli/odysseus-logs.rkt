#lang racket/base

;; odysseus-logs — unified view of log files across the app.
;;
;; Faithful Racket port of scripts/odysseus-logs (the first CLI ported off
;; Python — chosen because it is filesystem-only: no DB, no HTTP, pure stdlib).
;;
;;   odysseus-logs list                    # every log we know about
;;   odysseus-logs tail NAME               # tail -f a specific log
;;   odysseus-logs tail NAME -n 200        # last N lines only (no follow)
;;   odysseus-logs cat NAME                # print full content
;;   odysseus-logs clean                   # delete tmux logs older than 7 days
;;
;; Logs live in two places, mirroring the Python tool:
;;   <repo>/logs/                  app-level
;;   /tmp/odysseus-tmux/*.log      per-tmux-session download/serve logs

(require racket/date
         racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         racket/system
         cli-kit
         "../config.rkt")

(define app-logs  (build-path repo-root "logs"))
(define tmux-logs (string->path "/tmp/odysseus-tmux"))

;; ---- helpers ---------------------------------------------------------------

(define (pad-left n width)
  (define s (number->string n))
  (if (>= (string-length s) width) s
      (string-append (make-string (- width (string-length s)) #\0) s)))
(define (pad2 n) (pad-left n 2))

;; Local-time ISO-8601 matching Python's datetime.fromtimestamp(...).isoformat():
;; seconds always shown; fractional part appended as 6-digit microseconds only
;; when nonzero. Uses nanosecond-resolution stat so it matches the Python tool
;; byte-for-byte.
(define (iso-of p)
  (define ns (hash-ref (file-or-directory-stat p) 'modify-time-nanoseconds))
  (define secs (quotient ns 1000000000))
  (define usec (quotient (remainder ns 1000000000) 1000))
  (define d (seconds->date secs #t))
  (define base
    (format "~a-~a-~aT~a:~a:~a"
            (date-year d) (pad2 (date-month d)) (pad2 (date-day d))
            (pad2 (date-hour d)) (pad2 (date-minute d)) (pad2 (date-second d))))
  (if (zero? usec) base (string-append base "." (pad-left usec 6))))

(define (log-file? p)
  (regexp-match? #rx"\\.log$" (path->string p)))

;; Every *.log under either base dir, as a list of paths.
(define (all-logs)
  (for*/list ([base (in-list (list app-logs tmux-logs))]
              #:when (directory-exists? base)
              [p (in-list (directory-list base #:build? #t))]
              #:when (log-file? p))
    p))

(define (entry p)
  (hasheq 'name     (path->string (file-name-from-path p))
          'path     (path->string p)
          'bytes    (file-size p)
          'modified (iso-of p)))

;; Match a log by exact filename, basename-without-.log, or substring.
;; Returns the most-recently-modified match, or #f.
(define (resolve name)
  (define cands
    (for/list ([p (in-list (all-logs))]
               #:when (let* ([nm (path->string (file-name-from-path p))]
                             [stem (regexp-replace #rx"\\.log$" nm "")])
                        (or (string=? nm name)
                            (string=? stem name)
                            (string-contains? nm name))))
      p))
  (cond [(null? cands) #f]
        [else (first (sort cands > #:key file-or-directory-modify-seconds))]))

;; ---- subcommands -----------------------------------------------------------

(define (cmd-list pretty?)
  (define entries (map entry (all-logs)))
  ;; modified is ISO → string sort desc is chronological desc.
  (emit (sort entries string>? #:key (lambda (e) (hash-ref e 'modified)))
        #:pretty? pretty?))

(define (cmd-tail name lines follow?)
  (define p (resolve name))
  (unless p (fail (format "no log matching ~s; run `odysseus-logs list`" name)))
  (define tail (find-executable-path "tail"))
  (unless tail (fail "`tail` not found on PATH"))
  ;; system* inherits stdout; for --follow it blocks like `tail -f`.
  (define code
    (apply system*/exit-code tail
           (append (list "-n" (number->string lines))
                   (if follow? '("-f") '())
                   (list (path->string p)))))
  (exit code))

(define (cmd-cat name)
  (define p (resolve name))
  (unless p (fail (format "no log matching ~s" name)))
  ;; Copy raw bytes through so undecodable content can't crash us
  ;; (Python used read_text(errors="replace")).
  (call-with-input-file p
    (lambda (in) (copy-port in (current-output-port)))))

(define (cmd-clean days pretty?)
  (cond
    [(not (directory-exists? tmux-logs))
     (emit (hasheq 'deleted '() 'kept 0) #:pretty? pretty?)]
    [else
     (define cutoff (- (current-seconds) (* days 86400)))
     (define deleted '())
     (define kept 0)
     (for ([p (in-list (directory-list tmux-logs #:build? #t))]
           #:when (log-file? p))
       (cond
         [(< (file-or-directory-modify-seconds p) cutoff)
          (delete-file p)
          (set! deleted (cons (path->string (file-name-from-path p)) deleted))]
         [else (set! kept (add1 kept))]))
     (emit (hasheq 'deleted (reverse deleted) 'kept kept 'cutoff_days days)
           #:pretty? pretty?)]))

;; ---- arg parsing -----------------------------------------------------------

(define (parse-tail cargs)
  (let loop ([xs cargs] [name #f] [lines 80] [follow #f])
    (cond
      [(null? xs) (values name lines follow)]
      [(member (car xs) '("-n" "--lines"))
       (when (null? (cdr xs)) (fail "expected a number after -n/--lines" #:code 2))
       (define n (string->number (cadr xs)))
       (unless (exact-integer? n) (fail "-n/--lines wants an integer" #:code 2))
       (loop (cddr xs) name n follow)]
      [(member (car xs) '("-f" "--follow")) (loop (cdr xs) name lines #t)]
      [else (loop (cdr xs) (or name (car xs)) lines follow)])))

(define (parse-clean cargs)
  (let loop ([xs cargs] [days 7])
    (cond
      [(null? xs) days]
      [(string=? (car xs) "--days")
       (when (null? (cdr xs)) (fail "expected a number after --days" #:code 2))
       (define n (string->number (cadr xs)))
       (unless (exact-integer? n) (fail "--days wants an integer" #:code 2))
       (loop (cddr xs) n)]
      [else (loop (cdr xs) days)])))

(define (dispatch)
  (define args (vector->list (current-command-line-arguments)))
  (define pretty? (pretty-from-args? args))
  ;; strip --pretty so it works before OR after the subcommand
  (define rest (filter (lambda (a) (not (string=? a "--pretty"))) args))
  (when (null? rest) (fail "missing subcommand: list|tail|cat|clean" #:code 2))
  (define cmd (car rest))
  (define cargs (cdr rest))
  (case cmd
    [("list") (cmd-list pretty?)]
    [("tail")
     (define-values (name lines follow) (parse-tail cargs))
     (unless name (fail "tail needs a log NAME" #:code 2))
     (cmd-tail name lines follow)]
    [("cat")
     (when (null? cargs) (fail "cat needs a log NAME" #:code 2))
     (cmd-cat (car cargs))]
    [("clean") (cmd-clean (parse-clean cargs) pretty?)]
    [else (fail (format "unknown subcommand: ~a" cmd) #:code 2)]))

(module+ main
  (run "odysseus-logs" app-version dispatch))
