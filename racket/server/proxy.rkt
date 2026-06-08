#lang racket/base

;; server/proxy.rkt — strangler-fig reverse proxy in front of the app.
;;
;; Routes migrated paths to the Racket server and everything else to the real
;; Python FastAPI app (`uvicorn app:app`, default port 7000). Flip routes over
;; one at a time by adding to `racket-prefixes`; clients never notice.
;;
;;   # terminal 1: the real app
;;   .venv/bin/uvicorn app:app --port 7000
;;   # terminal 2: the migrated routes
;;   racket racket/server/main.rkt --port 8099
;;   # terminal 3: the proxy (front door)
;;   racket racket/server/proxy.rkt --port 8080
;;
;;   PYTHON_UPSTREAM / RACKET_UPSTREAM override the defaults.
;;
;; It forwards method, path+query, request headers, and body; and returns the
;; upstream status, headers, and body. (Production: a real proxy/Caddy —
;;   :8080 { handle /api/notes* /api/sessions* { reverse_proxy 127.0.0.1:8099 }
;;           handle { reverse_proxy 127.0.0.1:7000 } }
;; — but this is enough to drive a live migration.)

(require racket/cmdline
         racket/string
         racket/port
         net/http-client
         net/url
         web-server/servlet-env
         web-server/http)

(define (env-upstream name default)
  (define parts (string-split (or (getenv name) default) ":"))
  (values (car parts) (string->number (cadr parts))))

(define-values (py-host py-port)  (env-upstream "PYTHON_UPSTREAM" "127.0.0.1:7000"))
(define-values (rkt-host rkt-port) (env-upstream "RACKET_UPSTREAM" "127.0.0.1:8099"))

;; Paths the Racket server has taken over. Config-driven so flipping a route is
;; ops, not a code change: RACKET_PREFIXES="/api/notes,/api/foo". Default is only
;; the verified drop-in (/api/notes). NOTE: /api/sessions is deliberately NOT here
;; — it's not a web drop-in yet (SessionManager-coupled). See PORTING_PLAN.
(define racket-prefixes
  (let ([v (getenv "RACKET_PREFIXES")])
    (if (and v (not (string=? v ""))) (map string-trim (string-split v ",")) '("/api/notes"))))

(define (pick path)
  (if (for/or ([p (in-list racket-prefixes)]) (string-prefix? path p))
      (values rkt-host rkt-port "racket")
      (values py-host py-port "python")))

;; Headers we must not pass through (recomputed by the transport / per-hop).
(define hop-by-hop
  '("host" "content-length" "connection" "keep-alive" "transfer-encoding"
    "upgrade" "te" "trailers" "proxy-authorization" "proxy-authenticate"))
(define (drop? name) (member (string-downcase name) hop-by-hop))

(define (request-headers->forward req)
  (for/list ([h (in-list (request-headers/raw req))]
             #:unless (drop? (bytes->string/utf-8 (header-field h))))
    (bytes-append (header-field h) #": " (header-value h))))

;; upstream response header bytes ("Key: value") -> web-server header structs,
;; minus hop-by-hop (we send a full body, so let web-server frame it).
(define (response-headers hdrs)
  (for*/list ([h (in-list hdrs)]
              [m (in-value (regexp-match #px#"^([^:]+):[ \t]*(.*)$" h))]
              #:when (and m (not (drop? (bytes->string/utf-8 (cadr m))))))
    (make-header (cadr m) (caddr m))))

(define (status-line->code line)
  (define m (regexp-match #px#"\\b([0-9]{3})\\b" line))
  (if m (string->number (bytes->string/utf-8 (cadr m))) 502))

(define (handle req)
  (define path+q (let ([s (url->string (request-uri req))])
                   (if (string-prefix? s "/") s (string-append "/" s))))
  (define-values (host port who) (pick path+q))
  (with-handlers ([exn:fail? (lambda (e)
                               (response/output #:code 502 #:mime-type #"application/json"
                                 (lambda (o) (write-string
                                              (format "{\"error\":\"upstream ~a unreachable: ~a\"}"
                                                      who (exn-message e)) o))))])
    (define-values (status hdrs body-in)
      (http-sendrecv host path+q
                     #:port port
                     #:method (request-method req)
                     #:headers (request-headers->forward req)
                     #:data (request-post-data/raw req)))
    (define body (port->bytes body-in))
    (response/output #:code (status-line->code status)
                     #:headers (response-headers hdrs)
                     #:mime-type #f
                     (lambda (o) (write-bytes body o)))))

(module+ main
  (define port 8080)
  (command-line #:program "odysseus-proxy"
                #:once-each [("--port") p "Listen port (default 8080)" (set! port (string->number p))]
                #:args () (void))
  (printf "strangler proxy :~a → racket ~a:~a ~a · python ~a:~a (rest)\n"
          port rkt-host rkt-port racket-prefixes py-host py-port)
  (serve/servlet handle #:servlet-regexp #rx"" #:port port #:listen-ip "127.0.0.1" #:command-line? #t))
