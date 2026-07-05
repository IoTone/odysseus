#lang racket/base

;; domain/util.rkt — small shared helpers for the DB-backed agent tools:
;; jsexpr access with Python .get() semantics, Python truthiness, uuid4, and
;; SQLAlchemy-style timestamps. Used by domain/{notes,tasks}.rkt.

(require racket/string racket/random)

(provide jget jtruthy id8 uuid4 now-stamp)

(define (jget a k)                       ; args.get(k): missing/json-null -> #f
  (let ([v (hash-ref a k #f)]) (if (eq? v 'null) #f v)))

(define (jtruthy v)                      ; Python truthiness over jsexpr values
  (cond [(or (eq? v #f) (eq? v 'null)) #f]
        [(and (string? v) (string=? v "")) #f]
        [(and (number? v) (zero? v)) #f]
        [(and (list? v) (null? v)) #f]
        [else #t]))

(define (id8 id) (substring id 0 (min 8 (string-length id))))

(define (uuid4)
  (define b (bytes-copy (crypto-random-bytes 16)))
  (bytes-set! b 6 (bitwise-ior (bitwise-and (bytes-ref b 6) #x0f) #x40))
  (bytes-set! b 8 (bitwise-ior (bitwise-and (bytes-ref b 8) #x3f) #x80))
  (define hex (apply string-append (for/list ([x (in-bytes b)])
                                     (if (< x 16) (format "0~x" x) (format "~x" x)))))
  (string-append (substring hex 0 8) "-" (substring hex 8 12) "-" (substring hex 12 16)
                 "-" (substring hex 16 20) "-" (substring hex 20 32)))

(define (now-stamp)                      ; SQLAlchemy-style "YYYY-MM-DD HH:MM:SS.ffffff" (UTC)
  (define d (seconds->date (current-seconds) #f))
  (define (p2 n) (if (< n 10) (format "0~a" n) (number->string n)))
  (format "~a-~a-~a ~a:~a:~a.000000" (date-year d) (p2 (date-month d)) (p2 (date-day d))
          (p2 (date-hour d)) (p2 (date-minute d)) (p2 (date-second d))))
