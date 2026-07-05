#lang racket/base

;; config.rkt — Odysseus-app-specific glue that the generic kits deliberately
;; don't know about: where the repo/data live, the app version, and how to open
;; THIS app's database. Everything reusable lives in the cli-kit/db-kit/web-kit
;; packages under pkgs/; this is the only app-branded shared module.

(require racket/runtime-path
         db-kit)

(provide app-version repo-root data-dir database-url call-with-app-db)

(define app-version "0.1.0")

;; This file lives at <repo>/racket/config.rkt → repo root is one dir up.
(define-runtime-path here ".")
(define repo-root (simplify-path (build-path here 'up)))

;; App data dir (presets.json, etc.); ODYSSEUS_DATA_DIR overrides for tests/CI.
(define (data-dir)
  (define e (getenv "ODYSSEUS_DATA_DIR"))
  (if (and e (not (string=? e ""))) (string->path e) (build-path repo-root "data")))

;; Same default as core/database.py.
(define (database-url)
  (or (getenv "DATABASE_URL") "sqlite:///./data/app.db"))

;; Open the app db (relative URLs resolve against repo root, like the app).
(define (call-with-app-db proc #:mode [mode 'read/write])
  (call-with-sqlite (sqlite-path (database-url) #:base-dir repo-root) proc #:mode mode))
