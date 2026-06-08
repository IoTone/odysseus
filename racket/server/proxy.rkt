#lang racket/base

;; server/proxy.rkt — a minimal strangler-fig reverse proxy.
;;
;; Routes a few paths to the Racket server (routes already migrated) and
;; everything else to the Python FastAPI app. Flip routes over one at a time by
;; adding prefixes to `racket-prefixes`; the frontend never notices.
;;
;;   PYTHON_UPSTREAM=127.0.0.1:8000 RACKET_UPSTREAM=127.0.0.1:8099 \
;;     racket server/proxy.rkt --port 8080
;;
;; This is a deliberately small spike (forwards method, path+query, and body;
;; copies upstream status + content-type). For production prefer a real proxy —
;; the equivalent Caddy config is just:
;;
;;   :8080 {
;;     handle /api/notes*  { reverse_proxy 127.0.0.1:8099 }   # Racket
;;     handle              { reverse_proxy 127.0.0.1:8000 }   # Python/FastAPI
;;   }

(require racket/cmdline
         racket/string
         racket/port
         net/http-client
         net/url
         web-server/servlet-env
         web-server/http)

(define (env-upstream name default)
  (define v (or (getenv name) default))
  (define parts (string-split v ":"))
  (values (car parts) (string->number (cadr parts))))

(define-values (py-host py-port)  (env-upstream "PYTHON_UPSTREAM" "127.0.0.1:8000"))
(define-values (rkt-host rkt-port) (env-upstream "RACKET_UPSTREAM" "127.0.0.1:8099"))

;; Paths the Racket server has taken over (extend as routes migrate).
(define racket-prefixes '("/api/notes"))

(define (pick path)
  (if (for/or ([p (in-list racket-prefixes)]) (string-prefix? path p))
      (values rkt-host rkt-port "racket")
      (values py-host py-port "python")))

(define (status-line->code line)
  (define m (regexp-match #px#"\\b([0-9]{3})\\b" line))
  (if m (string->number (bytes->string/utf-8 (cadr m))) 502))

(define (content-type hdrs)
  (or (for/or ([h (in-list hdrs)])
        (and (regexp-match? #px#"(?i:^content-type:)" h)
             (string->bytes/utf-8 (string-trim (cadr (regexp-match #px"(?i:^content-type:)\\s*(.*)$"
                                                                   (bytes->string/utf-8 h)))))))
      #"application/octet-stream"))

(define (handle req)
  (define uri (request-uri req))
  (define path+q (let ([s (url->string uri)]) (if (string-prefix? s "/") s (string-append "/" s))))
  (define-values (host port who) (pick path+q))
  (with-handlers ([exn:fail? (lambda (e)
                               (response/output #:code 502 #:mime-type #"application/json"
                                 (lambda (o) (write-string (format "{\"error\":\"upstream ~a unreachable: ~a\"}"
                                                                   who (exn-message e)) o))))])
    (define-values (status hdrs body-in)
      (http-sendrecv host path+q
                     #:port port
                     #:method (request-method req)
                     #:data (request-post-data/raw req)))
    (define body (port->bytes body-in))
    (response/output #:code (status-line->code status) #:mime-type (content-type hdrs)
                     (lambda (o) (write-bytes body o)))))

(module+ main
  (define port 8080)
  (command-line #:program "odysseus-proxy"
                #:once-each [("--port") p "Listen port (default 8080)" (set! port (string->number p))]
                #:args () (void))
  (printf "strangler proxy on http://127.0.0.1:~a → racket ~a:~a (~a), python ~a:~a (rest)\n"
          port rkt-host rkt-port racket-prefixes py-host py-port)
  (serve/servlet handle #:servlet-regexp #rx"" #:port port #:listen-ip "127.0.0.1" #:command-line? #t))
