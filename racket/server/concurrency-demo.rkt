#lang racket/base

;; concurrency-demo.rkt — proof that Racket already has the async/event model
;; we'd otherwise reach for libuv to get. No FFI, no native C dep, no
;; OS-thread-per-connection.
;;
;; Racket (CS) runs M green threads over its own evented scheduler: blocking
;; I/O (TCP read/write, sleep) parks the *green* thread and lets the scheduler
;; run others on the SAME OS thread — exactly what uvloop/libuv does for
;; asyncio/ASGI, but native to the runtime and portable everywhere Racket runs.
;;
;;   racket server/concurrency-demo.rkt
;;
;; If this were thread-per-OS-thread or blocking, N connections each waiting
;; DELAY seconds would take ~N*DELAY. Evented, it takes ~DELAY.

(require racket/tcp)

(define PORT  8231)
(define DELAY 0.5)   ; each handler simulates 0.5s of downstream I/O (e.g. an LLM call)
(define N     40)    ; concurrent connections

;; --- server: one green thread per connection, single OS thread --------------
(define listener (tcp-listen PORT 128 #t "127.0.0.1"))
(define accept-thd
  (thread
   (lambda ()
     (let loop ()
       (define-values (in out) (tcp-accept listener))
       (thread
        (lambda ()
          (read-line in)            ; await request (parks green thread)
          (sleep DELAY)             ; await "downstream I/O" (parks green thread)
          (fprintf out "HTTP/1.0 200 OK\r\n\r\nok\r\n")
          (flush-output out)
          (close-input-port in)
          (close-output-port out)))
       (loop)))))

;; --- fire N clients at once -------------------------------------------------
(define start (current-inexact-milliseconds))
(define clients
  (for/list ([i (in-range N)])
    (thread
     (lambda ()
       (define-values (in out) (tcp-connect "127.0.0.1" PORT))
       (fprintf out "GET /~a\r\n" i)
       (flush-output out)
       (read-line in)
       (close-input-port in)
       (close-output-port out)))))
(for-each thread-wait clients)
(define secs (/ (- (current-inexact-milliseconds) start) 1000.0))

(define (r2 x) (/ (round (* x 100)) 100.0))
(printf "~a concurrent connections, each waiting ~as of I/O\n" N DELAY)
(printf "  wall-clock : ~as\n" (r2 secs))
(printf "  sequential : ~as  (N x DELAY)\n" (r2 (* N DELAY)))
(printf "  speedup    : ~ax on 1 OS thread (1 Racket place)\n" (r2 (/ (* N DELAY) secs)))
(printf "=> Racket's native green-thread + evented I/O scheduler IS the async\n")
(printf "   model. No libuv, no FFI, no per-platform C build.\n")
(tcp-close listener)
