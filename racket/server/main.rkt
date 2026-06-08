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
         net/url
         web-server/http       ; request-uri (web-kit provides only json-response/request-path/serve)
         web-kit
         "../domain/notes.rkt"      ; web shape matches routes/note_routes.py (strangler-fig)
         "../domain/sessions.rkt"
         "../config.rkt")

;; Real DB-backed routes taken over from FastAPI. Each shares its domain module
;; with the corresponding CLI, so HTTP and CLI can't drift. The reverse-proxy
;; split lives in server/proxy.rkt (PORTING_PLAN "Phase 3").
(define (db-route thunk)
  (with-handlers ([exn:fail? (lambda (e)
                               (json-response (hasheq 'error (exn-message e)) #:code 500))])
    (json-response (call-with-app-db #:mode 'read-only thunk))))

(define (query-ref req key)
  (cond [(assq key (url-query (request-uri req))) => cdr] [else #f]))

;; Identity is resolved by an upstream auth tier and passed as a trusted header
;; (X-Odysseus-User) — we don't re-implement cookie/session auth here. Absent
;; header = no owner filter (matches AUTH_ENABLED=false). See PORTING_PLAN.
(define (header-ref req name)
  (define v (for/or ([h (in-list (request-headers/raw req))])
              (and (string-ci=? (bytes->string/utf-8 (header-field h)) name) (header-value h))))
  (and v (let ([s (bytes->string/utf-8 v)]) (and (not (string=? s "")) s))))

;; GET /api/notes[?archived=true][&label=...] — drop-in for the FastAPI route.
(define (api-notes req)
  (define archived? (equal? (query-ref req 'archived) "true"))
  (define label (let ([l (query-ref req 'label)]) (and l (not (equal? l "")) l)))
  (define owner (header-ref req "x-odysseus-user"))
  (db-route (lambda (c) (list-notes-web c #:archived? archived? #:label label #:owner owner))))

(define (handle req)
  (case (request-path req)
    [(("health"))
     (json-response (hasheq 'status  "ok"
                            'service "odysseus-racket"
                            'version app-version))]
    [(("api" "notes"))    (api-notes req)]
    ;; NOT a web drop-in: the real /api/sessions reads the in-memory SessionManager
    ;; + joins docs/gallery + masks model names. Kept as a CLI-shape convenience;
    ;; do NOT route it through the proxy until reworked. See PORTING_PLAN.
    [(("api" "sessions")) (db-route list-sessions)]
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
