#lang racket/base

;; core/db.rkt — SQLite access for the port, resolving the same DATABASE_URL the
;; Python app uses (core/database.py). Shared by every DB-backed CLI
;; (signature now; notes/tasks/sessions/contacts/memory later).
;;
;; Only SQLite is supported so far — that's the Odysseus default
;; (sqlite:///./data/app.db). Postgres/MySQL would be added here when needed.

(require db
         racket/string
         "../cli/common.rkt")

(provide database-url sqlite-path open-db call-with-db)

(define default-url "sqlite:///./data/app.db")

(define (database-url)
  (or (getenv "DATABASE_URL") default-url))

;; Resolve DATABASE_URL to a filesystem path, mirroring core/database.py's
;; `DATABASE_URL.replace("sqlite:///", "")`. Relative paths resolve against the
;; repo root (CLIs run from there), so the CLI finds the same db.sqlite the app does.
(define (sqlite-path)
  (define url (database-url))
  (unless (string-prefix? url "sqlite:")
    (fail (format "only sqlite DATABASE_URL is supported so far, got: ~a" url)))
  (define raw (regexp-replace #rx"^sqlite:///" url ""))   ; "./data/app.db" or "/abs/app.db"
  (if (string-prefix? raw "/")
      (string->path raw)
      (simplify-path (build-path repo-root raw))))

;; Open the app's SQLite db. Fails clearly if it doesn't exist yet rather than
;; silently creating an empty one.
(define (open-db #:mode [mode 'read/write])
  (define p (sqlite-path))
  (unless (file-exists? p)
    (fail (format "database not found at ~a (start the app once to create it)" p)))
  (sqlite3-connect #:database p #:mode mode))

;; Run proc with an open connection, always disconnecting afterward.
(define (call-with-db proc #:mode [mode 'read/write])
  (define conn (open-db #:mode mode))
  (dynamic-wind void
                (lambda () (proc conn))
                (lambda () (disconnect conn))))
