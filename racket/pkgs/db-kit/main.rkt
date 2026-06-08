#lang racket/base

;; db-kit — turn a SQLAlchemy-style sqlite DATABASE_URL into a Racket `db`
;; connection. App-agnostic; raises plain `error` on problems so the caller's
;; own error handling (e.g. cli-kit's run harness) can present it.
;;
;;   (require db-kit)
;;   (call-with-sqlite (sqlite-path "sqlite:///./data/app.db" #:base-dir root)
;;                     (lambda (c) (query-rows c "SELECT 1")))
;;
;; Only sqlite is handled (the Odysseus default). Postgres/MySQL would extend
;; this package, not the app.

(require db racket/string)

(provide sqlite-path open-sqlite call-with-sqlite)

;; Resolve a sqlite URL to a filesystem path, mirroring SQLAlchemy /
;; core/database.py's `DATABASE_URL.replace("sqlite:///", "")`. Relative paths
;; resolve against base-dir.
(define (sqlite-path url #:base-dir [base-dir (current-directory)])
  (unless (string-prefix? url "sqlite:")
    (error 'sqlite-path "only sqlite URLs are supported, got: ~a" url))
  (define raw (regexp-replace #rx"^sqlite:///" url ""))   ; "./data/app.db" | "/abs/app.db"
  (if (string-prefix? raw "/")
      (string->path raw)
      (simplify-path (build-path base-dir raw))))

;; Open the db. By default fails loudly if it doesn't exist rather than silently
;; creating an empty one (#:create-missing? #t to allow creation).
(define (open-sqlite path #:mode [mode 'read/write] #:create-missing? [create? #f])
  (unless (or create? (file-exists? path))
    (error 'open-sqlite "database not found at ~a" path))
  (sqlite3-connect #:database path #:mode mode))

(define (call-with-sqlite path proc
                          #:mode [mode 'read/write]
                          #:create-missing? [create? #f])
  (define conn (open-sqlite path #:mode mode #:create-missing? create?))
  (dynamic-wind void
                (lambda () (proc conn))
                (lambda () (disconnect conn))))
