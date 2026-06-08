#lang racket/base

;; odysseus-mcp — MCP server *config* in the `mcp_servers` table (raw SQL via db-kit).
;; Faithful Racket port of scripts/odysseus-mcp. Manages config only; live
;; connection state lives in the running app's McpManager.
;;
;;   odysseus-mcp list
;;   odysseus-mcp show SERVER_ID [--reveal]
;;   odysseus-mcp enable|disable SERVER_ID
;;   odysseus-mcp add --name N [--transport stdio|sse] [--command C]
;;                    [--args '[...]'] [--env '{...}'] [--url U] [--disabled]
;;   odysseus-mcp delete SERVER_ID

(require db
         json
         racket/string
         cli-kit
         db-kit
         "../config.rkt")

(define cols "id,name,transport,command,args,env,url,is_enabled,oauth_config,created_at")

(define (json-list raw)
  (cond [(or (sql-null? raw) (not (string? raw)) (string=? raw "")) '()]
        [else (with-handlers ([exn:fail? (lambda (_) '())])
                (define v (string->jsexpr raw)) (if (list? v) v '()))]))
(define (json-obj raw)
  (cond [(or (sql-null? raw) (not (string? raw)) (string=? raw "")) (hasheq)]
        [else (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                (define v (string->jsexpr raw)) (if (hash? v) v (hasheq)))]))

;; env values redacted to "***" (or "" if falsy) unless reveal? is #t
(define (redact-env env reveal?)
  (if reveal? env
      (for/hasheq ([(k v) (in-hash env)])
        (values k (if (and v (not (eq? v 'null)) (not (equal? v ""))) "***" "")))))

(define (serialize r #:reveal? [reveal? #f])
  (hasheq 'id          (vector-ref r 0)
          'name        (vector-ref r 1)
          'transport   (vector-ref r 2)
          'command     (sql-or-empty (vector-ref r 3))
          'args        (json-list (vector-ref r 4))
          'env         (redact-env (json-obj (vector-ref r 5)) reveal?)
          'url         (sql-or-empty (vector-ref r 6))
          'is_enabled  (sql->bool (vector-ref r 7))
          'has_oauth   (let ([o (vector-ref r 8)]) (and (not (sql-null? o)) (not (equal? o ""))))
          'created_at  (sqlite-datetime->iso (vector-ref r 9))))

(define (fetch id)
  (call-with-app-db #:mode 'read-only
    (lambda (c)
      (define rs (query-rows c (string-append "SELECT " cols " FROM mcp_servers WHERE id = ?") id))
      (and (pair? rs) (car rs)))))

;; ---- subcommands -----------------------------------------------------------

(define (cmd-list pretty?)
  (define rows (call-with-app-db #:mode 'read-only
                 (lambda (c) (query-rows c (string-append "SELECT " cols " FROM mcp_servers ORDER BY name ASC")))))
  (emit (map serialize rows) #:pretty? pretty?))

(define (cmd-show id reveal? pretty?)
  (define r (fetch id))
  (unless r (fail (format "no MCP server with id ~s" id)))
  (emit (serialize r #:reveal? reveal?) #:pretty? pretty?))

(define (set-enabled id enabled? pretty?)
  (call-with-app-db
   (lambda (c)
     (unless (pair? (query-rows c "SELECT 1 FROM mcp_servers WHERE id = ? LIMIT 1" id))
       (fail (format "no MCP server with id ~s" id)))
     (query-exec c "UPDATE mcp_servers SET is_enabled = ? WHERE id = ?" (if enabled? 1 0) id)))
  (emit (hasheq 'ok #t 'id id 'is_enabled enabled?) #:pretty? pretty?))

(define (cmd-add name transport command args-str env-str url disabled? pretty?)
  (when (and (string=? transport "stdio") (not command)) (fail "--command is required for stdio transport"))
  (when (and (string=? transport "sse") (not url)) (fail "--url is required for sse transport"))
  (define args-arr
    (if args-str
        (with-handlers ([exn:fail? (lambda (e) (fail (format "invalid --args: ~a" (exn-message e))))])
          (define v (string->jsexpr args-str)) (unless (list? v) (fail "--args must be a JSON array")) v)
        '()))
  (define env-obj
    (if env-str
        (with-handlers ([exn:fail? (lambda (e) (fail (format "invalid --env: ~a" (exn-message e))))])
          (define v (string->jsexpr env-str)) (unless (hash? v) (fail "--env must be a JSON object")) v)
        (hasheq)))
  (define id (uuid))
  (call-with-app-db
   (lambda (c)
     (query-exec c
       (string-append "INSERT INTO mcp_servers (id,name,transport,command,args,env,url,is_enabled) "
                      "VALUES (?,?,?,?,?,?,?,?)")
       id name transport
       (if command command sql-null)
       (if (pair? args-arr) (jsexpr->string args-arr) sql-null)
       (if (positive? (hash-count env-obj)) (jsexpr->string env-obj) sql-null)
       (if url url sql-null)
       (if disabled? 0 1))))
  (cmd-show id #f pretty?))

(define (cmd-delete id pretty?)
  (define snap
    (call-with-app-db
     (lambda (c)
       (define rs (query-rows c (string-append "SELECT " cols " FROM mcp_servers WHERE id = ?") id))
       (unless (pair? rs) (fail (format "no MCP server with id ~s" id)))
       (define s (serialize (car rs)))
       (query-exec c "DELETE FROM mcp_servers WHERE id = ?" id)
       s)))
  (emit (hasheq 'ok #t 'deleted snap) #:pretty? pretty?))

(define (uuid)
  (define (hx n) (apply string-append (for/list ([_ (in-range n)]) (number->string (random 16) 16))))
  (format "~a-~a-4~a-~a~a-~a" (hx 8) (hx 4) (hx 3)
          (list-ref '("8" "9" "a" "b") (random 4)) (hx 3) (hx 12)))

;; ---- arg parsing -----------------------------------------------------------
(define (opt args flag)
  (let loop ([xs args]) (cond [(null? xs) #f]
                              [(and (string=? (car xs) flag) (pair? (cdr xs))) (cadr xs)]
                              [else (loop (cdr xs))])))
(define (has? args flag) (and (member flag args) #t))

(define (dispatch)
  (define args (vector->list (current-command-line-arguments)))
  (define pretty? (pretty-from-args? args))
  (define rest (filter (lambda (a) (not (string=? a "--pretty"))) args))
  (when (null? rest) (fail "missing subcommand: list|show|enable|disable|add|delete" #:code 2))
  (define cmd (car rest)) (define a (cdr rest))
  (case cmd
    [("list") (cmd-list pretty?)]
    [("show") (when (null? a) (fail "show needs a SERVER_ID" #:code 2)) (cmd-show (car a) (has? a "--reveal") pretty?)]
    [("enable") (when (null? a) (fail "enable needs a SERVER_ID" #:code 2)) (set-enabled (car a) #t pretty?)]
    [("disable") (when (null? a) (fail "disable needs a SERVER_ID" #:code 2)) (set-enabled (car a) #f pretty?)]
    [("add")
     (define name (opt a "--name")) (unless name (fail "add needs --name" #:code 2))
     (cmd-add name (or (opt a "--transport") "stdio") (opt a "--command")
              (opt a "--args") (opt a "--env") (opt a "--url") (has? a "--disabled") pretty?)]
    [("delete") (when (null? a) (fail "delete needs a SERVER_ID" #:code 2)) (cmd-delete (car a) pretty?)]
    [else (fail (format "unknown subcommand: ~a" cmd) #:code 2)]))

(module+ main
  (run "odysseus-mcp" app-version dispatch))
