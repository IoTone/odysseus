#lang racket/base

;; server/main.rkt — minimal Racket web-server (strangler-fig seed).
;;
;; Sits alongside the Python app behind a reverse proxy, taking over routes one
;; at a time. HTTP plumbing comes from the web-kit package; only the routes are
;; app code. Async/event handling is the Racket runtime's — see
;; concurrency-demo.rkt (no libuv/FFI needed).
;;
;;   racket server/main.rkt --port 8099
;;   curl localhost:8099/health  -> {"status":"ok","service":"odysseus-racket",...}

(require racket/cmdline
         racket/string
         web-kit
         "../config.rkt")

(define (handle req)
  (case (request-path req)
    [(("health"))
     (json-response (hasheq 'status  "ok"
                            'service "odysseus-racket"
                            'version app-version))]
    [else
     (json-response (hasheq 'error "not found"
                            'path  (string-join (request-path req) "/"))
                    #:code 404)]))

(module+ main
  (define port 8099)
  (command-line
   #:program "odysseus-server"
   #:once-each
   [("--port") p "Port to listen on (default 8099)"
               (set! port (string->number p))]
   #:args () (void))
  (printf "odysseus-racket server ~a listening on http://127.0.0.1:~a\n"
          app-version port)
  (serve handle #:port port))
