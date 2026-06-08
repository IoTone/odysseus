#lang racket/base

;; server/main.rkt — minimal Racket web-server.
;;
;; This is the strangler-fig seed: a tiny HTTP service that will sit alongside
;; the Python FastAPI app behind a reverse proxy, taking over routes one at a
;; time. For now it serves a single health endpoint so we can prove the server,
;; JSON, and packaging story end-to-end.
;;
;;   racket server/main.rkt                 # serve on 127.0.0.1:8099
;;   racket server/main.rkt --port 8100
;;
;;   curl localhost:8099/health  -> {"status":"ok","service":"odysseus-racket",...}

(require web-server/servlet-env
         web-server/http
         net/url
         json
         racket/cmdline
         racket/string
         "../cli/common.rkt")

(define (json-response jsx #:code [code 200])
  (response/output
   #:code code
   #:mime-type #"application/json; charset=utf-8"
   (lambda (out) (write-json jsx out))))

(define (request-path req)
  (map path/param-path (url-path (request-uri req))))

(define (handle req)
  (case (request-path req)
    [(("health"))
     (json-response (hasheq 'status  "ok"
                            'service "odysseus-racket"
                            'version version))]
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
   #:args ()
   (void))
  (printf "odysseus-racket server ~a listening on http://127.0.0.1:~a\n"
          version port)
  (serve/servlet handle
                 #:servlet-regexp #rx""        ; route everything to handle
                 #:port port
                 #:listen-ip "127.0.0.1"
                 #:command-line? #t))           ; don't pop a browser
