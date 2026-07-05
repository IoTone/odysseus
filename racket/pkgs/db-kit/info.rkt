#lang info

;; db-kit — generic SQLAlchemy-style DATABASE_URL → connection helpers.
;; Standalone Racket package; no Odysseus knowledge.
(define collection "db-kit")
(define version "0.1.0")
(define deps '("base" "db-lib"))
(define pkg-desc "Resolve sqlite DATABASE_URLs and open connections")
