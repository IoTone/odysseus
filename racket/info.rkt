#lang info

;; Package metadata for the Racket port of Odysseus.
;; Mirrors the role of requirements.txt / pyproject.toml on the Python side.
;;
;;   raco pkg install --auto    # from this directory, pulls deps
;;   raco make cli/*.rkt server/*.rkt   # byte-compile
;;   raco exe cli/odysseus-logs.rkt     # standalone binary (the packaging win)

(define collection "odysseus")
(define version "0.1.0")

;; Runtime deps. base/json are in minimal-racket already; the rest are the
;; packages we `raco pkg install`'d. Keep this list in sync as the port grows.
(define deps
  '("base"
    "web-server-lib"
    "db-lib"))

(define build-deps
  '("racket-doc"))

(define pkg-desc "Odysseus — Racket port (backend + CLIs)")
