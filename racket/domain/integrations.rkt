#lang racket/base

;; domain/integrations.rkt — the integration-surface agent tools:
;; manage_endpoints, manage_mcp, manage_webhooks, manage_tokens. Ports of the
;; matching do_manage_* functions in src/tool_implementations.py.
;;
;; Runtime notes (each is Python's own fallback, not a stub):
;; - manage_mcp: every branch that needs the live MCP manager has an explicit
;;   no-manager path in Python (list → "No MCP manager available", add →
;;   "(0 tools)", reconnect → error). This CLI has no manager, so those paths
;;   ARE the faithful port.
;; - manage_endpoints add: api_key is stored as plaintext — core/database.py's
;;   EncryptedText explicitly supports legacy plaintext rows (read unchanged,
;;   encrypted by the Python side on its next write / startup migration).
;; - manage_tokens create: Python bcrypt-hashes the token and app.py verifies
;;   with bcrypt; Racket has no bundled bcrypt, so a token created here could
;;   never authenticate. create returns an actionable error instead.

(require db
         json
         net/dns
         racket/string
         racket/list
         db-kit
         "util.rkt")

(provide manage-endpoints manage-mcp manage-webhooks manage-tokens
         validate-webhook-url validate-events)   ; exported for tests

(define (err msg) (hasheq 'error msg 'exit_code 1))
(define (or-sql-null v) (if (eq? v #f) sql-null v))

(define (parse-args content)
  (with-handlers ([exn:fail? (lambda (_) 'bad)])
    (let ([v (string->jsexpr content)]) (if (hash? v) v (hasheq)))))

;; ---- manage_endpoints --------------------------------------------------------

(define (manage-endpoints conn content #:owner [owner #f])
  (define args (parse-args content))
  (cond
    [(eq? args 'bad) (err "Invalid JSON arguments")]
    [else
     (define action (or (jget args 'action) "list"))
     (with-handlers ([exn:fail? (lambda (e) (err (exn-message e)))])
       (case action
         [("list")
          (define items
            (for/list ([r (in-list (query-rows conn
                            "SELECT id, name, base_url, is_enabled FROM model_endpoints"))])
              (hasheq 'id (vector-ref r 0) 'name (sql-or-null (vector-ref r 1))
                      'base_url (sql-or-null (vector-ref r 2))
                      'is_enabled (sql->bool (vector-ref r 3)))))
          (hasheq 'response (format "~a endpoints" (length items)) 'endpoints items 'exit_code 0)]
         [("add")
          (define name (or (jget args 'name) ""))
          (define base-url (or (jget args 'base_url) ""))
          (cond
            [(not (jtruthy base-url)) (err "base_url is required")]
            [else
             (define eid (id8 (uuid4)))
             (define now (now-stamp))
             (query-exec conn
               (string-append "INSERT INTO model_endpoints(id, name, base_url, api_key,"
                              " is_enabled, created_at, updated_at) VALUES(?,?,?,?,1,?,?)")
               eid (if (jtruthy name) name base-url) base-url (or (jget args 'api_key) "") now now)
             (hasheq 'response (format "Added endpoint '~a' (id: ~a)"
                                       (if (jtruthy name) name base-url) eid)
                     'exit_code 0)])]
         [("delete")
          (define eid (or (jget args 'endpoint_id) ""))
          (define r (query-maybe-row conn "SELECT name FROM model_endpoints WHERE id = ?" eid))
          (cond
            [(not r) (err (format "Endpoint ~a not found" eid))]
            [else (query-exec conn "DELETE FROM model_endpoints WHERE id = ?" eid)
                  (hasheq 'response (format "Deleted endpoint '~a'" (sql-or-null (vector-ref r 0)))
                          'exit_code 0)])]
         [("enable" "disable")
          (define eid (or (jget args 'endpoint_id) ""))
          (define r (query-maybe-row conn "SELECT name FROM model_endpoints WHERE id = ?" eid))
          (cond
            [(not r) (err (format "Endpoint ~a not found" eid))]
            [else
             (query-exec conn "UPDATE model_endpoints SET is_enabled = ?, updated_at = ? WHERE id = ?"
                         (if (equal? action "enable") 1 0) (now-stamp) eid)
             (hasheq 'response (format "Endpoint '~a' ~ad" (sql-or-null (vector-ref r 0)) action)
                     'exit_code 0)])]
         [else (err (format "Unknown action: ~a" action))]))]))

;; ---- manage_mcp ----------------------------------------------------------------

(define (manage-mcp conn content #:owner [owner #f])
  (define args (parse-args content))
  (cond
    [(eq? args 'bad) (err "Invalid JSON arguments")]
    [else
     (define action (or (jget args 'action) "list"))
     (with-handlers ([exn:fail? (lambda (e) (err (exn-message e)))])
       (case action
         ;; no MCP manager in this CLI — Python's list doesn't even hit the DB then
         [("list") (hasheq 'response "No MCP manager available" 'servers '() 'exit_code 0)]
         [("add")
          (define name (or (jget args 'name) ""))
          (define command (or (jget args 'command) ""))
          (cond
            [(or (not (jtruthy name)) (not (jtruthy command)))
             (err "name and command are required")]
            [else
             (define cmd-args (let ([a (jget args 'args)]) (if (list? a) a (or a '()))))
             (define env (let ([e (jget args 'env)]) (if (hash? e) e (or e (hasheq)))))
             (define sid (id8 (uuid4)))
             (define now (now-stamp))
             (query-exec conn
               (string-append "INSERT INTO mcp_servers(id, name, transport, command, args, env,"
                              " is_enabled, created_at, updated_at) VALUES(?,?,'stdio',?,?,?,1,?,?)")
               sid name command
               (if (list? cmd-args) (jsexpr->string cmd-args) cmd-args)
               (if (hash? env) (jsexpr->string env) env)
               now now)
             ;; no manager → no connect attempt → 0 tools (Python's connect-failed path)
             (hasheq 'response (format "Added MCP server '~a' (0 tools)" name) 'exit_code 0)])]
         [("delete")
          (define sid (or (jget args 'server_id) ""))
          (define r (query-maybe-row conn "SELECT name FROM mcp_servers WHERE id = ?" sid))
          (cond
            [(not r) (err (format "Server ~a not found" sid))]
            [else (query-exec conn "DELETE FROM mcp_servers WHERE id = ?" sid)
                  (hasheq 'response (format "Deleted MCP server '~a'" (sql-or-null (vector-ref r 0)))
                          'exit_code 0)])]
         [("reconnect") (err "MCP manager not available")]
         [("enable" "disable")
          (define sid (or (jget args 'server_id) ""))
          (define r (query-maybe-row conn "SELECT name FROM mcp_servers WHERE id = ?" sid))
          (cond
            [(not r) (err (format "Server ~a not found" sid))]
            [else
             (query-exec conn "UPDATE mcp_servers SET is_enabled = ?, updated_at = ? WHERE id = ?"
                         (if (equal? action "enable") 1 0) (now-stamp) sid)
             (hasheq 'response (format "MCP server '~a' ~ad" (sql-or-null (vector-ref r 0)) action)
                     'exit_code 0)])]
         [("list_tools") (hasheq 'response "No MCP manager" 'tools '() 'exit_code 0)]
         [else (err (format "Unknown action: ~a" action))]))]))

;; ---- manage_webhooks -----------------------------------------------------------

(define allowed-events (list "session.created" "chat.completed" "chat.message" "webhook.test"))

;; validate_events port: comma-split, trim, all must be allowed; rejoin.
;; Returns the cleaned string or raises exn:fail with Python's message.
(define (validate-events events-str)
  (define events (filter (lambda (e) (not (string=? e "")))
                         (map string-trim (string-split (if (string? events-str) events-str "") ","))))
  (cond
    [(null? events) (error 'validate-events "At least one event is required")]
    [else
     (define invalid (sort (remove-duplicates (filter (lambda (e) (not (member e allowed-events))) events))
                           string<?))
     (unless (null? invalid)
       (error 'validate-events "Invalid events: ~a. Allowed: ~a"
              (string-join invalid ", ")
              (string-join (sort (remove "webhook.test" allowed-events) string<?) ", ")))
     (string-join events ",")]))

;; ---- private/internal address detection (the SSRF guard) ----------------------
;; Mirrors webhook_manager._ip_is_private over literal IPs; DNS hostnames are
;; resolved (one address via net/dns vs Python's every-record — the delivery
;; side re-validates with the full check) and unresolvable names fail closed.

(define (ipv4-octets s)
  (define m (regexp-match #px"^([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})$" s))
  (and m (let ([os (map string->number (cdr m))]) (and (andmap (lambda (o) (<= o 255)) os) os))))

(define (ipv4-private? os)
  (define a (car os)) (define b (cadr os))
  (or (= a 0) (= a 10) (= a 127)                               ; unspecified/private/loopback
      (and (= a 172) (<= 16 b 31)) (and (= a 192) (= b 168))   ; private
      (and (= a 169) (= b 254))                                ; link-local
      (and (= a 100) (<= 64 b 127))                            ; CGNAT (is_private in py>=3.11... kept: reserved-ish)
      (>= a 224)))                                             ; multicast + reserved

;; parse an IPv6 literal into 8 16-bit groups, or #f. Handles :: expansion and
;; a trailing IPv4-mapped dotted quad.
(define (ipv6-groups s0)
  (define s (string-downcase s0))
  (define (groups part) (if (string=? part "") '() (string-split part ":" #:trim? #f)))
  (define (parse-group g) (and (regexp-match? #px"^[0-9a-f]{1,4}$" g) (string->number g 16)))
  (define (expand-tail gs)            ; trailing dotted quad → two groups
    (cond [(null? gs) '()]
          [(ipv4-octets (last gs))
           => (lambda (os) (append (drop-right gs 1)
                                   (list (format "~x" (+ (* 256 (car os)) (cadr os)))
                                         (format "~x" (+ (* 256 (caddr os)) (cadddr os))))))]
          [else gs]))
  (define halves (regexp-split #rx"::" s))
  (cond
    [(> (length halves) 2) #f]
    [(= (length halves) 2)
     (define l (groups (car halves))) (define r (expand-tail (groups (cadr halves))))
     (define pad (- 8 (+ (length l) (length r))))
     (and (>= pad 0)
          (let ([all (append l (make-list pad "0") r)])
            (let ([ns (map parse-group all)]) (and (andmap values ns) ns))))]
    [else
     (define all (expand-tail (groups s)))
     (and (= (length all) 8)
          (let ([ns (map parse-group all)]) (and (andmap values ns) ns)))]))

(define (ipv6-private? gs)
  (define g0 (car gs))
  (cond
    ;; IPv4-mapped ::ffff:a.b.c.d → judge the embedded IPv4
    [(and (andmap zero? (take gs 5)) (= (list-ref gs 5) #xffff))
     (ipv4-private? (list (quotient (list-ref gs 6) 256) (remainder (list-ref gs 6) 256)
                          (quotient (list-ref gs 7) 256) (remainder (list-ref gs 7) 256)))]
    [(andmap zero? gs) #t]                                     ; ::  unspecified
    [(and (andmap zero? (take gs 7)) (= (last gs) 1)) #t]      ; ::1 loopback
    [(= (arithmetic-shift g0 -9) #b1111110) #t]                ; fc00::/7 ULA
    [(= (arithmetic-shift g0 -6) #b1111111010) #t]             ; fe80::/10 link-local
    [(= (arithmetic-shift g0 -8) #xff) #t]                     ; ff00::/8 multicast
    [else #f]))

(define (host-private? host)
  (cond
    [(ipv4-octets host) => ipv4-private?]
    [(ipv6-groups host) => ipv6-private?]
    [else                                  ; DNS name — resolve; fail closed
     (with-handlers ([exn:fail? (lambda (_) #t)])
       (define ip (dns-get-address (dns-find-nameserver) host))
       (cond [(ipv4-octets ip) => ipv4-private?]
             [(ipv6-groups ip) => ipv6-private?]
             [else #t]))]))

;; validate_webhook_url port. Returns the trimmed URL or raises with Python's message.
(define (validate-webhook-url url0)
  (define url (string-trim (if (string? url0) url0 "")))
  (when (> (string-length url) 2048) (error 'validate-webhook-url "URL too long (max 2048 characters)"))
  (define m (regexp-match #px"^([a-zA-Z][a-zA-Z0-9+.-]*)://(?:[^@/]*@)?(\\[[^]]+\\]|[^:/?#]*)" url))
  (define scheme (and m (string-downcase (cadr m))))
  (define host0 (and m (caddr m)))
  (define host (and host0 (if (and (string-prefix? host0 "[") (string-suffix? host0 "]"))
                              (substring host0 1 (sub1 (string-length host0)))
                              host0)))
  (unless (member scheme '("http" "https")) (error 'validate-webhook-url "URL must use http or https"))
  (unless (and host (not (string=? host ""))) (error 'validate-webhook-url "URL must have a hostname"))
  (when (host-private? host)
    (error 'validate-webhook-url "URL must not point to private/internal addresses"))
  url)

(define (manage-webhooks conn content #:owner [owner #f])
  (define args (parse-args content))
  (cond
    [(eq? args 'bad) (err "Invalid JSON arguments")]
    [else
     (define action (or (jget args 'action) "list"))
     (with-handlers ([exn:fail? (lambda (e) (err (exn-message e)))])
       (case action
         [("list")
          (define items
            (for/list ([r (in-list (query-rows conn
                            "SELECT id, name, url, events, is_active FROM webhooks"))])
              (hasheq 'id (vector-ref r 0) 'name (sql-or-null (vector-ref r 1))
                      'url (sql-or-null (vector-ref r 2)) 'events (sql-or-null (vector-ref r 3))
                      'is_active (sql->bool (vector-ref r 4)))))
          (hasheq 'response (format "~a webhooks" (length items)) 'webhooks items 'exit_code 0)]
         [("add")
          (define name (or (jget args 'name) ""))
          (define url0 (or (jget args 'url) ""))
          (cond
            [(not (jtruthy url0)) (err "url is required")]
            [else
             ;; validation errors carry Python's ValueError text
             (define-values (url events ok?)
               (with-handlers ([exn:fail? (lambda (e) (values (exn-message e) #f #f))])
                 (values (validate-webhook-url url0)
                         (validate-events (or (jget args 'events) "chat.completed"))
                         #t)))
             (cond
               [(not ok?) (err (strip-who url))]   ; url holds the validation error text
               [else
                (define wid (id8 (uuid4)))
                (define now (now-stamp))
                (query-exec conn
                  (string-append "INSERT INTO webhooks(id, name, url, events, is_active,"
                                 " created_at, updated_at) VALUES(?,?,?,?,1,?,?)")
                  wid (if (jtruthy name) name url) url events now now)
                (hasheq 'response (format "Added webhook '~a'" (if (jtruthy name) name url))
                        'exit_code 0)])])]
         [("delete")
          (define wid (or (jget args 'webhook_id) ""))
          (define r (query-maybe-row conn "SELECT name FROM webhooks WHERE id = ?" wid))
          (cond
            [(not r) (err (format "Webhook ~a not found" wid))]
            [else (query-exec conn "DELETE FROM webhooks WHERE id = ?" wid)
                  (hasheq 'response (format "Deleted webhook '~a'" (sql-or-null (vector-ref r 0)))
                          'exit_code 0)])]
         [("enable" "disable")
          (define wid (or (jget args 'webhook_id) ""))
          (define r (query-maybe-row conn "SELECT name FROM webhooks WHERE id = ?" wid))
          (cond
            [(not r) (err (format "Webhook ~a not found" wid))]
            [else
             (query-exec conn "UPDATE webhooks SET is_active = ?, updated_at = ? WHERE id = ?"
                         (if (equal? action "enable") 1 0) (now-stamp) wid)
             (hasheq 'response (format "Webhook '~a' ~ad" (sql-or-null (vector-ref r 0)) action)
                     'exit_code 0)])]
         [else (err (format "Unknown action: ~a" action))]))]))

;; racket error messages carry a "who: " prefix; Python's ValueError text doesn't
(define (strip-who msg)
  (define m (regexp-match #px"^[^\\s:]+: (.*)$" msg))
  (if m (cadr m) msg))

;; ---- manage_tokens -------------------------------------------------------------

(define (manage-tokens conn content #:owner [owner #f])
  (define args (parse-args content))
  (cond
    [(eq? args 'bad) (err "Invalid JSON arguments")]
    [else
     (define action (or (jget args 'action) "list"))
     (with-handlers ([exn:fail? (lambda (e) (err (exn-message e)))])
       (case action
         [("list")
          (define items
            (for/list ([r (in-list (query-rows conn
                            "SELECT id, name, token_prefix, is_active FROM api_tokens"))])
              (hasheq 'id (vector-ref r 0) 'name (sql-or-null (vector-ref r 1))
                      'token_prefix (string-append (or (sql-or-empty (vector-ref r 2)) "") "...")
                      'is_active (sql->bool (vector-ref r 3)))))
          (hasheq 'response (format "~a API tokens" (length items)) 'tokens items 'exit_code 0)]
         [("create")
          ;; bcrypt-hashed tokens are how app.py authenticates; without bcrypt a
          ;; token minted here would never verify. Refuse with directions.
          (err (string-append "Token creation requires bcrypt hashing, which this adapter"
                              " doesn't have — create tokens via the web UI (Settings → API"
                              " Tokens) or the Python API"))]
         [("delete")
          (define tid (or (jget args 'token_id) ""))
          (define r (query-maybe-row conn "SELECT name FROM api_tokens WHERE id = ?" tid))
          (cond
            [(not r) (err (format "Token ~a not found" tid))]
            [else (query-exec conn "DELETE FROM api_tokens WHERE id = ?" tid)
                  (hasheq 'response (format "Deleted token '~a'" (sql-or-null (vector-ref r 0)))
                          'exit_code 0)])]
         [else (err (format "Unknown action: ~a" action))]))]))
