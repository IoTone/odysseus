#lang racket/base

;; racket/test/run-tests.rkt — portable behavior tests for the ported CLIs.
;;
;; Pure Racket (rackunit + subprocess), so it runs identically on Linux, macOS,
;; and Windows — no bash/PowerShell/Python needed. CI runs this on every
;; platform agent. Python-vs-Racket *fidelity* diffs (which need the app venv)
;; live in ci/fidelity.sh and run on the Linux agent only.
;;
;;   racket test/run-tests.rkt        # from the racket/ dir

(require rackunit
         rackunit/text-ui
         racket/system
         racket/port
         racket/file
         json
         db)

(define racket-bin (find-executable-path "racket"))
;; tests are run from the racket/ dir, so CLI sources are under cli/
(define (cli name) (path->string (build-path "cli" name)))

;; Run a CLI source file with args + env; return (values exit-code stdout-string).
(define (run-cli src args #:env [env '()])
  (define out (open-output-string))
  (define code
    (parameterize ([current-output-port out]
                   [current-error-port (open-output-nowhere)]
                   [current-environment-variables
                    (let ([e (environment-variables-copy (current-environment-variables))])
                      (for ([kv (in-list env)])
                        (environment-variables-set! e (string->bytes/utf-8 (car kv))
                                                   (string->bytes/utf-8 (cdr kv))))
                      e)])
      (apply system*/exit-code racket-bin src args)))
  (values code (get-output-string out)))

(define (run-json src args #:env [env '()])
  (define-values (code out) (run-cli src args #:env env))
  (check-equal? code 0 (format "~a ~a exited ~a" src args code))
  (string->jsexpr out))

;; ---- fixtures --------------------------------------------------------------

(define tmp (make-temporary-file "odyrkt~a" 'directory))
(define data-dir (build-path tmp "data"))
(make-directory* data-dir)
(define db-path (build-path tmp "app.db"))
(define env-data (list (cons "ODYSSEUS_DATA_DIR" (path->string data-dir))))
(define env-db (list (cons "DATABASE_URL"
                           (string-append "sqlite:///" (path->string db-path)))))

(define (seed-db!)
  (define c (sqlite3-connect #:database db-path #:mode 'create))
  (query-exec c "DROP TABLE IF EXISTS signatures")
  (query-exec c (string-append
                 "CREATE TABLE signatures(id TEXT PRIMARY KEY, owner TEXT, name TEXT, "
                 "width INTEGER, height INTEGER, data_png TEXT, svg TEXT, created_at TEXT)"))
  ;; a real 1x1 PNG as a data URL
  (define png-data-url
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=")
  (query-exec c "INSERT INTO signatures VALUES(?,?,?,?,?,?,?,?)"
              "sig1" "alice" "Alice" 200 80 png-data-url "<svg/>" "2026-01-02T03:04:05")
  (query-exec c "INSERT INTO signatures VALUES(?,?,?,?,?,?,?,?)"
              "sig2" sql-null "NoOwner" 100 40 png-data-url sql-null "2026-02-02T00:00:00")
  (disconnect c))

;; ---- tests -----------------------------------------------------------------

(define suite
  (test-suite "ported CLIs"

    (test-case "odysseus-logs --version"
      (define-values (code out) (run-cli (cli "odysseus-logs.rkt") '("--version")))
      (check-equal? code 0)
      (check-true (regexp-match? #rx"odysseus-logs 0\\.1\\.0" out)))

    (test-case "odysseus-preset round-trip (set/get/list/delete)"
      (run-json (cli "odysseus-preset.rkt")
                '("set" "coder" "--temperature" "0.3" "--prompt" "Write code." "--display-name" "Coder")
                #:env env-data)
      (define got (run-json (cli "odysseus-preset.rkt") '("get" "coder") #:env env-data))
      (check-equal? (hash-ref got 'id) "coder")
      (check-equal? (hash-ref got 'name) "Coder")
      (check-equal? (hash-ref got 'system_prompt) "Write code.")
      (define lst (run-json (cli "odysseus-preset.rkt") '("list") #:env env-data))
      (check-equal? (length lst) 1)
      (check-equal? (hash-ref (car lst) 'prompt_length) 11)  ; (string-length "Write code.")
      (define del (run-json (cli "odysseus-preset.rkt") '("delete" "coder") #:env env-data))
      (check-equal? (hash-ref del 'ok) #t)
      (check-equal? (length (run-json (cli "odysseus-preset.rkt") '("list") #:env env-data)) 0))

    (test-case "odysseus-signature list/show/export/delete"
      (seed-db!)
      (define lst (run-json (cli "odysseus-signature.rkt") '("list") #:env env-db))
      (check-equal? (map (lambda (r) (hash-ref r 'id)) lst) '("sig2" "sig1")) ; created_at DESC
      (define s2 (car lst))
      (check-equal? (hash-ref s2 'owner) "")        ; null owner -> ""
      (check-equal? (hash-ref s2 'has_svg) #f)      ; null svg
      (define sig1-show (run-json (cli "odysseus-signature.rkt") '("show" "sig1") #:env env-db))
      (check-equal? (hash-ref sig1-show 'has_svg) #t)
      (define out-png (build-path tmp "out.png"))
      (define exp (run-json (cli "odysseus-signature.rkt")
                            (list "export" "sig1" "--png" (path->string out-png)) #:env env-db))
      (check-equal? (hash-ref exp 'ok) #t)
      (check-true (file-exists? out-png))
      (check-true (>= (file-size out-png) 8))       ; has PNG header at least
      (run-json (cli "odysseus-signature.rkt") '("delete" "sig2") #:env env-db)
      (check-equal? (length (run-json (cli "odysseus-signature.rkt") '("list") #:env env-db)) 1)
      ;; deleting a missing id is a clean non-zero exit
      (define-values (code _o) (run-cli (cli "odysseus-signature.rkt") '("delete" "nope") #:env env-db))
      (check-equal? code 1))))

(module+ main
  (define n (run-tests suite))
  (delete-directory/files tmp #:must-exist? #f)
  (exit (if (= n 0) 0 1)))
